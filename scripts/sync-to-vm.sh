#!/bin/bash
# Sync host-built JVE to UTM macOS guest for smoke-test execution.
#
# The guest is only used to isolate L3 smoke keystrokes from the host's
# foreground apps — it does NOT build. Build on the host (faster, deps
# already installed, no virtio/rsync cache hazards) and push the
# self-contained .app + the runtime tree the runner needs.
#
# What gets pushed:
#   - build/bin/jve.app     (host-built bundle; macdeployqt makes it
#                                  self-contained, so Qt frameworks ride along)
#   - src/lua/                    (loaded from disk at runtime)
#   - keymaps/                    (TOML keybindings, loaded at runtime)
#   - tests/smoke/                (runner + cases, executed on guest)
#   - tests/fixtures/resolve/     (small DRP fixtures referenced by smokes)
#
# What's excluded:
#   - .git/                       (guest doesn't need git)
#   - build/* except the .app     (host cmake cache has absolute host paths)
#   - tests/fixtures/media/       (588 GB of rushes; smokes don't touch them)
#   - tests/, src/cpp/, etc.      (host-only — guest never builds)
#
# Prereqs (one-time): host has built `make -j4` so build/bin/jve.app
# exists with macdeployqt already applied.
#
# Defaults assume:
#   - Guest reachable at $JVE_VM_HOST (default joes-virtual-machine.local)
#   - Guest user $JVE_VM_USER (default joe)
#   - SSH key at ~/.ssh/jve_vm
#   - Guest tree at ~/jve

set -e

HOST="${JVE_VM_HOST:-joes-virtual-machine.local}"
USER="${JVE_VM_USER:-joe}"
GUEST_PATH="${JVE_VM_GUEST_PATH:-~/jve}"
KEY="${HOME}/.ssh/jve_vm"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO_ROOT/build/bin/jve.app"

if [ ! -f "$KEY" ]; then
    echo "error: SSH key not found at $KEY"
    echo "       generate with: ssh-keygen -t ed25519 -N '' -f $KEY -C jve-vm-sync"
    exit 1
fi

if [ ! -d "$APP" ]; then
    echo "error: $APP not found"
    echo "       build on host first: make -j4"
    exit 1
fi

SSH_OPTS="ssh -i $KEY -o StrictHostKeyChecking=accept-new"

echo "→ runtime tree → $USER@$HOST:$GUEST_PATH"
rsync -az --delete \
    -e "$SSH_OPTS" \
    --relative \
    --exclude='__pycache__/' \
    --exclude='*.pyc' \
    --exclude='.DS_Store' \
    -- \
    "$REPO_ROOT/./src/lua" \
    "$REPO_ROOT/./keymaps" \
    "$REPO_ROOT/./tests/smoke" \
    "$REPO_ROOT/./tests/fixtures/resolve" \
    "$USER@$HOST:$GUEST_PATH/"

echo "→ jve.app → $USER@$HOST:$GUEST_PATH/build/bin/"
$SSH_OPTS "$USER@$HOST" "mkdir -p $GUEST_PATH/build/bin"
rsync -az --delete \
    -e "$SSH_OPTS" \
    "$APP/" \
    "$USER@$HOST:$GUEST_PATH/build/bin/jve.app/"

echo "✓ synced. Run smokes in guest with:"
echo "    cd ~/jve && python3 -m pytest tests/smoke/cases/"
