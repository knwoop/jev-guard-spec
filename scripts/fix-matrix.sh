#!/usr/bin/env bash
# Prints a Markdown table: for each configuration module, whether the random
# simulator finds each counterexample class within MAX_STEPS steps.
# "open" means a violation was found (the path exists); "closed" means none
# was found in MAX_SAMPLES random traces. This is evidence, not proof; the
# exhaustive check for the fixed configuration is `just quint-verify`.
# Portable to bash 3.2 (macOS): no associative arrays.
set -euo pipefail
cd "$(dirname "$0")/.."

MAX_STEPS="${MAX_STEPS:-14}"
MAX_SAMPLES="${MAX_SAMPLES:-5000}"
SEED="${SEED:-0x1}"

MODULES="guard_vuln guard_fix1 guard_fix2 guard_fix3 guard_fix4 guard_fix12 guard_fix123 guard_fixed"
NAMES="CE1_intent CE2_failopen CE3_context CE4_stale safety"

file_of() {
  case "$1" in
    guard_vuln) echo specs/guard_vuln.qnt ;;
    *) echo specs/guard_fixed.qnt ;;
  esac
}

fixes_of() {
  case "$1" in
    guard_vuln) echo "none" ;;
    guard_fix1) echo "1" ;;
    guard_fix2) echo "2" ;;
    guard_fix3) echo "3" ;;
    guard_fix4) echo "4" ;;
    guard_fix12) echo "1+2" ;;
    guard_fix123) echo "1+2+3" ;;
    guard_fixed) echo "1+2+3+4" ;;
  esac
}

inv_of() {
  case "$1" in
    CE1_intent) echo 'execs.forall(e => not(e.basis == Cache and irreversible(e.act, e.ctx) and e.srcId != e.act.id))' ;;
    CE2_failopen) echo 'execs.forall(e => not(e.basis == FailOpen and irreversible(e.act, e.ctx)))' ;;
    CE3_context) echo 'execs.forall(e => not(e.basis == Cache and e.srcCtx != e.ctx and irreversible(e.act, e.ctx)))' ;;
    CE4_stale) echo 'execs.forall(e => not(e.basis == Oracle and not(answeredForThis(e)) and irreversible(e.act, e.ctx)))' ;;
    safety) echo 'safety' ;;
  esac
}

header="| module | fixes |"
sep="|---|---|"
for n in $NAMES; do header="$header $n |"; sep="$sep---|"; done
echo "$header"
echo "$sep"

for m in $MODULES; do
  row="| $m | $(fixes_of "$m") |"
  for n in $NAMES; do
    if quint run --main "$m" --invariant "$(inv_of "$n")" --max-steps "$MAX_STEPS" \
         --max-samples "$MAX_SAMPLES" --seed "$SEED" "$(file_of "$m")" >/dev/null 2>&1; then
      row="$row closed |"
    else
      row="$row **open** |"
    fi
  done
  echo "$row"
done
