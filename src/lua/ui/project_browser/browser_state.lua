-- Project Browser selection state
-- Normalizes browser selections into inspector-friendly payloads and notifies listeners.

local json = require("dkjson")
local selection_hub = require("ui.selection_hub")

local M = {}

local current_selection = {}
local selection_callback = nil

local function decode_metadata(raw)
    if not raw or raw == "" then
        return {}
    end

    if type(raw) == "table" then
        return raw
    end

    if type(raw) == "string" then
        local ok, decoded = pcall(json.decode, raw)
        if ok and type(decoded) == "table" then
            return decoded
        end
    end

    return {}
end

local function normalize_master_clip(item, context)
    context = context or {}
    local clip = nil

    if context.master_lookup and item.clip_id then
        clip = context.master_lookup[item.clip_id]
    end

    if not clip and context.master_lookup and item.media_id then
        clip = context.master_lookup[item.media_id]
    end

    if not clip and type(item.clip) == "table" then
        clip = item.clip
    end

    if not clip then
        return nil
    end

    local media = clip.media
    if not media and context.media_lookup and clip.media_id then
        media = context.media_lookup[clip.media_id]
    end

    local duration = tonumber(clip.duration or (media and media.duration) or 0) or 0
    local source_in = tonumber(clip.source_in) or 0
    local source_out = tonumber(clip.source_out) or duration

    return {
        id = clip.clip_id,
        clip_id = clip.clip_id,
        media_id = clip.media_id,
        name = clip.name or (media and media.name) or clip.clip_id,
        duration = duration,
        start_time = source_in,
        source_in = source_in,
        source_out = source_out,
        frame_rate = clip.frame_rate or (media and media.frame_rate) or 0,
        width = clip.width or (media and media.width) or 0,
        height = clip.height or (media and media.height) or 0,
        codec = clip.codec or (media and media.codec),
        file_path = clip.file_path or (media and media.file_path),
        metadata = decode_metadata(media and media.metadata),
        offline = clip.offline,
        master_sequence_id = clip.source_sequence_id,
        item_type = "master_clip",
        view = "project_browser",
    }
end

local function normalize_timeline(item, context)
    context = context or {}
    local sequence = nil

    if context.sequence_lookup and item.id then
        sequence = context.sequence_lookup[item.id]
    end

    if not sequence and item then
        sequence = item
    end

    if not sequence then
        return nil
    end

    local duration = tonumber(sequence.duration) or 0

    return {
        id = sequence.id,
        name = sequence.name or sequence.id,
        duration = duration,
        start_time = 0,
        source_in = 0,
        source_out = duration,
        frame_rate = sequence.frame_rate or 0,
        width = sequence.width or 0,
        height = sequence.height or 0,
        metadata = {},
        item_type = "timeline",
        view = "project_browser",
    }
end

function M.normalize_selection(raw_items, context)
    if type(raw_items) ~= "table" then
        return {}
    end

    local normalized = {}
    for _, item in ipairs(raw_items) do
        if item and (item.type == "clip" or item.type == "master_clip") then
            local clip_entry = normalize_master_clip(item, context)
            if clip_entry then
                table.insert(normalized, clip_entry)
            end
        elseif item and item.type == "timeline" then
            local timeline_entry = normalize_timeline(item, context)
            if timeline_entry then
                table.insert(normalized, timeline_entry)
            end
        end
    end
    return normalized
end

function M.update_selection(raw_items, context)
    current_selection = M.normalize_selection(raw_items, context)
    selection_hub.update_selection("project_browser", current_selection)
    if selection_callback then
        selection_callback(current_selection)
    end
    return current_selection
end

function M.clear_selection()
    current_selection = {}
    selection_hub.update_selection("project_browser", current_selection)
    if selection_callback then
        selection_callback(current_selection)
    end
end

function M.get_selected_items()
    return current_selection
end

function M.set_on_selection_changed(callback)
    selection_callback = callback
    if selection_callback then
        selection_callback(current_selection)
    end
end

return M
