#!/usr/bin/env bash

# t055 spike runner — does ExportLUT of a clip with its OWN grade
# compose in the timeline-level grade (force-bake soundness), and does
# SetNodeEnabled work on a timeline graph? STATE-CHANGING on the
# Resolve it talks to (media-pool import, append/remove one item,
# toggles the timeline grade node off/back-on, switches current
# timeline + page), so it must run on the VM's Resolve Studio, never
# against a host Resolve holding real work. Sourcing _run_in_vm.sh
# re-execs this script (args forwarded) on the guest when the VM is
# reachable. Must run BEFORE `set -e`.
#
# Usage: run_graded_item_bake_probe.sh <graded-timeline-name>
. "$(dirname "${BASH_SOURCE[0]}")/_run_in_vm.sh"

set -euo pipefail

# Refusal gate: if we're still on the host (VM off / key absent), DO NOT
# fall through to the host Resolve — that would mutate Joe's live
# grading session. _run_in_vm.sh only returns without exec'ing the
# guest when the VM path is unavailable.
if [ "${JVE_IN_VM:-0}" != "1" ]; then
    echo "run_graded_item_bake_probe: VM unreachable — refusing to" >&2
    echo "probe a host Resolve (state-changing: timeline-graph node" >&2
    echo "toggle + media pool mutation). Start the UTM guest, retry." >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT_DIR/tools/resolve-helper/spikes/t055_probe_graded_item_bake_composition.py" "$@"
