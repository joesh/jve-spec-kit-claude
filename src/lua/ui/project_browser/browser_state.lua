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

local function normalize_media(item, context)
    context = context or {}
    local media = nil

    if context.media_lookup and item.media_id then
        media = context.media_lookup[item.media_id]
    end

    if not media and type(item.media) == "table" then
        media = item.media
    end

    if not media then
        return nil
    end

    local duration = tonumber(media.duration) or 0

    return {
        id = media.id,
        media_id = media.id,
        name = media.name or media.file_name or media.id,
        duration = duration,
        start_time = 0,
        source_in = 0,
        source_out = duration,
        frame_rate = media.frame_rate or 0,
        width = media.width or 0,
        height = media.height or 0,
        codec = media.codec,
        file_path = media.file_path,
        metadata = decode_metadata(media.metadata),
        item_type = "media",
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
        if item and item.type == "clip" then
            local media_entry = normalize_media(item, context)
            if media_entry then
                table.insert(normalized, media_entry)
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
