-- Clipboard-aware copy/paste helpers for timeline and project browser

local clipboard = require("core.clipboard")
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

-- Rational serialization helpers for JSON compatibility
-- Rational objects have metatables that don't serialize, so convert to plain tables
local function serialize_rational(rational_obj)
    if not rational_obj then return nil end

    -- Rational objects have: frames, fps_numerator, fps_denominator
    return {
        frames = rational_obj.frames,
        num = rational_obj.fps_numerator,
        den = rational_obj.fps_denominator
    }
end

local function deserialize_rational(table_obj)
    if not table_obj or not table_obj.frames then return nil end

    local Rational = require("core.rational")
    return Rational.new(table_obj.frames, table_obj.num, table_obj.den)
end

local function get_active_sequence_rate()
    local conn = database.get_connection()
    if not conn then
        error("clipboard_actions: No database connection for sequence rate detection", 2)
    end

    local sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id() or nil
    if not sequence_id or sequence_id == "" then
        error("clipboard_actions: missing active sequence_id for sequence rate detection", 2)
    end

    local query = conn:prepare([[
        SELECT fps_numerator, fps_denominator
        FROM sequences
        WHERE id = ?
    ]])

    if not query then
        error("clipboard_actions: Failed to prepare sequence rate query", 2)
    end

    query:bind_value(1, sequence_id)
    if query:exec() and query:next() then
        local num = query:value(0)
        local den = query:value(1)
        query:finalize()

        -- Validate frame rate values
        if num and num > 0 and den and den > 0 then
            return num, den
        else
            error(string.format("clipboard_actions: invalid sequence frame rate %s/%s for %s",
                tostring(num), tostring(den), tostring(sequence_id)), 2)
        end
    end

    query:finalize()
    error("clipboard_actions: active sequence not found: " .. tostring(sequence_id), 2)
end

local function load_clip_properties(clip_id)
    local props = {}
    if not clip_id or clip_id == "" then
        return props
    end

    local conn = database.get_connection()
    if not conn then
        return props
    end

    local stmt = conn:prepare([[
        SELECT property_name, property_value, property_type, default_value
        FROM properties
        WHERE clip_id = ?
    ]])
    if not stmt then
        return props
    end

    stmt:bind_value(1, clip_id)
    if stmt:exec() then
        while stmt:next() do
            props[#props + 1] = {
                property_name = stmt:value(0),
                property_value = stmt:value(1),
                property_type = stmt:value(2),
                default_value = stmt:value(3)
            }
        end
    end
    stmt:finalize()
    return props
end

