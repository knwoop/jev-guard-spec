# Issue draft for godspede/construct-auto-classifier

Status: **draft, not filed**. To be filed before anything in this repository
is published, per the project rule.

---

**Title:** Allow cache serves `sudo …` and other-cwd variants of a previously allowed command without re-judging

**Summary**

`recentAllow` (src/index.ts:164-172) is consulted before the model with a key
from `normalizeCommand` (src/state/state-manager.ts:107-125). That key drops
`sudo`/`doas`, leading `NAME=value` assignments and quotes
(src/rules/command-shape.ts:224-245), and contains no working directory. A
model allow for one command is therefore served, with no fresh judgment, to
commands that the model never saw and that the fast-allow path would itself
refuse.

Reproduced at 9062b34 with the agy hook and a fake System One endpoint, no
code changes, environment variables only.

**Reproduction**

```sh
# fake endpoint that answers "allow" and logs every request
node fake-jev.mjs > port.txt &   # any allow-returning stub on POST /v1/systemone
export TYPESAFE_API_KEY=test TYPESAFE_BASE_URL=http://127.0.0.1:$(cat port.txt)
export AUTO_CLASSIFIER_PROVIDER=jev HOME=$(mktemp -d) XDG_RUNTIME_DIR=$HOME AUTO_CLASSIFIER_LOG=

hook() { printf '%s' "$1" | bun src/cli.ts agy; echo; }

hook '{"conversationId":"s1","toolCall":{"name":"run_command","args":{"CommandLine":"rm -rf build","Cwd":"/work/dev-sandbox"}}}'
# {"decision":"allow","reason":"Jev: allow (p(allow)=0.97 confidence=0.97)"}
#   -> one request to the endpoint, state = {"command":"rm -rf build"}

hook '{"conversationId":"s1","toolCall":{"name":"run_command","args":{"CommandLine":"rm -rf build","Cwd":"/srv/prod"}}}'
# {"decision":"allow","reason":"... (same verdict as earlier in this session)"}
#   -> no request

hook '{"conversationId":"s1","toolCall":{"name":"run_command","args":{"CommandLine":"sudo rm -rf build","Cwd":"/srv/prod"}}}'
# {"decision":"allow","reason":"... (same verdict as earlier in this session)"}
#   -> no request
```

The same key also unifies `PATH=/tmp/x cmd` with `cmd` and
`echo '$(rm -rf /)'` with `echo $(rm -rf /)` (quotes are removed by
`splitWords`). The fast-allow path refuses `PATH=` and `LD_*` prefixes as
"tells" (command-shape.ts:277-280); the cache path does not check tells.

**Why it matters**

The cache is consulted before the model and before the tells check, so it is
the only path on which a privilege escalation or an env-hijacked variant of a
judged command runs with no judgment at all. The model also never receives
the cwd (jev-client.ts:115-129), so "same verdict as earlier in this session"
is true relative to what the model saw, but the thing that decides whether
`rm -rf build` is recoverable is exactly what neither the model nor the key
sees.

**Suggested fixes** (any one closes the reported paths; the first two are
cheapest)

1. Key the allow cache on the exact trimmed command plus `Cwd`, and keep
   `normalizeCommand` only for the denial counter, where a looser key is
   harmless.
2. Do not strip privilege wrappers or env assignments when building the allow
   key; or refuse a cache hit when `analyzeCommand(cmd).tells` is non-empty.
3. Add `cwd` to the state sent to the model, so the judgment itself has the
   context that the key would then carry.

**Checked with a model**

We wrote a small Quint model of the guard's cache, timeout and retry logic
and confirmed that fix 1 removes both reported paths while a same-cwd repeat
is still a cache hit. One residual is worth naming: with fix 1 alone, a
command the model allowed in a given cwd is re-run from cache inside the
five-minute window without being judged again, even if it is destructive
there. If that is not acceptable for your threat model, the additional rule
is to skip `recordAllow` (or skip the lookup) when any risk answer is above
a conservative bar. Details, traces and the replay test:
`<link to guard-spec once published>`.
