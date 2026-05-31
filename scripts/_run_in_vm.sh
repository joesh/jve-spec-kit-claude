#!/bin/bash
# Source-able helper. When a host-side test runner sources this AND the UTM
# guest is configured + reachable, the runner is re-exec'd on the guest and
# the host process exits with the guest's exit code. Otherwise the helper
# returns and the caller continues on the host.
#
# Why: binding/integration tests spawn many `jve --test` processes in
# parallel, taking over Joe's host machine. Push them to the always-on UTM
# guest instead. The L3 smoke pipeline already proved the host-build /
# guest-runtime model; this reuses sync-to-vm.sh and the same SSH key.
#
# Activation (default-on, no env var needed):
#   - SSH key present at ~/.ssh/jve_vm  AND
#   - JVE_VM_HOST (default joes-virtual-machine.local) reachable in < 3s.
#
# Disable per-invocation: JVE_VM_DISABLE=1
# Recursion guard: JVE_IN_VM=1 is forced into the ssh command so the helper
# returns immediately on the guest side (no infinite re-exec).
#
# Contract: source from a runner script's top, before any `set -e` or work.
#   . "$(dirname "${BASH_SOURCE[0]}")/_run_in_vm.sh"

if [ "${JVE_IN_VM:-0}" = "1" ] || [ "${JVE_VM_DISABLE:-0}" = "1" ]; then
    return 0
fi

_VM_KEY="${HOME}/.ssh/jve_vm"
[ -f "$_VM_KEY" ] || return 0

_VM_HOST="${JVE_VM_HOST:-joes-virtual-machine.local}"
_VM_USER="${JVE_VM_USER:-joe}"
_VM_GUEST_PATH="${JVE_VM_GUEST_PATH:-~/jve}"
_VM_SSH="ssh -i $_VM_KEY -o StrictHostKeyChecking=accept-new -o ConnectTimeout=3 -o BatchMode=yes"

# Reachability probe (fast — falls through to host if VM is off).
if ! $_VM_SSH "$_VM_USER@$_VM_HOST" true 2>/dev/null; then
    echo "[vm-dispatch] $_VM_HOST unreachable; running on host" >&2
    return 0
fi

# Sync once per `make` invocation. Sentinel scoped to $PPID (the make/test
# orchestrator) so binding+integration runners share one sync per build.
# Stale sentinels across invocations are harmless — at worst we re-sync,
# which is cheap (rsync incremental).
_VM_SYNC_SENTINEL="/tmp/jve_vm_sync.$PPID"
_VM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_VM_REPO_ROOT="$(cd "$_VM_SCRIPT_DIR/.." && pwd)"

if [ ! -f "$_VM_SYNC_SENTINEL" ]; then
    echo "[vm-dispatch] syncing host → $_VM_USER@$_VM_HOST:$_VM_GUEST_PATH" >&2
    if ! bash "$_VM_REPO_ROOT/scripts/sync-to-vm.sh" >&2; then
        echo "[vm-dispatch] sync failed; falling back to host" >&2
        return 0
    fi
    touch "$_VM_SYNC_SENTINEL"
fi

# Re-exec the calling script on the guest. Resolve $0 to an absolute path
# first ($0 is relative when invoked as `bash scripts/foo.sh`), then strip
# the repo root prefix to get the guest-relative path.
_VM_SELF_ABS="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
_VM_SELF_REL="${_VM_SELF_ABS#$_VM_REPO_ROOT/}"
if [ "$_VM_SELF_REL" = "$_VM_SELF_ABS" ]; then
    echo "[vm-dispatch] caller $_VM_SELF_ABS is outside repo root; running on host" >&2
    return 0
fi

# Forward env knobs the runners read. Add to this list when a new runner
# needs more (keep it explicit — implicit env propagation across SSH is a
# debug nightmare).
echo "[vm-dispatch] $(basename "$0") → $_VM_HOST" >&2
$_VM_SSH "$_VM_USER@$_VM_HOST" \
    "cd $_VM_GUEST_PATH && JVE_IN_VM=1 JVE_SMOKE_IN_VM=1 RUN_SLOW_TESTS='${RUN_SLOW_TESTS:-0}' bash $_VM_SELF_REL"
exit $?
