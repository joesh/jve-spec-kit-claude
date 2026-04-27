--- Clipboard-aware copy/paste helpers for timeline and project browser
local clipboard = require("core.clipboard")
local log = require("core.logger").for_area("commands")
local focus_manager = require("ui.focus_manager")
local timeline_state = require("ui.timeline.timeline_state")
local command_manager = require("core.command_manager")
local uuid = require("uuid")


local project_browser = nil
do
    local ok, mod = pcall(require, "ui.project_browser")
    if ok and type(mod) == "table" then
        project_browser = mod
    end
end

local M = {}

local function load_clip_properties(clip_id)
    assert(clip_id and clip_id ~= "", "clipboard_actions.load_clip_properties: clip_id required")
    local Property = require("models.property")
    local props = Property.load_for_clip(clip_id)
    return props or {}
end

local function resolve_clip_entry(entry)
    if type(entry) == "table" and entry.timeline_start and entry.track_id then
        return entry
    end
    if type(entry) == "table" and entry.id and timeline_state.get_clip_by_id then
        local clip = timeline_state.get_clip_by_id(entry.id)
        assert(clip, "clipboard_actions.resolve_clip_entry: clip not found by id " .. tostring(entry.id))
        return clip
    end
    if type(entry) == "string" and timeline_state.get_clip_by_id then
        local clip = timeline_state.get_clip_by_id(entry)
        assert(clip, "clipboard_actions.resolve_clip_entry: clip not found by id " .. tostring(entry))
        return clip
    end
    error("clipboard_actions.resolve_clip_entry: unresolvable entry type " .. type(entry))
end

