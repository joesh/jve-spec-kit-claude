--- @file patch_drag_logic.lua
--- Pure-logic resolver for src-button drag-drops on the timeline panel.
--- Decouples the "which SetPatch should this gesture produce" decision
--- from Qt event plumbing — same answer whether driven by a real Qt drag
--- event or by a unit test. timeline_panel.lua installs the gesture
--- handler; this module decides what the gesture means.
local M = {}

--- Decide what SetPatch params (if any) a drop should produce.
---
--- Plain drag and modifier-drag stacking produce IDENTICAL params at the
--- data layer — UNIQUE(sequence_id, source_track_index) means stacking is
--- just multiple patches with the same `record_track_index`. The caller
--- snapshots the dragged button's current `source_track_index` (looked
--- up via `Patch.find_by_record` against its home row) before invoking.
---
--- @param source table {sequence_id, track_type, source_track_index,
---                      home_rec_track_index, project_id}
---   `home_rec_track_index` is the record row the dragged button sits on;
---   used to detect self-drop (drop onto own row → no-op refusal).
--- @param target table {sequence_id, track_type, rec_track_index}
---
--- @return table
---   on success: { params = {sequence_id, track_type, source_track_index,
---                           record_track_index, project_id, enabled = true} }
---   on refusal: { refusal = "<human-readable reason>" } — caller decides
---               whether to flash a status message or silently ignore
function M.compute_patch_drop_action(source, target)
    assert(type(source) == "table",
        "compute_patch_drop_action: source table required")
    assert(type(target) == "table",
        "compute_patch_drop_action: target table required")
    assert(source.sequence_id and source.sequence_id ~= "",
        "compute_patch_drop_action: source.sequence_id required")
    assert(source.track_type == "VIDEO" or source.track_type == "AUDIO",
        "compute_patch_drop_action: source.track_type must be VIDEO|AUDIO, "
        .. "got " .. tostring(source.track_type))
    assert(type(source.source_track_index) == "number",
        "compute_patch_drop_action: source.source_track_index required")
    assert(type(source.home_rec_track_index) == "number",
        "compute_patch_drop_action: source.home_rec_track_index required")
    assert(source.project_id and source.project_id ~= "",
        "compute_patch_drop_action: source.project_id required")
    assert(target.sequence_id and target.sequence_id ~= "",
        "compute_patch_drop_action: target.sequence_id required")
    assert(target.track_type == "VIDEO" or target.track_type == "AUDIO",
        "compute_patch_drop_action: target.track_type must be VIDEO|AUDIO, "
        .. "got " .. tostring(target.track_type))
    assert(type(target.rec_track_index) == "number",
        "compute_patch_drop_action: target.rec_track_index required")

    if source.sequence_id ~= target.sequence_id then
        return { refusal = "cross-sequence drag not supported" }
    end
    if source.track_type ~= target.track_type then
        return { refusal = string.format(
            "cross-type drag refused (%s source onto %s record)",
            source.track_type, target.track_type) }
    end
    -- Self-drop: dragging onto own home row would re-route to where it
    -- already is. Treat as no-op refusal (not an error).
    if source.home_rec_track_index == target.rec_track_index then
        return { refusal = "self-drop (no change)" }
    end
    return { params = {
        sequence_id        = target.sequence_id,
        track_type         = target.track_type,
        source_track_index = source.source_track_index,
        record_track_index = target.rec_track_index,
        project_id         = source.project_id,
        enabled            = true,
    } }
end

return M
