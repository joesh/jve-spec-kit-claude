--- DaVinci Resolve .drp Importer — parse, convert, and import
--
-- Responsibilities:
-- - parse_drp_file(): Parse .drp ZIP archive to structured Lua tables
-- - quick_metadata(): Lightweight name extraction (no full parse)
-- - convert(): Parse .drp and create new .jvp database (Open verb)
-- - import_into_project(): Import parsed DRP data into existing project (Import verb)
--
-- Non-goals:
-- - Opening the converted project (caller handles that)
-- - Resolve DB peer mode (that's direct open, not conversion)
--
-- Invariants:
-- - Conversion creates a NEW .jvp file (never modifies existing)
-- - All media items use duration_frames (not duration in ms)
-- - fps MUST come from DRP metadata — no silent fallbacks
--
-- @file drp_importer.lua
local M = {}

local log = require("core.logger").for_area("media")

--- Unzip .drp file to temporary directory
-- @param drp_path string: Path to .drp file
-- @return string|nil: Temp directory path, or nil on error
-- @return string|nil: Error message if failed
local function extract_drp(drp_path)
    local tmp_dir = os.tmpname()
    os.remove(tmp_dir)  -- Remove the file, we want a directory
    os.execute("mkdir -p " .. tmp_dir)

    local cmd = string.format('unzip -q "%s" -d "%s"', drp_path, tmp_dir)
    local result = os.execute(cmd)

    if result ~= 0 then
        return nil, "Failed to extract .drp archive"
    end

    return tmp_dir, nil
end

--- Parse XML file using C++ QXmlStreamReader.
-- Returns {tag, text, attrs, children} table tree.
-- @param xml_path string: Path to XML file
-- @return table|nil: Root element table, or nil on error
-- @return string|nil: Error message if failed
local function parse_xml_file(xml_path)
    assert(qt_xml_parse, "qt_xml_parse not available (requires C++ bindings)")
    return qt_xml_parse(xml_path)
end

--- Parse XML from string using C++ QXmlStreamReader.
-- @param content string: XML content
-- @return table|nil: Root element table, or nil on error
-- @return string|nil: Error message if failed
local function parse_xml_string(content)
    assert(qt_xml_parse_string, "qt_xml_parse_string not available (requires C++ bindings)")
    if not content or content == "" then
        return nil, "Empty XML content"
    end
    return qt_xml_parse_string(content)
end

--- Find direct child element by tag name (non-recursive)
-- Use this for properties that belong to the element itself (Name, Duration, etc.)
-- @param elem table: XML element to search
-- @param tag_name string: Tag name to find
-- @return table|nil: First matching direct child, or nil if not found
local function find_direct_child(elem, tag_name)
    if not elem or not elem.children then return nil end

    for _, child in ipairs(elem.children) do
        if child.tag == tag_name then
            return child
        end
    end

    return nil
end

--- Find XML element by tag name (recursive search)
-- Use this for finding nested structures (tracks, clips, etc.)
-- @param elem table: XML element to search
-- @param tag_name string: Tag name to find
-- @return table|nil: First matching element, or nil if not found
local function find_element(elem, tag_name)
    if elem.tag == tag_name then
        return elem
    end

    for _, child in ipairs(elem.children) do
        local found = find_element(child, tag_name)
        if found then return found end
    end

    return nil
end

--- Find all XML elements by tag name (recursive search)
-- @param elem table: XML element to search
-- @param tag_name string: Tag name to find
-- @return table: Array of matching elements
local function find_all_elements(elem, tag_name)
    local results = {}

    if elem.tag == tag_name then
        table.insert(results, elem)
    end

    for _, child in ipairs(elem.children) do
        local found = find_all_elements(child, tag_name)
        for _, item in ipairs(found) do
            table.insert(results, item)
        end
    end

    return results
end

--- Find top-level clips within an Sm2TiTrack element.
-- DRP structure: Track > Items > Element > Sm2TiVideoClip/Sm2TiAudioClip
-- Must NOT recurse into clip internals (Fusion/compound clips nest source clips inside)
--
-- TODO: Nested clips (Fusion comps, compound clips) contain source material refs inside
-- the parent clip. We currently ignore these. To properly import them we'd need to:
--   1. Detect nested Sm2TiVideoClip/Sm2TiAudioClip within a parent clip
--   2. Determine if the parent is a compound clip or Fusion comp
--   3. Import the parent as a single clip (the rendered result)
--   4. Optionally import the nested structure as a compound clip sequence
--
-- @param track_elem table: Sm2TiTrack element
-- @param clip_tag string: "Sm2TiVideoClip" or "Sm2TiAudioClip"
-- @return table: Array of clip elements at the Items/Element level only
local function find_track_clips(track_elem, clip_tag)
    local results = {}
    local items = find_direct_child(track_elem, "Items")
    if not items then return results end

    for _, wrapper in ipairs(items.children) do
        -- Each Element wrapper contains one clip
        if wrapper.tag == "Element" then
            for _, child in ipairs(wrapper.children) do
                if child.tag == clip_tag then
                    table.insert(results, child)
                end
            end
        end
    end
    return results
end

--- Get text content from XML element
-- @param elem table: XML element
-- @return string: Trimmed text content
local function get_text(elem)
    if not elem then return "" end
    return elem.text:match("^%s*(.-)%s*$")  -- Trim whitespace
end

--- Decode a big-endian IEEE 754 double from hex string at given offset
-- @param hex_str string: Hex string containing doubles
-- @param offset number: Character offset (0 = first double, 16 = second double)
-- @return number|nil: Decoded double value, or nil if invalid
local function decode_hex_double_at(hex_str, offset)
    if not hex_str or #hex_str < offset + 16 then return nil end

    local ffi = require("ffi")

    -- Parse 16 hex chars (8 bytes) into byte array starting at offset
    -- DRP stores doubles in little-endian byte order (x86 native), no reversal needed
    local bytes = ffi.new("uint8_t[8]")
    for i = 0, 7 do
        local hex_byte = hex_str:sub(offset + i * 2 + 1, offset + i * 2 + 2)
        local byte_val = tonumber(hex_byte, 16)
        if not byte_val then return nil end
        bytes[i] = byte_val
    end

    -- Cast directly to double (already little-endian)
    local double_ptr = ffi.cast("double*", bytes)
    return double_ptr[0]
end

--- Decode a big-endian IEEE 754 double from 16-char hex string
-- DRP stores fps/resolution as 128-bit hex: two doubles, we take the first
-- Example: "00000000000038400000000000000000" = 24.0 (fps)
-- @param hex_str string: 32-char hex string (first 16 chars used)
-- @return number|nil: Decoded double value, or nil if invalid
local function decode_hex_double(hex_str)
    return decode_hex_double_at(hex_str, 0)
end

--- Decode resolution from 32-char hex string (two doubles: width, height)
-- Example: "00000000000087400000000000e08640" = 1920×1080
-- @param hex_str string: 32-char hex string
-- @return number|nil, number|nil: width, height (or nil if invalid)
local function decode_hex_resolution(hex_str)
    if not hex_str or #hex_str < 32 then return nil, nil end
    local width = decode_hex_double_at(hex_str, 0)
    local height = decode_hex_double_at(hex_str, 16)
    return width, height
end

--- Decode a protobuf varint from raw byte string
-- @param bytes string: raw byte string
-- @param pos number: 1-indexed start position
-- @return number|nil: decoded value
-- @return number: next position after varint
local function decode_protobuf_varint(bytes, pos)
    local value = 0
    local mult = 1
    while pos <= #bytes do
        local b = bytes:byte(pos)
        value = value + (b % 128) * mult
        pos = pos + 1
        if b < 128 then
            return value, pos
        end
        mult = mult * 128
    end
    return nil, pos
end

--- Decode BtVideoInfo/BtAudioInfo Clip binary blob to extract original source path.
-- DaVinci Resolve encodes the original media file path in a protobuf-like binary
-- structure inside <Clip> elements under BtVideoInfo and BtAudioInfo.
--
-- Binary layout:
--   [4B version=2] [4B payload_len] [2B marker 0x81,0x28] [8B entry_id]
--   [2B video_prefix (video only)] [protobuf fields...]
--
-- Detection: byte at offset 18 (0-indexed) == 0x0a means audio (no prefix);
--            otherwise video (2-byte prefix before protobuf).
--
-- Protobuf field 1 (tag 0x0a) = directory path
-- Protobuf field 2 (tag 0x12) = filename
-- Full path = field1 .. "/" .. field2
--
-- @param hex_str string: hex-encoded binary blob from <Clip> element
-- @return string|nil: decoded file path, or nil if unparseable
local function decode_bt_clip_path(hex_str)
    if not hex_str or #hex_str < 40 then return nil end

    -- Hex decode to raw bytes
    local parts = {}
    local clean = hex_str:gsub("%s+", "")
    if #clean % 2 ~= 0 then return nil end  -- odd-length hex = corrupt
    for i = 1, #clean, 2 do
        local h = clean:sub(i, i + 1)
        local n = tonumber(h, 16)
        if not n then return nil end
        parts[#parts + 1] = string.char(n)
    end
    local bytes = table.concat(parts)

    if #bytes < 21 then return nil end

    -- Determine protobuf start (1-indexed)
    -- Audio: byte at 0-indexed offset 18 (pos 19) is 0x0a, protobuf starts there
    -- Video: 2-byte prefix at pos 19-20, protobuf starts at pos 21
    local proto_start
    if bytes:byte(19) == 0x0a then
        proto_start = 19  -- audio: field 1 tag is the first byte
    else
        proto_start = 21  -- video: skip 2-byte prefix
    end

    if proto_start > #bytes then return nil end

    -- Field 1: directory (tag 0x0a = field 1, wire type LEN)
    if bytes:byte(proto_start) ~= 0x0a then return nil end
    local dir_len, dir_data_pos = decode_protobuf_varint(bytes, proto_start + 1)
    if not dir_len or dir_data_pos + dir_len - 1 > #bytes then return nil end
    local directory = bytes:sub(dir_data_pos, dir_data_pos + dir_len - 1)

    -- Field 2: filename (tag 0x12 = field 2, wire type LEN)
    local f2_pos = dir_data_pos + dir_len
    if f2_pos > #bytes or bytes:byte(f2_pos) ~= 0x12 then return nil end
    local fname_len, fname_data_pos = decode_protobuf_varint(bytes, f2_pos + 1)
    if not fname_len or fname_data_pos + fname_len - 1 > #bytes then return nil end
    local filename = bytes:sub(fname_data_pos, fname_data_pos + fname_len - 1)

    -- Both components must be non-empty to form a valid path
    if #directory == 0 or #filename == 0 then return nil end

    -- Reject garbled paths: protobuf field data sometimes leaks into filename/directory
    -- (e.g., "file.mp4\x1a\x18Sun Aug 21"). Valid paths never contain control chars.
    if directory:find("[%z\1-\31]") then
        log.warn("decode_bt_clip_path: garbled directory in blob (raw=%s), skipping",
            directory:sub(1, 30))
        return nil
    end
    if filename:find("[%z\1-\31]") then
        log.warn("decode_bt_clip_path: garbled filename in blob (dir=%s, raw=%s), skipping",
            directory, filename:sub(1, 30))
        return nil
    end

    return directory .. "/" .. filename
end

--- Decode hex string to raw byte string.
-- @param hex_str string: hex-encoded data (whitespace stripped)
-- @return string|nil: raw bytes, or nil if invalid
local function hex_to_bytes(hex_str)
    if not hex_str then return nil end
    local clean = hex_str:gsub("%s+", "")
    if #clean < 2 or #clean % 2 ~= 0 then return nil end
    local parts = {}
    for i = 1, #clean, 2 do
        local n = tonumber(clean:sub(i, i + 1), 16)
        if not n then return nil end
        parts[#parts + 1] = string.char(n)
    end
    return table.concat(parts)
end

--- Read a big-endian uint32 from a raw byte string at 1-indexed position.
local function read_be32(bytes, pos)
    if pos + 3 > #bytes then return nil end
    local b1, b2, b3, b4 = bytes:byte(pos, pos + 3)
    return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

--- Read a big-endian uint64 from a raw byte string at 1-indexed position.
local function read_be64(bytes, pos)
    if pos + 7 > #bytes then return nil end
    local hi = read_be32(bytes, pos)
    local lo = read_be32(bytes, pos + 4)
    if not hi or not lo then return nil end
    return hi * 4294967296 + lo  -- hi * 2^32 + lo
end

--- Decode TLV fields from a DRP binary blob.
-- Each field: [BE32 name_byte_len] [UTF-16BE name] [BE16 sep=0] [BE16 type] [value...]
--
-- Type encodings:
--   0x0002: 4-byte aux + 1-byte val → aux*256 + val (small/medium int)
--   0x0003: 4-byte aux + 1-byte val → aux*256 + val (same encoding)
--   0x0004: 8-byte aux + 1-byte val → aux*256 + val (large int, e.g. audio samples)
--   0x0006: 1-byte pad + 8-byte BE double
--   0x000a: 4-byte aux + 1-byte len → len bytes UTF-16BE string
--   0x000c: 4-byte aux + 1-byte val → aux*256+val bytes payload; LE double from first 8
--
-- @param bytes string: raw bytes of the blob
-- @param header_size number: bytes to skip before first field
-- @param field_count number: number of fields to decode
-- @return table|nil: {field_name = value, ...} or nil on decode error
-- @return table|nil: {field_name = raw_bytes, ...} for 0x000c blob payloads
local function decode_tlv_fields(bytes, header_size, field_count)
    if not bytes or #bytes < header_size + 8 then return nil end
    if field_count <= 0 or field_count > 20 then return nil end

    local ffi = require("ffi")
    local fields = {}
    local raw_payloads = {}
    local pos = header_size + 1  -- 1-indexed

    for _ = 1, field_count do
        -- Field name: [BE32 name_byte_len] [UTF-16BE name bytes]
        local name_len = read_be32(bytes, pos)
        if not name_len then return nil end
        pos = pos + 4

        if pos + name_len - 1 > #bytes then return nil end
        -- Decode UTF-16BE name to ASCII (field names are all ASCII)
        local name_chars = {}
        for j = 0, name_len - 1, 2 do
            local lo = bytes:byte(pos + j + 1)
            if lo then name_chars[#name_chars + 1] = string.char(lo) end
        end
        local field_name = table.concat(name_chars)
        pos = pos + name_len

        -- Separator (BE16, always 0) + type (BE16)
        if pos + 3 > #bytes then return nil end
        pos = pos + 2  -- skip separator
        local b1, b2 = bytes:byte(pos, pos + 1)
        local field_type = b1 * 256 + b2
        pos = pos + 2

        -- Value encoding depends on type
        if field_type == 0x0002 or field_type == 0x0003 then
            -- 4-byte aux + 1-byte val → aux*256 + val
            local aux = read_be32(bytes, pos)
            if not aux then return nil end
            pos = pos + 4
            if pos > #bytes then return nil end
            local val = bytes:byte(pos)
            pos = pos + 1
            fields[field_name] = aux * 256 + val

        elseif field_type == 0x0004 then
            -- 8-byte aux + 1-byte val → aux*256 + val
            local aux = read_be64(bytes, pos)
            if not aux then return nil end
            pos = pos + 8
            if pos > #bytes then return nil end
            local val = bytes:byte(pos)
            pos = pos + 1
            fields[field_name] = aux * 256 + val

        elseif field_type == 0x0006 then
            -- 1-byte pad + 8-byte BE double
            if pos + 8 > #bytes then return nil end
            pos = pos + 1  -- skip pad
            -- Read 8 bytes, reverse for LE, cast to double
            local be_bytes = ffi.new("uint8_t[8]")
            for j = 0, 7 do
                be_bytes[7 - j] = bytes:byte(pos + j)
            end
            fields[field_name] = ffi.cast("double*", be_bytes)[0]
            pos = pos + 8

        elseif field_type == 0x000a then
            -- 4-byte aux + 1-byte string_len → string_len bytes UTF-16BE
            if pos + 4 > #bytes then return nil end
            pos = pos + 4  -- skip aux
            if pos > #bytes then return nil end
            local str_len = bytes:byte(pos)
            pos = pos + 1
            if pos + str_len - 1 > #bytes then return nil end
            -- Decode UTF-16BE to ASCII
            local chars = {}
            for j = 0, str_len - 1, 2 do
                local lo = bytes:byte(pos + j + 1)
                if lo then chars[#chars + 1] = string.char(lo) end
            end
            fields[field_name] = table.concat(chars)
            pos = pos + str_len

        elseif field_type == 0x000c then
            -- 4-byte aux + 1-byte val → payload_len = aux*256 + val (consistent
            -- with types 0x0002/0x0003). Handles payloads > 255 bytes (e.g. KeyframesBA).
            local aux = read_be32(bytes, pos)
            if not aux then return nil end
            pos = pos + 4
            if pos > #bytes then return nil end
            local val = bytes:byte(pos)
            pos = pos + 1
            local payload_len = aux * 256 + val
            if payload_len < 8 or pos + payload_len - 1 > #bytes then return nil end
            -- First 8 bytes of payload = LE double (native x86 order)
            local le_bytes = ffi.new("uint8_t[8]")
            for j = 0, 7 do
                le_bytes[j] = bytes:byte(pos + j)
            end
            fields[field_name] = ffi.cast("double*", le_bytes)[0]
            -- Store raw payload bytes for nested blob parsing (e.g. KeyframesBA)
            raw_payloads[field_name] = bytes:sub(pos, pos + payload_len - 1)
            pos = pos + payload_len

        else
            -- Unknown type — stop decoding but return what we have
            log.warn("decode_tlv_fields: unknown type 0x%04x for field '%s'", field_type, field_name)
            break
        end
    end

    return fields, raw_payloads
end

--- Decode BtVideoInfo/Time blob → {num_frames, frame_rate, unique_id}
-- Header: 8 bytes [BE32 version=1] [BE32 field_count]
-- Fields: UniqueId, [Timecode], StartFrame, NumFrames, FrameRate, DbType
-- @param hex_str string: hex-encoded Time blob
-- @return table|nil: {num_frames=int, frame_rate=number, unique_id=string} or nil
local function decode_bt_video_time(hex_str)
    local bytes = hex_to_bytes(hex_str)
    if not bytes or #bytes < 16 then return nil end

    local field_count = read_be32(bytes, 5)  -- offset 4 (0-indexed) = pos 5 (1-indexed)
    if not field_count or field_count < 4 or field_count > 8 then return nil end

    local fields = decode_tlv_fields(bytes, 8, field_count)
    if not fields then return nil end

    local num_frames = fields["NumFrames"]
    if not num_frames or num_frames <= 0 then return nil end

    return {
        num_frames = num_frames,
        frame_rate = fields["FrameRate"],
        unique_id = fields["UniqueId"],
    }
end

--- Decode BtAudioInfo/TracksBA blob → {duration_samples, sample_rate}
-- Header: 31 bytes (version, track metadata, field_count at byte offset 27)
-- Fields: UniqueId, StartTime, SampleRate, NumChannels, IdxTrack, Duration, DbType, ...
-- @param hex_str string: hex-encoded TracksBA blob
-- @return table|nil: {duration_samples=int, sample_rate=int} or nil
local function decode_bt_audio_duration(hex_str)
    local bytes = hex_to_bytes(hex_str)
    if not bytes or #bytes < 40 then return nil end

    local field_count = read_be32(bytes, 28)  -- offset 27 (0-indexed) = pos 28 (1-indexed)
    if not field_count or field_count < 5 or field_count > 15 then return nil end

    local fields = decode_tlv_fields(bytes, 31, field_count)
    if not fields then return nil end

    local duration = fields["Duration"]
    local sample_rate = fields["SampleRate"]
    if not duration or not sample_rate then return nil end
    if sample_rate <= 0 then return nil end
    if duration <= 0 then return nil end

    return {
        duration_samples = duration,
        sample_rate = sample_rate,
    }
end

--- Detect reverse playback from KeyframesBA raw payload.
-- KeyframesBA contains nested keyframe data where each keyframe has:
--   {interp, YOut, YIn, Y, XOut, XIn, X}
-- Y = source time (seconds), X = retimed time (seconds).
-- If last keyframe's Y < first keyframe's Y → reverse playback (negative slope).
--
-- The nested structure uses the same TLV encoding as the parent blob.
-- We extract Y values from the first and last keyframes.
--
-- @param kf_bytes string: raw bytes of KeyframesBA payload
-- @return boolean: true if reverse playback detected
local function detect_reverse_from_keyframes(kf_bytes)
    if not kf_bytes or #kf_bytes < 16 then return false end

    -- KeyframesBA header: [BE32 version] [BE32 keyframe_count]
    local version = read_be32(kf_bytes, 1)
    if not version then return false end
    local kf_count = read_be32(kf_bytes, 5)
    if not kf_count or kf_count < 2 then return false end

    -- Each keyframe is a nested TLV block with its own field_count header.
    -- Parse first keyframe to get its Y value, then skip to last.
    local ffi = require("ffi")
    local pos = 9  -- after 8-byte header

    local first_y, last_y

    for kf_idx = 1, kf_count do
        -- Each keyframe: [BE32 field_count] [TLV fields...]
        local fc = read_be32(kf_bytes, pos)
        if not fc or fc < 1 or fc > 10 then return false end
        pos = pos + 4

        -- Parse this keyframe's TLV fields to find Y
        local kf_y = nil
        for _ = 1, fc do
            -- Field name: [BE32 name_byte_len] [UTF-16BE name]
            local name_len = read_be32(kf_bytes, pos)
            if not name_len then return false end
            pos = pos + 4
            if pos + name_len - 1 > #kf_bytes then return false end
            -- Decode name
            local name_chars = {}
            for j = 0, name_len - 1, 2 do
                local lo = kf_bytes:byte(pos + j + 1)
                if lo then name_chars[#name_chars + 1] = string.char(lo) end
            end
            local field_name = table.concat(name_chars)
            pos = pos + name_len

            -- Separator (BE16) + type (BE16)
            if pos + 3 > #kf_bytes then return false end
            pos = pos + 2
            local b1, b2 = kf_bytes:byte(pos, pos + 1)
            local field_type = b1 * 256 + b2
            pos = pos + 2

            -- Read value and advance pos
            if field_type == 0x0002 or field_type == 0x0003 then
                pos = pos + 5  -- 4-byte aux + 1-byte val
            elseif field_type == 0x0004 then
                pos = pos + 9  -- 8-byte aux + 1-byte val
            elseif field_type == 0x0006 then
                -- 1-byte pad + 8-byte BE double
                if pos + 8 > #kf_bytes then return false end
                if field_name == "Y" then
                    pos = pos + 1  -- skip pad
                    local be_bytes = ffi.new("uint8_t[8]")
                    for j = 0, 7 do
                        be_bytes[7 - j] = kf_bytes:byte(pos + j)
                    end
                    kf_y = ffi.cast("double*", be_bytes)[0]
                    pos = pos + 8
                else
                    pos = pos + 9  -- pad + 8 bytes
                end
            elseif field_type == 0x000a then
                if pos + 4 > #kf_bytes then return false end
                pos = pos + 4  -- skip aux
                if pos > #kf_bytes then return false end
                local str_len = kf_bytes:byte(pos)
                pos = pos + 1 + str_len
            elseif field_type == 0x000c then
                local aux = read_be32(kf_bytes, pos)
                if not aux then return false end
                pos = pos + 4
                if pos > #kf_bytes then return false end
                local val = kf_bytes:byte(pos)
                pos = pos + 1
                local payload_len = aux * 256 + val
                pos = pos + payload_len
            else
                return false  -- unknown type, bail
            end

            if pos > #kf_bytes + 1 then return false end
        end

        if kf_idx == 1 then
            first_y = kf_y
        end
        if kf_idx == kf_count then
            last_y = kf_y
        end
    end

    if not first_y or not last_y then return false end
    return last_y < first_y
end

--- Decode MediaTimemapBA blob → {speed_ratio, is_reverse, y_max, x_max}
--
-- Two MTBA formats exist:
--   Header 0x02 (9 bytes): [1-byte header] [8-byte BE double = media duration]
--     → No speed/direction info, return nil.
--   Header 0x01 (large): [BE32 version=1] [BE32 field_count] [TLV fields]
--     → YMax (source duration sec), XMax (retimed duration sec), KeyframesBA
--     → speed_ratio = YMax / XMax, direction from keyframe slope.
--
-- @param hex_str string: hex-encoded MediaTimemapBA blob
-- @return table|nil: {speed_ratio=number, is_reverse=boolean, y_max=number, x_max=number}
local function decode_media_timemap(hex_str)
    local bytes = hex_to_bytes(hex_str)
    if not bytes or #bytes <= 9 then return nil end

    -- Large MTBA: [BE32 version=1] [BE32 field_count] + TLV fields
    local version = read_be32(bytes, 1)
    if version ~= 1 then return nil end

    local field_count = read_be32(bytes, 5)
    if not field_count or field_count < 2 or field_count > 10 then return nil end

    local fields, raw_payloads = decode_tlv_fields(bytes, 8, field_count)
    if not fields then return nil end

    local y_max = fields["YMax"]
    local x_max = fields["XMax"]
    if not y_max or not x_max then return nil end
    if x_max <= 0 or y_max <= 0 then return nil end

    local speed_ratio = y_max / x_max

    -- Direction detection from KeyframesBA nested blob
    local is_reverse = false
    local kf_raw = raw_payloads and raw_payloads["KeyframesBA"]
    if kf_raw then
        is_reverse = detect_reverse_from_keyframes(kf_raw)
    end

    return {
        speed_ratio = speed_ratio,
        is_reverse = is_reverse,
        y_max = y_max,
        x_max = x_max,
    }
end

--- Extract original source file path from a MediaPool master clip element.
-- Searches BtVideoInfo and BtAudioInfo children for Clip binary blobs.
-- @param clip_elem table: Sm2MpVideoClip or Sm2MpAudioClip XML element
-- @return string|nil: decoded original path, or nil if no blob found/parseable
local function extract_original_path(clip_elem)
    -- Try BtVideoInfo first (video master clips)
    local bt_video = find_element(clip_elem, "BtVideoInfo")
    if bt_video then
        local blob_elem = find_direct_child(bt_video, "Clip")
        if blob_elem then
            local path = decode_bt_clip_path(get_text(blob_elem))
            if path then return path end
        end
    end

    -- Try BtAudioInfo (audio master clips or embedded audio)
    local bt_audio = find_element(clip_elem, "BtAudioInfo")
    if bt_audio then
        local blob_elem = find_direct_child(bt_audio, "Clip")
        if blob_elem then
            local path = decode_bt_clip_path(get_text(blob_elem))
            if path then return path end
        end
    end

    return nil
end

--- Extract media duration from a MediaPool master clip's binary blobs.
-- Video master clips: BtVideoInfo > Time → NumFrames (video frame count)
-- Audio-only clips: BtAudioInfo > TracksBA or EmbeddedAudioVec > ... > TracksBA
-- Video MCs with embedded audio: Time blob takes priority (already in frames)
--
-- For video MCs: returns {num_frames = N} (already in video frames)
-- For audio-only MCs: returns {audio_duration = {samples=N, sample_rate=N}}
--   (caller converts to frames using project fps)
-- @param clip_elem table: Sm2MpVideoClip or Sm2MpAudioClip XML element
-- @return table|nil: duration info, or nil if no blob found/parseable
local function extract_media_duration(clip_elem)
    -- Try video Time blob first (BtVideoInfo > Time)
    local bt_video = find_element(clip_elem, "BtVideoInfo")
    if bt_video then
        local time_elem = find_direct_child(bt_video, "Time")
        if time_elem then
            local result = decode_bt_video_time(get_text(time_elem))
            if result and result.num_frames and result.num_frames > 0 then
                return { num_frames = result.num_frames }
            end
        end
    end

    -- Fall back to audio TracksBA blob (BtAudioInfo > TracksBA or EmbeddedAudioVec path)
    local bt_audio = find_element(clip_elem, "BtAudioInfo")
    if bt_audio then
        local tracks_elem = find_direct_child(bt_audio, "TracksBA")
        if tracks_elem then
            local result = decode_bt_audio_duration(get_text(tracks_elem))
            if result and result.duration_samples and result.duration_samples > 0 then
                return { audio_duration = {
                    samples = result.duration_samples,
                    sample_rate = result.sample_rate,
                } }
            end
        end
    end

    return nil
end

--- Parse Resolve timecode string to integer frames
-- Resolve uses rational notation: "900/30" = frame 900 at 30fps
-- @param timecode_str string: Timecode string (e.g., "900/30")
-- @param frame_rate number: Timeline frame rate
-- @return number: Integer frames at sequence frame rate
local function parse_resolve_timecode(timecode_str, frame_rate)
    if not timecode_str or timecode_str == "" then
        return 0
    end

    -- Handle rational notation (frames/divisor)
    local numerator, denominator = timecode_str:match("^(%d+)/(%d+)$")
    if numerator and denominator then
        local src_frames = tonumber(numerator)
        local src_fps = tonumber(denominator)
        -- Resolve's rational format means: src_frames @ src_fps FPS.
        -- Rescale to sequence fps: (src_frames / src_fps) * frame_rate
        return math.floor(src_frames * frame_rate / src_fps + 0.5)
    end

    -- Handle absolute frame count
    local frames = tonumber(timecode_str)
    if frames then
        return math.floor(frames + 0.5)
    end

    return 0
end

--- Parse SequenceTabsData from a Resolve FieldsBlob hex string.
-- The FieldsBlob stores binary fields; SequenceTabsData contains the ACTUALLY
-- open timeline tabs (not the full MRU/history in TimelineHandleVec).
--
-- Binary layout after the ASCII "SequenceTabsData" field name:
--   3 padding bytes, then N+2 UUID slots:
--   [active_uuid] [count as 3-byte BE int] [uuid_1] ... [uuid_N] [active_uuid_again]
--   Each UUID: 0x00 0x48 (length=72) + 36 chars UTF-16-BE
--
-- @param hex_str string|nil: hex-encoded FieldsBlob content
-- @return table: { tab_ids = {uuid, ...}, active_id = uuid|nil }
local function parse_fields_blob_tabs(hex_str)
    local empty = { tab_ids = {}, active_id = nil }
    if not hex_str or hex_str == "" then return empty end

    -- Convert hex to byte string
    local bytes = {}
    for i = 1, #hex_str - 1, 2 do
        local byte = tonumber(hex_str:sub(i, i + 1), 16)
        if not byte then return empty end
        bytes[#bytes + 1] = string.char(byte)
    end
    local data = table.concat(bytes)

    -- Find ASCII "SequenceTabsData" (17 bytes, preceded by length byte 0x11)
    local marker = "SequenceTabsData"
    local pos = data:find(marker, 1, true)
    if not pos then return empty end

    -- Helper: scan forward from offset, skip zero padding, read UUID.
    -- UUID format: 0x48 length byte (=72), then 72 bytes of UTF-16-BE (36 chars).
    -- Returns uuid_string, next_offset or nil, offset.
    local function read_uuid(offset)
        -- Skip zero padding (up to 8 bytes)
        local skipped = 0
        while offset <= #data and data:byte(offset) == 0 and skipped < 8 do
            offset = offset + 1
            skipped = skipped + 1
        end
        -- Expect length byte 0x48 (72)
        if offset > #data or data:byte(offset) ~= 0x48 then
            return nil, offset
        end
        offset = offset + 1  -- skip length byte

        -- Read 36 UTF-16-BE characters (72 bytes)
        if offset + 71 > #data then return nil, offset end
        local chars = {}
        for i = 0, 35 do
            local hi = data:byte(offset + i * 2)
            local lo = data:byte(offset + i * 2 + 1)
            if not hi or not lo then return nil, offset end
            if hi ~= 0 then return nil, offset end  -- ASCII range only
            chars[#chars + 1] = string.char(lo)
        end
        local uuid = table.concat(chars)
        offset = offset + 72

        -- Validate UUID format (8-4-4-4-12 hex)
        if not uuid:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
            return nil, offset
        end
        return uuid, offset
    end

    -- Skip past field name (variable padding follows)
    local offset = pos + #marker

    -- Read active UUID (first UUID after field name, preceded by padding)
    local active_uuid, next_offset = read_uuid(offset)
    if not active_uuid then return empty end
    offset = next_offset

    -- Read 3-byte BE count (preceded by zero padding)
    while offset <= #data and data:byte(offset) == 0 do offset = offset + 1 end
    if offset + 2 > #data then return empty end
    -- The count byte is non-zero (we skipped zeros). Read as single byte.
    local count = data:byte(offset)
    offset = offset + 1
    if count > 100 then return empty end  -- sanity: can't have 100+ tabs

    -- Read tab UUIDs
    local tab_ids = {}
    for _ = 1, count do
        local uuid
        uuid, offset = read_uuid(offset)
        if not uuid then break end
        tab_ids[#tab_ids + 1] = uuid
    end

    return { tab_ids = tab_ids, active_id = active_uuid }
end

--- Parse project.xml to extract project metadata
-- @param project_elem table: XML element for <Project>
-- @return table: Project metadata
local function parse_project_metadata(project_elem)
    local project = {
        name = "Untitled Project",
        settings = {}
    }

    if not project_elem then
        -- No <Project> element — will be overridden by fps inference in converter.
        -- Use nil to signal "unknown"; converter must infer or fail.
        project.settings.frame_rate = nil
        project.settings.width = 1920
        project.settings.height = 1080
        return project
    end

    -- Use find_direct_child for project-level properties to avoid nested elements
    local name_elem = find_direct_child(project_elem, "ProjectName") or find_direct_child(project_elem, "Name")
    if name_elem then
        local name = get_text(name_elem)
        if name and name ~= "" then
            project.name = name
        end
    end

    local function numeric_from(elem, default)
        if not elem then
            return default
        end
        local value = tonumber(get_text(elem))
        return value or default
    end

    -- Look for timeline settings as direct children first, then fall back to recursive
    local frame_rate_elem = find_direct_child(project_elem, "TimelineFrameRate") or find_element(project_elem, "TimelineFrameRate")
    local width_elem = find_direct_child(project_elem, "TimelineResolutionWidth") or find_element(project_elem, "TimelineResolutionWidth")
    local height_elem = find_direct_child(project_elem, "TimelineResolutionHeight") or find_element(project_elem, "TimelineResolutionHeight")

    if not frame_rate_elem or not width_elem or not height_elem then
        local settings_elem = find_element(project_elem, "ProjectSettings")
        if settings_elem then
            frame_rate_elem = frame_rate_elem or find_element(settings_elem, "TimelineFrameRate")
            width_elem = width_elem or find_element(settings_elem, "TimelineResolutionWidth")
            height_elem = height_elem or find_element(settings_elem, "TimelineResolutionHeight")
        end
    end

    if frame_rate_elem then
        local fr = tonumber(get_text(frame_rate_elem))
        assert(fr, string.format(
            "parse_project_metadata: <TimelineFrameRate> is not numeric: '%s'",
            tostring(get_text(frame_rate_elem))))
        project.settings.frame_rate = fr
    else
        -- No frame rate in project element — converter will infer from clip positions
        project.settings.frame_rate = nil
    end
    project.settings.width = numeric_from(width_elem, 1920)
    project.settings.height = numeric_from(height_elem, 1080)

    -- Parse open timeline tabs from FieldsBlob > SequenceTabsData.
    -- NOT from TimelineHandleVec (that's the full MRU history, not open tabs).
    local fields_blob_elem = find_direct_child(project_elem, "FieldsBlob")
    local blob_hex = fields_blob_elem and get_text(fields_blob_elem) or nil
    local tabs_data = parse_fields_blob_tabs(blob_hex)
    project.open_timeline_ids = tabs_data.tab_ids
    project.active_timeline_id = tabs_data.active_id

    return project
end

--- Parse MediaPool XML to extract media items
-- @param media_pool_elem table: XML element for <MediaPool>
-- @return table: Array of media items
local function parse_media_pool(media_pool_elem)
    local media_items = {}

    local clips = find_all_elements(media_pool_elem, "Clip")
    for _, clip_elem in ipairs(clips) do
        local name_elem = find_element(clip_elem, "Name")
        local file_elem = find_element(clip_elem, "File")
        local duration_elem = find_element(clip_elem, "Duration")

        local media_item = {
            name = name_elem and get_text(name_elem) or "Untitled",
            file_path = file_elem and get_text(file_elem) or "",
            duration = duration_elem and tonumber(get_text(duration_elem)) or 0
        }

        -- Extract media ID if present
        if clip_elem.attrs and clip_elem.attrs.id then
            media_item.resolve_id = clip_elem.attrs.id
        end

        table.insert(media_items, media_item)
    end

    return media_items
end

-- ---------------------------------------------------------------------------
-- MediaPool Folder/Bin Hierarchy Parsing
-- ---------------------------------------------------------------------------
--
-- Resolve's MediaPool stores master clips in a folder hierarchy:
--
--   MediaPool/Master/MpFolder.xml              → Root "Master" folder
--   MediaPool/Master/000_02 Footage/MpFolder.xml → "02 Footage" subfolder
--   MediaPool/Master/001_03 Sound/MpFolder.xml   → "03 Sound" subfolder
--
-- Each MpFolder.xml contains:
--   <Sm2MpFolder DbId="...">
--     <Name>Folder Name</Name>
--     <MpFolder>parent-folder-id</MpFolder>   (reference to parent)
--     <MediaVec>
--       <Element><Sm2MpVideoClip>...</Sm2MpVideoClip></Element>
--       <Element><Sm2MpAudioClip>...</Sm2MpAudioClip></Element>
--     </MediaVec>
--   </Sm2MpFolder>
--
-- Master clips have marks and media references:
--   <Sm2MpVideoClip DbId="...">
--     <Name>Clip Name</Name>
--     <MpFolder>parent-folder-id</MpFolder>
--     <MarkIn>frame-value</MarkIn>
--     <MarkOut>frame-value</MarkOut>
--     <CurPlayheadPosition>frame-value</CurPlayheadPosition>
--     <Video><BtVideoInfo>...</BtVideoInfo></Video>
--   </Sm2MpVideoClip>

--- Parse a master clip element (Sm2MpVideoClip or Sm2MpAudioClip)
-- @param clip_elem table: XML element for master clip
-- @param folder_id string: Parent folder ID
-- @return table: Master clip data
--- Parse a single master clip element from MediaPool XML.
-- NOTE on <Name>: Always contains the original filename, NOT the user's display rename.
-- Resolve stores MC renames in FieldsBlob, which is encrypted when grading data is present
-- (format flag fd60 = encrypted, fd20 = plaintext without grading). Renames don't survive
-- DRP import. Reversing FieldsBlob encryption would be needed to support this.
local function parse_master_clip_element(clip_elem, folder_id)
    local db_id = clip_elem.attrs and clip_elem.attrs.DbId
    if not db_id then return nil end

    local name_elem = find_direct_child(clip_elem, "Name")
    local mark_in_elem = find_direct_child(clip_elem, "MarkIn")
    local mark_out_elem = find_direct_child(clip_elem, "MarkOut")
    local playhead_elem = find_direct_child(clip_elem, "CurPlayheadPosition")

    -- Decode original source path from BtVideoInfo/BtAudioInfo binary blob
    local original_path = extract_original_path(clip_elem)

    -- Parse authoritative media duration from Time/TracksBA blobs
    local duration_info = extract_media_duration(clip_elem)

    local master_clip = {
        id = db_id,
        name = name_elem and get_text(name_elem) or "Untitled",
        folder_id = folder_id,
        mark_in = mark_in_elem and tonumber(get_text(mark_in_elem)) or nil,
        mark_out = mark_out_elem and tonumber(get_text(mark_out_elem)) or nil,
        playhead = playhead_elem and tonumber(get_text(playhead_elem)) or nil,
        clip_type = clip_elem.tag == "Sm2MpVideoClip" and "video" or "audio",
        file_path = original_path,
    }

    -- Store duration info: video frames directly, or raw audio samples for later conversion
    if duration_info then
        if duration_info.num_frames then
            master_clip.num_frames = duration_info.num_frames
        elseif duration_info.audio_duration then
            master_clip.audio_duration = duration_info.audio_duration
        end
    end

    return master_clip
end

--- Parse a single MpFolder.xml file
-- @param mp_file_path string: Path to MpFolder.xml
-- @param parent_folder_path string: Filesystem parent path (for deriving hierarchy)
-- @return table: { folder = {...}, master_clips = {...} }
local function parse_mp_folder_file(mp_file_path, parent_folder_path)
    local mp_root = parse_xml_file(mp_file_path)
    if not mp_root then
        return { folder = nil, master_clips = {} }
    end

    local result = { folder = nil, master_clips = {} }

    -- Find the Sm2MpFolder element
    local folder_elem = find_element(mp_root, "Sm2MpFolder")
    if folder_elem then
        local db_id = folder_elem.attrs and folder_elem.attrs.DbId
        local name_elem = find_direct_child(folder_elem, "Name")
        local parent_ref_elem = find_direct_child(folder_elem, "MpFolder")
        local color_elem = find_direct_child(folder_elem, "ColorTag")

        result.folder = {
            id = db_id,
            name = name_elem and get_text(name_elem) or "Untitled",
            parent_ref = parent_ref_elem and get_text(parent_ref_elem) or nil,
            color = color_elem and get_text(color_elem) or nil,
            path = parent_folder_path,
        }

        -- Find master clips in MediaVec
        local media_vec = find_direct_child(folder_elem, "MediaVec")
        if media_vec then
            for _, element in ipairs(media_vec.children or {}) do
                if element.tag == "Element" then
                    for _, child in ipairs(element.children or {}) do
                        if child.tag == "Sm2MpVideoClip" or child.tag == "Sm2MpAudioClip" then
                            local master_clip = parse_master_clip_element(child, db_id)
                            if master_clip then
                                table.insert(result.master_clips, master_clip)
                            end
                        end
                    end
                end
            end
        end
    end

    return result
end

--- Parse full MediaPool hierarchy recursively
-- @param tmp_dir string: Extracted .drp temp directory
-- @return table: { folders = {...}, master_clips = {...}, folder_map = {...} }
local function parse_media_pool_hierarchy(tmp_dir, pump)
    pump = pump or function() end
    local folders = {}
    local master_clips = {}
    local folder_map = {}  -- id -> folder

    -- Find all MpFolder.xml files recursively
    local find_cmd = string.format('find "%s/MediaPool" -name "MpFolder.xml" 2>/dev/null', tmp_dir)
    local find_handle = io.popen(find_cmd)
    if not find_handle then
        return { folders = folders, master_clips = master_clips, folder_map = folder_map }
    end

    local mp_files_raw = find_handle:read("*all")
    find_handle:close()

    local mp_file_list = {}
    for f in mp_files_raw:gmatch("[^\n]+") do
        mp_file_list[#mp_file_list + 1] = f
    end

    -- Parse each MpFolder.xml
    for file_idx, mp_file in ipairs(mp_file_list) do
        if file_idx % 5 == 0 then
            pump(math.floor(file_idx / #mp_file_list * 100))
        end
        -- Derive parent path from file location
        local parent_path = mp_file:match("^(.+)/MpFolder%.xml$") or ""
        local relative_path = parent_path:gsub(tmp_dir .. "/MediaPool/Master/?", "")

        local parsed = parse_mp_folder_file(mp_file, relative_path)

        if parsed.folder then
            table.insert(folders, parsed.folder)
            folder_map[parsed.folder.id] = parsed.folder
        end

        for _, clip in ipairs(parsed.master_clips) do
            table.insert(master_clips, clip)
        end
    end

    -- Resolve parent relationships using folder_map
    -- Each folder has parent_ref pointing to parent's DbId
    for _, folder in ipairs(folders) do
        if folder.parent_ref and folder_map[folder.parent_ref] then
            folder.parent_id = folder.parent_ref
            folder.parent_name = folder_map[folder.parent_ref].name
        else
            folder.parent_id = nil  -- Root folder
        end
    end

    -- Exclude "Master" root — it's the DRP MediaPool root, not a user bin.
    -- Reparent its children to root (nil).
    local master_root_id = nil
    for _, folder in ipairs(folders) do
        if folder.parent_id == nil and folder.name == "Master" then
            master_root_id = folder.id
            break
        end
    end

    if master_root_id then
        -- Reparent children of Master to root
        for _, folder in ipairs(folders) do
            if folder.parent_id == master_root_id then
                folder.parent_id = nil
                folder.parent_name = nil
            end
        end
        -- Reparent pool master clips whose folder_id == Master root
        for _, clip in ipairs(master_clips) do
            if clip.folder_id == master_root_id then
                clip.folder_id = nil
            end
        end
        -- Remove Master from folders list
        for i, folder in ipairs(folders) do
            if folder.id == master_root_id then
                table.remove(folders, i)
                break
            end
        end
        folder_map[master_root_id] = nil
    end

    return {
        folders = folders,
        master_clips = master_clips,
        folder_map = folder_map,
        excluded_root_id = master_root_id,
    }
end

-- ---------------------------------------------------------------------------
-- Timeline Metadata Resolution
-- ---------------------------------------------------------------------------
--
-- Resolve's .drp format stores timeline metadata separately from sequence data:
--
--   SeqContainer/*.xml     → Contains tracks and clips (Sm2SequenceContainer)
--                            Each track has a <Sequence> reference ID
--
--   MediaPool/**/*.xml     → Contains Sm2Timeline elements with:
--                            - <Name> (the timeline's display name)
--                            - <Sequence><Sm2Sequence DbId="..."> (the sequence ID)
--                            - <Sequence><Sm2Sequence><FrameRate> (hex-encoded fps)
--
-- To get timeline metadata, we must:
-- 1. Recursively scan all MpFolder.xml files in MediaPool/
-- 2. Find all <Sm2Timeline> elements
-- 3. Extract <Name>, <Sm2Sequence DbId>, and <FrameRate>
-- 4. Build a map: Sequence ID → {name, fps}
-- 5. When parsing SeqContainer, look up metadata using track's <Sequence> ref
--
-- @param tmp_dir string: Extracted .drp temp directory
-- @return table: Map of sequence_id → {name=string, fps=number|nil}
--
--- Extract metadata from an Sm2Timeline element into metadata_map.
-- @param metadata_map table: seq_id → {name, fps, width, height, folder_id}
-- @param timeline_id_map table: Sm2Timeline DbId → {name, seq_id} (for TimelineHandleVec)
-- @param timeline_elem table: <Sm2Timeline> XML element
-- @param folder_id string|nil: parent folder DbId (from Sm2MpTimelineClip)
local function extract_timeline_metadata(metadata_map, timeline_id_map, timeline_elem, folder_id)
    local name_elem = find_direct_child(timeline_elem, "Name")
    local timeline_name = name_elem and get_text(name_elem) or nil
    if not timeline_name or timeline_name == "" then return end

    -- Structure: <Sm2Timeline DbId="..."><Sequence><Sm2Sequence DbId="..."><FrameRate>hex
    local seq_wrapper = find_direct_child(timeline_elem, "Sequence")
    if not seq_wrapper then return end

    local sm2_seq = find_direct_child(seq_wrapper, "Sm2Sequence")
    if not sm2_seq or not sm2_seq.attrs or not sm2_seq.attrs.DbId then return end

    local seq_id = sm2_seq.attrs.DbId

    local fps = nil
    local frame_rate_elem = find_direct_child(sm2_seq, "FrameRate")
    if frame_rate_elem then
        fps = decode_hex_double(get_text(frame_rate_elem))
    end

    local width, height = nil, nil
    local resolution_elem = find_direct_child(sm2_seq, "Resolution")
    if resolution_elem then
        width, height = decode_hex_resolution(get_text(resolution_elem))
        if width then width = math.floor(width) end
        if height then height = math.floor(height) end
    end

    metadata_map[seq_id] = {
        name = timeline_name,
        fps = fps,
        width = width,
        height = height,
        folder_id = folder_id,
    }

    -- Map Sm2Timeline DbId → name (for resolving TimelineHandleVec)
    local timeline_db_id = timeline_elem.attrs and timeline_elem.attrs.DbId
    if timeline_db_id and timeline_id_map then
        timeline_id_map[timeline_db_id] = {
            name = timeline_name,
            seq_id = seq_id,
        }
    end
end

local function build_timeline_metadata_map(tmp_dir, pump)
    pump = pump or function() end
    local metadata_map = {}
    local timeline_id_map = {}  -- Sm2Timeline DbId → {name, seq_id}

    local find_cmd = string.format('find "%s/MediaPool" -name "MpFolder.xml" 2>/dev/null', tmp_dir)
    local find_handle = io.popen(find_cmd)
    if not find_handle then
        return metadata_map, timeline_id_map
    end

    local mp_files_raw = find_handle:read("*all")
    find_handle:close()

    local mp_file_list = {}
    for f in mp_files_raw:gmatch("[^\n]+") do
        mp_file_list[#mp_file_list + 1] = f
    end

    for file_idx, mp_file in ipairs(mp_file_list) do
        if file_idx % 5 == 0 then
            pump(math.floor(file_idx / #mp_file_list * 100))
        end
        local mp_root = parse_xml_file(mp_file)
        if mp_root then
            -- Primary: find Sm2MpTimelineClip elements (contain folder ref + nested Sm2Timeline)
            local timeline_clips = find_all_elements(mp_root, "Sm2MpTimelineClip")
            for _, tc_elem in ipairs(timeline_clips) do
                local folder_ref_elem = find_direct_child(tc_elem, "MpFolder")
                local tc_folder_id = folder_ref_elem and get_text(folder_ref_elem) or nil

                local nested_timeline = find_element(tc_elem, "Sm2Timeline")
                if nested_timeline then
                    extract_timeline_metadata(metadata_map, timeline_id_map, nested_timeline, tc_folder_id)
                end
            end

            -- Fallback: bare Sm2Timeline elements not inside Sm2MpTimelineClip
            local all_timelines = find_all_elements(mp_root, "Sm2Timeline")
            for _, timeline_elem in ipairs(all_timelines) do
                local seq_wrapper = find_direct_child(timeline_elem, "Sequence")
                if seq_wrapper then
                    local sm2_seq = find_direct_child(seq_wrapper, "Sm2Sequence")
                    if sm2_seq and sm2_seq.attrs and sm2_seq.attrs.DbId then
                        if not metadata_map[sm2_seq.attrs.DbId] then
                            extract_timeline_metadata(metadata_map, timeline_id_map, timeline_elem, nil)
                        end
                    end
                end
            end
        end
    end

    return metadata_map, timeline_id_map
end

-- Extract the sequence reference ID from a SeqContainer
-- Tracks reference their parent sequence via <Sequence>...</Sequence>
-- @param seq_container_elem table: The Sm2SequenceContainer element
-- @return string|nil: The sequence reference ID, or nil if not found
local function extract_sequence_ref_id(seq_container_elem)
    -- Look in tracks for the <Sequence> reference
    -- All tracks in a container reference the same sequence
    local track = find_element(seq_container_elem, "Sm2TiTrack")
    if track then
        local seq_ref = find_direct_child(track, "Sequence")
        if seq_ref then
            return get_text(seq_ref)
        end
    end
    return nil
end

--- Parse Resolve tracks from sequence element
-- NSF: frame_rate is REQUIRED - DRP reliably encodes fps in metadata
-- @param seq_elem table: XML sequence element
-- @param frame_rate number: Frame rate from DRP metadata (required)
-- @return video_tracks, audio_tracks, media_lookup
local function parse_resolve_tracks(seq_elem, frame_rate, media_ref_path_map, media_ref_name_map)
    -- NSF: frame_rate is required, no fallbacks
    assert(type(frame_rate) == "number" and frame_rate > 0, string.format(
        "parse_resolve_tracks: frame_rate is required (got %s) - DRP must provide fps metadata",
        tostring(frame_rate)))

    local video_tracks = {}
    local audio_tracks = {}
    local media_lookup = {}
    local video_index = 1
    local audio_index = 1

    local track_elements = find_all_elements(seq_elem, "Sm2TiTrack")

    for _, track_elem in ipairs(track_elements) do
        local type_elem = find_element(track_elem, "Type")
        assert(type_elem, "parse_resolve_tracks: track missing Type element")
        local type_value = tonumber(get_text(type_elem))
        assert(type_value, "parse_resolve_tracks: track Type element has no numeric value")
        local track_type = (type_value == 1) and "AUDIO" or "VIDEO"
        local track_index = track_type == "AUDIO" and audio_index or video_index
        local track_info = {
            type = track_type,
            index = track_index,
            name = string.format("%s %d", track_type, track_index),
            enabled = true,
            locked = false,
            clips = {}
        }

        local clip_tag = track_type == "AUDIO" and "Sm2TiAudioClip" or "Sm2TiVideoClip"
        local clip_elements = find_track_clips(track_elem, clip_tag)
        local clip_count = 0

        for _, clip_elem in ipairs(clip_elements) do
            local file_path = get_text(find_element(clip_elem, "MediaFilePath"))

            -- MediaFilePath is authoritative — it always contains the correct full path.
            -- Proxy paths live in proxy.dat, not in MediaFilePath. The blob path is a
            -- fallback only: blob filenames can be garbled (protobuf field data leaking
            -- into filename bytes).
            if (not file_path or file_path == "") and media_ref_path_map then
                local media_ref = get_text(find_element(clip_elem, "MediaRef"))
                if media_ref ~= "" and media_ref_path_map[media_ref] then
                    file_path = media_ref_path_map[media_ref]
                end
            end

            local clip_name = get_text(find_element(clip_elem, "Name")) or file_path or "unnamed"

            -- NSF: Assert on missing required clip fields
            local start_elem = find_element(clip_elem, "Start")
            local duration_elem = find_element(clip_elem, "Duration")
            local in_elem = find_element(clip_elem, "In")

            assert(start_elem, string.format(
                "parse_resolve_tracks: clip '%s' missing Start element", clip_name))
            assert(duration_elem, string.format(
                "parse_resolve_tracks: clip '%s' missing Duration element", clip_name))

            -- DRP format: some values use "frames|metadata" format (e.g., "2699|00e0401cd451d83f")
            -- Extract numeric portion before pipe
            local function parse_drp_numeric(text, field_name)
                if not text then return nil end
                local num_str = text:match("^(%d+)") -- extract leading digits
                local num = tonumber(num_str)
                assert(num, string.format(
                    "parse_resolve_tracks: clip '%s' %s has no numeric value (raw='%s')",
                    clip_name, field_name, text))
                return num
            end

            local start_frames = parse_drp_numeric(get_text(start_elem), "Start")
            local duration_raw = parse_drp_numeric(get_text(duration_elem), "Duration")

            start_frames = math.floor(start_frames)
            duration_raw = math.floor(duration_raw)

            -- Extract <MediaStartTime> — file's TC origin in seconds since midnight.
            -- This is a per-file property (not per-clip). All clips from the same file
            -- share the same MediaStartTime. Stored on media + master clip for relink TC verify.
            local mst_elem = find_element(clip_elem, "MediaStartTime")
            local media_start_time = mst_elem and tonumber(get_text(mst_elem))

            -- DRP field meanings (confirmed from real DRP XML analysis):
            --   <MediaStartTime> = file's TC origin in SECONDS since midnight (not per-clip)
            --   <In>             = source mark-in offset in TIMELINE FRAMES
            --   <Start>          = timeline position (frames)
            --   <Duration>       = timeline duration (frames)
            --
            -- source_in comes from <In>, NOT <MediaStartTime>.
            -- Empty/missing <In> means untrimmed (source_in = 0).
            local in_text = in_elem and get_text(in_elem) or ""
            local in_value
            local clip_speed = 1.0
            if in_text == "" then
                in_value = 0  -- empty/missing <In> = untrimmed
            else
                -- DRP <In> can be "12345" or "12345|hexdata" (pipe-delimited
                -- with hex-encoded speed ratio). Extract integer before pipe.
                local num_part, hex_part = in_text:match("^(%d+)|?(%x*)")
                in_value = assert(num_part and tonumber(num_part), string.format(
                    "parse_resolve_tracks: clip '%s' <In> has no numeric prefix: '%s'",
                    clip_name, in_text))
                -- Hex part encodes speed ratio as LE IEEE 754 double
                if hex_part and #hex_part >= 16 then
                    local speed = decode_hex_double_at(hex_part, 0)
                    if speed and math.abs(speed) > 0.001 and math.abs(speed) < 100 then
                        -- Preserve signed speed: negative = reverse playback.
                        -- Direction is encoded via source_in > source_out swap below.
                        clip_speed = speed
                    else
                        log.warn("DRP retime: clip '%s' hex speed invalid (decoded=%s from '%s')",
                                 clip_name, tostring(speed), hex_part:sub(1, 16))
                    end
                end
            end

            -- Try MediaTimemapBA for authoritative speed/direction on retimed clips.
            -- MTBA is present on all retimed clips; hex speed is unreliable for
            -- variable-speed clips (encodes garbage near-zero values).
            local mtba_elem = find_element(clip_elem, "MediaTimemapBA")
            if mtba_elem then
                local mtba_hex = get_text(mtba_elem)
                -- 9-byte blobs (18 hex chars) = just media duration, no speed data.
                -- Larger blobs = version 1 with YMax/XMax/KeyframesBA.
                if #mtba_hex > 18 then
                    local mtba = decode_media_timemap(mtba_hex)
                    if mtba then
                        local mtba_speed = mtba.is_reverse and -mtba.speed_ratio or mtba.speed_ratio
                        -- MTBA is authoritative — hex speed is unreliable
                        -- (encodes internal Resolve values that don't match user-visible speed)
                        if clip_speed ~= 1.0 then
                            local hex_abs = math.abs(clip_speed)
                            if math.abs(hex_abs - mtba.speed_ratio) / mtba.speed_ratio > 0.05 then
                                log.warn("DRP retime: clip '%s' hex speed %.4f overridden by MTBA %.4f (YMax/XMax=%.2f/%.2f)",
                                         clip_name, clip_speed, mtba_speed, mtba.y_max, mtba.x_max)
                            end
                        end
                        clip_speed = mtba_speed
                        log.event("DRP retime: clip '%s' speed from MTBA: %.4f (YMax=%.2f XMax=%.2f reverse=%s)",
                                  clip_name, clip_speed, mtba.y_max, mtba.x_max, tostring(mtba.is_reverse))
                    end
                end
            end

            local duration_timeline_frames = duration_raw
            local abs_speed = math.abs(clip_speed)
            local source_in_native
            local source_duration
            if track_type == "AUDIO" then
                -- Audio: convert <In> from timeline frames to samples (48kHz)
                -- Use abs_speed for magnitude; direction handled via coord swap below.
                local audio_speed = (abs_speed ~= 1.0) and abs_speed or 1.0
                source_in_native = math.floor(in_value * 48000 / frame_rate * audio_speed + 0.5)
                source_duration = math.floor(duration_raw * 48000 / frame_rate * audio_speed + 0.5)
            elseif abs_speed ~= 1.0 then
                -- Retimed video: in_value and duration_raw are in RETIMED timebase
                -- (not actual source frames). Apply speed magnitude to convert.
                source_in_native = math.floor(in_value * abs_speed + 0.5)
                source_duration = math.floor(duration_raw * abs_speed + 0.5)
            else
                -- Non-retimed video: in_value IS the source frame directly
                source_in_native = math.floor(in_value)
                source_duration = duration_raw
            end

            -- Source extent in VIDEO FRAMES (for media duration tracking).
            -- The file must be at least this many frames long for this clip to exist.
            local source_extent_frames
            if track_type == "AUDIO" then
                -- Audio source_in/duration are in samples after conversion above,
                -- but in_value and duration_raw are still in timeline frames.
                -- Extent in frames = in_value + duration_raw (pre-conversion).
                source_extent_frames = math.floor(in_value) + duration_raw
            else
                -- Video (incl. retimed): source_in_native + source_duration
                source_extent_frames = source_in_native + source_duration
            end
            assert(source_extent_frames >= 0, string.format(
                "parse_resolve_tracks: clip '%s' has negative source_extent_frames=%d",
                clip_name, source_extent_frames))

            -- Compute source_out, then swap for reverse clips.
            -- Reverse: source_in = high frame (playback start), source_out = low frame.
            local source_out_native = source_in_native + source_duration
            if clip_speed < 0 then
                source_in_native, source_out_native = source_out_native, source_in_native
            end

            local clip = {
                name = clip_name,
                start_value = start_frames,        -- timeline position (integer frames)
                duration = duration_timeline_frames,  -- duration on timeline (integer frames)
                -- Absolute timecode addressing for source selection:
                source_in_tc = source_in_native,   -- native units (samples for audio, frames for video)
                source_length = source_duration,   -- duration in source units
                source_in = source_in_native,
                source_out = source_out_native,
                clip_speed = clip_speed,            -- signed speed for downstream validation
                enabled = get_text(find_element(clip_elem, "WasDisbanded")) ~= "true",
                file_path = file_path,
                media_key = file_path,
                file_id = get_text(find_element(clip_elem, "MediaRef")),
                frame_rate = frame_rate,
                media_start_time = media_start_time  -- seconds since midnight (file TC origin)
            }

            -- Skip degenerate zero-duration clips (Resolve artifacts: speed changes, disabled items)
            if clip.duration <= 0 then
                log.detail("Skipping zero-duration clip '%s' (duration=%d)", clip_name, clip.duration)
            else
                table.insert(track_info.clips, clip)
                clip_count = clip_count + 1

                if file_path and file_path ~= "" then
                    local entry = media_lookup[file_path]
                    if not entry then
                        -- Use master clip name (original filename) for media name,
                        -- not timeline clip name (user's custom label)
                        local mc_name = media_ref_name_map and media_ref_name_map[clip.file_id]
                        media_lookup[file_path] = {
                            id = clip.file_id,
                            name = mc_name or clip.name or file_path,
                            path = file_path,
                            duration = source_extent_frames,
                            frame_rate = frame_rate,
                            width = 1920,
                            height = 1080,
                            audio_channels = track_type == "AUDIO" and 2 or 0,
                            key = file_path,
                            media_start_time = media_start_time
                        }
                    else
                        if source_extent_frames > entry.duration then
                            entry.duration = source_extent_frames
                        end
                        if track_type == "AUDIO" and entry.audio_channels < 2 then
                            entry.audio_channels = 2
                        end
                    end
                end
            end
        end

        if clip_count > 0 then
            if track_type == "AUDIO" then
                table.insert(audio_tracks, track_info)
                audio_index = audio_index + 1
            else
                table.insert(video_tracks, track_info)
                video_index = video_index + 1
            end
        end
    end

    return video_tracks, audio_tracks, media_lookup
end

-- Forward declaration (defined below parse_sequence)
local parse_clip_item

--- Parse sequence XML to extract timeline data
-- NSF: frame_rate is REQUIRED - DRP reliably encodes fps
-- @param seq_elem table: XML element for <Sequence>
-- @param frame_rate number: Frame rate from DRP metadata (required)
-- @param media_ref_path_map table|nil: MediaRef DbId → original file path (for stale-path resolution)
-- @return table: Timeline data
local function parse_sequence(seq_elem, frame_rate, media_ref_path_map, media_ref_name_map)
    -- NSF: frame_rate is required
    assert(type(frame_rate) == "number" and frame_rate > 0, string.format(
        "parse_sequence: frame_rate is required (got %s) - DRP must provide fps metadata",
        tostring(frame_rate)))

    -- Use find_direct_child for sequence properties to avoid picking up
    -- nested <Name>/<Duration> elements from clips
    local name_elem = find_direct_child(seq_elem, "Name")
    local duration_elem = find_direct_child(seq_elem, "Duration")

    local timeline = {
        name = name_elem and get_text(name_elem) or "Untitled Timeline",
        duration = duration_elem and tonumber(get_text(duration_elem)) or 0,
        tracks = {}
    }

    -- Parse video tracks
    local video_tracks = find_all_elements(seq_elem, "VideoTrack")
    for i, track_elem in ipairs(video_tracks) do
        local track = {
            type = "VIDEO",
            index = i,
            clips = {}
        }

        local clip_items = find_all_elements(track_elem, "ClipItem")
        for _, clip_elem in ipairs(clip_items) do
            local clip = parse_clip_item(clip_elem, frame_rate)
            if clip then
                table.insert(track.clips, clip)
            end
        end

        table.insert(timeline.tracks, track)
    end

    -- Parse audio tracks
    local audio_tracks = find_all_elements(seq_elem, "AudioTrack")
    for i, track_elem in ipairs(audio_tracks) do
        local track = {
            type = "AUDIO",
            index = i,
            clips = {}
        }

        local clip_items = find_all_elements(track_elem, "ClipItem")
        for _, clip_elem in ipairs(clip_items) do
            local clip = parse_clip_item(clip_elem, frame_rate)
            if clip then
                table.insert(track.clips, clip)
            end
        end

        table.insert(timeline.tracks, track)
    end

    if #timeline.tracks == 0 then
        local resolve_video_tracks, resolve_audio_tracks, media_map = parse_resolve_tracks(seq_elem, frame_rate, media_ref_path_map, media_ref_name_map)
        timeline.media_files = media_map

        for _, track in ipairs(resolve_video_tracks) do
            table.insert(timeline.tracks, track)
        end
        for _, track in ipairs(resolve_audio_tracks) do
            table.insert(timeline.tracks, track)
        end
    end

    -- NSF: If no tracks were parsed, that's an error - no silent fallback with dummy data
    -- (Empty timeline with 0 tracks is valid - it means the timeline exists but has no content)

    return timeline
end

--- Parse ClipItem XML to extract clip data
-- @param clip_elem table: XML element for <ClipItem>
-- @param frame_rate number: Timeline frame rate
-- @return table|nil: Clip data, or nil if invalid
parse_clip_item = function(clip_elem, frame_rate)
    local name_elem = find_element(clip_elem, "Name")
    local start_elem = find_element(clip_elem, "Start")
    local end_elem = find_element(clip_elem, "End")
    local in_elem = find_element(clip_elem, "In")
    local out_elem = find_element(clip_elem, "Out")

    if not start_elem or not end_elem then
        return nil  -- Invalid clip
    end

    local start_value = parse_resolve_timecode(get_text(start_elem), frame_rate)
    local end_time = parse_resolve_timecode(get_text(end_elem), frame_rate)

    -- All coordinates are integer frames
    local source_in = in_elem and parse_resolve_timecode(get_text(in_elem), frame_rate) or 0
    local source_out = out_elem and parse_resolve_timecode(get_text(out_elem), frame_rate) or 0

    -- DRP freeze frame: Resolve encodes <In> == <Out> for the frozen source position.
    -- (Not FCP7 convention — FCP7 uses <stillframe> + <stillframeoffset> instead.)
    -- Single-frame source range → speed_ratio = 1/duration at playback.
    if source_in >= source_out then
        local clip_name = name_elem and get_text(name_elem) or "Untitled Clip"
        local duration = end_time - start_value
        log.event("DRP freeze frame: '%s' at source frame %d (duration=%d)",
                  clip_name, source_in, duration)
        source_out = source_in + 1
    end

    local clip = {
        name = name_elem and get_text(name_elem) or "Untitled Clip",
        start_value = start_value,
        duration = end_time - start_value,
        source_in = source_in,
        source_out = source_out
    }

    -- Extract media reference if present
    local file_elem = find_element(clip_elem, "File")
    if file_elem then
        local pathurl_elem = find_element(file_elem, "PathURL")
        if pathurl_elem then
            clip.file_path = get_text(pathurl_elem)
        end
    end

    return clip
end

--- Main entry point: Parse .drp file
-- @param drp_path string: Path to .drp file
-- @return table: Result with success flag and parsed data
--   {
--     success = true/false,
--     error = "error message" (if failed),
--     project = { name, settings },
--     media_items = { {name, file_path, duration}, ... },
--     timelines = { {name, duration, tracks}, ... },
--     folders = { {id, name, parent_id, color}, ... },  -- MediaPool bin hierarchy
--     pool_master_clips = { {id, name, folder_id, mark_in, mark_out, playhead}, ... },
--     folder_map = { [folder_id] = folder, ... },  -- Lookup by ID
--   }
function M.parse_drp_file(drp_path, progress_cb)
    local pump = progress_cb or function() end

    -- Extract .drp archive
    local tmp_dir, err = extract_drp(drp_path)
    if not tmp_dir then
        return {success = false, error = err}
    end

    -- Parse project.xml
    local project_xml_path = tmp_dir .. "/project.xml"
    local project_root, parse_err = parse_xml_file(project_xml_path)
    if not project_root then
        os.execute("rm -rf " .. tmp_dir)
        return {success = false, error = "Failed to parse project.xml: " .. tostring(parse_err)}
    end

    local project_elem = find_element(project_root, "Project")
    if not project_elem then
        if project_root.tag == "SM_Project" or project_root.tag == "Project" then
            project_elem = project_root
        else
            project_elem = find_element(project_root, "SM_Project")
        end
    end

    if not project_elem then
        os.execute("rm -rf " .. tmp_dir)
        return {success = false, error = "No <Project> element found in project.xml"}
    end

    local project = parse_project_metadata(project_elem)
    pump(10, "Scanning media pool…")

    -- Parse MediaPool XML for master clips
    local media_pool_path = tmp_dir .. "/MediaPool/Master/MpFolder.xml"
    local media_items = {}
    local media_pool_root = parse_xml_file(media_pool_path)
    if media_pool_root then
        media_items = parse_media_pool(media_pool_root)
    end

    -- Build timeline metadata map by scanning all MediaPool folders
    -- This maps Sequence IDs to {name, fps} from Sm2Timeline/Sm2Sequence elements
    local timeline_metadata_map = build_timeline_metadata_map(tmp_dir, function(sub_pct)
        pump(10 + math.floor(sub_pct * 0.15), "Scanning timeline metadata…")
    end)

    pump(25, "Parsing media pool hierarchy…")

    -- Parse MediaPool folder hierarchy (with blob-decoded original source paths)
    -- Must happen before sequence parsing so we can resolve stale MediaFilePath values
    local media_pool_hierarchy = parse_media_pool_hierarchy(tmp_dir, function(sub_pct)
        pump(25 + math.floor(sub_pct * 0.45), "Decoding media pool clips…")
    end)

    -- Build MediaRef DbId → original file path map.
    -- Timeline clips reference pool master clips via <MediaRef>. The pool master clip's
    -- binary blob encodes the original source path, while the timeline clip's <MediaFilePath>
    -- may be stale (e.g., proxy path or old volume name from a prior relink).
    local media_ref_path_map = {}
    local media_ref_name_map = {}
    for _, pmc in ipairs(media_pool_hierarchy.master_clips) do
        if pmc.id and pmc.file_path then
            media_ref_path_map[pmc.id] = pmc.file_path
        end
        if pmc.id and pmc.name then
            media_ref_name_map[pmc.id] = pmc.name
        end
    end

    pump(70, "Parsing sequences…")

    -- Parse sequence XMLs
    local timelines = {}
    local seq_dir = tmp_dir .. "/SeqContainer"
    local seq_files_raw = io.popen("ls " .. seq_dir .. "/*.xml 2>/dev/null")
    local sequence_file_list = {}
    local seq_files = ""
    if seq_files_raw then
        seq_files = seq_files_raw:read("*all")
        seq_files_raw:close()
    end

    -- Collect file list for progress counting
    local seq_file_paths = {}
    for f in seq_files:gmatch("[^\n]+") do
        seq_file_paths[#seq_file_paths + 1] = f
    end
    local seq_count = #seq_file_paths

    for seq_idx, seq_file in ipairs(seq_file_paths) do
        table.insert(sequence_file_list, seq_file)
        if seq_count > 0 then
            pump(70 + math.floor(seq_idx / seq_count * 25))
        end
        local seq_root = parse_xml_file(seq_file)
        if seq_root then
            local seq_elem = find_element(seq_root, "Sequence")
            if seq_elem then
                local has_classic_tracks = find_element(seq_elem, "VideoTrack") or find_element(seq_elem, "AudioTrack")
                local has_resolve_tracks = find_element(seq_elem, "Sm2TiTrack")
                if not has_classic_tracks and not has_resolve_tracks then
                    seq_elem = find_element(seq_root, "Sm2SequenceContainer") or seq_root
                end
            else
                seq_elem = find_element(seq_root, "Sm2SequenceContainer") or seq_root
            end
            if seq_elem then
                -- Look up the timeline's metadata (name + fps) using the sequence reference
                local seq_ref_id = extract_sequence_ref_id(seq_elem)
                local metadata = seq_ref_id and timeline_metadata_map[seq_ref_id]

                -- Skip orphan sequences with no MediaPool metadata (compound clips, deleted timelines)
                local fps_for_parsing = metadata and metadata.fps
                if not fps_for_parsing or fps_for_parsing <= 0 then
                    log.warn("Skipping sequence '%s' (seq_ref_id=%s) - no fps in MediaPool metadata",
                        seq_file:match("([^/]+)%.xml$") or seq_file,
                        tostring(seq_ref_id))
                    goto continue_seq
                end
                local timeline = parse_sequence(seq_elem, fps_for_parsing, media_ref_path_map, media_ref_name_map)

                -- Apply timeline name from metadata
                if metadata and metadata.name then
                    timeline.name = metadata.name
                end

                -- Store the fps for downstream use
                timeline.fps = fps_for_parsing

                -- Store resolution from metadata (or use project defaults)
                -- NOTE: Lua truthy-zero — `0 or fallback` == 0, so check > 0 explicitly
                local meta_w = metadata and metadata.width
                local meta_h = metadata and metadata.height
                timeline.width = (meta_w and meta_w > 0) and meta_w or project.settings.width
                timeline.height = (meta_h and meta_h > 0) and meta_h or project.settings.height

                -- Store folder_id for bin hierarchy import
                timeline.folder_id = metadata and metadata.folder_id or nil

                table.insert(timelines, timeline)
                ::continue_seq::
            end
        end
    end

    local media_lookup = {}
    for _, item in ipairs(media_items) do
        if item.file_path and item.file_path ~= "" then
            media_lookup[item.file_path] = item
        end
    end

    for _, timeline in ipairs(timelines) do
        if timeline.media_files then
            for key, info in pairs(timeline.media_files) do
                local path = info.path or key
                if path and path ~= "" and not media_lookup[path] then
                    local entry = {
                        name = info.name or path,
                        file_path = path,
                        duration = info.duration or 0,
                        resolve_id = info.id,
                        media_start_time = info.media_start_time
                    }
                    table.insert(media_items, entry)
                    media_lookup[path] = entry
                end
            end
        end
    end

    for _, seq_file in ipairs(sequence_file_list) do
        local handle = io.open(seq_file, "r")
        if handle then
            local content = handle:read("*all")
            handle:close()
            for raw_path in content:gmatch("<MediaFilePath>(.-)</MediaFilePath>") do
                local cleaned = raw_path:match("^%s*(.-)%s*$")
                if cleaned ~= "" and not media_lookup[cleaned] then
                    local entry = {
                        name = cleaned:match("([^/\\]+)$") or cleaned,
                        file_path = cleaned,
                        duration = 0
                    }
                    table.insert(media_items, entry)
                    media_lookup[cleaned] = entry
                end
            end
        end
    end

    -- Propagate first timeline fps to project settings when DRP lacks TimelineFrameRate.
    -- Media items need a frame_rate; the first timeline's metadata-derived fps is the
    -- best approximation available from DRP.
    if not project.settings.frame_rate and #timelines > 0 then
        assert(timelines[1].fps, "parse_drp_file: first timeline has no fps")
        project.settings.frame_rate = timelines[1].fps
    end

    -- Apply authoritative media durations from MediaPool blob data.
    -- Pool master clips contain Time/TracksBA blobs with actual media duration,
    -- which is more accurate than source_extent derived from timeline clips.
    local project_fps = project.settings.frame_rate
    for _, pmc in ipairs(media_pool_hierarchy.master_clips) do
        if pmc.file_path then
            local entry = media_lookup[pmc.file_path]
            if entry then
                if pmc.num_frames and pmc.num_frames > 0 then
                    entry.duration = pmc.num_frames
                elseif pmc.audio_duration and project_fps then
                    local audio_frames = math.floor(
                        pmc.audio_duration.samples * project_fps
                        / pmc.audio_duration.sample_rate + 0.5)
                    if audio_frames > 0 then
                        entry.duration = audio_frames
                    end
                end
            end
        end
    end

    -- Nil out timeline folder_ids that referenced the excluded Master root
    if media_pool_hierarchy.excluded_root_id then
        for _, timeline in ipairs(timelines) do
            if timeline.folder_id == media_pool_hierarchy.excluded_root_id then
                timeline.folder_id = nil
            end
        end
    end

    -- Resolve open timeline tab names from SequenceTabsData + timeline_metadata_map
    -- SequenceTabsData UUIDs are Sm2Sequence.DbId (= BlobOwner in project.xml),
    -- which is the same key used by timeline_metadata_map
    local open_timeline_names = {}
    local active_timeline_name = nil
    if #project.open_timeline_ids > 0 then
        for _, tid in ipairs(project.open_timeline_ids) do
            local tl_info = timeline_metadata_map[tid]
            if tl_info then
                table.insert(open_timeline_names, tl_info.name)
            end
        end
        -- Active tab is identified directly by UUID (not by index)
        if project.active_timeline_id then
            local active_info = timeline_metadata_map[project.active_timeline_id]
            if active_info then
                active_timeline_name = active_info.name
            end
        end
    end

    -- Cleanup temp directory
    os.execute("rm -rf " .. tmp_dir)

    return {
        success = true,
        project = project,
        media_items = media_items,
        timelines = timelines,
        -- Folder/bin hierarchy and master clips from MediaPool
        folders = media_pool_hierarchy.folders,
        pool_master_clips = media_pool_hierarchy.master_clips,
        folder_map = media_pool_hierarchy.folder_map,
        -- Open timeline state from Resolve
        active_timeline_name = active_timeline_name,
        open_timeline_names = open_timeline_names,
    }
end

-- Parsing kernel exports (stable public API for testing + extension)
M.parse_resolve_tracks = parse_resolve_tracks
M.parse_fields_blob_tabs = parse_fields_blob_tabs
M.decode_bt_video_time = decode_bt_video_time
M.decode_bt_audio_duration = decode_bt_audio_duration
M.decode_media_timemap = decode_media_timemap

--- Lightweight metadata extraction — project name only, no full parse.
-- Pipes project.xml from ZIP via unzip -p (no temp directory).
-- @param drp_path string: Path to .drp file
-- @return table|nil: { name = "Project Name" }, or nil on error
-- @return string|nil: error message if failed
function M.quick_metadata(drp_path)
    assert(drp_path and drp_path ~= "", "drp_importer.quick_metadata: drp_path required")

    local cmd = string.format('unzip -p "%s" project.xml 2>/dev/null', drp_path)
    local handle = io.popen(cmd)
    if not handle then return nil, "Failed to read .drp archive" end

    local xml_content = handle:read("*a")
    handle:close()

    if not xml_content or xml_content == "" then
        return nil, "No project.xml in .drp archive"
    end

    local project_root, parse_err = parse_xml_string(xml_content)
    if not project_root then return nil, "Failed to parse project.xml: " .. tostring(parse_err) end

    local project_elem = find_element(project_root, "Project")
    if not project_elem then
        if project_root.tag == "SM_Project" or project_root.tag == "Project" then
            project_elem = project_root
        else
            project_elem = find_element(project_root, "SM_Project")
        end
    end
    if not project_elem then return nil, "No <Project> element" end

    local name_elem = find_direct_child(project_elem, "ProjectName")
        or find_direct_child(project_elem, "Name")
    local name = name_elem and get_text(name_elem) or "Untitled Project"

    return { name = name }
end

-- ===========================================================================
-- Conversion + Import
-- ===========================================================================
--
-- Two verbs use the same entity-creation logic:
--   Open  → convert() → parse + init DB + create project + import_into_project()
--   Import → command executor → import_into_project() with existing project
--
-- import_into_project() is the single source of truth for DRP entity creation:
-- media records, sequences, tracks, clips, A/V link groups.

-- Models (SQL isolation: all DB access goes through models)
local Project = require("models.project")
local Media = require("models.media")
local Sequence = require("models.sequence")
local Track = require("models.track")
local Clip = require("models.clip")
local clip_link = require("models.clip_link")

-- ---------------------------------------------------------------------------
-- Helper: Infer frame rate from 1-hour timecode start position
-- ---------------------------------------------------------------------------
--
-- HEURISTIC: Professional video workflows typically use 1-hour timecode start
-- (01:00:00:00). Different frame rates produce different frame counts:
--
--   Frame Rate    | Frames in 1 Hour | Rational (num/den)
--   23.976 fps    | ~86,314          | 24000/1001
--   24 fps        |  86,400          | 24/1
--   25 fps        |  90,000          | 25/1
--   29.97 fps     | ~107,892         | 30000/1001
--   30 fps        | 108,000          | 30/1
--   50 fps        | 180,000          | 50/1
--   59.94 fps     | ~215,784         | 60000/1001
--   60 fps        | 216,000          | 60/1
--
local function infer_fps_from_one_hour_start(min_start_frame)
    if not min_start_frame or min_start_frame <= 0 then
        return nil
    end

    local one_hour_markers = {
        { 86314,  23.976, 24000, 1001 },
        { 86400,  24,     24,    1    },
        { 90000,  25,     25,    1    },
        { 107892, 29.97,  30000, 1001 },
        { 108000, 30,     30,    1    },
        { 180000, 50,     50,    1    },
        { 215784, 59.94,  60000, 1001 },
        { 216000, 60,     60,    1    },
    }

    local tolerance = 0.01

    for _, marker in ipairs(one_hour_markers) do
        local expected = marker[1]
        local lower = expected * (1 - tolerance)
        local upper = expected * (1 + tolerance)

        if min_start_frame >= lower and min_start_frame <= upper then
            log.event("Inferred %.3f fps from 1-hour TC start (frame %d ~ %d)",
                    marker[2], min_start_frame, expected)
            return marker[2], marker[3], marker[4]
        end
    end

    log.event("Could not infer fps from start frame %d (not near 1-hour TC)", min_start_frame)
    return nil
end

-- ---------------------------------------------------------------------------
-- Helper: Frame rate to rational
-- ---------------------------------------------------------------------------

local function frame_rate_to_rational(frame_rate)
    local fps = tonumber(frame_rate)
    assert(fps and fps > 0, "drp_importer: invalid frame_rate: " .. tostring(frame_rate))

    if math.abs(fps - 23.976) < 0.01 then
        return 24000, 1001
    elseif math.abs(fps - 29.97) < 0.01 then
        return 30000, 1001
    elseif math.abs(fps - 59.94) < 0.01 then
        return 60000, 1001
    end

    return math.floor(fps + 0.5), 1
end

-- ---------------------------------------------------------------------------
-- import_into_project: Shared entity-creation for both Open and Import verbs
-- ---------------------------------------------------------------------------

--- Apply pool master clip marks (mark_in, mark_out, playhead) to JVE master clips.
-- DRP stores per-clip marks in MediaPool master clip elements. After import creates
-- masterclip sequences, this function matches by media name and applies the marks
-- to the corresponding stream clips (video/audio) in each masterclip sequence.
-- Uses model APIs only (SQL isolation: no database.get_connection() in importers).
-- @param pool_master_clips table: Array from parse_drp_file().pool_master_clips
-- @param media_by_path table: file_path → Media record (from import loop)
local function apply_pool_master_clip_marks(pool_master_clips, media_by_path)
    if not pool_master_clips or #pool_master_clips == 0 then return end

    -- Build name → marks map, keyed by (media_name, clip_type)
    -- clip_type is "video" or "audio" from pool master clip parsing
    local marks_by_name = {}  -- name → { video = {mark_in, mark_out, playhead}, audio = {...} }
    for _, pmc in ipairs(pool_master_clips) do
        if pmc.mark_in or pmc.mark_out or (pmc.playhead and pmc.playhead > 0) then
            if not marks_by_name[pmc.name] then
                marks_by_name[pmc.name] = {}
            end
            marks_by_name[pmc.name][pmc.clip_type] = {
                mark_in = pmc.mark_in,
                mark_out = pmc.mark_out,
                playhead = pmc.playhead or 0,
            }
        end
    end

    local applied_count = 0
    for _, media in pairs(media_by_path) do
        local name_marks = marks_by_name[media.name]
        if not name_marks then goto next_media end

        -- Find the masterclip sequence for this media (via Sequence model)
        local mc_seq_id = Sequence.find_masterclip_for_media(media.id)
        if not mc_seq_id then
            log.warn("apply_marks: no masterclip sequence for media '%s' (id=%s)",
                media.name, media.id)
            goto next_media
        end

        local mc_seq = Sequence.load(mc_seq_id)
        assert(mc_seq, string.format(
            "apply_marks: Sequence.load failed for masterclip %s (media=%s)",
            mc_seq_id, media.name))

        -- Apply video marks to video stream clip
        if name_marks.video then
            local video_clip = mc_seq:video_stream()
            if video_clip then
                video_clip.mark_in = name_marks.video.mark_in
                video_clip.mark_out = name_marks.video.mark_out
                video_clip.playhead_frame = name_marks.video.playhead
                assert(video_clip:save({skip_occlusion = true}), string.format(
                    "apply_marks: save failed for video clip %s (media=%s)",
                    video_clip.id, media.name))
                applied_count = applied_count + 1
            end
        end

        -- Apply audio marks to all audio stream clips
        if name_marks.audio then
            for _, audio_clip in ipairs(mc_seq:audio_streams()) do
                audio_clip.mark_in = name_marks.audio.mark_in
                audio_clip.mark_out = name_marks.audio.mark_out
                audio_clip.playhead_frame = name_marks.audio.playhead
                assert(audio_clip:save({skip_occlusion = true}), string.format(
                    "apply_marks: save failed for audio clip %s (media=%s)",
                    audio_clip.id, media.name))
                applied_count = applied_count + 1
            end
        end

        ::next_media::
    end

    if applied_count > 0 then
        log.event("Applied marks to %d master clip stream(s)", applied_count)
    end
end

-- mark_offline_clips removed: offline status is now transient,
-- recomputed reactively by core.media.media_status registry.

--- Import parsed DRP data into an existing project.
-- Creates: media records, sequences, tracks, clips, A/V link groups.
-- @param project_id string: Target project ID (must already exist)
-- @param parse_result table: Output of parse_drp_file()
-- @param opts table: Optional settings
--   opts.project_settings table: {frame_rate, width, height} project defaults
-- @return table: {media_ids, sequence_ids, track_ids, clip_ids} for undo
function M.import_into_project(project_id, parse_result, opts)
    assert(project_id and project_id ~= "", "drp_importer.import_into_project: project_id required")
    assert(parse_result and parse_result.success, "drp_importer.import_into_project: parse_result must be successful")
    opts = opts or {}
    local project_settings = opts.project_settings or parse_result.project.settings
    local sub_report = opts.progress_cb or function() end

    local tag_service = require("core.tag_service")
    local uuid = require("uuid")

    -- Track created entity IDs for undo
    local result = {
        media_ids = {},
        sequence_ids = {},
        track_ids = {},
        clip_ids = {},
    }

    -- Import DRP folder hierarchy as bins
    local drp_folder_to_bin = {}  -- DRP folder DbId → JVE bin_id
    for _, folder in ipairs(parse_result.folders or {}) do
        -- Map DRP parent_ref to JVE parent_id (already-created bin)
        local parent_bin_id = folder.parent_id and drp_folder_to_bin[folder.parent_id] or nil
        local bin_id = uuid.generate_with_prefix("bin")
        local ok, def = tag_service.create_bin(project_id, {
            id = bin_id,
            name = folder.name,
            parent_id = parent_bin_id,
        })
        if ok and def then
            drp_folder_to_bin[folder.id] = def.id
            log.event("  Created bin: %s (parent=%s)", folder.name, tostring(parent_bin_id))
        else
            log.warn("Failed to create bin: %s", folder.name)
        end
    end

    -- Build pool master clip name → DRP folder bin mapping
    -- pool_master_clips have {name, folder_id} from MediaPool hierarchy
    -- Two indexes: by exact name and by filename (for audio-from-video matching)
    local pool_name_to_drp_bin = {}
    for _, pmc in ipairs(parse_result.pool_master_clips or {}) do
        if pmc.folder_id and drp_folder_to_bin[pmc.folder_id] then
            pool_name_to_drp_bin[pmc.name] = drp_folder_to_bin[pmc.folder_id]
        end
    end

    -- Import media items
    local media_by_path = {}
    for _, media_item in ipairs(parse_result.media_items) do
        local dur = media_item.duration or 0
        if dur <= 0 then
            log.warn("Skipping zero-duration media: %s", media_item.name)
        else
            -- Build metadata JSON with start_timecode if available
            local media_metadata = '{}'
            if media_item.media_start_time then
                local json = require("dkjson")
                media_metadata = json.encode({
                    start_timecode_seconds = media_item.media_start_time
                })
            end

            local media = Media.create({
                project_id = project_id,
                name = media_item.name,
                file_path = media_item.file_path,
                duration_frames = dur,
                frame_rate = assert(media_item.frame_rate or project_settings.frame_rate,
                    string.format("drp_importer: no frame_rate for media '%s'", media_item.name)),
                width = project_settings.width,
                height = project_settings.height,
                metadata = media_metadata,
            })

            assert(media:save(), string.format(
                "drp_importer: failed to save media '%s' (path=%s)",
                media_item.name, media_item.file_path))
            media_by_path[media_item.file_path] = media
            table.insert(result.media_ids, media.id)
            log.event("  Imported media: %s", media.name)
        end
    end

    sub_report(20, "Importing timelines…")

    -- Import timelines
    local timeline_count = #parse_result.timelines
    for tl_idx, timeline_data in ipairs(parse_result.timelines) do
        sub_report(20 + math.floor(tl_idx / timeline_count * 70),
            string.format("Importing: %s", timeline_data.name))
        -- STEP 1: Analyze clip positions for viewport + fps inference
        local min_start_frame = nil
        local max_end_frame = 0
        for _, track_data in ipairs(timeline_data.tracks) do
            for _, clip_data in ipairs(track_data.clips) do
                local start = clip_data.start_value or 0
                local dur = clip_data.duration or 0
                if not min_start_frame or start < min_start_frame then
                    min_start_frame = start
                end
                if (start + dur) > max_end_frame then
                    max_end_frame = start + dur
                end
            end
        end

        -- STEP 2: Determine frame rate
        local fps_num, fps_den

        if timeline_data.fps and timeline_data.fps > 0 then
            fps_num, fps_den = frame_rate_to_rational(timeline_data.fps)
            log.event("Using explicit fps from DRP metadata: %.3f (%d/%d)",
                    timeline_data.fps, fps_num, fps_den)
        else
            local inferred_fps, inferred_num, inferred_den = infer_fps_from_one_hour_start(min_start_frame)

            if inferred_fps then
                fps_num, fps_den = inferred_num, inferred_den
                log.event("Inferred fps from 1-hour TC: %.3f (%d/%d)",
                        inferred_fps, fps_num, fps_den)
            else
                fps_num, fps_den = frame_rate_to_rational(project_settings.frame_rate)
                log.warn("No fps metadata, no 1-hour TC; using project default: %d/%d",
                        fps_num, fps_den)
            end
        end

        -- STEP 3: Zoom-to-fit viewport
        local view_start = min_start_frame or 0
        local content_duration = max_end_frame - view_start
        local view_duration

        if content_duration > 0 then
            local margin = math.floor(content_duration * 0.05)
            view_start = math.max(0, view_start - margin)
            view_duration = content_duration + (margin * 2)
        else
            local effective_fps = fps_num / fps_den
            view_duration = math.floor(10 * effective_fps)
        end

        -- STEP 4: Create Sequence
        local seq_width = (timeline_data.width and timeline_data.width > 0)
            and timeline_data.width or project_settings.width
        local seq_height = (timeline_data.height and timeline_data.height > 0)
            and timeline_data.height or project_settings.height

        local sequence = Sequence.create(
            timeline_data.name,
            project_id,
            { fps_numerator = fps_num, fps_denominator = fps_den },
            seq_width,
            seq_height,
            {
                audio_rate = 48000,
                view_start_frame = view_start,
                view_duration_frames = view_duration,
                playhead_frame = min_start_frame or 0,
            }
        )

        assert(sequence:save(), string.format(
            "drp_importer: failed to save timeline '%s'", timeline_data.name))
        do
            table.insert(result.sequence_ids, sequence.id)
            log.event("  Created timeline: %s @ %d/%d fps, %dx%d, viewport [%d..%d]",
                    timeline_data.name, fps_num, fps_den, seq_width, seq_height, view_start, view_start + view_duration)

            -- Assign timeline sequence to DRP folder bin
            local timeline_folder_bin = timeline_data.folder_id and drp_folder_to_bin[timeline_data.folder_id] or nil
            if timeline_folder_bin then
                tag_service.add_to_bin(project_id, {sequence.id}, timeline_folder_bin, "sequence")
            end

            -- Create per-sequence master clip bin: "{seq_name} Master Clips"
            -- Parent = timeline's folder bin (from DRP hierarchy), or nil (root)
            local parent_bin_id = timeline_folder_bin
            local mc_bin_label = string.format("%s Master Clips", timeline_data.name)
            local mc_bin_id = uuid.generate_with_prefix("bin")
            local mc_ok, mc_def = tag_service.create_bin(project_id, {
                id = mc_bin_id,
                name = mc_bin_label,
                parent_id = parent_bin_id,
            })
            local master_bin_id = (mc_ok and mc_def) and mc_def.id or nil
            if master_bin_id then
                log.event("  Created master clip bin: %s", mc_bin_label)
            end

            local clips_for_linking = {}

            -- STEP 5: Import tracks + clips
            for _, track_data in ipairs(timeline_data.tracks) do
                local track_prefix = track_data.type == "VIDEO" and "V" or "A"
                local track_name = string.format("%s%d", track_prefix, track_data.index)

                local track
                if track_data.type == "VIDEO" then
                    track = Track.create_video(track_name, sequence.id, { index = track_data.index })
                else
                    track = Track.create_audio(track_name, sequence.id, { index = track_data.index })
                end

                assert(track:save(), string.format(
                    "drp_importer: failed to save track '%s' in timeline '%s'",
                    track_name, timeline_data.name))
                do
                    table.insert(result.track_ids, track.id)

                    for _, clip_data in ipairs(track_data.clips) do
                        local media_id = nil
                        if clip_data.file_path and media_by_path[clip_data.file_path] then
                            media_id = media_by_path[clip_data.file_path].id
                        end

                        -- Skip clips with no resolvable media (generated clips, titles, removed media)
                        if not media_id then
                            log.warn("Skipping clip '%s' - no media record for path: %s",
                                clip_data.name or "unnamed", tostring(clip_data.file_path))
                            goto continue_clip
                        end

                        local clip_rate_num, clip_rate_den
                        if track_data.type == "VIDEO" then
                            clip_rate_num, clip_rate_den = fps_num, fps_den
                        else
                            clip_rate_num, clip_rate_den = 48000, 1
                        end

                        local source_out = clip_data.source_out
                        local is_reverse = (clip_data.clip_speed or 1) < 0

                        if not is_reverse then
                            -- Forward clip: source_out must exceed source_in
                            if not source_out or source_out <= (clip_data.source_in or 0) then
                                source_out = (clip_data.source_in or 0) + (clip_data.duration or 0)
                            end
                            if source_out <= (clip_data.source_in or 0) then
                                log.warn("Skipping clip '%s' - zero source range (source_in=%s, source_out=%s)",
                                    clip_data.name or "unnamed", tostring(clip_data.source_in), tostring(source_out))
                                goto continue_clip
                            end
                        else
                            -- Reverse clip: source_in > source_out is intentional
                            if not source_out then
                                source_out = (clip_data.source_in or 0) - (clip_data.duration or 0)
                            end
                            if source_out == (clip_data.source_in or 0) then
                                log.warn("Skipping reverse clip '%s' - zero source range (source_in=%s, source_out=%s)",
                                    clip_data.name or "unnamed", tostring(clip_data.source_in), tostring(source_out))
                                goto continue_clip
                            end
                        end

                        local clip = Clip.create(clip_data.name or "Untitled Clip", media_id, {
                            project_id = project_id,
                            owner_sequence_id = sequence.id,
                            track_id = track.id,
                            timeline_start = clip_data.start_value,
                            duration = clip_data.duration,
                            source_in = clip_data.source_in,
                            source_out = source_out,
                            fps_numerator = clip_rate_num,
                            fps_denominator = clip_rate_den,
                            bin_id = master_bin_id,
                        })

                        assert(clip:save(), string.format(
                            "drp_importer: failed to save clip '%s' in track '%s'",
                            clip_data.name, track_name))
                        do
                            table.insert(result.clip_ids, clip.id)

                            -- Assign masterclip sequence to DRP folder bin (many-to-many safe)
                            -- Match by media name first, then by file path basename
                            -- (audio-from-video clips have different names than pool master clips)
                            if clip.master_clip_id and clip_data.file_path then
                                local media = media_by_path[clip_data.file_path]
                                local drp_bin = media and pool_name_to_drp_bin[media.name]
                                if not drp_bin then
                                    local basename = clip_data.file_path:match("([^/\\]+)$")
                                    drp_bin = basename and pool_name_to_drp_bin[basename]
                                end
                                if drp_bin then
                                    tag_service.add_to_bin(project_id, {clip.master_clip_id}, drp_bin, "master_clip")
                                end
                            end

                            if clip_data.file_path then
                                table.insert(clips_for_linking, {
                                    clip_id = clip.id,
                                    file_path = clip_data.file_path,
                                    timeline_start = clip_data.start_value,
                                    role = track_data.type == "VIDEO" and "video" or "audio",
                                })
                            end
                        end
                        ::continue_clip::
                    end
                end
            end

            -- STEP 6: Create A/V link groups
            local link_groups_by_key = {}
            for _, clip_info in ipairs(clips_for_linking) do
                local key = clip_info.file_path .. ":" .. tostring(clip_info.timeline_start)
                link_groups_by_key[key] = link_groups_by_key[key] or {}
                table.insert(link_groups_by_key[key], clip_info)
            end

            local link_count = 0
            for _, group in pairs(link_groups_by_key) do
                if #group >= 2 then
                    local clips_to_link = {}
                    for _, info in ipairs(group) do
                        table.insert(clips_to_link, {
                            clip_id = info.clip_id,
                            role = info.role,
                            time_offset = 0,
                        })
                    end

                    local link_id, link_err = clip_link.create_link_group(clips_to_link)
                    if link_id then
                        link_count = link_count + 1
                    else
                        log.warn("Failed to create link group: %s", link_err or "unknown error")
                    end
                end
            end

            if link_count > 0 then
                log.event("Created %d A/V link groups for timeline: %s", link_count, timeline_data.name)
            end
        end
    end

    sub_report(90, "Applying marks…")

    -- STEP 7: Apply pool master clip marks to JVE master clips
    apply_pool_master_clip_marks(parse_result.pool_master_clips, media_by_path)

    -- Offline detection removed: handled reactively by media_status registry

    log.event("Import complete: %d media, %d sequences, %d tracks, %d clips",
        #result.media_ids, #result.sequence_ids, #result.track_ids, #result.clip_ids)

    return result
end

-- ---------------------------------------------------------------------------
-- convert: Parse .drp and create new .jvp at target path (Open verb)
-- ---------------------------------------------------------------------------

--- Convert .drp file to .jvp at target path
-- @param drp_path string: Path to source .drp file
-- @param jvp_path string: Path for new .jvp file
-- @param progress_cb function|nil: optional progress(pct, text [, log_line])
-- @return boolean: success
-- @return string|nil: error message if failed
function M.convert(drp_path, jvp_path, progress_cb)
    assert(drp_path and drp_path ~= "", "drp_importer.convert: drp_path required")
    assert(jvp_path and jvp_path ~= "", "drp_importer.convert: jvp_path required")
    local report = progress_cb or function() end

    log.event("Converting %s -> %s", drp_path, jvp_path)

    report(5, "Parsing archive…")
    -- Thread progress_cb into parse phase so Qt events get pumped.
    -- parse_drp_file reports 0-100 internally; remap to 5-30 of overall.
    local parse_progress = progress_cb and function(sub_pct, text)
        report(5 + math.floor(sub_pct * 0.25), text)
    end or nil
    local parse_result = M.parse_drp_file(drp_path, parse_progress)
    if not parse_result.success then
        return false, "Failed to parse .drp file: " .. tostring(parse_result.error)
    end

    report(30, "Creating project database…")

    -- Remove existing file if present (user confirmed overwrite in save dialog)
    os.remove(jvp_path)
    os.remove(jvp_path .. "-shm")
    os.remove(jvp_path .. "-wal")

    local database = require("core.database")
    local ok, err = pcall(function()
        database.init(jvp_path)
    end)

    if not ok then
        return false, "Failed to create database: " .. tostring(err)
    end

    local json = require("dkjson")
    local settings = {
        frame_rate = parse_result.project.settings.frame_rate,
        width = parse_result.project.settings.width,
        height = parse_result.project.settings.height,
    }

    local project = Project.create(parse_result.project.name, {
        settings = json.encode(settings),
    })

    if not project:save() then
        return false, "Failed to save project record"
    end

    log.event("Created project: %s (%dx%d @ %sfps)",
        project.name, settings.width, settings.height, tostring(settings.frame_rate))

    report(40, "Importing media…")
    M.import_into_project(project.id, parse_result, {
        project_settings = settings,
        progress_cb = progress_cb and function(sub_pct, text)
            -- Map sub_pct 0-100 → overall range 40-90
            report(40 + math.floor(sub_pct * 0.5), text)
        end or nil,
    })

    -- Store open timeline state as project settings for layout.lua
    report(95, "Setting active timeline…")
    local pid = database.get_current_project_id()
    if parse_result.active_timeline_name or
       (parse_result.open_timeline_names and #parse_result.open_timeline_names > 0) then
        local sequences = database.load_sequences(pid)

        -- Build name → sequence ID lookup
        local name_to_seq = {}
        for _, seq in ipairs(sequences) do
            name_to_seq[seq.name] = seq
        end

        -- Resolve open timeline names → JVE sequence IDs
        if parse_result.open_timeline_names and #parse_result.open_timeline_names > 0 then
            local open_sequence_ids = {}
            local active_sequence_id = nil
            for _, tl_name in ipairs(parse_result.open_timeline_names) do
                local seq = name_to_seq[tl_name]
                if seq then
                    table.insert(open_sequence_ids, seq.id)
                    if tl_name == parse_result.active_timeline_name then
                        active_sequence_id = seq.id
                    end
                end
            end
            if #open_sequence_ids > 0 then
                database.set_project_setting(pid, "open_sequence_ids", open_sequence_ids)
            end
            if active_sequence_id then
                database.set_project_setting(pid, "last_open_sequence_id", active_sequence_id)
            end
        elseif parse_result.active_timeline_name then
            local seq = name_to_seq[parse_result.active_timeline_name]
            if seq then
                database.set_project_setting(pid, "last_open_sequence_id", seq.id)
            end
        end
    end

    report(100, "Done")
    return true
end

M.frame_rate_to_rational = frame_rate_to_rational
M.decode_bt_clip_path = decode_bt_clip_path

return M