local function resolve_clip_entry(entry)
    if type(entry) == "table" and entry.start_value and entry.track_id then
        return entry
    end
    if type(entry) == "table" and entry.id and timeline_state.get_clip_by_id then
        return timeline_state.get_clip_by_id(entry.id)
    end
    if type(entry) == "string" and timeline_state.get_clip_by_id then
        return timeline_state.get_clip_by_id(entry)
    end
    return nil
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
            
            local start_frame = clip.timeline_start.frames
            
            if clip.media_id == nil and clip.parent_clip_id == nil then
                goto continue
            end

            earliest_start_frame = math.min(earliest_start_frame, start_frame)

            clip_payloads[#clip_payloads + 1] = {
                original_id = clip.id,
                track_id = clip.track_id,
                media_id = clip.media_id,
                parent_clip_id = clip.parent_clip_id,
                source_sequence_id = clip.source_sequence_id,
                owner_sequence_id = clip.owner_sequence_id,
                clip_kind = clip.clip_kind,

                -- Serialize Rational objects to plain tables for JSON
                timeline_start = serialize_rational(clip.timeline_start),
                duration = serialize_rational(clip.duration),
                source_in = serialize_rational(clip.source_in),
                source_out = serialize_rational(clip.source_out),

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
        earliest_start_frame = (clip_payloads[1].timeline_start and clip_payloads[1].timeline_start.frames or 0)
    end

    for _, entry in ipairs(clip_payloads) do
        local entry_start_frame = (entry.timeline_start and entry.timeline_start.frames or 0)
        entry.offset_frames = entry_start_frame - earliest_start_frame
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
    print(string.format("📋 Copied %d timeline clip(s)", #clip_payloads))
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

    local Rational = require("core.rational")
    local playhead_ms = (timeline_state.get_playhead_position and timeline_state.get_playhead_position()) or 0

    -- Get active sequence frame rate from database
    local seq_fps_num, seq_fps_den = get_active_sequence_rate()

    -- Convert playhead (milliseconds) to frames at sequence rate
    local playhead_frames = math.floor((playhead_ms / 1000.0) * (seq_fps_num / seq_fps_den))

    local clips = payload.clips or {}
    if #clips == 0 then
        return false, "Clipboard is empty"
    end

    local specs = {}
    local new_selection = {}

    for _, clip_data in ipairs(clips) do
        if clip_data.track_id and (clip_data.media_id or clip_data.parent_clip_id) then

            -- Deserialize Rational objects from JSON tables
            local timeline_start = deserialize_rational(clip_data.timeline_start)
            local duration = deserialize_rational(clip_data.duration)
            local source_in = deserialize_rational(clip_data.source_in)
            local source_out = deserialize_rational(clip_data.source_out)

            if not timeline_start or not duration then
                print(string.format("WARNING: Skipping clip %s - missing timing data",
                                    clip_data.original_id or "unknown"))
                goto continue
            end

            -- Calculate offset from reference point
            local offset_frames = clip_data.offset_frames or 0
            local paste_start_frame = playhead_frames + offset_frames

            -- Create new Rational at paste position (preserving original clip's frame rate)
            local overwrite_time = Rational.new(
                paste_start_frame,
                timeline_start.fps_numerator,
                timeline_start.fps_denominator
            )

            local clip_id = uuid.generate()

            local spec = {
                command_type = "Overwrite",
                parameters = {
                    project_id = project_id,
                    sequence_id = active_sequence_id,
                    track_id = clip_data.track_id,
                    media_id = clip_data.media_id,
                    master_clip_id = clip_data.parent_clip_id,
                    overwrite_time = overwrite_time,
                    duration = duration,
                    source_in = source_in,
                    source_out = source_out,
                    clip_name = clip_data.name,
                    clip_id = clip_id,
                    copied_properties = clip_data.copied_properties,
                    advance_playhead = false
                }
            }
            specs[#specs + 1] = spec
            new_selection[#new_selection + 1] = {id = clip_id}
        end
        ::continue::
    end

    if #specs == 0 then
        return false, "Clipboard clips missing media references"
    end

    local result
    if #specs == 1 then
        local spec = specs[1]
        local cmd = Command.create(spec.command_type, project_id)
        for key, value in pairs(spec.parameters) do
            cmd:set_parameter(key, value)
        end
        result = command_manager.execute(cmd)
    else
        local commands_json = json.encode(specs)
        local batch_cmd = Command.create("BatchCommand", project_id)
        batch_cmd:set_parameter("commands_json", commands_json)
        batch_cmd:set_parameter("sequence_id", active_sequence_id)
        batch_cmd:set_parameter("__snapshot_sequence_ids", {active_sequence_id})
        result = command_manager.execute(batch_cmd)
    end

    if not result or not result.success then
        local message = (result and result.error_message) or "Paste failed"
        return false, message
    end

    if timeline_state and timeline_state.set_selection then
        timeline_state.set_selection(new_selection)
    end

    print(string.format("✅ Pasted %d timeline clip(s)", #specs))
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
    base = base or "Master Clip"
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
            local clip = Clip.load(entry.clip_id, database.get_connection())
            if clip then
                project_id = project_id or clip.project_id or entry.project_id
                if not project_id or project_id == "" then
                    error("Clipboard copy: missing project_id for browser selection clip " .. tostring(entry.clip_id), 2)
                end
                items[#items + 1] = {
                    bin_id = entry.bin_id,
                    duplicate_name = duplicate_name(entry.name or clip.name),
                    snapshot = {
                        name = clip.name,
                        media_id = clip.media_id,
                        duration = clip.duration,
                        source_in = clip.source_in or 0,
                        source_out = clip.source_out or clip.duration,
                        source_sequence_id = clip.source_sequence_id,
                        start_value = clip.start_value or 0,
                        enabled = clip.enabled,
                        offline = clip.offline,
                        project_id = clip.project_id or entry.project_id,
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
        project_id = project_id or database.get_current_project_id(),
        items = items,
        count = #items
    }

    clipboard.set(payload)
    print(string.format("📋 Copied %d master clip(s)", #items))
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

    local project_id = payload.project_id or database.get_current_project_id()
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
    local batch_cmd = Command.create("BatchCommand", project_id)
    batch_cmd:set_parameter("commands_json", commands_json)
    local result = command_manager.execute(batch_cmd)

    if not result or not result.success then
        local message = (result and result.error_message) or "Paste failed"
        return false, message
    end

    if project_browser and project_browser.refresh then
        project_browser.refresh()
    end

    print(string.format("✅ Pasted %d browser clip(s)", #specs))
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
