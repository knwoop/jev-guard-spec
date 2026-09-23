# guard-spec task runner. Requires: quint 0.32.0, JDK 17+ (verify), bun (replay), python3 (replay).

quint := "quint"
max_steps := env_var_or_default("MAX_STEPS", "12")

default:
    @just --list

# Typecheck every spec.
typecheck:
    {{quint}} typecheck specs/guard.qnt
    {{quint}} typecheck specs/guard_vuln.qnt
    {{quint}} typecheck specs/guard_fixed.qnt
    {{quint}} typecheck specs/construct_auto_classifier.qnt
    {{quint}} typecheck specs/jev_engineering.qnt

# Find a violation in the vulnerable guard. quint exits non-zero, which is the expected result here.
quint-red:
    {{quint}} run --main guard_vuln --invariant safety --max-steps {{max_steps}} --max-samples 3000 specs/guard_vuln.qnt

# Same as quint-red but exits 0 when the violation is found, for CI.
quint-red-expected:
    ./scripts/expect-violation.sh --main guard_vuln --invariant safety --max-steps {{max_steps}} --max-samples 3000 specs/guard_vuln.qnt

# Pinned counterexamples, typecheck, random exploration of the fixed guards, and the reachability check.
quint-check: typecheck
    {{quint}} test --main guard_vuln --match ".*Test" specs/guard_vuln.qnt
    {{quint}} test --main guard_fixed --match ".*Test" specs/guard_fixed.qnt
    {{quint}} test --main construct_auto_classifier --match ".*Test" specs/construct_auto_classifier.qnt
    {{quint}} test --main construct_auto_classifier_fix1 --match ".*Test" specs/construct_auto_classifier.qnt
    {{quint}} test --main construct_auto_classifier_fixed --match ".*Test" specs/construct_auto_classifier.qnt
    {{quint}} test --main jev_engineering_guard --match ".*Test" specs/jev_engineering.qnt
    {{quint}} test --main jev_engineering_enforce --match ".*Test" specs/jev_engineering.qnt
    {{quint}} run --main guard_fixed --invariant safety --max-steps 15 --max-samples 5000 specs/guard_fixed.qnt
    # The key-only fix keeps provenance (no cross-call reuse) but not full safety; see README.md.
    {{quint}} run --main construct_auto_classifier_fix1 --invariant provenance --max-steps 15 --max-samples 5000 specs/construct_auto_classifier.qnt
    ./scripts/expect-violation.sh --main construct_auto_classifier_fix1 --invariant safety --max-steps 15 --max-samples 5000 specs/construct_auto_classifier.qnt
    {{quint}} run --main construct_auto_classifier_fixed --invariant safety --max-steps 15 --max-samples 5000 specs/construct_auto_classifier.qnt
    {{quint}} run --main jev_engineering_enforce --invariant safety --max-steps 15 --max-samples 5000 specs/jev_engineering.qnt
    # Over-blocking check: the fixed guard must still be able to run a reversible action.
    ./scripts/expect-violation.sh --main guard_fixed --invariant noReversibleExecuted --max-steps 10 --max-samples 3000 specs/guard_fixed.qnt

# Exhaustive check of the fixed guards with Apalache (needs JDK 17+).
quint-verify:
    {{quint}} verify --main guard_fixed --invariant safety --max-steps {{max_steps}} specs/guard_fixed.qnt
    {{quint}} verify --main construct_auto_classifier_fix1 --invariant provenance --max-steps {{max_steps}} specs/construct_auto_classifier.qnt
    {{quint}} verify --main construct_auto_classifier_fixed --invariant safety --max-steps {{max_steps}} specs/construct_auto_classifier.qnt
    {{quint}} verify --main jev_engineering_enforce --invariant safety --max-steps {{max_steps}} specs/jev_engineering.qnt

# Which single fix closes which path. Prints a Markdown table.
fix-matrix:
    ./scripts/fix-matrix.sh

# Regenerate the ITF traces under traces/.
traces:
    rm -f traces/*.itf.json
    {{quint}} test --main guard_vuln --match ".*Test" --out-itf "traces/guard_vuln_{test}.itf.json" specs/guard_vuln.qnt
    {{quint}} test --main construct_auto_classifier --match ".*Test" --out-itf "traces/construct_auto_classifier_{test}.itf.json" specs/construct_auto_classifier.qnt
    {{quint}} test --main jev_engineering_guard --match ".*Test" --out-itf "traces/jev_engineering_guard_{test}.itf.json" specs/jev_engineering.qnt
    # One violation found by random search, with action labels (--mbt). quint exits non-zero on a violation; that is the point.
    -{{quint}} run --main guard_vuln --invariant safety --max-steps 12 --max-samples 3000 --mbt --out-itf traces/guard_vuln_random_violation.itf.json specs/guard_vuln.qnt > /dev/null

# Clone the pinned targets and replay the traces against their public interfaces.
replay: replay-setup replay-construct-auto-classifier replay-jev-engineering

replay-setup:
    ./replay/setup.sh

replay-construct-auto-classifier:
    # The explicit file keeps bun from also collecting the target's own tests.
    cd replay/construct-auto-classifier && bun test ./replay.test.ts

replay-jev-engineering:
    cd replay/jev-engineering && python3 -m unittest -v

# Everything CI runs.
ci: quint-check replay
