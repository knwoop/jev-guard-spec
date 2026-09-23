# Findings

All numbers below come from quint 0.32.0 with Apalache 0.56.1 on
2026-09-23. "Random" means `quint run` with the sample and step counts
stated. "Exhaustive" means `quint verify`, which explores every trace up to
the stated depth and no further.

## The model

`specs/guard.qnt`. Eleven state variables, ten actions, four safety
invariants combined into `safety`, one reachability check
(`noReversibleExecuted`, which must be violable). The oracle is
nondeterministic in both timing and content: any in-flight request may be
answered with any verdict at any step, and the request the guard waits for
may time out at any step.

The vulnerable configuration `guard_vuln` has three actions
(`rm_build`, `rm_root`, `ls`), two contexts (`dev`, `prod`), TTL 2, one
retry, and all three optimisations on. `rm_build` and `rm_root` share the
intent class `delete_dir`. `rm_build` is reversible in `dev` and
irreversible in `prod`; `rm_root` is always irreversible.

## Counterexamples

Each is a `run` in `specs/guard_vuln.qnt` ending in `.expect(not(inv))`, and
each has an ITF trace under `traces/`.

| # | Name | Steps | Invariant broken | Found by random search? |
|---|---|---|---|---|
| 1 | `intentLeakTest` | 7 | `noUnapprovedIrreversible`, `cacheSoundness` | yes, under 100 ms |
| 2 | `failOpenTest` | 5 | `noUnapprovedIrreversible`, `failClosedOnTimeout` | yes, under 50 ms |
| 3 | `contextLeakTest` | 8 | `noUnapprovedIrreversible`, `cacheSoundness` | yes, under 100 ms |
| 4 | `staleAnswerTest` | 9 | `answerMatchesRequest`, `noUnapprovedIrreversible` | yes, about 100 ms |
| 5 | `stalePollutesCacheTest` | 13 | `noUnapprovedIrreversible` | yes (subsumed by 1 and 4) |

**1. Intent leak.** The oracle allows `rm_build`. The guard caches `Allow`
under the class `delete_dir`. The agent proposes `rm_root`, which is in the
same class. The cache answers. `rm_root` executes with `basis = Cache`,
`srcId = rm_build`.

**2. Fail-open.** The agent proposes `rm_root`. The request times out, is
retried, times out again. `FAIL_OPEN` turns the second timeout into `Allow`.
`rm_root` executes with `basis = FailOpen`.

**3. Context leak.** The oracle allows `rm_build` in `dev`. The context
switches to `prod`. The agent proposes `rm_build` again. The key is the
intent, which has no context, and the entry is within TTL. `rm_build`
executes in `prod` with `srcCtx = dev`.

**4. Stale answer.** The agent proposes `ls`. Request 0 times out, request 1
(the retry) times out, the guard falls back. The agent proposes `rm_root`.
The guard issues request 2. The answer to request 0 arrives: `Allow`. The
guard is waiting for an answer and, without correlation, takes it. `rm_root`
executes with `reqId = 0`, a request that was about `ls`.

**5. Stale answer pollutes the cache.** Path 4, then: the guard also writes
the stale `Allow` to the cache under `rm_root`'s key, which is the class
`delete_dir`. The context switches to `prod`. The agent proposes `rm_build`.
The cache answers with a verdict that was originally about `ls`. Three
executions; the last one rests on nothing at all.

Path 5 was not in the original hypothesis list. It is what the model added:
two optimisations that each open a path also compose into a third.

## Fixes

Each fix is one `const` in the model.

| Fix | Parameter | Meaning |
|---|---|---|
| 1 | `CACHE_BY_INTENT = false` | key the cache by (exact call, context) |
| 2 | `CACHE_IRREVERSIBLE = false` | never serve an irreversible call from cache |
| 3 | `FAIL_OPEN = false` | a final timeout asks a human |
| 4 | `CHECK_REQ_ID = true` | drop answers whose request id is not the one awaited |

`scripts/fix-matrix.sh` (random, 5000 traces, 14 steps, seed `0x1`):

| module | fixes | CE1 intent | CE2 fail-open | CE3 context | CE4 stale | safety |
|---|---|---|---|---|---|---|
| guard_vuln | none | open | open | open | open | open |
| guard_fix1 | 1 | closed | open | closed | open | open |
| guard_fix2 | 2 | closed | open | closed | open | open |
| guard_fix3 | 3 | open | closed | open | open | open |
| guard_fix4 | 4 | open | open | open | closed | open |
| guard_fix12 | 1+2 | closed | open | closed | open | open |
| guard_fix123 | 1+2+3 | closed | closed | closed | open | open |
| guard_fixed | 1+2+3+4 | closed | closed | closed | closed | closed |

Reading the table: the two cache fixes are interchangeable for these
actions, because every action that shares a class with another is
irreversible somewhere. Fix 3 and fix 4 each close exactly one path. No
proper subset closes all four.