--- Copy clips in mark range [mark_in, mark_out) to clipboard.
-- Clips partially overlapping are clipped to the range boundaries.
local function copy_mark_range()
    local mark_in = timeline_state.get_mark_in and timeline_state.get_mark_in()
    local mark_out = timeline_state.get_mark_out and timeline_state.get_mark_out()
    if not mark_in or not mark_out or mark_out <= mark_in then
        return false, "Marks not set or empty range"
    end

    -- Sequence rate for timeline→source unit conversion
    local seq_fps_num = timeline_state.get_sequence_fps_numerator()
    local seq_fps_den = timeline_state.get_sequence_fps_denominator()
    assert(type(seq_fps_num) == "number" and seq_fps_num > 0,
        "copy_mark_range: sequence fps_numerator missing or invalid: " .. tostring(seq_fps_num))
    assert(type(seq_fps_den) == "number" and seq_fps_den > 0,
        "copy_mark_range: sequence fps_denominator missing or invalid: " .. tostring(seq_fps_den))
    local seq_rate = seq_fps_num / seq_fps_den

    assert(timeline_state.get_clips,
        "copy_mark_range: timeline_state.get_clips not available")
    local all_clips = timeline_state.get_clips()
    local clip_payloads = {}

    for _, clip in ipairs(all_clips) do
        -- Skip gap clips — they have no media to copy
        if clip.is_gap then goto continue end

        local clip_start = clip.timeline_start
        local clip_end = clip_start + clip.duration
        -- Skip clips entirely outside mark range
        if clip_end <= mark_in or clip_start >= mark_out then goto continue end

        assert(clip.rate and clip.rate.fps_numerator and clip.rate.fps_denominator,
            "copy_mark_range: clip " .. tostring(clip.id) .. " missing rate")

        -- Clip to mark range boundaries
        local eff_start = math.max(clip_start, mark_in)
        local eff_end = math.min(clip_end, mark_out)
        local eff_duration = eff_end - eff_start

        -- Adjust source_in/source_out for the trimmed portion.
        -- left_trim/right_trim are in timeline frames; source coords are in source units
        -- (video frames or audio samples). Convert via clip_rate/seq_rate.
        local left_trim = eff_start - clip_start
        local right_trim = clip_end - eff_end
        local clip_rate = clip.rate.fps_numerator / clip.rate.fps_denominator
        local source_per_timeline = clip_rate / seq_rate

        local source_left = math.floor(left_trim * source_per_timeline + 0.5)
        local source_right = math.floor(right_trim * source_per_timeline + 0.5)
        local source_in = clip.source_in + source_left
        local source_out = clip.source_out - source_right

        clip_payloads[#clip_payloads + 1] = {
            original_id = clip.id,
            track_id = clip.track_id,
            fps_numerator = clip.rate.fps_numerator,
            fps_denominator = clip.rate.fps_denominator,
            nested_sequence_id = clip.nested_sequence_id,
            master_layer_track_id = clip.master_layer_track_id,
            master_audio_track_id = clip.master_audio_track_id,
            fps_mismatch_policy = clip.fps_mismatch_policy,
            owner_sequence_id = clip.owner_sequence_id,
            track_type = clip.track_type,
            timeline_start = eff_start,
            duration = eff_duration,
            source_in = source_in,
            source_out = source_out,
            name = clip.name,
            copied_properties = load_clip_properties(clip.id),
        }
        ::continue::
    end

    if #clip_payloads == 0 then
        return false, "No clips in mark range"
    end

    -- Offsets relative to mark_in
    for _, entry in ipairs(clip_payloads) do
        entry.offset_frames = entry.timeline_start - mark_in
        log.event("  clipboard entry: track=%s name=%s offset=%d dur=%d src_in=%d src_out=%d",
            tostring(entry.track_id), tostring(entry.name),
            entry.offset_frames, entry.duration, entry.source_in, entry.source_out)
    end

    local payload = {
        kind = "timeline_clips",
        project_id = (timeline_state.get_project_id and timeline_state.get_project_id()) or nil,
        sequence_id = (timeline_state.get_sequence_id and timeline_state.get_sequence_id()) or nil,
        reference_start_frame = mark_in,
        clips = clip_payloads,
        count = #clip_payloads,
    }
    assert(payload.project_id and payload.project_id ~= "")
    assert(payload.sequence_id and payload.sequence_id ~= "")

    clipboard.set(payload)
    log.event("Copied %d clip(s) from mark range [%d, %d)", #clip_payloads, mark_in, mark_out)
    return true
end

local function copy_timeline_selection()
    if not timeline_state or not timeline_state.get_selected_clips then
        return false, "Timeline state unavailable"
    end

    local selected = timeline_state.get_selected_clips() or {}
    if #selected == 0 then
        return false, "No timeline clips selected"
    end

    local clip_payloads = {}
    local earliest_start_frame = math.huge

    for _, raw in ipairs(selected) do
        local clip = resolve_clip_entry(raw)
        if clip and clip.id and clip.track_id and clip.timeline_start then
            assert(type(clip.timeline_start) == "number", "clipboard_actions: clip.timeline_start must be integer")
            local start_frame = clip.timeline_start

            if clip.nested_sequence_id == nil then
                goto continue
            end

            earliest_start_frame = math.min(earliest_start_frame, start_frame)

            assert(clip.rate and clip.rate.fps_numerator and clip.rate.fps_denominator,
                "clipboard_actions.copy_timeline_selection: clip " .. tostring(clip.id) .. " missing rate metadata")
            assert(type(clip.duration) == "number", "clipboard_actions: clip.duration must be integer")
            assert(type(clip.source_in) == "number", "clipboard_actions: clip.source_in must be integer")
            assert(type(clip.source_out) == "number", "clipboard_actions: clip.source_out must be integer")
            clip_payloads[#clip_payloads + 1] = {
                original_id = clip.id,
                track_id = clip.track_id,
                fps_numerator = clip.rate.fps_numerator,
                fps_denominator = clip.rate.fps_denominator,
                nested_sequence_id = clip.nested_sequence_id,
                master_layer_track_id = clip.master_layer_track_id,
                master_audio_track_id = clip.master_audio_track_id,
                fps_mismatch_policy = clip.fps_mismatch_policy,
                owner_sequence_id = clip.owner_sequence_id,
                track_type = clip.track_type,

                -- All coords are integers
                timeline_start = clip.timeline_start,
                duration = clip.duration,
                source_in = clip.source_in,
                source_out = clip.source_out,

                name = clip.name,
                copied_properties = load_clip_properties(clip.id)
            }
        end
        ::continue::
    end

    if #clip_payloads == 0 then
        return false, "Timeline selection missing media"
    end

    if earliest_start_frame == math.huge then
        assert(type(clip_payloads[1].timeline_start) == "number",
            "clipboard_actions: first clip timeline_start must be integer")
        earliest_start_frame = clip_payloads[1].timeline_start
    end

    for _, entry in ipairs(clip_payloads) do
        assert(type(entry.timeline_start) == "number",
            "clipboard_actions: clip timeline_start must be integer for offset calculation")
        entry.offset_frames = entry.timeline_start - earliest_start_frame
    end

    local payload = {
        kind = "timeline_clips",
        project_id = (timeline_state.get_project_id and timeline_state.get_project_id()) or nil,
        sequence_id = (timeline_state.get_sequence_id and timeline_state.get_sequence_id()) or nil,
        reference_start_frame = earliest_start_frame,
        clips = clip_payloads,
        count = #clip_payloads
    }
    assert(payload.project_id and payload.project_id ~= "", "clipboard_actions.copy_timeline_selection: missing active project_id")
    assert(payload.sequence_id and payload.sequence_id ~= "", "clipboard_actions.copy_timeline_selection: missing active sequence_id")

    clipboard.set(payload)
    log.event("Copied %d timeline clip(s)", #clip_payloads)
    return true
end

local function paste_timeline()
    local project_id = (timeline_state.get_project_id and timeline_state.get_project_id()) or nil
    assert(project_id and project_id ~= "", "clipboard_actions.paste_timeline: missing active project_id")

    local result = command_manager.execute_interactive("Paste", {
        project_id = project_id,
    })
    if not result or not result.success then
        return false, result and result.error_message or "Paste command failed"
    end
    return true
end

local function normalize_selection_item(item)
    if type(item) ~= "table" then
        return nil
    end
    if item.type == "master_clip" then
        return item
    end
    return nil
end

local function duplicate_name(base)
    assert(base and base ~= "", "clipboard_actions.duplicate_name: base name required")
    if base:lower():match(" copy$") then
        return base
    end
    return base .. " copy"
end

local function copy_browser_selection()
    if not project_browser or not project_browser.get_selection_snapshot then
        return false, "Project browser unavailable"
    end

    local snapshot = project_browser.get_selection_snapshot()
    if not snapshot or #snapshot == 0 then
        return false, "No browser items selected"
    end

    -- V13: a project-browser "master clip" is a master Sequence with one
    -- media leaf reachable via media_refs. Load the sequence + first
    -- media_ref to materialise the snapshot DuplicateMasterClip needs.
    local Sequence = require("models.sequence")
    local items = {}
    local project_id = nil
    for _, raw in ipairs(snapshot) do
        local entry = normalize_selection_item(raw)
        if entry and entry.clip_id then
            local seq = Sequence.load(entry.clip_id)
            if seq and seq.kind == "master" then
                project_id = project_id or seq.project_id or entry.project_id
                assert(project_id and project_id ~= "",
                    "clipboard_actions.copy_browser_selection: missing project_id for master " .. tostring(entry.clip_id))
                local leaf_media_id, leaf_source_out =
                    Sequence.get_first_media_ref(entry.clip_id)
                if leaf_media_id then
                    items[#items + 1] = {
                        bin_id = entry.bin_id,
                        duplicate_name = duplicate_name(entry.name or seq.name),
                        snapshot = {
                            name = seq.name,
                            media_id = leaf_media_id,
                            fps_numerator = seq.frame_rate.fps_numerator,
                            fps_denominator = seq.frame_rate.fps_denominator,
                            duration = leaf_source_out,
                            source_in = 0,
                            source_out = leaf_source_out,
                            timeline_start = 0,
                            project_id = project_id,
                        },
                        copied_properties = load_clip_properties(entry.clip_id),
                    }
                end
            end
        end
    end

    if #items == 0 then
        return false, "Browser selection missing master clips"
    end

    local payload = {
        kind = "browser_master_clips",
        project_id = assert(project_id, "clipboard_actions.copy_browser_selection: unable to determine project_id"),
        items = items,
        count = #items
    }

    clipboard.set(payload)
    log.event("Copied %d master clip(s)", #items)
    return true
end

local function resolve_target_bin(default_bin_id)
    if not project_browser then
        return default_bin_id
    end
    if project_browser.get_selected_bin then
        local bin = project_browser.get_selected_bin()
        if bin and bin.id and bin.id ~= "" then
            return bin.id
        end
    end
    return default_bin_id
end

local function paste_browser(payload)
    if type(payload) ~= "table" or payload.kind ~= "browser_master_clips" then
        return false, "Clipboard does not contain browser items"
    end

    local items = payload.items or {}
    if #items == 0 then
        return false, "Clipboard is empty"
    end

    local project_id = assert(payload.project_id, "clipboard_actions.paste_browser: payload missing project_id")
    local target_bin_override = resolve_target_bin(nil)

    command_manager.begin_undo_group("PasteBrowser")

    local pasted = 0
    local failed = 0
    for _, item in ipairs(items) do
        if item.snapshot and item.snapshot.media_id then
            local result = command_manager.execute_interactive("DuplicateMasterClip", {
                project_id = project_id,
                clip_snapshot = item.snapshot,
                bin_id = target_bin_override or item.bin_id,
                new_master_id = uuid.generate(),
                name = item.duplicate_name,
                copied_properties = item.copied_properties,
            })
            assert(type(result) == "table", "paste_browser: execute returned non-table")
            if result.success then
                pasted = pasted + 1
            else
                failed = failed + 1
                log.error("paste_browser: DuplicateMasterClip failed: %s",
                    result.error_message or "unknown")
            end
        end
    end

    command_manager.end_undo_group()

    if failed > 0 then
        log.warn("paste_browser: %d of %d paste(s) failed", failed, pasted + failed)
    end
    if pasted == 0 then
        return false, "Clipboard snapshot missing media references"
    end

    if project_browser and project_browser.refresh then
        project_browser.refresh()
    end

    log.event("Pasted %d browser clip(s)", pasted)
    return true
end

--- Copy based on focused panel.
-- @return boolean success, string|nil error_message
function M.copy()
    local focused_panel = focus_manager.get_focused_panel and focus_manager.get_focused_panel()
    if focused_panel == "timeline" then
        -- Marks take priority over selection for copy
        local mark_in = timeline_state.get_mark_in and timeline_state.get_mark_in()
        local mark_out = timeline_state.get_mark_out and timeline_state.get_mark_out()
        if mark_in and mark_out and mark_out > mark_in then
            return copy_mark_range()
        end
        return copy_timeline_selection()
    elseif focused_panel == "project_browser" then
        return copy_browser_selection()
    end
    return false, "Copy is available only in the timeline or project browser"
end

--- Paste clipboard payload based on focus.
-- @return boolean success, string|nil error_message
function M.paste()
    local payload = clipboard.get()
    if not payload then
        return false, "Clipboard is empty"
    end

    local focused_panel = focus_manager.get_focused_panel and focus_manager.get_focused_panel()
    if payload.kind == "timeline_clips" then
        if focused_panel ~= "timeline" then
            return false, "Timeline paste requires timeline focus"
        end
        return paste_timeline()
    elseif payload.kind == "browser_master_clips" then
        if focused_panel ~= "project_browser" then
            return false, "Browser paste requires project browser focus"
        end
        return paste_browser(payload)
    end

    return false, string.format("Clipboard kind '%s' not supported", tostring(payload.kind))
end

return M
