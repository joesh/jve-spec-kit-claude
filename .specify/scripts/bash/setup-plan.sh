#!/usr/bin/env bash

set -e

# Parse command line arguments
JSON_MODE=false
FORCE=false
ARGS=()

for arg in "$@"; do
    case "$arg" in
        --json)
            JSON_MODE=true
            ;;
        --force)
            FORCE=true
            ;;
        --help|-h)
            echo "Usage: $0 [--json] [--force]"
            echo "  --json    Output results in JSON format"
            echo "  --force   Overwrite an existing filled-in plan.md (default: refuse)"
            echo "  --help    Show this help message"
            exit 0
            ;;
        *)
            ARGS+=("$arg")
            ;;
    esac
done

# Get script directory and load common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# Get all paths and variables from common functions
eval $(get_feature_paths)

# Check if we're on a proper feature branch (only for git repos)
check_feature_branch "$CURRENT_BRANCH" "$HAS_GIT" || exit 1

# Ensure the feature directory exists
mkdir -p "$FEATURE_DIR"

# Scaffold the plan from the template — but NEVER clobber a filled-in plan.
# Re-running /plan must be safe: an existing plan that differs from the pristine
# template is real authored work (see the 023 incident where a blind cp wiped a
# finished, audited plan). Refuse unless --force; a plan still identical to the
# template is an untouched scaffold and is safe to re-copy.
TEMPLATE="$REPO_ROOT/.specify/templates/plan-template.md"
if [[ ! -f "$TEMPLATE" ]]; then
    echo "Error: plan template not found at $TEMPLATE" >&2
    exit 1
fi

if [[ -f "$IMPL_PLAN" ]] && ! cmp -s "$TEMPLATE" "$IMPL_PLAN" && [[ "$FORCE" != true ]]; then
    echo "Error: $IMPL_PLAN already exists and contains authored content." >&2
    echo "Refusing to overwrite it with the blank template. Re-run with --force to discard it." >&2
    exit 1
fi

cp "$TEMPLATE" "$IMPL_PLAN"
echo "Copied plan template to $IMPL_PLAN"

# Output results
if $JSON_MODE; then
    printf '{"FEATURE_SPEC":"%s","IMPL_PLAN":"%s","SPECS_DIR":"%s","BRANCH":"%s","HAS_GIT":"%s"}\n' \
        "$FEATURE_SPEC" "$IMPL_PLAN" "$FEATURE_DIR" "$CURRENT_BRANCH" "$HAS_GIT"
else
    echo "FEATURE_SPEC: $FEATURE_SPEC"
    echo "IMPL_PLAN: $IMPL_PLAN" 
    echo "SPECS_DIR: $FEATURE_DIR"
    echo "BRANCH: $CURRENT_BRANCH"
    echo "HAS_GIT: $HAS_GIT"
fi
