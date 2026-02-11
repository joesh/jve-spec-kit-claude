--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~485 LOC
-- Volatility: unknown
--
-- @file clipboard_actions.lua
-- Original intent (unreviewed):
-- Clipboard-aware copy/paste helpers for timeline and project browser
local clipboard = require("core.clipboard")
local logger = require("core.logger")
local focus_manager = require("ui.focus_manager")
local timeline_state = require("ui.timeline.timeline_state")
local command_manager = require("core.command_manager")
local database = require("core.database")
local Command = require("command")
local uuid = require("uuid")
local Clip = require("models.clip")
local json = require("dkjson")

local project_browser = nil
do
    local ok, mod = pcall(require, "ui.project_browser")
    if ok and type(mod) == "table" then
        project_browser = mod
    end
end

local M = {}

local function get_active_sequence_rate()
    local sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id() or nil
    if not sequence_id or sequence_id == "" then
        error("clipboard_actions: missing active sequence_id for sequence rate detection", 2)
    end

    local Sequence = require("models.sequence")
    local sequence = Sequence.load(sequence_id)

    if not sequence then
        error("clipboard_actions: active sequence not found: " .. tostring(sequence_id), 2)
    end

    if not sequence.frame_rate or not sequence.frame_rate.fps_numerator or not sequence.frame_rate.fps_denominator then
        error(string.format("clipboard_actions: sequence %s missing frame rate", tostring(sequence_id)), 2)
    end

    local num = sequence.frame_rate.fps_numerator
    local den = sequence.frame_rate.fps_denominator

    -- Validate frame rate values
    if num and num > 0 and den and den > 0 then
        return num, den
    else
        error(string.format("clipboard_actions: invalid sequence frame rate %s/%s for %s",
            tostring(num), tostring(den), tostring(sequence_id)), 2)
    end
end

local function load_clip_properties(clip_id)
    assert(clip_id and clip_id ~= "", "clipboard_actions.load_clip_properties: clip_id required")
    local Property = require("models.property")
    local props = Property.load_for_clip(clip_id)
    return props or {}
end

