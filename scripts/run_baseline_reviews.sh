#!/usr/bin/env bash
set -euo pipefail

CODEX_BIN="${CODEX_BIN:-codex}"

PROMPT_FILE="prompts/BASELINE_MASTER_REVIEW.md"
PASS_FILE="prompts/baseline_passes.txt"

if [[ ! -f ENGINEERING.md || ! -f DEVELOPMENT-PROCESS.md || ! -d src || ! -d tests || ! -d docs ]]; then
  echo "ERROR: Must be run from repo root (ENGINEERING.md, DEVELOPMENT-PROCESS.md, src/, tests/, docs/ must exist)" >&2
  exit 1
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "Missing prompt file: $PROMPT_FILE" >&2
  exit 1
fi

if [[ ! -f "$PASS_FILE" ]]; then
  echo "Missing pass definition file: $PASS_FILE" >&2
  exit 1
fi

shopt -s globstar nullglob

while IFS='|' read -r pass_name pass_paths; do
  [[ -z "${pass_name// }" ]] && continue
  [[ "$pass_name" =~ ^# ]] && continue

  pass_name="$(echo "$pass_name" | xargs)"
  pass_paths="$(echo "$pass_paths" | xargs)"

  for pattern in $pass_paths; do
    matches=( $pattern )
    if (( ${#matches[@]} == 0 )); then
      echo "ERROR: Pass '$pass_name' glob matches nothing: $pattern" >&2
      exit 1
    fi
  done

  echo
  echo "=== BASELINE REVIEW: $pass_name ==="
  echo "Scope: $pass_paths"
  echo

  {
    cat "$PROMPT_FILE"
    printf "\n\nSubsystem scope:\n"
    for p in $pass_paths; do
      printf -- "- %s\n" "$p"
    done
  } | "$CODEX_BIN" exec -
done < "$PASS_FILE"
