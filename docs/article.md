# Where a tool-call guard leaks: cache, fail-open, retry, and the paths between them

*Draft. Numbers and commits as of 2026-09-23.*

## tl;dr

We modelled a tool-call guard for AI coding agents in Quint, with the
judgment model treated as a black box that may answer anything. Five paths
let an irreversible action run without a fresh judgment or a human:

1. A safe call's Allow is cached under its similarity class; a dangerous call in the same class is served from the cache.
2. Two timeouts end in fail-open; the action runs.
3. An Allow obtained in one working directory survives a directory change; the same call, now irreversible, is served from the cache.
4. A late answer to an earlier, timed-out request is applied to a later proposal.
5. The late answer of path 4 is written to the cache under the later proposal's key and served a third time.

Paths 1 and 3 replay against an unmodified real guard through its public
hook interface: `sudo rm -rf build` and `rm -rf build` in a production
checkout are both served from the cached Allow of `rm -rf build` in a
sandbox, with no model call. Path 2 replays against a second guard whose
`guard` mode exits 0 when the model is unreachable. Path 4 exists in no
implementation we read. Path 5 was not on our list before the model.

Four fixes close the five paths. No proper subset does. The fixed guard has no
violation to depth 15 in an exhaustive search, and still runs reversible
actions.

## The shape every guard shares

There are now dozens of open-source guards that sit between a coding agent
and its tools and ask a small judgment model whether each call should run.
We read twelve of them at source level (the full survey, with file and line
citations and a flow diagram per guard, is in `docs/survey.md`). Under the
differences in harness and question wording they share one loop:

```
tool call arrives
  -> deterministic rules (allowlist, hard deny)
  -> [cache lookup]
  -> ask the model, with a timeout
  -> [retry]
  -> map the answer to allow / ask / block
  -> [on failure: allow or ask]
  -> run, prompt a human, or refuse
```

The bracketed steps are optimisations. Each is defensible on its own:

- **A verdict cache** saves a round trip when the agent repeats itself, which
  agents do constantly. To catch near-repeats, the key is not the exact
  command but a normalised or semantic form: strip the `sudo`, drop the
  pipe to `tail`, ask the model itself whether two requests have the same
  intent.
- **Fail-open** keeps the agent working when the model is slow or down. Of
  the twelve guards, five fail open by default in at least one mode.
- **Retries** absorb transient errors. Meanwhile the agent, which has its
  own timeout, may have moved on to the next call.

What made us suspicious is that the three optimisations have a shared blind
spot. Each of them reuses or fabricates a verdict in a situation where the
thing being judged has changed: a different command, a different directory,
a different request. The question was whether the combinations open a path
that none of them opens alone, and whether that path exists in real code.

## Keeping only the state that matters

The model (`specs/guard.qnt`, about 250 lines) does not model any specific
guard. It models the loop above with every optimisation as a switch.

The first decision was what to do about semantic similarity. A cache that
asks "is this the same intent as an earlier request" is running a judgment
we cannot model and do not want to. So the model does not compute
similarity. Every action carries an `intent`, and two actions with the same
`intent` are, by definition, what the cache treats as equal:

```quint
type Action = { id: str, intent: str }
pure def cacheKey(a: Action, c: str): Key =
  if (CACHE_BY_INTENT) { k: a.intent, c: "" } else { k: a.id, c: c }
```

This turns a question about a similarity function into a question about
reuse: whatever the function is, what does it cost to reuse a verdict across
the class it induces? The answer does not depend on the function being good
or bad.

The second decision was context. A cache key that omits the working
directory is a problem only if the directory changes what the call does. So
irreversibility is a property of the pair (action, context), not of the
action:

```quint
const IRREVERSIBLE: Set[(str, str)]
pure def irreversible(a: Action, c: str): bool = IRREVERSIBLE.contains((a.id, c))
```

`rm -rf build` is recoverable in a sandbox and not in a production checkout.
The model does not decide which directories are which. It takes a table.

The third decision was the oracle. The judgment model is an action that may
fire on any in-flight request with any verdict at any step, and a timeout is
an action that may fire on the awaited request at any step. Timed-out
requests stay in flight, because in the real world the reply may still
arrive:

