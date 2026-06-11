#!/usr/bin/env bash

# t051 spike runner — does TimelineItem.ExportLUT bake color-group
# grades? STATE-CHANGING on the Resolve it talks to (creates/deletes a
# probe color group, switches pages), so it must run on the VM's
# Resolve Studio, never against a host Resolve holding real work.
# Sourcing _run_in_vm.sh re-execs this script on the guest when the VM
# is reachable. Must run BEFORE `set -e`.
. "$(dirname "${BASH_SOURCE[0]}")/_run_in_vm.sh"

set -euo pipefail

# Refusal gate: if we're still on the host (VM off / key absent), DO NOT
# fall through to the host Resolve — that would mutate Joe's live
# grading session. _run_in_vm.sh only returns without exec'ing the
# guest when the VM path is unavailable.
if [ "${JVE_IN_VM:-0}" != "1" ]; then
    echo "run_group_bake_probe: VM unreachable — refusing to probe a" >&2
    echo "host Resolve (state-changing: group create/assign + page" >&2
    echo "switch). Start the UTM guest and retry." >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT_DIR/tools/resolve-helper/spikes/t051_probe_group_grade_bake.py"
