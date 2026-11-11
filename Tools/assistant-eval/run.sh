#!/bin/zsh
# Runs the assistant harness against the on-device model of this Mac.
#
#   Tools/assistant-eval/run.sh unit            # pure helpers, no model
#   Tools/assistant-eval/run.sh tokens          # prompt + tool schema size
#   Tools/assistant-eval/run.sh eval            # graded cases (TRIALS=3, ONLY=0,5,…)
#   Tools/assistant-eval/run.sh chat            # the friend's two conversations
#   Tools/assistant-eval/run.sh chat "turn 1||turn 2"
#   BASELINE_REF=HEAD~1 Tools/assistant-eval/run.sh eval   # score an older commit
#
# Never run two of these at once: concurrent sessions on the model hang.
set -euo pipefail

here=${0:A:h}
repo=${here:h:h}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mode=${1:-eval}

src=$repo
if [[ -n "${BASELINE_REF:-}" ]]; then
  mkdir -p "$work/base/Calarm/Chat"
  for f in AssistantService AssistantTools; do
    git -C "$repo" show "$BASELINE_REF:Calarm/Chat/$f.swift" > "$work/base/Calarm/Chat/$f.swift"
  done
  src=$work/base
  export BASELINE=1
fi

python3 -I "$here/gen.py" "$src" "$work/harness.swift" "$here/driver.swift" \
  "$repo/Calarm/Chat/AssistantService.swift" > /dev/null
swiftc -O -o "$work/harness" "$work/harness.swift"

case $mode in
  unit)   export HARNESS_UNIT=1 ;;
  tokens) export HARNESS_TOKENS=1 ;;
  eval)   export HARNESS_EVAL=1 HARNESS_TRIALS=${TRIALS:-3}; [[ -n "${ONLY:-}" ]] && export HARNESS_ONLY=$ONLY ;;
  chat)   export HARNESS_TRIALS=${TRIALS:-2}; [[ -n "${2:-}" ]] && export HARNESS_TURNS=$2 ;;
  *)      echo "unknown mode: $mode" >&2; exit 2 ;;
esac
TZ=America/Lima "$work/harness"