```quint
action oracleAnswer: bool = all {
  inflight != Set(),
  nondet r = inflight.oneOf()
  nondet v = Set(Allow, Ask, Block).oneOf()
  answer(r, v),
}
```

Everything the model keeps is there because an invariant reads it. The
executed list records, for every execution, what it rested on: the oracle's
answer to a specific request, a cache entry about a specific action and
context, a human, or a fallback. The invariants ask whether that basis was
about the thing that ran:

```quint
val noUnapprovedIrreversible = execs.forall(e =>
  irreversible(e.act, e.ctx) implies
    (e.basis == Human or (e.basis == Oracle and answeredForThis(e))))

val cacheSoundness = execs.forall(e =>
  e.basis == Cache implies (e.srcId == e.act.id and e.srcCtx == e.ctx))
```

What is not in the model: deterministic rules (they never touch the cache or
the timeout), the content of any command, the harness, and any notion of the
model being right. A guard that blocks everything satisfies every invariant,
so there is also a reachability check that must fail: a reversible action
must be able to execute on the oracle's Allow.

## Counterexamples, and the same values in the implementation

`quint run` finds a violation in the vulnerable configuration in tens of
milliseconds. Each path is pinned as a `run` that expects the violation, so
it cannot silently disappear when the model changes.

The interesting question was whether the paths exist in real code. Two of
the twelve guards keep a verdict cache. One of them,
construct-auto-classifier, keys its allow cache on a normalised command that
drops `sudo`, leading environment assignments, and quotes, keeps entries for
five minutes per session on disk, and does not include the working
directory in the key or in the state sent to the model. That is path 1 and
path 3 with real values.

We instantiated the model with its parameters
(`specs/construct_auto_classifier.qnt`), exported the counterexample traces,
and wrote a test that reads each trace and replays it through the guard's
hook interface, using only documented environment variables and a fake
model endpoint that answers what the trace says the oracle answered:

```
construct_auto_classifier_contextLeakTest
  rm_build@dev-sandbox  model=Allow/Oracle  hook=allow  calls=1
  rm_build@prod         model=Allow/Cache   hook=allow  calls=0
construct_auto_classifier_sudoLeakTest
  rm_build@dev-sandbox  model=Allow/Oracle  hook=allow  calls=1
  sudo_rm_build@dev-sandbox  model=Allow/Cache  hook=allow  calls=0
```

`calls` is the number of requests the fake endpoint received. Where the
model says the basis is `Cache`, the fake is programmed to answer `deny`, so
a hidden model call could not pass. The endpoint received the state
`{"command":"rm -rf build"}` and nothing else: the directory that decides
whether the deletion is recoverable is invisible to both the key and the
judgment.

The same guard fails closed on a model timeout, which the third replayed
trace confirms. Path 2 was replayed against a different guard,
jev-engineering, whose `guard` mode turns an unreachable model into `ask`
and `ask` into exit 0. With an endpoint that never answers, the hook exits 0
in `guard` mode and 2 in `enforce` mode, which is the model's `FAIL_OPEN`
switch with real values.

Path 4 needs a guard that keeps a slot for "the answer I am waiting for"
without checking which request the answer belongs to. Every guard we read
awaits a single promise per call or runs one process per call, so the path
does not exist in any of them. We report it as a model-level result. The
nearest thing in real code is a human-side twin: one guard holds a call,
then treats the user's next "ok, go ahead" as approval for whatever
confirm-level call comes next, not for the held one. Our invariant accepts
any human approval unconditionally, so the model cannot see this. That is a
limit of the abstraction, not a finding.

## Fixes and what they cost

Each fix is one parameter. Running the simulator against every single-fix
and multi-fix configuration gives a matrix (`just fix-matrix`):

| fixes | CE1 intent | CE2 fail-open | CE3 context | CE4 stale |
|---|---|---|---|---|
| none | open | open | open | open |
| key by (call, context) | closed | open | closed | open |
| never cache irreversible | closed | open | closed | open |
| fail closed | open | closed | open | open |
| check request id | open | open | open | closed |
| all four | closed | closed | closed | closed |

