--- @file patch_drag_logic.lua
--- Pure-logic lookup for src-button drag-drops on the timeline panel.
--- Decouples the "which SetPatch should this gesture produce" decision
--- from Qt event plumbing — same answer whether driven by a real Qt drag
--- event or by a unit test. timeline_panel.lua installs the gesture
--- handler; this module decides what the gesture means.
---
--- Three responsibilities (FR-010, FR-010a):
---   1. build_payload / parse_payload — round-trip the drag-source
---      identity through a QMimeData payload string. Drop targets read
---      identity from the payload, NOT by re-querying "what was the
---      drag source" — the payload is the immutable snapshot taken at
---      gesture start.
---   2. derive_target_from_strip — at a timeline-strip drop site, map
---      the local Y to a target row using the view's layout cache and
---      an injected track-info lookup (decoupled from Track model).
---   3. compute_patch_drop_action — pure lookup: given source + target,
---      return SetPatch params or a refusal. Cross-type, cross-sequence,
---      and self-drop are refusals (no-op); happy path produces params.
local M = {}

local REQUIRED_SOURCE_KEYS = {
    "sequence_id", "track_type", "source_shape",
    "source_track_index", "home_rec_track_index", "project_id",
}

local function assert_source_shape(source, where)
    assert(type(source) == "table",
        where .. ": source must be a table")
    assert(source.sequence_id and source.sequence_id ~= "",
        where .. ": source.sequence_id required")
    assert(source.track_type == "VIDEO" or source.track_type == "AUDIO",
        where .. ": source.track_type must be VIDEO|AUDIO, got "
        .. tostring(source.track_type))
    -- source_shape is the count of source tracks of `track_type` at the
    -- time the drag started — snapshot at gesture-start so the drop
    -- targets the same shape that was visible to the user.
    assert(type(source.source_shape) == "number" and source.source_shape > 0,
        where .. ": source.source_shape must be positive number, got "
        .. tostring(source.source_shape))
    assert(type(source.source_track_index) == "number",
        where .. ": source.source_track_index must be number, got "
        .. type(source.source_track_index))
    assert(type(source.home_rec_track_index) == "number",
        where .. ": source.home_rec_track_index must be number, got "
        .. type(source.home_rec_track_index))
    assert(source.project_id and source.project_id ~= "",
        where .. ": source.project_id required")
end

--- Encode a drag-source identity into a QMimeData payload string.
--- Caller passes the result to QMimeData::setData under the patch-drag
--- mime type. Asserts on missing/malformed fields — the bug surfaces at
--- gesture start where the user can correlate it.
---
--- @param source table {sequence_id, track_type, source_track_index,
---                      home_rec_track_index, project_id}
--- @return string JSON-encoded payload
function M.build_payload(source)
    assert_source_shape(source, "build_payload")
    local json = require("dkjson")
    return json.encode({
        sequence_id          = source.sequence_id,
        track_type           = source.track_type,
        source_shape         = source.source_shape,
        source_track_index   = source.source_track_index,
        home_rec_track_index = source.home_rec_track_index,
        project_id           = source.project_id,
    })
end

--- Decode a QMimeData payload string back into a drag-source identity.
--- Asserts on malformed JSON or missing fields — the drop handler should
--- never receive a malformed payload from a healthy drag source, so this
--- is an invariant violation (ENGINEERING 1.14) not a recoverable case.
---
--- @param payload string JSON payload from QMimeData
--- @return table source identity
function M.parse_payload(payload)
    assert(type(payload) == "string" and payload ~= "",
        "parse_payload: payload must be a non-empty string, got "
        .. type(payload))
    local json = require("dkjson")
    local parsed, _, err = json.decode(payload)
    assert(parsed, "parse_payload: malformed JSON: " .. tostring(err))
    -- Re-use the shape assertions for symmetry with build_payload.
    assert_source_shape(parsed, "parse_payload")
    -- Re-construct to drop any unexpected keys an attacker (or bug) might
    -- have stuffed in — only the known fields propagate to the lookup.
    local source = {}
    for _, key in ipairs(REQUIRED_SOURCE_KEYS) do
        source[key] = parsed[key]
    end
    return source
end

--- Resolve a strip-widget drop coordinate into a target row.
--- The strip is a single QWidget; rows are paint regions identified by
--- Y range via the view's layout cache. This function is the seam
--- between Qt event coords and the pure lookup — both sides injected
--- so it tests cleanly without Qt.
---
--- @param args table {view, local_y, widget_height, sequence_id, info_lookup}
---   view: object with get_track_id_at_y(y, height) returning track_id|nil
---   local_y: drop Y in widget-local coords
---   widget_height: strip widget's current pixel height (passed explicitly
---     so this module never reaches into Qt to ask)
---   sequence_id: the sequence the strip is rendering
---   info_lookup: function(track_id) → {track_index, track_type}
--- @return table|nil target {sequence_id, track_type, rec_track_index},
---   or nil if Y lies outside any rendered row (caller ignores the drop).
function M.derive_target_from_strip(args)
    assert(type(args) == "table",
        "derive_target_from_strip: args table required")
    assert(type(args.view) == "table",
        "derive_target_from_strip: args.view required")
    assert(type(args.view.get_track_id_at_y) == "function",
        "derive_target_from_strip: view must expose get_track_id_at_y")
    assert(type(args.local_y) == "number",
        "derive_target_from_strip: args.local_y must be number")
    assert(type(args.widget_height) == "number" and args.widget_height > 0,
        "derive_target_from_strip: args.widget_height must be positive number, got "
        .. tostring(args.widget_height))
    assert(args.sequence_id and args.sequence_id ~= "",
        "derive_target_from_strip: args.sequence_id required")
    assert(type(args.info_lookup) == "function",
        "derive_target_from_strip: args.info_lookup function required")

    local track_id = args.view:get_track_id_at_y(args.local_y,
        args.widget_height)
    if not track_id then
        -- User released over a region that's not a track row. Not an
        -- invariant violation — just an ignored drop. Return nil.
        return nil
    end
    local info = args.info_lookup(track_id)
    assert(type(info) == "table",
        "derive_target_from_strip: info_lookup returned non-table for "
        .. tostring(track_id))
    assert(type(info.track_index) == "number",
        "derive_target_from_strip: info.track_index required for "
        .. tostring(track_id))
    assert(info.track_type == "VIDEO" or info.track_type == "AUDIO",
        "derive_target_from_strip: info.track_type must be VIDEO|AUDIO for "
        .. tostring(track_id))
    return {
        sequence_id     = args.sequence_id,
        track_type      = info.track_type,
        rec_track_index = info.track_index,
    }
end

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
    assert(type(source.source_shape) == "number" and source.source_shape > 0,
        "compute_patch_drop_action: source.source_shape must be positive number, got "
        .. tostring(source.source_shape))
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
        source_shape       = source.source_shape,
        source_track_index = source.source_track_index,
        record_track_index = target.rec_track_index,
        project_id         = source.project_id,
        enabled            = true,
    } }
end

return M
