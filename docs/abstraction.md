# Abstraction: how the model maps to the implementations

The model in `specs/guard.qnt` keeps only the state that the safety
properties depend on. This document records what each model element stands
for in the two implementations that the traces are replayed against, and
what was deliberately left out.

## The principle

A semantic cache is a function from concrete calls to equivalence classes.
The model does not compute similarity. It takes the class as given: every
action carries an `intent`, and two actions with the same `intent` are, by
definition, what the cache treats as "the same". This is the only honest way
to model a judgment we do not control. The question the model asks is not
"is the cache's similarity function good" but "is it safe to reuse a verdict
across a class at all, given what the class does and does not contain".

The oracle is the same kind of abstraction. It returns any verdict at any
time. Nothing in the model depends on the oracle being right, so nothing the
model finds depends on the judgment model's calibration.

## Generic model to construct-auto-classifier

Commit `9062b340f5b57e917245431dd7189b626c44c869`, agy hook adapter.

| Model | Implementation | Where |
|---|---|---|
| `Action.id` | the literal `CommandLine` of the tool call | `src/adapters/agy.ts:204` |
| `Action.intent` | `normalizeCommand(cmd)`: the key of `recentAllows`. Drops `sudo`, `doas`, leading `NAME=value`, quotes, `2>&1`, trailing output shapers; flattens separators | `src/state/state-manager.ts:107-125`, `src/rules/command-shape.ts:224-245` |
| `ctx` | the working directory `Cwd` of the tool call. Not in the key; not in the state sent to the model | `agy.ts:227`, `src/classifier/jev-client.ts:115-129` |
| `IRREVERSIBLE` | whether `rm -rf build` destroys something that matters in that cwd. The model treats a sandbox as recoverable and a production checkout as not. `sudo` is always irreversible for the purpose of the test | judgment of the authors, not of the code |
| `TTL = 5` | `slidingWindowMs = 300 000` (5 minutes) | `src/config.ts:284-285` |
| `MAX_RETRY = 0` | one Jev request per evaluation | `jev-client.ts:172-190` |
| `FAIL_OPEN = false` | transport failure is `{allow: false, source: "error"}` | `jev-client.ts:257-260` |
| `CACHE_BY_INTENT = true` | `recentAllow(sessionId, trimmed, contextKey)` is consulted before the model | `src/index.ts:164-172` |
| `CACHE_IRREVERSIBLE = true` | no danger check on the cache path | same |
| `CHECK_REQ_ID = true` | one process per hook call, one awaited promise | `agy.ts:243-254` |
| `cacheHit` | the branch returning `source: "cache"` with reason `... (same verdict as earlier in this session)` | `src/index.ts:165-171` |
| `askOracle` + `answer` | `llmClient.classify` and `combine` | `jev-client.ts:131-168` |
| `oracleTimeout` | AbortController at `jev.timeoutMs` | `jev-client.ts:174-187` |
| `resolve` with `Allow` | hook prints `{"decision":"allow"}`; agy runs the command | `agy.ts:229-233` |
| `Ask` / `Block` | `deny` on the first attempt, `force_ask` on the second identical attempt within the window | `src/index.ts:208-276` |
| `humanApprove` | the operator answers agy's own prompt after `force_ask`. Not remembered by the hook | outside the repository |
| `switchCtx` | the agent's next tool call carries a different `Cwd` | replay input |
| `advanceTime` | wall clock; one tick is 60 s | `state-manager.ts:172-176` |

Replay values (`replay/construct-auto-classifier/replay.test.ts`):

| Model | Replay |
|---|---|
| `rm_build` | `rm -rf build` |
| `sudo_rm_build` | `sudo rm -rf build` |
| `ls` | `ls` |
| `dev-sandbox` | `Cwd: /work/dev-sandbox` |
| `prod` | `Cwd: /srv/prod` |
| `answer(r, Allow)` | fake endpoint returns `verdict: allow`, all nine risk nouls 0.01 |
| `answer(r, Block)` | fake endpoint returns `verdict: deny`, risk nouls 0.95 |
| `oracleTimeout` | fake endpoint never responds; `jev.timeoutMs` set to 1500 in a temporary config file |
| `basis == Cache` | fake endpoint is programmed to `deny` and is asserted to receive zero calls |

What is left out: the fast-allow rules, the script-provenance check, the
denial counter (collapsed into `Ask`), the OpenCode adapter, and file-write
tools. None of them touch the allow cache.

Fix modules in the same file:

| Module | Model change | Implementation change it stands for |
|---|---|---|
| `construct_auto_classifier_fix1` | `CACHE_BY_INTENT = false` | `allowKey` built from the trimmed command plus `Cwd`; no `sudo` or env stripping for the allow key |
| `construct_auto_classifier_fixed` | fix 1 plus `CACHE_IRREVERSIBLE = false` | additionally skip `recordAllow` (or the lookup) when any risk noul is above a conservative bar |

## Generic model to jev-engineering

Commit `3161dbfb44f21bafa2ec7940ec18cfb090c7b43d`, Claude Code PreToolUse hook.

| Model | Implementation | Where |
|---|---|---|
| `Action.id` | the `command` of the tool input | `jev_gate.py:229-235` |
| `Action.intent` | unused: `TTL = 0`, there is no cache | |
| `ctx` | one context `repo`; the hook has no cross-call state | |
| `MAX_RETRY = 0` | one `urllib` request | `jev_gate.py:108-123` |
| `FAIL_OPEN = true` (`guard` mode) | any `HTTPError`, `URLError`, `TimeoutError`, `ValueError` returns `None`, which becomes `ask`, which exits 0 | `jev_gate.py:121-123, 141-142, 263-271` |
| `FAIL_OPEN = false` (`enforce` mode) | the same `ask` exits 2 | `jev_gate.py:268-270` |
| `resolve` with `Allow` on basis `FailOpen` | exit 0: the hook does not block. Whether Claude Code then prompts depends on its own permission mode, which is outside the guard | |
| `humanApprove` / `humanDeny` | exit 2 hands the decision back; the model then sees the stderr text | |

Replay values (`replay/jev-engineering/test_replay.py`):

| Model | Replay |
|---|---|
| `rm_data` | `rm -rf ./data` (not matched by any `hard_deny` or `fast_path` regex) |
| `ls` | `ls` (fast path; sanity only) |
| `oracleTimeout` | fake endpoint sleeps 5 s; `JEV_GATE_TIMEOUT=1` |
| `FAIL_OPEN = true` | `JEV_GATE_MODE=guard`, assert exit 0 |
| `FAIL_OPEN = false` | `JEV_GATE_MODE=enforce`, assert exit 2 |

What is left out: the policy layering, the threshold mapping of a successful
answer, `observe` mode (which exits 0 unconditionally and is therefore not a
guard at all).

## What the model cannot see

- **Approval binding.** The invariant treats `basis == Human` as sufficient.
  A guard whose human approval is not bound to the held call (pi-warden's
  post-hold approval, see `docs/survey.md`) satisfies the invariant while
  having the same shape of problem as a stale oracle answer. Modelling that
  would need a `Human` request id, which is a small extension we did not
  make.
- **The host's own permission flow.** For hook-based guards, "the guard did
  not block" and "the action ran" are the same only when the host would run
  it. We model exit 0 as `Allow` because in bypass and auto-approve modes it
  is.
- **Similarity quality.** The model never asks whether `rm -rf build` and
  `sudo rm -rf build` should be the same intent. It asks what happens if they
  are.
