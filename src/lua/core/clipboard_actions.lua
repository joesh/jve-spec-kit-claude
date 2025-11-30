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
    local earliest_start = math.huge

    for _, raw in ipairs(selected) do
        local clip = resolve_clip_entry(raw)
        if clip and clip.id and clip.track_id and clip.start_value then
            if clip.media_id == nil and clip.parent_clip_id == nil then
                goto continue
            end

            earliest_start = math.min(earliest_start, clip.start_value)
            local duration = clip.duration or ((clip.source_out or 0) - (clip.source_in or 0))

            clip_payloads[#clip_payloads + 1] = {
                original_id = clip.id,
                track_id = clip.track_id,
                media_id = clip.media_id,
                parent_clip_id = clip.parent_clip_id,
                source_sequence_id = clip.source_sequence_id,
                owner_sequence_id = clip.owner_sequence_id,
                clip_kind = clip.clip_kind,
                start_value = clip.start_value,
                duration = duration,
                source_in = clip.source_in or 0,
                source_out = clip.source_out or ((clip.source_in or 0) + duration),
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

    if earliest_start == math.huge then
        earliest_start = clip_payloads[1].start_value or 0
    end

    for _, entry in ipairs(clip_payloads) do
        entry.offset = (entry.start_value or 0) - earliest_start
    end

    local payload = {
        kind = "timeline_clips",
        project_id = (timeline_state.get_project_id and timeline_state.get_project_id()) or "default_project",
        sequence_id = (timeline_state.get_sequence_id and timeline_state.get_sequence_id()) or "default_sequence",
        reference_start = earliest_start,
        clips = clip_payloads,
        count = #clip_payloads
    }

    clipboard.set(payload)
    print(string.format("📋 Copied %d timeline clip(s)", #clip_payloads))
    return true
end

local function paste_timeline(payload)
    if type(payload) ~= "table" or payload.kind ~= "timeline_clips" then
        return false, "Clipboard does not contain timeline clips"
    end

    local active_sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id() or "default_sequence"
    if payload.sequence_id and payload.sequence_id ~= active_sequence_id then
        return false, string.format("Clipboard sequence '%s' differs from active sequence '%s'",
            tostring(payload.sequence_id), tostring(active_sequence_id))
    end

    local project_id = (timeline_state.get_project_id and timeline_state.get_project_id())
        or payload.project_id or "default_project"
    local playhead = (timeline_state.get_playhead_position and timeline_state.get_playhead_position()) or 0

    local clips = payload.clips or {}
    if #clips == 0 then
        return false, "Clipboard is empty"
    end

    local specs = {}
    local new_selection = {}

    for _, clip in ipairs(clips) do
        if clip.track_id and (clip.media_id or clip.parent_clip_id) then
            local overwrite_time = playhead + (clip.offset or 0)
            local clip_id = uuid.generate()

            local spec = {
                command_type = "Overwrite",
                parameters = {
                    project_id = project_id,
                    sequence_id = active_sequence_id,
                    track_id = clip.track_id,
                    media_id = clip.media_id,
                    master_clip_id = clip.parent_clip_id,
                    overwrite_time = overwrite_time,
                    duration = clip.duration,
                    source_in = clip.source_in,
                    source_out = clip.source_out,
                    clip_name = clip.name,
                    clip_id = clip_id,
                    copied_properties = clip.copied_properties,
                    advance_playhead = false
                }
            }
            specs[#specs + 1] = spec
            new_selection[#new_selection + 1] = {id = clip_id}
        end
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
                project_id = project_id or clip.project_id or entry.project_id or "default_project"
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
