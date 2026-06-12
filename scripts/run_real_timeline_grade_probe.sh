#!/usr/bin/env bash

# t054 spike runner — do REAL (UI-authored) timeline grades reach
# stills and per-item ExportLUT bakes? Closes the question t053 left
# open (scripted timeline-graph writes are render-inert, so only a
# hand-authored grade can answer it). STATE-CHANGING on the Resolve it
# talks to (media-pool import, append/remove one item on the graded
# timeline, switches current timeline), so it must run on the VM's
# Resolve Studio, never against a host Resolve holding real work.
# Sourcing _run_in_vm.sh re-execs this script (args forwarded) on the
# guest when the VM is reachable. Must run BEFORE `set -e`.
#
# Usage: run_real_timeline_grade_probe.sh [graded-timeline-name]
#   no arg -> discovery mode: lists the project's timelines, exit 2.
. "$(dirname "${BASH_SOURCE[0]}")/_run_in_vm.sh"

set -euo pipefail

# Refusal gate: if we're still on the host (VM off / key absent), DO NOT
# fall through to the host Resolve — that would mutate Joe's live
# grading session. _run_in_vm.sh only returns without exec'ing the
# guest when the VM path is unavailable.
if [ "${JVE_IN_VM:-0}" != "1" ]; then
    echo "run_real_timeline_grade_probe: VM unreachable — refusing to" >&2
    echo "probe a host Resolve (state-changing: media pool + timeline" >&2
    echo "item mutation). Start the UTM guest and retry." >&2
    exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT_DIR/tools/resolve-helper/spikes/t054_probe_real_timeline_grade.py" "$@"
