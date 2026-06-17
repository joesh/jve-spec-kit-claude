--- Per-channel names embedded in pro-audio media (BWF/WAV iXML TRACK_LIST).
---
--- A field recorder labels each track it captures (BOOM, LAV-A, the boom
--- operator's name, ...) and writes those labels into the file's iXML
--- <TRACK_LIST>: one <TRACK> per recorded channel, with <INTERLEAVE_INDEX>
--- giving the channel's 1-based position in the interleaved stream and
--- <NAME> the label. JVE's media_refs index channels 0-based
--- (source_channel), so source_channel N maps to INTERLEAVE_INDEX N+1.
---
--- These names are the dynamic fallback shown on a master's audio tracks
--- when the user has not renamed them (see ui/timeline/track_header_label).
--- The probe is lazy (driven by the view when a master tab opens) and
--- session-cached per media id — re-derived from the file each launch, so a
--- recorder re-label is picked up without persistence. The names are NEVER
--- written into the project; tracks.name holds only the user's override.
---
--- This reads the file's metadata chunks only (RIFF chunk headers + the
--- iXML chunk body) — it does not decode audio. XML parsing reuses the
--- C++ QXmlStreamReader binding (qt_xml_parse_string), so it runs inside
--- the editor process / --test, not bare luajit.
---
--- @file core/media/channel_names.lua
local log = require("core.logger").for_area("media")

local M = {}

-- media_id -> ({ [interleave_index]=name } | false). false marks "probed,
-- no names" so a nameless file is not re-read every header rebuild.
local cache = {}

local function read_u32le(bytes)
    local a, b, c, d = string.byte(bytes, 1, 4)
    return a + b * 256 + c * 65536 + d * 16777216
end

--- Return the iXML chunk body of a RIFF/WAVE file, or nil if absent.
--- Walks the chunk list by header (8 bytes: 4-char id + u32 LE size),
--- seeking past every body except iXML's. Non-RIFF / unreadable -> nil.
local function read_ixml_chunk(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local riff = f:read(12)
    if not riff or #riff < 12
        or riff:sub(1, 4) ~= "RIFF" or riff:sub(9, 12) ~= "WAVE" then
        f:close()
        return nil
    end
    local ixml = nil
    while true do
        local header = f:read(8)
        if not header or #header < 8 then break end
        local id = header:sub(1, 4)
        local size = read_u32le(header:sub(5, 8))
        if id == "iXML" then
            ixml = f:read(size)
            break
        end
        -- chunk bodies are padded to an even byte count.
        if not f:seek("cur", size + (size % 2)) then break end
    end
    f:close()
    return ixml
end

local function find_element(element, tag)
    if element.tag == tag then return element end
    if element.children then
        for _, child in ipairs(element.children) do
            local found = find_element(child, tag)
            if found then return found end
        end
    end
    return nil
end

local function child_text(element, tag)
    if not element.children then return nil end
    for _, child in ipairs(element.children) do
        if child.tag == tag then return child.text end
    end
    return nil
end

--- Parse an iXML document string into { [interleave_index]=name }, or nil
--- if it carries no usable TRACK_LIST.
local function parse_track_names(ixml)
    assert(qt_xml_parse_string, "channel_names: qt_xml_parse_string binding "
        .. "unavailable (requires the editor process / --test)")
    local root = qt_xml_parse_string(ixml)
    if not root then return nil end
    local track_list = find_element(root, "TRACK_LIST")
    if not track_list or not track_list.children then return nil end
    local names = {}
    local count = 0
    for _, track in ipairs(track_list.children) do
        if track.tag == "TRACK" then
            local index = tonumber(child_text(track, "INTERLEAVE_INDEX"))
            local name = child_text(track, "NAME")
            if index and name and name ~= "" then
                names[index] = name
                count = count + 1
            end
        end
    end
    if count == 0 then return nil end
    return names
end

local function probe(media_id, path)
    local ixml = read_ixml_chunk(path)
    if not ixml then
        log.detail("channel_names: no iXML in %s", path)
        return false
    end
    local names = parse_track_names(ixml)
    if not names then
        log.detail("channel_names: no TRACK_LIST names in %s", path)
        return false
    end
    return names
end

--- Channel name for a media file's 0-based source_channel, or nil if the
--- file carries no name for that channel. Lazy + session-cached per media.
--- @param media_id string   identity used as the session cache key
--- @param path string       absolute media file path
--- @param source_channel number  0-based channel index
function M.get(media_id, path, source_channel)
    assert(media_id, "channel_names.get: media_id required")
    assert(type(path) == "string" and path ~= "",
        "channel_names.get: path required")
    assert(type(source_channel) == "number",
        "channel_names.get: source_channel must be a number")
    local names = cache[media_id]
    if names == nil then
        names = probe(media_id, path)
        cache[media_id] = names
    end
    if not names then return nil end
    return names[source_channel + 1]
end

--- Drop the session cache (test isolation; not used in production).
function M.clear_cache()
    cache = {}
end

return M
