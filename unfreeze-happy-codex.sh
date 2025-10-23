#!/usr/bin/env bash
set -euo pipefail

choose_pid() {
  ps -Ao pid,ppid,tty,state,etime,command | awk 'NR==1 || /happy|codex/ {print}'
  echo
  read -p "Enter HAPPY_PID: " HAPPY_PID
  read -p "Enter CODEX_PID: " CODEX_PID
}

nudge() {
  kill -WINCH "$CODEX_PID" 2>/dev/null || true
  kill -CONT  "$CODEX_PID" 2>/dev/null || true
  kill -STOP  "$HAPPY_PID" 2>/dev/null || true
  sleep 1
  kill -CONT  "$HAPPY_PID" 2>/dev/null || true
}

snapshots() {
  sample "$CODEX_PID" 5 1 -file "$HOME/Desktop/codex-sample.txt" >/dev/null 2>&1 || true
  sample "$HAPPY_PID" 5 1 -file "$HOME/Desktop/happy-sample.txt" >/dev/null 2>&1 || true
}

lsofs() {
  lsof -p "$CODEX_PID" | head -n 80 > "$HOME/Desktop/codex-lsof.txt" 2>/dev/null || true
  lsof -p "$HAPPY_PID" | head -n 80 > "$HOME/Desktop/happy-lsof.txt" 2>/dev/null || true
}

health() {
  { codex --version; codex -e "print('ok')"; } > "$HOME/Desktop/codex-health.txt" 2>&1 || true
}

paths() {
  { 
    getconf DARWIN_USER_TEMP_DIR || true
    TMPDIR=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || echo /tmp)
    ls -lt "$TMPDIR" 2>/dev/null | head -n 30 || true
    find "$TMPDIR" -maxdepth 1 -iname 'happy*' -or -iname 'codex*' 2>/dev/null || true
    ls -la "$HOME/Library/Application Support" 2>/dev/null | grep -i happy || true
    ls -la "$HOME/Library/Logs" 2>/dev/null | grep -i happy || true
  } > "$HOME/Desktop/happy-codex-paths.txt" 2>&1 || true
}

print_summary() {
  echo "Wrote:"
  echo "$HOME/Desktop/codex-sample.txt"
  echo "$HOME/Desktop/happy-sample.txt"
  echo "$HOME/Desktop/codex-lsof.txt"
  echo "$HOME/Desktop/happy-lsof.txt"
  echo "$HOME/Desktop/codex-health.txt"
  echo "$HOME/Desktop/happy-codex-paths.txt"
}

main() {
  choose_pid
  nudge
  snapshots
  lsofs
  health
  paths
  print_summary
  echo "If still frozen, re-run nudge once more: kill -WINCH $CODEX_PID; kill -STOP $HAPPY_PID; sleep 1; kill -CONT $HAPPY_PID; kill -CONT $CODEX_PID"
}

main
