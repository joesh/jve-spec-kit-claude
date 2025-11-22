#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/bin/JVEEditor"
WAIT_SECONDS="${JVE_SMOKE_WAIT_SECONDS:-2}"

if [[ ! -x "$APP" ]]; then
  echo "ERROR: App binary not found at $APP" >&2
  exit 1
fi

"$APP" &
PID=$!
sleep "${WAIT_SECONDS}"

if ! kill -0 "$PID" >/dev/null 2>&1; then
  if wait "$PID" >/dev/null 2>&1; then
    echo "ERROR: App exited before smoke test could observe UI startup." >&2
    exit 1
  else
    status=$?
    echo "ERROR: App crashed early during smoke run (status ${status})." >&2
    exit "${status}"
  fi
fi

# Ask app to quit gracefully, then force if needed.
if kill -TERM "$PID" >/dev/null 2>&1; then
  term_sent=1
  for _ in {1..10}; do
    if ! kill -0 "$PID" >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done
else
  term_sent=0
fi

if kill -0 "$PID" >/dev/null 2>&1; then
  echo "WARN: app still running after TERM, sending KILL" >&2
  kill -KILL "$PID" >/dev/null 2>&1 || true
fi

if wait "$PID"; then
  :
else
  status=$?
  if [[ $term_sent -eq 0 ]]; then
    echo "ERROR: App exited with status ${status} during smoke shutdown." >&2
    exit "${status}"
  fi
fi
echo "Smoke run completed"
