#!/usr/bin/env bash

# Cut and check out the feature branch for the active feature.
#
# Branch creation is deferred from /specify to here (/implement) so that spec
# authoring (spec -> plan -> tasks) happens on master and the branch is only cut
# when coding starts. The clean-tree and unmerged-ancestor guards that used to
# live in create-new-feature.sh moved here, because THIS is where a branch is
# actually created and where those hazards apply.
#
# Idempotent: if the feature branch already exists / is checked out, it is a
# successful no-op (re-running /implement must not fail).
#
# Usage: ./start-feature-branch.sh [--json]

set -e

JSON_MODE=false
for arg in "$@"; do
    case "$arg" in
        --json) JSON_MODE=true ;;
        --help|-h) echo "Usage: $0 [--json]"; exit 0 ;;
        *) echo "ERROR: Unknown option '$arg'." >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

REPO_ROOT="$(get_repo_root)"
cd "$REPO_ROOT"

FEATURE="$(get_current_branch)"

emit() {
    local status="$1" branch="$2" message="$3"
    if $JSON_MODE; then
        printf '{"STATUS":"%s","BRANCH":"%s","MESSAGE":"%s"}\n' "$status" "$branch" "$message"
    else
        echo "STATUS: $status"
        echo "BRANCH: $branch"
        echo "MESSAGE: $message"
    fi
}

if ! has_git; then
    emit "no-git" "$FEATURE" "Git not detected; no branch cut. Proceeding on working tree."
    exit 0
fi

# The feature must be a real feature slug, not a stray branch name like master.
if [[ ! "$FEATURE" =~ ^[0-9]{3}- ]]; then
    echo "ERROR: No active feature resolved (got '$FEATURE'). Run /specify first." >&2
    exit 1
fi

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Already on the feature branch (re-run) — no-op success.
if [ "$CURRENT_BRANCH" = "$FEATURE" ]; then
    emit "already-on-branch" "$FEATURE" "Already on feature branch."
    exit 0
fi

# Branch already exists but isn't checked out — check it out (carrying the spec
# edits made on master into the feature branch is the intent).
if git rev-parse --verify "$FEATURE" >/dev/null 2>&1; then
    git checkout "$FEATURE"
    emit "checked-out" "$FEATURE" "Checked out existing feature branch."
    exit 0
fi

# --- Cutting a NEW branch: apply the guards that moved from create-new-feature.sh ---

# Guard 1: refuse to branch when the working tree is dirty. A new branch cut from
# a dirty tree silently carries whatever was uncommitted — including sibling
# parallel-session work (see CLAUDE.md WARNING #5). Commit the spec first.
if [ -n "$(git status --porcelain)" ]; then
    echo "Error: working tree is not clean. Commit your spec/plan/tasks (and only your files) before /implement cuts the branch." >&2
    echo "Dirty files:" >&2
    git status --short >&2
    exit 1
fi

# Guard 2: refuse to branch from a feature branch whose commits aren't on the
# default branch — branching there orphans them (the 017->018 hazard).
DEFAULT_BRANCH="master"
if ! git rev-parse --verify "$DEFAULT_BRANCH" >/dev/null 2>&1; then
    DEFAULT_BRANCH="main"
fi
if [ "$CURRENT_BRANCH" != "$DEFAULT_BRANCH" ]; then
    if ! git merge-base --is-ancestor HEAD "$DEFAULT_BRANCH" 2>/dev/null; then
        UNMERGED=$(git rev-list --count "$DEFAULT_BRANCH..HEAD" 2>/dev/null || echo "?")
        echo "Error: current branch '$CURRENT_BRANCH' has $UNMERGED commit(s) not on $DEFAULT_BRANCH." >&2
        echo "Branching here would orphan them. Merge/rebase into $DEFAULT_BRANCH (or check it out) before /implement." >&2
        echo "Unmerged commits:" >&2
        git log --oneline "$DEFAULT_BRANCH..HEAD" >&2
        exit 1
    fi
fi

git checkout -b "$FEATURE"
emit "created" "$FEATURE" "Cut and checked out new feature branch."
