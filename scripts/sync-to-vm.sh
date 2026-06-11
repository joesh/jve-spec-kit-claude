#!/bin/bash
# Sync host-built JVE to UTM macOS guest for smoke-test execution.
#
# The guest is only used to isolate L3 smoke keystrokes from the host's
# foreground apps — it does NOT build. Build on the host (faster, deps
# already installed, no virtio/rsync cache hazards) and push the
# self-contained .app + the runtime tree the runner needs.
#
# What gets pushed:
#   - build/bin/jve.app           (host-built, self-contained: Qt frameworks
#                                  via macdeployqt, src/lua + keymaps +
#                                  resources via CMake post-build bundling)
#   - tests/live/                (Python runner + cases — lives outside
#                                  the .app by design, drives it)
#   - tests/synthetic/binding/    (Lua --test scripts dispatched via _run_in_vm.sh)
#   - tests/synthetic/integration/ (Lua --test scripts dispatched via _run_in_vm.sh)
#   - tools/resolve-helper/       (Python helper.py spawned by helper_fixture.lua
#                                  in spec-023 binding tests — without this the
#                                  helper-* binding tests fail to bind socket)
#   - tests/test_env.lua          (test bootstrap; sets package.path)
#   - tests/import_schema.lua     (loads src/lua/schema.sql via io.open)
#   - tests/fixtures/resolve/     (small DRP fixtures consumed by the
#                                  template builder + DRP import tests)
#   - src/lua/                    (test_env.lua injects ~/jve/src/lua/ into
#                                  package.path so `require("core.foo")`
#                                  resolves on guest exactly as on host —
#                                  the .app bundle's Resources/src/lua is
#                                  not in test_env's search list, and
#                                  import_schema.lua reads schema.sql via
#                                  io.open (not require) from this tree)
#   - resources/                  (templates/*.jvp opened by importer tests;
#                                  icons/*.svg loaded during ui.layout init —
#                                  missing either of these makes ui-touching
#                                  binding tests fail with a 'loop or previous
#                                  error loading module ui.layout' cascade)
#   - keymaps/                    (keyboard_shortcuts.init resolves
#                                  keymaps/default.jvekeys relative to PWD)
#   - scripts/run_binding_tests.sh + tests/run_integration_tests.sh +
#     scripts/_run_in_vm.sh       (the runners themselves are re-exec'd
#                                  on the guest)
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
#   - Guest tree at ~/jve-<hash-of-host-repo-path> (per-checkout, so two
#     sessions in different checkouts don't fight on the same VM tree).
#     Override with JVE_VM_GUEST_PATH.

set -e
set -o pipefail  # propagate failures from non-last pipeline commands (e.g. the
                 # local tar in the tar | ssh tar push below). Without this a
                 # silent local-tar failure would let the script claim success.

HOST="${JVE_VM_HOST:-joes-virtual-machine.local}"
USER="${JVE_VM_USER:-joe}"
KEY="${HOME}/.ssh/jve_vm"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Per-checkout VM staging path (see scripts/_run_in_vm.sh for rationale).
# Derive a stable suffix from the host repo path so parallel sessions
# in different checkouts don't share a guest tree.
VM_PATH_SUFFIX="$(printf '%s' "$REPO_ROOT" | shasum | cut -c 1-8)"
GUEST_PATH="${JVE_VM_GUEST_PATH:-~/jve-$VM_PATH_SUFFIX}"
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
# cd into repo so --relative roots paths at repo-relative names.
# (The `/./` marker trick is unreliable with -a; cd + relative paths
# gives the same effect deterministically.)
cd "$REPO_ROOT"
rsync -az --delete \
    -e "$SSH_OPTS" \
    --relative \
    --exclude='__pycache__/' \
    --exclude='*.pyc' \
    --exclude='.DS_Store' \
    -- \
    tests/live \
    tests/synthetic/binding \
    tests/synthetic/integration \
    tests/test_env.lua \
    tests/import_schema.lua \
    tests/synthetic/helpers \
    tests/fixtures/resolve \
    tools/resolve-helper \
    "tests/fixtures/premiere/2026-03-20-anamnesis joe edit.prproj" \
    "tests/fixtures/media/anamnesis-trimmed/2026-03-28-anamnesis-GOLD-MASTER-CANDIDATE.drt" \
    src/lua \
    resources \
    keymaps \
    menus.xml \
    scripts/run_binding_tests.sh \
    scripts/run_group_bake_probe.sh \
    scripts/run_timeline_graph_probe.sh \
    tests/run_integration_tests.sh \
    scripts/_run_in_vm.sh \
    "$USER@$HOST:$GUEST_PATH/"

echo "→ jve.app → $USER@$HOST:$GUEST_PATH/build/bin/"
# Use tar-over-ssh, not rsync, for the .app: macOS ships openrsync
# (not GNU rsync), which dies mid-stream on codesign'd dylibs
# inside a bundle (xattr handling). tar is simple, full-transfer
# (not incremental — but the .app is small enough that doesn't matter),
# and round-trips Apple xattrs correctly.
#
# `-h` dereferences symlinks. The host bundle's Resources/{src/lua,
# keymaps, menus.xml, resources} are CMake-POST_BUILD symlinks into the
# repo (fast dev-iteration trick); without -h, those land on the guest
# as dangling pointers to host-only paths and the binary's bundle-path
# check (pathExists Resources/src/lua) fails, dropping back to a
# repo-fallback that misses Resources/lua_modules (lxp.so).
$SSH_OPTS "$USER@$HOST" "mkdir -p $GUEST_PATH/build/bin && rm -rf $GUEST_PATH/build/bin/jve.app"
tar -ch -C "$(dirname "$APP")" "$(basename "$APP")" \
    | $SSH_OPTS "$USER@$HOST" "tar -x -C $GUEST_PATH/build/bin"

echo "→ VM-side symlinks for media fixtures whose host targets don't exist on guest"
# tests/fixtures/media/anamnesis-trimmed is a host symlink →
# /Users/joe/Local/Anamnesis/anamnesis-trimmed-gold-timeline (host-only path).
# On the guest the same content is mounted at
# /Volumes/My Shared Files/Local/Anamnesis/anamnesis-trimmed-gold-timeline.
# resolve_repo_path() in tests/test_env.lua prefers the synced tree over the
# virtiofs mount, so a VM-side symlink at ~/jve/tests/fixtures/media/anamnesis-trimmed
# wins over the broken host-target symlink that came across via rsync.
$SSH_OPTS "$USER@$HOST" "
    set -e
    cd $GUEST_PATH/tests/fixtures/media
    # rm -rf handles both cases: a prior symlink (file) OR a real directory
    # left behind by earlier touch_media_fixtures runs or fixture-bootstrap
    # code that didn't know the host path was a symlink.
    rm -rf anamnesis-trimmed
    ln -s '/Volumes/My Shared Files/Local/Anamnesis/anamnesis-trimmed-gold-timeline' anamnesis-trimmed
"

echo "✓ synced. Run smokes in guest with:"
echo "    cd ~/jve && python3 -m pytest tests/live/cases/"
