--- DaVinci Resolve binary blob decoders — TLV, hex, protobuf parsing.
--
-- Responsibilities:
-- - Hex-encoded IEEE 754 double decoding (LE and BE)
-- - Big-endian integer reading (BE32, BE64)
-- - TLV field decoding (DRP's binary field format)
-- - Protobuf varint decoding
-- - BtVideoInfo/BtAudioInfo blob path extraction
-- - Time/TracksBA/MediaTimemapBA/EffectFiltersBA blob decoding
-- - KeyframesBA parsing and piecewise-linear curve evaluation
-- - UIElementsState double extraction
--
-- Non-goals:
-- - DRP XML parsing (that's drp_importer.lua)
-- - Entity creation / DB access (that's importer_core.lua)
--
-- Invariants:
-- - All functions are pure (no I/O, no DB, no state)
-- - Decode failures return nil, never assert (caller decides severity)
--
-- @file drp_binary.lua
local M = {}

local log = require("core.logger").for_area("media")

-- ---------------------------------------------------------------------------
-- Primitive decoders: hex, integers, doubles
-- ---------------------------------------------------------------------------

--- Decode hex string to raw byte string.
-- @param hex_str string: hex-encoded data (whitespace stripped)
-- @return string|nil: raw bytes, or nil if invalid
function M.hex_to_bytes(hex_str)
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
function M.read_be32(bytes, pos)
    if pos + 3 > #bytes then return nil end
    local b1, b2, b3, b4 = bytes:byte(pos, pos + 3)
    return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

--- Read a big-endian uint64 from a raw byte string at 1-indexed position.
function M.read_be64(bytes, pos)
    if pos + 7 > #bytes then return nil end
    local hi = M.read_be32(bytes, pos)
    local lo = M.read_be32(bytes, pos + 4)
    if not hi or not lo then return nil end
    return hi * 4294967296 + lo  -- hi * 2^32 + lo
end

--- Decode a LE IEEE 754 double from hex string at given character offset.
-- DRP stores doubles in little-endian byte order (x86 native).
-- @param hex_str string: Hex string containing doubles
-- @param offset number: Character offset (0 = first double, 16 = second double)
-- @return number|nil: Decoded double value, or nil if invalid
function M.decode_hex_double_at(hex_str, offset)
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

--- Decode a LE IEEE 754 double from first 16 hex chars.
-- @param hex_str string: 32-char hex string (first 16 chars used)
-- @return number|nil: Decoded double value, or nil if invalid
function M.decode_hex_double(hex_str)
    return M.decode_hex_double_at(hex_str, 0)
end

--- Decode a big-endian IEEE 754 double from hex at a BYTE offset.
-- UIElementsState uses BE encoding (unlike FieldsBlob which is LE).
function M.decode_hex_double_be_at(hex_str, byte_offset)
    if not hex_str or #hex_str < byte_offset * 2 + 16 then return nil end
    local ffi = require("ffi")
    local bytes = ffi.new("uint8_t[8]")
    for i = 0, 7 do
        local hex_byte = hex_str:sub(byte_offset * 2 + i * 2 + 1, byte_offset * 2 + i * 2 + 2)
        local byte_val = tonumber(hex_byte, 16)
        if not byte_val then return nil end
        bytes[7 - i] = byte_val  -- reverse for BE→LE
    end
    return ffi.cast("double*", bytes)[0]
end

--- Decode a LE IEEE 754 double from 16 hex chars without FFI.
-- Pure Lua implementation safe for high-frequency calls (125K+ clips in large DRPs).
-- decode_hex_double_at uses ffi.new/ffi.cast which corrupts LuaJIT state at scale.
-- @param hex16 string: 16 hex characters representing 8 LE bytes
-- @return number|nil: decoded double, or nil if invalid
function M.decode_le_double_pure(hex16)
    if #hex16 ~= 16 then return nil end
    -- Parse 8 bytes (LE order)
    local b = {}
    for i = 1, 8 do
        local byte = tonumber(hex16:sub(i * 2 - 1, i * 2), 16)
        if not byte then return nil end
        b[i] = byte
    end
    -- IEEE 754 double: sign(1) exponent(11) mantissa(52), big-endian bit layout
    -- LE bytes: b[1]=LSB .. b[8]=MSB
    local sign = (b[8] >= 128) and -1 or 1
    local exp = ((b[8] % 128) * 16) + math.floor(b[7] / 16)
    -- Mantissa: 52 bits from b[7](low 4 bits) .. b[1]
    local mantissa = (b[7] % 16) * 2^48
                   + b[6] * 2^40 + b[5] * 2^32
                   + b[4] * 2^24 + b[3] * 2^16
                   + b[2] * 2^8  + b[1]
    if exp == 0 and mantissa == 0 then return 0.0 end
    if exp == 0x7FF then return nil end  -- Inf/NaN
    if exp == 0 then
        -- Subnormal
        return sign * 2^(-1022) * (mantissa / 2^52)
    end
    return sign * 2^(exp - 1023) * (1 + mantissa / 2^52)
end

--- Decode resolution from 32-char hex string (two LE doubles: width, height)
-- @param hex_str string: 32-char hex string
-- @return number|nil, number|nil: width, height (or nil if invalid)
function M.decode_hex_resolution(hex_str)
    if not hex_str or #hex_str < 32 then return nil, nil end
    local width = M.decode_hex_double_at(hex_str, 0)
    local height = M.decode_hex_double_at(hex_str, 16)
    return width, height
end

-- ---------------------------------------------------------------------------
-- UIElementsState parser
-- ---------------------------------------------------------------------------

--- Extract a named double from a UIElementsState hex blob.
-- UIElementsState TLV format: 4B version, 4B count, then entries:
--   4B name_byte_count, N bytes UTF-16BE name, 4B type_tag, 1B pad, value
-- @param hex_str string: Full UIElementsState hex
-- @param key_name string: ASCII key name (e.g. "UI_SEQUENCE_SCALE")
-- @return number|nil: The double value, or nil if not found
function M.extract_ui_state_double(hex_str, key_name)
    if not hex_str or hex_str == "" then return nil end
    -- Build UTF-16 BE search pattern for the key name
    local pattern_parts = {}
    for i = 1, #key_name do
        pattern_parts[#pattern_parts + 1] = string.format("00%02x", key_name:byte(i))
    end
    local pattern = table.concat(pattern_parts)
    local pos = hex_str:find(pattern, 1, true)
    if not pos then return nil end
    -- All offsets in hex char positions (1-based Lua string indices)
    -- After name pattern: type tag (8 hex) + pad (2 hex) + double (16 hex)
    local type_hex_start = pos + #pattern
    local type_hex = hex_str:sub(type_hex_start, type_hex_start + 7)
    if type_hex ~= "00000026" then return nil end
    -- Double value starts after type (8 hex) + pad (2 hex) = 10 hex chars
    local double_hex_start = type_hex_start + 10
    -- Convert to 0-based byte offset for decode function
    local double_byte_off = (double_hex_start - 1) / 2
    return M.decode_hex_double_be_at(hex_str, double_byte_off)
end

-- ---------------------------------------------------------------------------
-- Protobuf varint decoder
-- ---------------------------------------------------------------------------

--- Decode a protobuf varint from raw byte string
-- @param bytes string: raw byte string
-- @param pos number: 1-indexed start position
-- @return number|nil: decoded value
-- @return number: next position after varint
function M.decode_protobuf_varint(bytes, pos)
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

-- ---------------------------------------------------------------------------
-- BtVideoInfo/BtAudioInfo clip path decoder
-- ---------------------------------------------------------------------------

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
function M.decode_bt_clip_path(hex_str)
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
    local dir_len, dir_data_pos = M.decode_protobuf_varint(bytes, proto_start + 1)
    if not dir_len or dir_data_pos + dir_len - 1 > #bytes then return nil end
    local directory = bytes:sub(dir_data_pos, dir_data_pos + dir_len - 1)

    -- Field 2: filename (tag 0x12 = field 2, wire type LEN)
    local f2_pos = dir_data_pos + dir_len
    if f2_pos > #bytes or bytes:byte(f2_pos) ~= 0x12 then return nil end
    local fname_len, fname_data_pos = M.decode_protobuf_varint(bytes, f2_pos + 1)
    if not fname_len or fname_data_pos + fname_len - 1 > #bytes then return nil end
    local filename = bytes:sub(fname_data_pos, fname_data_pos + fname_len - 1)

    -- Both components must be non-empty to form a valid path
    if #directory == 0 or #filename == 0 then return nil, nil end

    -- Reject garbled directories (protobuf field data leak). Valid paths never contain control chars.
    if directory:find("[%z\1-\31]") then
        log.warn("decode_bt_clip_path: garbled directory in blob (raw=%s), skipping",
            directory:sub(1, 30))
        return nil, nil
    end

    -- Filename may contain control chars (protobuf date fields leaking into
    -- the filename field — common in audio clip blobs). When this happens,
    -- the full path is unreliable. Return nil for path but provide the
    -- directory so the caller can construct the path using the XML <Name>.
    if filename:find("[%z\1-\31]") then
        log.detail("decode_bt_clip_path: garbled filename in blob (dir=%s, raw=%s), returning dir only",
            directory, filename:sub(1, 30))
        return nil, directory
    end

    return directory .. "/" .. filename, directory
end

-- ---------------------------------------------------------------------------
-- TLV field decoder (DRP's binary field format)
-- ---------------------------------------------------------------------------

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
function M.decode_tlv_fields(bytes, header_size, field_count)
    if not bytes or #bytes < header_size + 8 then return nil end
    if field_count <= 0 or field_count > 20 then return nil end

    local ffi = require("ffi")
    local fields = {}
    local raw_payloads = {}
    local pos = header_size + 1  -- 1-indexed

    for _ = 1, field_count do
        -- Field name: [BE32 name_byte_len] [UTF-16BE name bytes]
        local name_len = M.read_be32(bytes, pos)
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
            local aux = M.read_be32(bytes, pos)
            if not aux then return nil end
            pos = pos + 4
            if pos > #bytes then return nil end
            local val = bytes:byte(pos)
            pos = pos + 1
            fields[field_name] = aux * 256 + val

        elseif field_type == 0x0004 then
            -- 8-byte aux + 1-byte val → aux*256 + val
            local aux = M.read_be64(bytes, pos)
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
            local aux = M.read_be32(bytes, pos)
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

-- ---------------------------------------------------------------------------
-- High-level blob decoders
-- ---------------------------------------------------------------------------

--- Decode BtVideoInfo/Time blob → {num_frames, frame_rate, unique_id}
-- Header: 8 bytes [BE32 version=1] [BE32 field_count]
-- Fields: UniqueId, [Timecode], StartFrame, NumFrames, FrameRate, DbType
-- @param hex_str string: hex-encoded Time blob
-- @return table|nil: {num_frames=int, frame_rate=number, unique_id=string} or nil
function M.decode_bt_video_time(hex_str)
    local bytes = M.hex_to_bytes(hex_str)
    if not bytes or #bytes < 16 then return nil end

    local field_count = M.read_be32(bytes, 5)  -- offset 4 (0-indexed) = pos 5 (1-indexed)
    if not field_count or field_count < 4 or field_count > 8 then return nil end

    local fields = M.decode_tlv_fields(bytes, 8, field_count)
    if not fields then return nil end

    local num_frames = fields["NumFrames"]
    if not num_frames or num_frames <= 0 then return nil end

    return {
        num_frames = num_frames,
        frame_rate = fields["FrameRate"],
        unique_id = fields["UniqueId"],
    }
end

--- Decode BtAudioInfo/TracksBA blob → {duration_samples, sample_rate, start_time_seconds}
-- Header: 31 bytes (version, track metadata, field_count at byte offset 27)
-- Fields: UniqueId, StartTime, SampleRate, NumChannels, IdxTrack, Duration, DbType, ...
-- @param hex_str string: hex-encoded TracksBA blob
-- @return table|nil: {duration_samples=int, sample_rate=int, start_time_seconds=number|nil} or nil
function M.decode_bt_audio_duration(hex_str)
    local bytes = M.hex_to_bytes(hex_str)
    if not bytes or #bytes < 40 then return nil end

    local field_count = M.read_be32(bytes, 28)  -- offset 27 (0-indexed) = pos 28 (1-indexed)
    if not field_count or field_count < 5 or field_count > 15 then return nil end

    local fields = M.decode_tlv_fields(bytes, 31, field_count)
    if not fields then return nil end

    local duration = fields["Duration"]
    local sample_rate = fields["SampleRate"]
    if not duration or not sample_rate then return nil end
    if sample_rate <= 0 then return nil end
    if duration <= 0 then return nil end

    return {
        duration_samples = duration,
        sample_rate = sample_rate,
        start_time_seconds = fields["StartTime"],
    }
end

--- Decode clip volume from EffectFiltersBA hex blob.
-- EffectFiltersBA contains per-clip audio effects (volume, EQ, reverb, etc.) in a
-- variable-length TLV binary. The volume double (LE IEEE 754, dB) always follows
-- the marker "0f085f1a0b0a0911".
-- @param hex_str string|nil: hex-encoded EffectFiltersBA content
-- @return number|nil: volume in dB (0.0 = unity, negative = quieter), nil if no volume found
function M.decode_effect_filters_volume_db(hex_str)
    if not hex_str or hex_str == "" then return nil end
    local marker = "0f085f1a0b0a0911"
    local marker_pos = hex_str:find(marker, 1, true)
    if not marker_pos then return nil end
    local vol_start = marker_pos + #marker
    if vol_start + 15 > #hex_str then return nil end
    local hex16 = hex_str:sub(vol_start, vol_start + 15)
    local db_val = M.decode_le_double_pure(hex16)
    if not db_val then return nil end
    -- Sanity: Resolve volume range is -inf..+12dB fader.
    -- Anything outside [-100, +24] is corrupt blob data, not volume.
    if db_val < -100 or db_val > 24 then return nil end
    return db_val
end

-- ---------------------------------------------------------------------------
-- KeyframesBA parsing (retime curves)
-- ---------------------------------------------------------------------------

--- Parse one inner keyframe blob → (x, y) doubles in seconds.
-- Inner blob structure: [BE32 inner_version] [BE32 inner_fc] [TLV fields...]
-- Fields include interp, YOut, YIn, Y, XOut, XIn, X.
-- Uses decode_tlv_fields to avoid duplicating TLV walking logic.
-- @param bytes string: full KeyframesBA payload bytes
-- @param start_pos integer: 1-indexed start position of the inner blob
-- @param max_end integer: 1-indexed inclusive last position the blob can occupy
-- @return number|nil, number|nil: x, y values in seconds, or nil/nil on parse error
local function parse_inner_keyframe(bytes, start_pos, max_end)
    if start_pos + 7 > max_end then return nil, nil end
    local inner_fc = M.read_be32(bytes, start_pos + 4)
    if not inner_fc or inner_fc < 1 or inner_fc > 20 then return nil, nil end

    -- Extract the inner blob substring and decode via TLV
    local inner_bytes = bytes:sub(start_pos, max_end)
    local fields = M.decode_tlv_fields(inner_bytes, 8, inner_fc)
    if not fields then return nil, nil end

    return fields["X"], fields["Y"]
end

--- Parse the KeyframesBA nested payload into an array of {x, y} pairs.
-- KeyframesBA outer structure:
--   [BE32 version] [BE32 keyframe_count]
--   kf_count × [outer TLV field with name="0"/"1"/..., type=0x000c]
-- Each outer field's 0x000c payload is an inner blob:
--   [BE32 inner_version] [BE32 inner_fc] [TLV fields including X, Y]
-- X = master playback timeline seconds, Y = source seconds.
-- @param kf_bytes string: raw bytes of the KeyframesBA payload
-- @return table|nil: array of {x=number, y=number} sorted ascending by x
function M.parse_keyframes(kf_bytes)
    if not kf_bytes or #kf_bytes < 16 then return nil end

    local kf_count = M.read_be32(kf_bytes, 5)
    if not kf_count or kf_count < 2 or kf_count > 100 then return nil end

    -- The outer structure is itself TLV with numeric field names ("0", "1", ...).
    -- Each field is type 0x000c containing an inner keyframe blob.
    -- Use decode_tlv_fields to walk the outer structure, then parse each
    -- inner payload with parse_inner_keyframe.
    local _, raw_payloads = M.decode_tlv_fields(kf_bytes, 8, kf_count)
    if not raw_payloads then return nil end

    local keyframes = {}
    for i = 0, kf_count - 1 do
        local field_name = tostring(i)
        local payload = raw_payloads[field_name]
        if payload and #payload >= 16 then
            local kf_x, kf_y = parse_inner_keyframe(payload, 1, #payload)
            if kf_x ~= nil and kf_y ~= nil then
                keyframes[#keyframes + 1] = { x = kf_x, y = kf_y }
            end
        end
    end

    if #keyframes < 2 then return nil end
    table.sort(keyframes, function(a, b) return a.x < b.x end)
    return keyframes
end

--- Detect reverse playback from KeyframesBA raw payload.
-- If last keyframe's Y < first keyframe's Y → reverse playback (negative slope).
-- Uses parse_keyframes to avoid duplicating TLV walking logic.
-- @param kf_bytes string: raw bytes of KeyframesBA payload
-- @return boolean: true if reverse playback detected
function M.detect_reverse_from_keyframes(kf_bytes)
    local keyframes = M.parse_keyframes(kf_bytes)
    if not keyframes or #keyframes < 2 then return false end
    return keyframes[#keyframes].y < keyframes[1].y
end

--- Evaluate a piecewise-linear retime curve at master-timeline X (seconds).
-- Returns the corresponding source-time Y (seconds). Clamps to endpoints.
-- @param keyframes table: array of {x, y} pairs sorted ascending by x
-- @param x number: query position in master playback timeline seconds
-- @return number: corresponding source position in seconds
function M.eval_curve(keyframes, x)
    if not keyframes or #keyframes < 2 then return x end
    -- Clamp to curve domain: source position outside the media's range is
    -- physically meaningless. Extrapolation past bounds (especially with
    -- reverse slopes) produces negative source positions.
    if x <= keyframes[1].x then
        return keyframes[1].y
    end
    if x >= keyframes[#keyframes].x then
        return keyframes[#keyframes].y
    end
    for i = 1, #keyframes - 1 do
        local k0 = keyframes[i]
        local k1 = keyframes[i + 1]
        if x >= k0.x and x <= k1.x then
            local span = k1.x - k0.x
            if span <= 0 then return k0.y end
            local t = (x - k0.x) / span
            return k0.y + t * (k1.y - k0.y)
        end
    end
    return keyframes[#keyframes].y
end

--- Decode MediaTimemapBA blob → {speed_ratio, is_reverse, y_max, x_max, keyframes}
--
-- Two MTBA formats exist:
--   Header 0x02 (9 bytes): [1-byte header] [8-byte BE double = media duration]
--     → No speed/direction info, return nil.
--   Header 0x01 (large): [BE32 version=1] [BE32 field_count] [TLV fields]
--     → YMax (source duration sec), XMax (retimed duration sec), KeyframesBA
--     → speed_ratio = YMax / XMax, direction from keyframe slope.
--     → keyframes = parsed (X, Y) pairs from KeyframesBA for curve walking.
--
-- @param hex_str string: hex-encoded MediaTimemapBA blob
-- @return table|nil: {speed_ratio, is_reverse, y_max, x_max, keyframes}
function M.decode_media_timemap(hex_str)
    local bytes = M.hex_to_bytes(hex_str)
    if not bytes or #bytes <= 9 then return nil end

    -- Large MTBA: [BE32 version=1] [BE32 field_count] + TLV fields
    local version = M.read_be32(bytes, 1)
    if version ~= 1 then return nil end

    local field_count = M.read_be32(bytes, 5)
    if not field_count or field_count < 2 or field_count > 10 then return nil end

    local fields, raw_payloads = M.decode_tlv_fields(bytes, 8, field_count)
    if not fields then return nil end

    local y_max = fields["YMax"]
    local x_max = fields["XMax"]
    if not y_max or not x_max then return nil end
    if x_max <= 0 or y_max <= 0 then return nil end

    local speed_ratio = y_max / x_max

    -- Parse the KeyframesBA nested blob into both reverse-flag and curve.
    local is_reverse = false
    local keyframes = nil
    local kf_raw = raw_payloads and raw_payloads["KeyframesBA"]
    if kf_raw then
        is_reverse = M.detect_reverse_from_keyframes(kf_raw)
        keyframes = M.parse_keyframes(kf_raw)

        -- Sanity-check the parsed keyframes against the parent YMax/XMax.
        -- Valid curves span the full master clip:
        --   Forward: first≈(0, 0)         last≈(XMax, YMax)
        --   Reverse: first≈(0, YMax)      last≈(XMax, 0)
        -- Discard only when keyframes look like garbage (all-zero anchors from
        -- tangent-only test fixtures).
        if keyframes and #keyframes >= 2 then
            local first = keyframes[1]
            local last = keyframes[#keyframes]
            local epsilon = 0.1  -- seconds; 0.01 was too tight for Resolve's rounding
            local x_ok = math.abs(first.x) < epsilon
                and math.abs(last.x - x_max) < epsilon
            -- Y endpoints: forward (0→YMax) or reverse (YMax→0)
            local forward_ok = math.abs(first.y) < epsilon
                and math.abs(last.y - y_max) < epsilon
            local reverse_ok = math.abs(first.y - y_max) < epsilon
                and math.abs(last.y) < epsilon
            if not (x_ok and (forward_ok or reverse_ok)) then
                log.detail("decode_media_timemap: keyframes inconsistent with YMax/XMax — first=(%.3f,%.3f) last=(%.3f,%.3f) ymax=%.3f xmax=%.3f — discarding curve",
                    first.x, first.y, last.x, last.y, y_max, x_max)
                keyframes = nil
            end
        end
    end

    return {
        speed_ratio = speed_ratio,
        is_reverse = is_reverse,
        y_max = y_max,
        x_max = x_max,
        keyframes = keyframes,
    }
end

-- ---------------------------------------------------------------------------
-- Sm2Mp*.FieldsBlob decoding (synced-clip support).
--
-- On-wire shape:
--     [BE32 version][BE32 declared_size][0x81 marker][zstd frame]
--
-- The zstd frame decompresses to a protobuf-ish payload. For synced-clip
-- resolution we don't parse the protobuf fully — we only need the ordered
-- list of embedded MediaRef UUIDs (each one is a `BtAudioInfo` DbId that
-- resolves to an audio pool item).
-- ---------------------------------------------------------------------------

--- Strip the [BE32 version][BE32 size][0x81] wrapper and zstd-decompress.
-- The 9-byte wrapper is shared by Sm2Mp FieldsBlobs and the inner BlobData
-- payload of marker blobs, so both decode paths share this helper.
-- @param bytes string: raw FieldsBlob bytes (9-byte wrapper + zstd frame)
-- @return string|nil: decompressed payload on success
-- @return string|nil: human-readable error on failure
function M.decode_fields_blob_bytes(bytes)
    if type(bytes) ~= "string" or #bytes < 10 then
        return nil, "FieldsBlob bytes too short (< 9-byte wrapper + frame)"
    end

    local marker = bytes:byte(9)
    if marker ~= 0x81 then
        return nil, string.format(
            "FieldsBlob wrapper byte 9 must be 0x81, got 0x%02x", marker)
    end

    if type(qt_zstd_decompress) ~= "function" then
        return nil, "FieldsBlob: qt_zstd_decompress binding not available"
    end

    return qt_zstd_decompress(bytes:sub(10))
end

--- Decompress a Sm2Mp*.FieldsBlob hex string.
-- @param hex_str string: full FieldsBlob hex (including 9-byte wrapper)
-- @return string|nil: decompressed payload bytes on success
-- @return string|nil: human-readable error on failure
function M.decode_fields_blob(hex_str)
    if type(hex_str) ~= "string" or #hex_str < 18 then
        return nil, "FieldsBlob hex too short (< 9 bytes of wrapper)"
    end

    local bytes = M.hex_to_bytes(hex_str)
    if not bytes or #bytes < 9 then
        return nil, "FieldsBlob hex is not valid hex or decoded < 9 bytes"
    end

    return M.decode_fields_blob_bytes(bytes)
end

--- Extract all UTF-16BE UUID strings from a decompressed FieldsBlob.
--
-- The Sm2MpVideoClip FieldsBlob embeds a `MediaRef` field per audio
-- stream the pool item claims (own embedded audio, synced external
-- audio, or both). Each MediaRef's value is a 72-byte UTF-16BE encoding
-- of a canonical dashed UUID. Rather than walk the protobuf, we scan
-- the decompressed bytes for the canonical UUID shape. The order matches
-- the protobuf field order (callers rely on that for source-index ↔ file
-- mapping).
--
-- Returns UUIDs in on-wire order, duplicates preserved: callers can
-- build a distinct set or count occurrences as needed.
-- @param bytes string: decompressed FieldsBlob payload
-- @return table: array of lowercase dashed UUID strings
function M.extract_media_refs(bytes)
    assert(type(bytes) == "string",
        "extract_media_refs: bytes string required")
    local out = {}
    local n = #bytes
    local i = 1
    while i <= n - 71 do
        -- Cheap filter: UTF-16BE hex digits always have a 0x00 high
        -- byte; a canonical UUID has '-' at char offset 8 (byte 16).
        if bytes:byte(i) == 0 and bytes:byte(i + 16) == 0
            and bytes:byte(i + 17) == 0x2d then
            local s = bytes:sub(i, i + 71)
            local chars = {}
            local ok = true
            for j = 1, 72, 2 do
                if s:byte(j) ~= 0 then ok = false; break end
                chars[#chars + 1] = string.char(s:byte(j + 1))
            end
            if ok then
                local ascii = table.concat(chars)
                if ascii:match(
                        "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-"
                        .. "%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") then
                    out[#out + 1] = ascii:lower()
                    i = i + 72
                    goto continue
                end
            end
        end
        i = i + 1
        ::continue::
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Clip marker decoding (Sm2TiItemLockableBlob → per-clip markers).
--
-- Resolve stores a clip's markers in an Sm2TiItemLockableBlob whose
-- <BlobOwner> is the owning clip's Sm2Ti DbId. The <FieldsBlob> is a Fusion
-- "Fields" TLV container holding one field, "BlobData", whose value is a
-- [BE32 version][BE32 size][0x81][zstd] blob (same wrapper as Sm2Mp blobs).
-- The decompressed payload is a protobuf marker collection:
--
--   f2 LEN  = collection
--     repeated f1 LEN = one per marker:
--       f1 varint = frame (relative to clip start)
--       f2 LEN    = [BE32 ver=2][BE32 size] + f1 LEN color message:
--           f1 varint = color value (see MARKER_COLOR_NAMES)
--           f3 str    = note     (present even when empty)
--           f3 str    = duration (decimal string; span width)
--           f3 str    = name     (Resolve rejects empty-name markers)
--           f6 str    = custom data (omitted when empty)
--
-- Sm2TiItemLockableBlob is a MIXED per-item state container; only some
-- entries are markers. A non-marker blob's BlobData lacks the 0x81+zstd
-- wrapper or fails the structural walk, so the decoders return nil and the
-- caller skips it (consistent with this module's "nil on failure" contract).
-- ---------------------------------------------------------------------------

-- Resolve marker color value → display name. Pinned by an exhaustive
-- 16-color round-trip export. Values are bit positions with a gap at 256
-- (2^8 is unused between Purple=128 and Fuchsia=512) — hence an explicit
-- table, not a formula.
local MARKER_COLOR_NAMES = {
    [2] = "Blue", [4] = "Cyan", [8] = "Green", [16] = "Yellow",
    [32] = "Red", [64] = "Pink", [128] = "Purple", [512] = "Fuchsia",
    [1024] = "Rose", [2048] = "Lavender", [4096] = "Sky", [8192] = "Mint",
    [16384] = "Lemon", [32768] = "Sand", [65536] = "Cocoa", [131072] = "Cream",
}

--- Read a protobuf tag at pos → field_number, wire_type, next_pos (or nil).
local function read_pb_tag(bytes, pos)
    local tag, np = M.decode_protobuf_varint(bytes, pos)
    if not tag then return nil end
    return math.floor(tag / 8), tag % 8, np
end

--- Decode a marker's inner color message protobuf.
-- @param bytes string: the color-message bytes
-- @return table|nil: {color, note, duration, name, custom_data}
local function decode_marker_color_message(bytes)
    local color_value, custom_data
    local strings = {}
    local pos = 1
    while pos <= #bytes do
        local field_num, wire_type, np = read_pb_tag(bytes, pos)
        if not field_num then return nil end
        pos = np
        if field_num == 1 and wire_type == 0 then
            color_value, pos = M.decode_protobuf_varint(bytes, pos)
            if not color_value then return nil end
        elseif wire_type == 2 then
            local len
            len, pos = M.decode_protobuf_varint(bytes, pos)
            if not len or pos + len - 1 > #bytes then return nil end
            local s = bytes:sub(pos, pos + len - 1)
            pos = pos + len
            if field_num == 3 then
                strings[#strings + 1] = s
            elseif field_num == 6 then
                custom_data = s
            end
        else
            return nil  -- unexpected wire type → not a marker message
        end
    end

    -- Positional strings are exactly [note, duration, name].
    if #strings ~= 3 then return nil end
    local color_name = MARKER_COLOR_NAMES[color_value]
    if not color_name then return nil end
    local duration = tonumber(strings[2])
    if not duration then return nil end
    return {
        color = color_name,
        note = strings[1],
        duration = math.floor(duration),
        name = strings[3],
        custom_data = custom_data or "",
    }
end

--- Decode the marker-collection protobuf payload → array of markers.
-- @param payload string: decompressed BlobData payload
-- @return table|nil: array of {frame, color, name, note, duration, custom_data}
local function decode_marker_protobuf(payload)
    if type(payload) ~= "string" or #payload < 2 then return nil end

    -- Outer: a single f2 LEN field = the collection.
    local field_num, wire_type, pos = read_pb_tag(payload, 1)
    if field_num ~= 2 or wire_type ~= 2 then return nil end
    local coll_len
    coll_len, pos = M.decode_protobuf_varint(payload, pos)
    if not coll_len then return nil end
    local coll_end = pos + coll_len - 1
    if coll_end > #payload then return nil end

    local markers = {}
    while pos <= coll_end do
        -- Each marker is an f1 LEN entry.
        local mfn, mwt, mp = read_pb_tag(payload, pos)
        if mfn ~= 1 or mwt ~= 2 then return nil end
        local mlen
        mlen, mp = M.decode_protobuf_varint(payload, mp)
        if not mlen then return nil end
        local marker_end = mp + mlen - 1
        if marker_end > coll_end then return nil end
        pos = mp

        -- frame: f1 varint
        local ffn, fwt, fp = read_pb_tag(payload, pos)
        if ffn ~= 1 or fwt ~= 0 then return nil end
        local frame
        frame, fp = M.decode_protobuf_varint(payload, fp)
        if not frame then return nil end
        pos = fp

        -- record: f2 LEN = [BE32 ver][BE32 size] + f1 LEN color message
        local rfn, rwt, rp = read_pb_tag(payload, pos)
        if rfn ~= 2 or rwt ~= 2 then return nil end
        local rlen
        rlen, rp = M.decode_protobuf_varint(payload, rp)
        if not rlen or rp + rlen - 1 > marker_end then return nil end
        local record = payload:sub(rp, rp + rlen - 1)
        pos = marker_end + 1

        if #record < 8 then return nil end
        local inner_size = M.read_be32(record, 5)
        if not inner_size or 8 + inner_size > #record then return nil end
        local body = record:sub(9, 8 + inner_size)

        -- body wraps the color message in an f1 LEN field.
        local cfn, cwt, cp = read_pb_tag(body, 1)
        if cfn ~= 1 or cwt ~= 2 then return nil end
        local clen
        clen, cp = M.decode_protobuf_varint(body, cp)
        if not clen or cp + clen - 1 > #body then return nil end

        local marker = decode_marker_color_message(body:sub(cp, cp + clen - 1))
        if not marker then return nil end
        marker.frame = frame
        markers[#markers + 1] = marker
    end
    return markers
end

--- Decode all markers from a Sm2TiItemLockableBlob's FieldsBlob hex.
-- Returns nil when the blob is not a marker blob (other per-item state), so
-- the importer can try every Sm2TiItemLockableBlob and keep what decodes.
-- @param fields_blob_hex string: <FieldsBlob> hex (whitespace tolerated)
-- @return table|nil: array of {frame, color, name, note, duration, custom_data}
function M.decode_clip_markers(fields_blob_hex)
    local bytes = M.hex_to_bytes(fields_blob_hex)
    if not bytes or #bytes < 12 then return nil end

    -- Outer Fields TLV: [BE32 version=1][BE32 field_count] then fields.
    local version = M.read_be32(bytes, 1)
    local field_count = M.read_be32(bytes, 5)
    if version ~= 1 or not field_count or field_count < 1 or field_count > 8 then
        return nil
    end

    local _, raw_payloads = M.decode_tlv_fields(bytes, 8, field_count)
    if not raw_payloads then return nil end
    local blob_data = raw_payloads["BlobData"]
    if not blob_data then return nil end

    local payload = M.decode_fields_blob_bytes(blob_data)
    if not payload then return nil end

    return decode_marker_protobuf(payload)
end

return M