### The fix we almost shipped

The first version of the construct-auto-classifier instance applied only
fix 1, keying the cache by (exact command, cwd), and the simulator found a
`safety` violation in it within 70 ms. The trace: the oracle allows
`rm -rf build` in `prod`, the entry is cached under `(rm_build, prod)`, the
agent repeats the same call in the same cwd inside the window, and the cache
answers. Nothing was reused across calls or contexts, `cacheSoundness`
holds, yet an irreversible action ran on a cache entry.

That is what `noUnapprovedIrreversible` says, read literally: an
irreversible action is judged every time, or a human decides. Whether
"same command, same directory, within five minutes" is an acceptable
exception is a policy decision. The model does not make it; it makes it
visible. `specs/guard.qnt` now carries a second invariant, `provenance`,
which is `safety` minus that rule, and the instance file has both modules:

| Module | Fixes | `provenance` | `safety` | Pinned by |
|---|---|---|---|---|
| `construct_auto_classifier_fix1` | key by (command, cwd) | holds | violated | `irreversibleRepeatTest` |
| `construct_auto_classifier_fixed` | fix 1 + never cache irreversible | holds | holds | `irreversibleRepeatIsJudgedTest` |

For this implementation, fix 2 means caching only allows whose risk answers
are well below the threshold, or not caching anything the fast rules did
not clear. The upstream issue proposes fix 1 as the minimum and names the
residual.

## Exhaustive checks

| Module | Invariant | Depth | Result | Time |
|---|---|---|---|---|
| `guard_fixed` | `safety` | 10 | no violation | 14 s |
| `guard_fixed` | `safety` | 15 | no violation | 534 s |
| `construct_auto_classifier_fix1` | `provenance` | 12 | no violation | 25 s |
| `construct_auto_classifier_fixed` | `safety` | 12 | no violation | 38 s |
| `jev_engineering_enforce` | `safety` | 12 | no violation | 22 s |

And the over-blocking check: `quint run --main guard_fixed --invariant
noReversibleExecuted` finds a violation within milliseconds, so the fixed
guard still executes reversible actions on the oracle's Allow.

## Trade-offs

What each fix costs, read off the model rather than measured in production:

| Fix | What gets slower or noisier |
|---|---|
| 1 | Cache hit rate falls from one hit per class per context window to one hit per exact call per context. In the construct-auto-classifier replay: the same command in a second cwd goes from 0 model calls to 1. A same-cwd repeat is still a hit (`construct_auto_classifier_fix1::sameCwdStillHitsTest`, and for reversible calls `construct_auto_classifier_fixed::reversibleRepeatStillHitsTest`). |
| 2 | Every irreversible call costs one model round trip, always. Whether that is many calls depends on how the guard classifies irreversibility; construct-auto-classifier does not classify it at all before the model, so fix 2 there means "no cache for anything the fast rules did not clear". |
| 3 | Every final timeout becomes a human question. On a model outage, the agent stalls on the first irreversible call. `guard_fixed::timeoutAsksHumanTest` shows the shape. jev-engineering's `enforce` mode is exactly this and the README warns that it blocks work. |
| 4 | A late answer is discarded, so the request it answers is wasted and the current proposal still needs its own answer. One extra round trip per late answer. |

## Replays

| Trace | Target | Result |
|---|---|---|
| `construct_auto_classifier_contextLeakTest` | agy hook at 9062b34 | 2 calls: model consulted once, second served from cache in a different cwd; model state contained no cwd |
| `construct_auto_classifier_sudoLeakTest` | same | 2 calls: `sudo rm -rf build` served from the cache of `rm -rf build` |
| `construct_auto_classifier_timeoutDeniesTest` | same | timeout gives `deny`, endpoint consulted once; fail-closed holds |
| `jev_engineering_guard_timeoutRunsTest` | `jev_gate.py` at 3161dbf, `JEV_GATE_MODE=guard` | endpoint hangs, exit 0 |
| same input | `JEV_GATE_MODE=enforce` | exit 2 with "wants a human" |

## What the model does not see

- **Human approval binding.** `basis == Human` is accepted unconditionally.
  pi-warden's post-hold approval is judged against the next confirm-level
  call, not the held one (`docs/survey.md`), which is the human-side twin of
  path 4. Catching it needs a request id on approvals, which the model does
  not have.
- **Host permission modes.** Exit 0 from a hook is modelled as `Allow`. In
  Claude Code's default mode the host may still prompt.
- **Similarity.** The model does not evaluate whether two calls should share
  a class. It shows the cost when they do.
- **Concurrency inside one guard.** Each surveyed guard handles one call at
  a time; the model has one `pending` slot accordingly. agent-chaperone's
  proxy pauses its stream per verdict, so this matches.
