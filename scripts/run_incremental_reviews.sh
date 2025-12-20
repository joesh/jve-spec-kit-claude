#!/usr/bin/env bash
set -euo pipefail

CODEX_BIN="${CODEX_BIN:-codex}"

PROMPT_FILE="prompts/INCREMENTAL_REVIEW.md"
PASS_FILE="prompts/baseline_passes.txt"

usage() {
  echo "Usage:" >&2
  echo "  $0 --uncommitted" >&2
  echo "  $0 --commit <sha>" >&2
  echo "  $0 --base <branch>" >&2
  exit 1
}

if (( $# < 1 )); then
  usage
fi

MODE=""
MODE_ARG=""

case "$1" in
  --uncommitted)
    MODE="uncommitted"
    ;;
  --commit)
    [[ $# -eq 2 ]] || usage
    MODE="commit"
    MODE_ARG="$2"
    ;;
  --base)
    [[ $# -eq 2 ]] || usage
    MODE="base"
    MODE_ARG="$2"
    ;;
  *)
    usage
    ;;
esac

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

get_diff() {
  if [[ "$MODE" == "uncommitted" ]]; then
    git diff
  elif [[ "$MODE" == "commit" ]]; then
    git show --no-color --format=fuller "$MODE_ARG"
  else
    git diff --no-color "$MODE_ARG"...HEAD
  fi
}

DIFF_TEXT="$(get_diff)"
if [[ -z "${DIFF_TEXT// }" ]]; then
  echo "ERROR: No diff to review for mode=$MODE ${MODE_ARG:-}" >&2
  exit 1
fi

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
  echo "=== INCREMENTAL REVIEW: $pass_name ==="
  if [[ "$MODE" == "uncommitted" ]]; then
    echo "Mode: uncommitted"
  elif [[ "$MODE" == "commit" ]]; then
    echo "Mode: commit $MODE_ARG"
  else
    echo "Mode: base $MODE_ARG...HEAD"
  fi
  echo "Scope: $pass_paths"
  echo

  {
    cat "$PROMPT_FILE"
    printf "\n\nSubsystem scope:\n"
    for p in $pass_paths; do
      printf -- "- %s\n" "$p"
    done
    printf "\n\nDIFF (authoritative):\n```diff\n%s\n```\n" "$DIFF_TEXT"
  } | "$CODEX_BIN" exec -
done < "$PASS_FILE"
