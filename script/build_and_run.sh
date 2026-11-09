#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/bundle.sh
if pgrep -x Snowpile >/dev/null; then
  pkill -TERM -x Snowpile
  for attempt in {1..30}; do
    pgrep -x Snowpile >/dev/null || break
    sleep 0.1
  done
  if pgrep -x Snowpile >/dev/null; then
    echo "Snowpile did not exit; leaving the running app intact." >&2
    exit 1
  fi
fi
open -n "$PWD/build/Snowpile.app"
if [[ "${1:-}" == "--verify" ]]; then
  sleep 2
  pgrep -x Snowpile >/dev/null
fi