local function resolve_clip_entry(entry)
    if type(entry) == "table" and entry.start_value and entry.track_id then
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

            if clip.master_clip_id == nil then
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
                media_id = clip.media_id,
                fps_numerator = clip.rate.fps_numerator,
                fps_denominator = clip.rate.fps_denominator,
                parent_clip_id = clip.parent_clip_id,
                master_clip_id = clip.master_clip_id,
                owner_sequence_id = clip.owner_sequence_id,
                clip_kind = clip.clip_kind,

                -- All coords are integers
                timeline_start = clip.timeline_start,
                duration = clip.duration,
                source_in = clip.source_in,
                source_out = clip.source_out,

                name = clip.name,
                offline = clip.offline,
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
    logger.info("clipboard_actions", string.format("Copied %d timeline clip(s)", #clip_payloads))
    return true
end

local function paste_timeline(payload)
    if type(payload) ~= "table" or payload.kind ~= "timeline_clips" then
        return false, "Clipboard does not contain timeline clips"
    end

    local active_sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id() or nil
    assert(active_sequence_id and active_sequence_id ~= "", "clipboard_actions.paste_timeline: missing active sequence_id")
    if payload.sequence_id and payload.sequence_id ~= active_sequence_id then
        return false, string.format("Clipboard sequence '%s' differs from active sequence_id '%s'",
            tostring(payload.sequence_id), tostring(active_sequence_id))
    end

    local project_id = (timeline_state.get_project_id and timeline_state.get_project_id()) or nil
    assert(project_id and project_id ~= "", "clipboard_actions.paste_timeline: missing active project_id")

    assert(timeline_state.get_playhead_position, "clipboard_actions.paste_timeline: timeline_state missing get_playhead_position")
    local playhead_ms = timeline_state.get_playhead_position()
    assert(playhead_ms ~= nil, "clipboard_actions.paste_timeline: playhead position is nil")

    -- Get active sequence frame rate from database
    local seq_fps_num, seq_fps_den = get_active_sequence_rate()

    -- Convert playhead (milliseconds) to frames at sequence rate
    local playhead_frames = math.floor((playhead_ms / 1000.0) * (seq_fps_num / seq_fps_den))

    local clips = payload.clips or {}
    if #clips == 0 then
        return false, "Clipboard is empty"
    end

    local new_selection = {}
    local tracks = database.load_tracks(active_sequence_id)
    local track_lookup = {}
    for _, track in ipairs(tracks) do
        if track and track.id then
            track_lookup[track.id] = track
        end
    end

    for _, clip_data in ipairs(clips) do
        if clip_data.track_id and (clip_data.media_id or clip_data.parent_clip_id) then
            local track = assert(track_lookup[clip_data.track_id], "clipboard_actions.paste_timeline: missing track for clip")
            local track_type = assert(track.track_type, "clipboard_actions.paste_timeline: missing track type")

            -- All coords are integers
            assert(type(clip_data.timeline_start) == "number", "clipboard_actions.paste_timeline: timeline_start must be integer")
            assert(type(clip_data.duration) == "number", "clipboard_actions.paste_timeline: duration must be integer")
            assert(type(clip_data.source_in) == "number", "clipboard_actions.paste_timeline: source_in must be integer")
            assert(type(clip_data.source_out) == "number", "clipboard_actions.paste_timeline: source_out must be integer")

            -- Calculate offset from reference point
            assert(clip_data.offset_frames ~= nil, "clipboard_actions.paste_timeline: clip missing offset_frames")
            local offset_frames = clip_data.offset_frames
            local paste_start_frame = playhead_frames + offset_frames

            -- Clipboard clips are single video OR audio clips (not linked pairs)
            -- Paste directly using Overwrite command
            assert(track_type == "VIDEO" or track_type == "AUDIO",
                "clipboard_actions.paste_timeline: unsupported track type: " .. tostring(track_type))

            local clip_id = uuid.generate()
            local cmd = assert(Command.create("Overwrite", project_id),
                "clipboard_actions.paste_timeline: failed to create command")
            cmd:set_parameters({
                sequence_id = active_sequence_id,
                track_id = track.id,
                overwrite_time = paste_start_frame,
                duration = clip_data.duration,
                source_in = clip_data.source_in,
                source_out = clip_data.source_out,
                project_id = project_id,
                clip_id = clip_id,
            })
            -- master_clip_id is the masterclip sequence ID (master_clip_id on timeline clips)
            if clip_data.master_clip_id then
                cmd:set_parameter("master_clip_id", clip_data.master_clip_id)
            end
            if clip_data.name then
                cmd:set_parameter("clip_name", clip_data.name)
            end
            assert(clip_data.master_clip_id,
                "clipboard_actions.paste_timeline: missing master_clip_id")

            local result = command_manager.execute(cmd)
            assert(result and result.success,
                string.format("clipboard_actions.paste_timeline: paste failed: %s",
                    result and result.error_message or "unknown error"))

            new_selection[#new_selection + 1] = {id = clip_id}
        end
    end

    if #new_selection == 0 then
        return false, "Clipboard clips missing media references"
    end

    if timeline_state and timeline_state.set_selection then
        timeline_state.set_selection(new_selection)
    end

    logger.info("clipboard_actions", string.format("Pasted %d timeline clip(s)", #new_selection))
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

    local items = {}
    local project_id = nil
    for _, raw in ipairs(snapshot) do
        local entry = normalize_selection_item(raw)
        if entry and entry.clip_id then
            local clip = Clip.load(entry.clip_id)
            if clip then
                project_id = project_id or clip.project_id or entry.project_id
                assert(project_id and project_id ~= "",
                    "clipboard_actions.copy_browser_selection: missing project_id for clip " .. tostring(entry.clip_id))
                items[#items + 1] = {
                    bin_id = entry.bin_id,
                    duplicate_name = duplicate_name(entry.name or clip.name),
                    snapshot = {
                        name = clip.name,
                        media_id = clip.media_id,
                        fps_numerator = assert(clip.rate and clip.rate.fps_numerator,
                            "clipboard_actions: browser clip " .. tostring(entry.clip_id) .. " missing rate.fps_numerator"),
                        fps_denominator = assert(clip.rate and clip.rate.fps_denominator,
                            "clipboard_actions: browser clip " .. tostring(entry.clip_id) .. " missing rate.fps_denominator"),
                        duration = assert(clip.duration,
                            "clipboard_actions: browser clip " .. tostring(entry.clip_id) .. " missing duration"),
                        source_in = assert(clip.source_in,
                            "clipboard_actions: browser clip " .. tostring(entry.clip_id) .. " missing source_in"),
                        source_out = assert(clip.source_out,
                            "clipboard_actions: browser clip " .. tostring(entry.clip_id) .. " missing source_out"),
                        master_clip_id = clip.master_clip_id,
                        start_value = assert(clip.start_value,
                            "clipboard_actions: browser clip " .. tostring(entry.clip_id) .. " missing start_value"),
                        enabled = clip.enabled,
                        offline = clip.offline,
                        project_id = assert(clip.project_id or entry.project_id,
                            "clipboard_actions: browser clip " .. tostring(entry.clip_id) .. " missing project_id"),
                        clip_kind = clip.clip_kind,
                    },
                    copied_properties = load_clip_properties(clip.id)
                }
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
    logger.info("clipboard_actions", string.format("Copied %d master clip(s)", #items))
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

    local specs = {}
    for _, item in ipairs(items) do
        if item.snapshot and item.snapshot.media_id then
            local params = {
                project_id = project_id,
                clip_snapshot = item.snapshot,
                bin_id = target_bin_override or item.bin_id,
                new_clip_id = uuid.generate(),
                name = item.duplicate_name,
                copied_properties = item.copied_properties
            }
            specs[#specs + 1] = {
                command_type = "DuplicateMasterClip",
                parameters = params
            }
        end
    end

    if #specs == 0 then
        return false, "Clipboard snapshot missing media references"
    end

    local commands_json = json.encode(specs)
    local result = command_manager.execute("BatchCommand", {
        commands_json = commands_json,
        project_id = project_id,
    })

    if not result or not result.success then
        local message = (result and result.error_message) or "Paste failed"
        return false, message
    end

    if project_browser and project_browser.refresh then
        project_browser.refresh()
    end

    logger.info("clipboard_actions", string.format("Pasted %d browser clip(s)", #specs))
    return true
end

--- Copy based on focused panel.
-- @return boolean success, string|nil error_message
function M.copy()
    local focused_panel = focus_manager.get_focused_panel and focus_manager.get_focused_panel()
    if focused_panel == "timeline" then
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
        return paste_timeline(payload)
    elseif payload.kind == "browser_master_clips" then
        if focused_panel ~= "project_browser" then
            return false, "Browser paste requires project browser focus"
        end
        return paste_browser(payload)
    end

    return false, string.format("Clipboard kind '%s' not supported", tostring(payload.kind))
end

return M