The two cache fixes are interchangeable here, because in this universe every
call that shares a class with another is irreversible somewhere. Fail-closed
and request correlation each close exactly one path. Nothing short of all
four closes everything, and with all four Apalache finds no violation to
depth 15.

The costs, read off the model:

- **Key by (call, context).** The cache still hits on an exact repeat in
  the same directory (there is a test for that), so the saving the cache was
  built for survives. It stops hitting on `sudo` variants and on directory
  changes, which is the point.
- **Never cache irreversible.** Every irreversible call is a model round
  trip. For a guard that does not classify irreversibility before the model,
  this collapses to "no cache for anything the fast rules did not clear".
- **Fail closed.** Every final timeout is a human question. During an
  outage the agent stalls on its first irreversible call. The guard whose
  `enforce` mode does this warns in its README that it blocks work; the
  warning is accurate.
- **Check request id.** A late answer is discarded, so that request was
  wasted. One extra round trip per late answer.

The first fix is the cheapest and is the one we suggested upstream. It is
also where the model corrected us. Our first "fixed" instance of the real
guard applied only that fix, and the simulator found a violation in it in
70 ms: the oracle allows `rm -rf build` in the production checkout, the
entry is cached under that exact command and directory, and the agent
repeats the call inside the five-minute window. Nothing was reused across
calls or directories. An irreversible action still ran on a cache entry.

Read literally, the invariant says an irreversible action is judged every
time or a human decides. Whether "same command, same directory, five
minutes" deserves an exception is a policy question, and we do not think
the model should answer it. So the model now carries two invariants:
`provenance`, which forbids reuse across calls and contexts, and `safety`,
which also forbids reuse for irreversible calls. The key fix satisfies the
first. The key fix plus "never cache irreversible" satisfies both, at the
cost of a model round trip for every risky repeat. The issue we drafted for upstream
names the minimum and the residual.

## What Quint did, and what it did not do

Honesty about the order of events: the hypotheses came first. We suspected
the cache before we wrote a line of Quint, and the replay against
construct-auto-classifier could have been written from reading its source
alone. Quint did not discover paths 1 to 3.

What it did:

- **It turned a checklist into a checked checklist.** Writing the invariants
  forced us to say what "the verdict was about this action" means, and the
  simulator then found every path we had listed in milliseconds, which is a
  cheap confirmation that the list was not wrong.
- **It found path 5.** Two optimisations we had already blamed individually
  compose into a third path we had not written down. This is the kind of
  thing a human does not enumerate.
- **It produced the fix matrix.** Knowing which fix closes which path, and
  that no three of them suffice, is a mechanical result of flipping
  constants. Doing it by hand would be guesswork.
- **It rejected our first fix.** The key-by-cwd fix looked complete on
  paper. The simulator showed the irreversible-repeat residual before we
  wrote it up as complete.
- **It backed the claim "no violation to depth 15".** That is not a proof
  of anything beyond depth 15, and we do not say it is. It is a stronger
  statement than "we thought about it".
- **It ruled out over-blocking.** The trivial guard passes every safety
  invariant. The reachability check catches that.

What it cost: about 250 lines and an afternoon, including learning that a
record field cannot be named `action`. Random simulation needed no JDK;
exhaustive checking did.

## The general point

Nothing here depends on the judgment model. The oracle in the model may be
perfectly calibrated or answer at random; the five paths exist either way,
because none of them passes through the model's answer to the action that
ran. Each path substitutes something else for that answer: a verdict about a
sibling, a verdict from another directory, a fallback, a reply to a
different question.

That is the pattern to look for in any system that puts a judgment in a hot
path and then optimises around it. The optimisations are where the boundary
between "judged" and "assumed" gets redrawn, and each one redraws it a little
outward. A better model does not move it back. Only the plumbing does.

## Reproduce

```
git clone <repo> && cd guard-spec
just quint-red        # expect a violation
just quint-check      # pinned counterexamples, random exploration, over-blocking check
just fix-matrix
just quint-verify     # JDK 17+
just replay           # bun, python3; clones the two targets at the surveyed commits
```
