# guard-spec

A small executable model of a *tool-call guard* for AI coding agents, and
the counterexamples it produces when the guard is built from three ordinary
optimisations: a semantic verdict cache, fail-open on model timeout, and
retries. Each counterexample is pinned as a Quint test, exported as an ITF
trace, and replayed against an unmodified real implementation through its
public interface.

The judgment model itself is out of scope. The model treats it as an oracle
that may answer anything, and asks whether the guard around it is safe for
every answer.

## Results in one screen

Five paths let an irreversible action run without a fresh judgment or a
human, in a guard that has all three optimisations:

| # | Path | Pinned test | Replayed against |
|---|---|---|---|
| 1 | A safe call's Allow is cached under its intent class; a dangerous call in the same class is served from it | `guard_vuln::intentLeakTest` | construct-auto-classifier (`sudo rm -rf build` after `rm -rf build`) |
| 2 | Two timeouts end in fail-open; the action runs | `guard_vuln::failOpenTest` | jev-engineering (`guard` mode exits 0 on an unreachable model) |
| 3 | An Allow obtained in one context survives a context switch; the same call, now irreversible, is served from cache | `guard_vuln::contextLeakTest` | construct-auto-classifier (`rm -rf build` in a prod cwd after a sandbox cwd) |
| 4 | A late answer to an earlier, timed-out request is applied to a later proposal | `guard_vuln::staleAnswerTest` | model only; no surveyed implementation has this shape |
| 5 | The late answer of path 4 is also written to the cache under the later proposal's key and served a third time | `guard_vuln::stalePollutesCacheTest` | model only; not in the original hypothesis list |

Which fix closes which path (`just fix-matrix`, random simulation, 5000
traces of up to 14 steps):

| module | fixes | CE1 intent | CE2 fail-open | CE3 context | CE4 stale | safety |
|---|---|---|---|---|---|---|
| guard_vuln | none | open | open | open | open | open |
| guard_fix1 | key by (id, ctx) | closed | open | closed | open | open |
| guard_fix2 | never cache irreversible | closed | open | closed | open | open |
| guard_fix3 | fail closed | open | closed | open | open | open |
| guard_fix4 | check request id | open | open | open | closed | open |
| guard_fix12 | 1+2 | closed | open | closed | open | open |
| guard_fix123 | 1+2+3 | closed | closed | closed | open | open |
| guard_fixed | 1+2+3+4 | closed | closed | closed | closed | closed |

`guard_fixed` has no violation of `safety` in an exhaustive search to depth 15
with Apalache, and can still execute a reversible action on the oracle's
Allow (the over-blocking check). See `docs/findings.md` for the numbers and
the trade-offs.

One more thing the model caught: the cheapest fix for the real guard, keying
the cache by (command, cwd), closes both replayed paths but still lets an
irreversible call repeat from cache inside the window. The model keeps two
invariants apart for exactly this, `provenance` (no cross-call reuse) and
`safety` (irreversible calls are judged every time), and the instance file
has a module for each.

## Layout

```
specs/
  guard.qnt                      generic, parametric model
  guard_vuln.qnt                 all optimisations on; five pinned counterexamples
  guard_fixed.qnt                the four fixes, plus one-fix-at-a-time modules
  construct_auto_classifier.qnt  instance with that implementation's parameters
  jev_engineering.qnt            instance for guard and enforce modes
traces/                          ITF traces of every pinned test, plus one random violation
replay/
  setup.sh                       clones the two targets at the surveyed commits
  itf.ts, jev-engineering/itf.py ITF readers: trace -> sequence of tool calls
  construct-auto-classifier/     bun test driving the real agy hook
  jev-engineering/               unittest driving the real PreToolUse hook
scripts/fix-matrix.sh            the table above
docs/
  survey.md                      twelve implementations read at source level, with flow diagrams
  abstraction.md                 model <-> implementation mapping tables
  findings.md                    counterexamples, fixes, trade-offs, what the model cannot see
  article.md                     write-up
  issues/                        issue drafts for upstream
```

## Running it

Versions used: quint 0.32.0 (Apalache 0.56.1 downloaded by `quint verify`),
JDK 17 for `verify`, bun 1.3 and Python 3.12+ for the replays, `just` for
the recipes.

```sh
just quint-red      # find a violation in the vulnerable guard; non-zero exit is the expected result
just quint-check    # typecheck, pinned counterexamples, random exploration of the fixed guards, over-blocking check
just quint-verify   # exhaustive check of the fixed guards (MAX_STEPS=12 by default)
just fix-matrix     # which single fix closes which path
just traces         # regenerate traces/*.itf.json
just replay         # clone the pinned targets and replay the traces against them
```

## Checking your own guard

Instantiate the model with your parameters and run the same checks:

```quint
module my_guard {
  import guard(
    TTL = 3,                   // cache lifetime in ticks; 0 = no cache
    MAX_RETRY = 1,
    FAIL_OPEN = true,          // what a final timeout does
    CACHE_BY_INTENT = true,    // key = similarity class (true) or exact call + context (false)
    CACHE_IRREVERSIBLE = true, // may an irreversible call be served from cache
    CHECK_REQ_ID = false,      // are answers matched to the request they answer
    ACTIONS = Set({ id: "a", intent: "x" }, { id: "b", intent: "x" }),
    CTXS = Set("dev", "prod"),
    IRREVERSIBLE = Set(("b", "dev"), ("b", "prod"), ("a", "prod")),
    INITIAL_CTX = "dev"
  ).* from "./guard"
}
```

```sh
quint run --main my_guard --invariant safety --max-steps 12 specs/my_guard.qnt
```

A violation prints the trace. `intent` is whatever your cache keys on; the
model does not judge similarity, it only asks what reuse across a class
costs.

## Scope and honesty

- The survey (`docs/survey.md`) records what the code did at the commits
  listed there, on 2026-09-23. Everything in that list is days old; expect
  drift.
- The pinned counterexamples were written knowing what we were looking for.
  The model's contribution is the fix matrix, the fifth path, and the claim
  "no violation to depth N", not the discovery of paths 1 to 3.
- The replays use public interfaces and documented environment variables
  only. Nothing in the targets is patched.
- Path 4 was not found in any implementation we read. It is reported as a
  model-level result.
- Upstream issues are filed before publication; see `docs/issues/`.

## License

Apache-2.0.
