-- drt_binary.lua — byte-exact ENCODER mirror of importers/drp_binary.lua.
--
-- Every function here is the inverse of a decoder in drp_binary.lua and is
-- kept beside its decoder's documented layout. Round-trip is proven by
-- tests/test_drt_writer_roundtrip.lua: drp_binary.decode(encode(x)) == x.
--
-- Pure Lua, no FFI. drp_binary.lua:111 warns that ffi.new/ffi.cast corrupt
-- LuaJIT state when used per-item at scale; the writer encodes one field per
-- clip, so the encoder mirrors decode_le_double_pure's arithmetic approach
-- rather than the FFI path.
--
-- I/O type matches each decoder's INPUT: low-level integer writers return raw
-- bytes (read_be32/64 take bytes); blob encoders return hex strings (the
-- decode_bt_*/decode_media_timemap take hex). Nested payloads (KeyframesBA,
-- inner keyframes) are raw bytes — they live inside a 0x000c field.

local drp_binary = require("importers.drp_binary")

local M = {}

-- ---------------------------------------------------------------------------
-- Big-endian integers — inverse of M.read_be32 / M.read_be64
-- ---------------------------------------------------------------------------

--- @param n integer: non-negative, < 2^32
--- @return string: 4 raw bytes, big-endian
function M.write_be32(n)
    assert(type(n) == "number" and n >= 0 and n < 4294967296 and n % 1 == 0,
        "write_be32: integer in [0, 2^32) required, got " .. tostring(n))
    return string.char(
        math.floor(n / 16777216) % 256,
        math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256,
        n % 256)
end

--- @param n integer: non-negative, < 2^53 (Lua double-exact integer range)
--- @return string: 8 raw bytes, big-endian (hi*2^32 + lo)
function M.write_be64(n)
    assert(type(n) == "number" and n >= 0 and n < 2 ^ 53 and n % 1 == 0,
        "write_be64: integer in [0, 2^53) required, got " .. tostring(n))
    local hi = math.floor(n / 4294967296)
    local lo = n - hi * 4294967296
    return M.write_be32(hi) .. M.write_be32(lo)
end

-- BE16: TLV separator + type tag (decode_tlv_fields reads b1*256 + b2).
local function write_be16(n)
    assert(type(n) == "number" and n >= 0 and n < 65536 and n % 1 == 0,
        "write_be16: integer in [0, 2^16) required, got " .. tostring(n))
    return string.char(math.floor(n / 256), n % 256)
end

-- ---------------------------------------------------------------------------
-- IEEE-754 binary64 — inverse of decode_le_double_pure / decode_hex_double_at
-- ---------------------------------------------------------------------------

-- Encode a Lua number to 8 raw bytes, little-endian (LSB first). x86/arm64
-- native order, which is what decode_hex_double_at's ffi.cast expects and what
-- decode_le_double_pure reconstructs arithmetically.
local function double_to_le_bytes(value)
    assert(type(value) == "number", "double_to_le_bytes: number required")
    local sign = 0
    if value < 0 then sign = 1; value = -value end

    local hi, lo  -- hi = sign(1)|exp(11)|mantissa_top(20); lo = mantissa_low(32)
    if value == 0 then
        hi, lo = sign * 2147483648, 0
    elseif value == math.huge then
        hi, lo = sign * 2147483648 + 0x7FF00000, 0
    elseif value ~= value then
        hi, lo = 0x7FF80000, 0  -- canonical quiet NaN (not expected in our domain)
    else
        local m, e = math.frexp(value)   -- value = m * 2^e, 0.5 <= m < 1
        local exp_field = e - 1 + 1023   -- unbiased exponent = e-1, biased +1023
        assert(exp_field > 0,
            "double_to_le_bytes: subnormal/underflow unsupported (value=" .. tostring(value) .. ")")
        assert(exp_field < 0x7FF,
            "double_to_le_bytes: exponent overflow (value=" .. tostring(value) .. ")")
        local frac = m * 2 - 1           -- normalized fraction in [0, 1)
        local mant = frac * 2 ^ 52       -- integer in [0, 2^52)
        local mant_hi = math.floor(mant / 4294967296)   -- top 20 bits
        local mant_lo = mant - mant_hi * 4294967296      -- low 32 bits
        hi = sign * 2147483648 + exp_field * 1048576 + mant_hi
        lo = mant_lo
    end

    local function le32(x)
        return string.char(
            x % 256,
            math.floor(x / 256) % 256,
            math.floor(x / 65536) % 256,
            math.floor(x / 16777216) % 256)
    end
    return le32(lo) .. le32(hi)
end

local function to_hex(bytes)
    return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

--- LE double as 16 hex chars — inverse of decode_hex_double_at / decode_le_double_pure.
--- Used for frame rates and the <Start>|hex sub-frame fraction.
--- @param x number
--- @return string: 16 lowercase hex chars
function M.encode_le_double(x)
    return to_hex(double_to_le_bytes(x))
end

--- BE double as 16 hex chars — byte-reverse of encode_le_double.
--- Used inside MediaTimemapBA (`02` type tag + BE double seconds).
--- @param x number
--- @return string: 16 lowercase hex chars
function M.encode_be_double(x)
    return to_hex(string.reverse(double_to_le_bytes(x)))
end

--- Resolve's <MediaFrameRate> wire shape: LE-double(rate) + 16 zero hex chars.
--- The trailing zeros are a fixed pad (observed byte-identical in every
--- Resolve-authored DRP; their meaning is not yet decoded but Resolve refuses
--- the element without them — see phase0-findings.md §K3c).
--- @param rate number: media's native fps
--- @return string: 32 lowercase hex chars
function M.encode_resolve_frame_rate(rate)
    return M.encode_le_double(rate) .. "0000000000000000"
end

--- Two adjacent LE doubles — inverse of decode_hex_resolution.
--- @return string: 32 hex chars (width then height)
function M.encode_resolution(width, height)
    return M.encode_le_double(width) .. M.encode_le_double(height)
end

-- ---------------------------------------------------------------------------
-- TLV fields — inverse of decode_tlv_fields
--
-- Per field: [BE32 name_byte_len][UTF-16BE name][BE16 sep=0][BE16 type][value]
-- Field names are ASCII stored UTF-16BE (decoder reads only the low byte of
-- each 2-byte unit), so name_byte_len = 2 * #ascii.
-- ---------------------------------------------------------------------------

-- ASCII → UTF-16BE (high byte 0x00 per char), matching the decoder's reader.
local function utf16be(ascii)
    return (ascii:gsub(".", function(c) return "\0" .. c end))
end

-- TLV type tags — pinned by decode_tlv_fields (drp_binary.lua:300-306). 0x0002
-- and 0x0003 share an encoding (small/medium int); the encoder emits 0x0002.
local TLV_INT     = 0x0002
local TLV_DOUBLE  = 0x0006
local TLV_STRING  = 0x000a
local TLV_PAYLOAD = 0x000c

-- Encode one field's value bytes for the given type tag.
local function encode_value(type_tag, value)
    if type_tag == TLV_INT then
        -- integer: value = aux*256 + val (aux BE32, val one byte)
        assert(type(value) == "number" and value >= 0 and value % 1 == 0,
            "encode_value: TLV int requires non-negative integer, got " .. tostring(value))
        local aux = math.floor(value / 256)
        local val = value % 256
        return M.write_be32(aux) .. string.char(val)
    elseif type_tag == TLV_DOUBLE then
        -- double: [1 byte pad=0][8-byte BE double]. The decoder reverses the 8
        -- bytes to LE before casting, so we store big-endian = reverse(LE).
        return "\0" .. string.reverse(double_to_le_bytes(value))
    elseif type_tag == TLV_STRING then
        -- string: [BE32 aux (ignored)][1 byte str_byte_len][UTF-16BE chars]
        local u = utf16be(value)
        assert(#u < 256, "encode_value: TLV string too long (" .. #u .. " bytes)")
        return M.write_be32(0) .. string.char(#u) .. u
    elseif type_tag == TLV_PAYLOAD then
        -- nested payload: [BE32 aux][1 byte val] where payload_len = aux*256+val,
        -- then the raw payload (first 8 bytes are read as an LE double, ignored).
        assert(type(value) == "string" and #value >= 8,
            "encode_value: 0x000c payload must be >= 8 bytes")
        local plen = #value
        local aux = math.floor(plen / 256)
        local val = plen % 256
        return M.write_be32(aux) .. string.char(val) .. value
    end
    error(string.format("encode_value: unsupported TLV type 0x%04x", type_tag))
end

local function encode_field(name, type_tag, value)
    local u = utf16be(name)
    return M.write_be32(#u) .. u .. write_be16(0) .. write_be16(type_tag)
        .. encode_value(type_tag, value)
end

-- Public field-kind name → tag, for callers that don't want raw hex constants.
local KIND_TYPE = {
    int     = TLV_INT,
    double  = TLV_DOUBLE,
    string  = TLV_STRING,
    payload = TLV_PAYLOAD,
}

--- Encode a flat field list to TLV bytes (no header) — inverse of
--- decode_tlv_fields(bytes, 0, #list).
--- @param list table: array of { name, kind="int"|"double"|"string"|"payload", value }
--- @return string: raw TLV bytes
function M.encode_tlv_fields(list)
    local parts = {}
    for _, f in ipairs(list) do
        local type_tag = KIND_TYPE[f.kind]
        assert(type_tag, "encode_tlv_fields: unknown kind '" .. tostring(f.kind) .. "'")
        parts[#parts + 1] = encode_field(f.name, type_tag, f.value)
    end
    return table.concat(parts)
end

-- ---------------------------------------------------------------------------
-- BtVideoInfo Time blob — inverse of decode_bt_video_time
-- Header: [BE32 version=1][BE32 field_count]; then TLV. field_count ∈ [4,8].
-- ---------------------------------------------------------------------------

--- @param t table: { num_frames=int>0, frame_rate=number, unique_id=string,
---                    timecode=string? }  -- timecode = media source-TC origin
---                    as "HH:MM:SS:FF"; omit/empty for zero-origin media.
--- @return string: hex-encoded Time blob
function M.encode_bt_video_time(t)
    assert(type(t.num_frames) == "number" and t.num_frames > 0,
        "encode_bt_video_time: num_frames must be > 0")
    assert(type(t.frame_rate) == "number", "encode_bt_video_time: frame_rate required")
    assert(type(t.unique_id) == "string", "encode_bt_video_time: unique_id required")
    -- Timecode is written verbatim as a TLV string and parsed by Resolve as
    -- the source-TC origin, so a malformed label would clamp the source range
    -- silently — assert the HH:MM:SS:FF / HH:MM:SS;FF (drop-frame) shape.
    assert(t.timecode == nil or (type(t.timecode) == "string"
            and t.timecode:match("^%d+:%d%d:%d%d[:;]%d%d$")),
        "encode_bt_video_time: timecode must be HH:MM:SS:FF, got "
            .. tostring(t.timecode))

    -- Reference shape (live Resolve 20.3 DRT export, dissected 2026-06-10
    -- / 2026-06-14): FrameRate as a 0x000c payload (LE double + 8 zero
    -- bytes) and a trailing DbType string "BtVideoTime".
    --
    -- The `Timecode` string (media's embedded source-TC origin, e.g.
    -- "01:00:00:00") is REQUIRED for media whose TC origin is non-zero:
    -- without it Resolve cannot map the timeline item's media-relative
    -- <In> onto the source media and clamps the imported clip's source
    -- range to media-end (GetSourceStartFrame == NumFrames, src 108..108
    -- on a 108-frame file). Live-confirmed 2026-06-14: injecting this one
    -- entry flips the readback 108 → 29 (the media-relative in-point,
    -- ±1 per Resolve's GetSourceStartFrame rounding) —
    -- test_drt_mptime_timecode_clamp. A Resolve-native item omits Timecode
    -- only when the media's TC origin is zero, so callers pass it only
    -- then (5-field shape == the zero-origin reference).
    -- StartFrame is 0 in every measured Resolve DRT/DRP Time blob (the source
    -- in-point lives in the timeline item's <In>, not here).
    local START_FRAME = 0
    local fields = encode_field("UniqueId", TLV_STRING, t.unique_id)
    local field_count = 5
    if t.timecode and t.timecode ~= "" then
        fields = fields .. encode_field("Timecode", TLV_STRING, t.timecode)
        field_count = 6
    end
    fields = fields
        .. encode_field("StartFrame", TLV_INT, START_FRAME)
        .. encode_field("NumFrames", TLV_INT, t.num_frames)
        .. encode_field("FrameRate", TLV_PAYLOAD,
            double_to_le_bytes(t.frame_rate) .. string.rep("\0", 8))
        .. encode_field("DbType", TLV_STRING, "BtVideoTime")
    local header = M.write_be32(1) .. M.write_be32(field_count)
    return to_hex(header .. fields)
end

-- ---------------------------------------------------------------------------
-- KeyframesBA + MediaTimemapBA — inverse of parse_keyframes / decode_media_timemap
-- ---------------------------------------------------------------------------

-- One inner keyframe blob: [BE32 ver][BE32 inner_fc=7][TLV interp,YOut,YIn,Y,XOut,XIn,X].
-- Real Resolve keyframes (dissected from "test audio, reverse audio.drp")
-- carry SEVEN fields, in this order: interp (int), then the bezier
-- tangent/value pairs YOut/YIn/Y and XOut/XIn/X (doubles). Resolve only
-- exercises X (master-timeline seconds) and Y (source seconds); the tangents
-- and interp are 0 for the linear ±speed ramps we emit. JVE's decoder reads
-- only X/Y, but Resolve's parser requires the full field set (the minimal
-- 2-field form parsed in JVE but Resolve refused to render — same failure
-- class as the short MTBA forms).
local function encode_inner_keyframe(kf)
    local fields = encode_field("interp", 0x0002, 0)
        .. encode_field("YOut", 0x0006, 0)
        .. encode_field("YIn",  0x0006, 0)
        .. encode_field("Y",    0x0006, kf.y)
        .. encode_field("XOut", 0x0006, 0)
        .. encode_field("XIn",  0x0006, 0)
        .. encode_field("X",    0x0006, kf.x)
    return M.write_be32(1) .. M.write_be32(7) .. fields
end

-- KeyframesBA payload: [BE32 ver][BE32 kf_count][TLV "0".."n-1" each 0x000c→inner].
-- parse_keyframes reads kf_count at offset 4; needs kf_count ∈ [2,100].
--
-- `keyframes` arrives sorted ASCENDING by x. The name attached to each keyframe
-- is its ascending-x rank (the x=0 keyframe is always "0"), which is how the
-- decoder keys them. But Resolve writes the field BLOCKS in DESCENDING order
-- (highest-x / highest-name first) — verified byte-exact against the reverse
-- curve in "test audio, reverse audio.drp" ("1" block precedes "0"). The
-- decoder is name-keyed so order is semantically irrelevant, but emitting
-- Resolve's order keeps the output byte-identical to its own exports.
local function encode_keyframes(keyframes)
    assert(#keyframes >= 2 and #keyframes <= 100,
        "encode_keyframes: keyframe count must be in [2,100], got " .. #keyframes)
    local body = {}
    for i = #keyframes, 1, -1 do
        body[#body + 1] = encode_field(tostring(i - 1), 0x000c, encode_inner_keyframe(keyframes[i]))
    end
    return M.write_be32(1) .. M.write_be32(#keyframes) .. table.concat(body)
end

--- MediaTimemapBA (large 0x01 format) — inverse of decode_media_timemap, in
--- the full SIX-field shape Resolve authors (dissected from the reverse clip
--- in "test audio, reverse audio.drp"): YMax, XMax, UniqueId, LastValidYOffset,
--- KeyframesBA, DbType. The decoder reads only YMax/XMax/KeyframesBA; Resolve's
--- own parser needs the rest (UniqueId per-curve UUID, LastValidYOffset = YMax,
--- DbType = "Sm2TimeMap"). speed_ratio = YMax/XMax and the direction come from
--- the keyframe slope: forward (0,0)→(XMax,YMax), reverse (0,YMax)→(XMax,0).
--- @param tm table: { y_max>0, x_max>0, unique_id:string, keyframes={{x,y},...} }
--- @return string: hex-encoded MediaTimemapBA blob
function M.encode_media_timemap(tm)
    assert(type(tm.y_max) == "number" and tm.y_max > 0, "encode_media_timemap: y_max must be > 0")
    assert(type(tm.x_max) == "number" and tm.x_max > 0, "encode_media_timemap: x_max must be > 0")
    assert(type(tm.keyframes) == "table", "encode_media_timemap: keyframes required")
    assert(type(tm.unique_id) == "string" and #tm.unique_id == 36,
        "encode_media_timemap: unique_id must be a 36-char UUID string (Resolve "
        .. "mints one per retime curve)")

    local fields = encode_field("YMax", 0x0006, tm.y_max)
        .. encode_field("XMax", 0x0006, tm.x_max)
        .. encode_field("UniqueId", 0x000a, tm.unique_id)
        .. encode_field("LastValidYOffset", 0x0006, tm.y_max)
        .. encode_field("KeyframesBA", 0x000c, encode_keyframes(tm.keyframes))
        .. encode_field("DbType", 0x000a, "Sm2TimeMap")
    local header = M.write_be32(1) .. M.write_be32(6)  -- version=1, field_count=6
    return to_hex(header .. fields)
end

-- ---------------------------------------------------------------------------
-- Sm2Mp*.FieldsBlob — inverse of decode_fields_blob
-- On-wire: [BE32 version][BE32 declared_size][0x81 marker][zstd frame].
-- declared_size counts the bytes AFTER the 8-byte header (marker + zstd
-- frame), NOT the decompressed payload — uniform across every framed blob
-- in the reference DRT export (6/6, ver 2) and the gold DRP (1365/1365,
-- ver 10001). Resolve trusts it on import: a decompressed-size value made
-- it read the wrong byte count and materialize a broken ' import' pool
-- item with no file path (live-bisected 2026-06-10, VM Resolve 20.3).
-- Requires the qt_zstd_compress C++ binding (added in T005); fail-fast if absent.
-- ---------------------------------------------------------------------------

--- @param payload string: raw bytes to compress and wrap
--- @param version integer: wrapper version. Resolve uses 1/2 for Sm2Mp
---   FieldsBlobs and 10001 for the Sm2TiItemLockableBlob marker payload
---   (inbound-findings.md §5). Decoder is version-agnostic (strips fixed
---   9-byte prefix); this assertion just pins the known-good values so a
---   drifted caller fails fast rather than emitting unreadable bytes.
--- @return string: hex-encoded FieldsBlob
function M.encode_fields_blob(payload, version)
    assert(type(payload) == "string", "encode_fields_blob: payload bytes required")
    assert(version == 1 or version == 2 or version == 10001,
        "encode_fields_blob: version must be 1, 2, or 10001 "
        .. "(Resolve's known wrappers), got " .. tostring(version))
    assert(type(qt_zstd_compress) == "function",
        "encode_fields_blob: qt_zstd_compress binding not available")
    local frame, zstd_err = qt_zstd_compress(payload)
    assert(frame, "encode_fields_blob: qt_zstd_compress failed: " .. tostring(zstd_err))
    local wrapper = M.write_be32(version) .. M.write_be32(#frame + 1) .. string.char(0x81)
    return to_hex(wrapper .. frame)
end

-- ---------------------------------------------------------------------------
-- Protobuf varint + field encoders — inverse of drp_binary's decoders.
-- Used by the clip-marker FieldsBlob encoder below; kept module-local so
-- the public surface stays the marker-blob entry point.
-- ---------------------------------------------------------------------------

local PB_WIRE_VARINT = 0
local PB_WIRE_LEN    = 2

local function encode_pb_varint(n)
    assert(type(n) == "number" and n >= 0 and n % 1 == 0,
        "encode_pb_varint: non-negative integer required, got " .. tostring(n))
    if n == 0 then return string.char(0) end
    local bytes = {}
    while n > 0 do
        local b = n % 128
        n = math.floor(n / 128)
        if n > 0 then b = b + 128 end
        bytes[#bytes + 1] = string.char(b)
    end
    return table.concat(bytes)
end

local function encode_pb_tag(field_num, wire_type)
    return encode_pb_varint(field_num * 8 + wire_type)
end

local function encode_pb_varint_field(field_num, value)
    return encode_pb_tag(field_num, PB_WIRE_VARINT) .. encode_pb_varint(value)
end

local function encode_pb_len_field(field_num, payload)
    return encode_pb_tag(field_num, PB_WIRE_LEN)
        .. encode_pb_varint(#payload) .. payload
end

-- ---------------------------------------------------------------------------
-- BtVideoInfo/BtAudioInfo <Clip> blob — the field Resolve binds media by
-- on DRT import (live-dissected 2026-06-10 against Resolve 20.3: a DRT
-- whose Clip blob carried a stale directory imported with
-- GetSourceStartFrame()=None even though the XML <MediaFilePath> was
-- valid; the reference export with the true directory linked, including
-- into a clean media pool, materializing the pool item).
--
-- Decompressed payload schema (protobuf; inverse of
-- drp_binary.decode_bt_clip_path's f1/f2 reads):
--   f1 LEN directory          f2 LEN filename
--   f3 LEN ctime-style date   f5 LEN codec ('avc1' / 'AAC')
--   video only: f6 LEN clip display name, f7 LEN uuid string
--   then an opaque varint tail (f13 onward) matching the pristine
--   reference export. The t050b reference (real Resolve 20.3 DRT export
--   of the A005 fixture, 2026-06-10) carries the IDENTICAL tail for the
--   video and audio shapes; an earlier kitchen-sink capture's video blob
--   had an extra f14 varint (20862 — file-instance-specific residue)
--   which the reference omits, so we omit it too. The tail is template
--   residue scoped by author_a005_compatible's existing media gate; an
--   encoder for arbitrary media must derive it (tracked with the
--   writer's other a005-gate limits).
-- ---------------------------------------------------------------------------

local BT_CLIP_TAIL = assert(
    drp_binary.hex_to_bytes("6880fbb2ba9ad6ce0278048001649001808001"),
    "BT_CLIP_TAIL: invalid hex literal")

--- Encode a BtVideoInfo/BtAudioInfo <Clip> blob (FieldsBlob-framed hex).
--- @param t table {directory, filename, date, codec,
---                 clip_name?, clip_uuid?}  — clip_name/clip_uuid are the
---                video-shape fields and must be supplied together;
---                their absence selects the audio shape.
function M.encode_bt_clip_blob(t)
    assert(type(t) == "table", "encode_bt_clip_blob: table required")
    for _, key in ipairs({ "directory", "filename", "date", "codec" }) do
        assert(type(t[key]) == "string" and t[key] ~= "",
            "encode_bt_clip_blob: " .. key .. " required (non-empty string)")
    end
    assert((t.clip_name == nil) == (t.clip_uuid == nil),
        "encode_bt_clip_blob: clip_name and clip_uuid are the video-shape "
        .. "pair — supply both or neither")
    local payload = encode_pb_len_field(1, t.directory)
        .. encode_pb_len_field(2, t.filename)
        .. encode_pb_len_field(3, t.date)
        .. encode_pb_len_field(5, t.codec)
    if t.clip_name ~= nil then
        assert(type(t.clip_name) == "string" and t.clip_name ~= "",
            "encode_bt_clip_blob: clip_name must be non-empty string")
        assert(type(t.clip_uuid) == "string" and t.clip_uuid ~= "",
            "encode_bt_clip_blob: clip_uuid must be non-empty string")
        payload = payload
            .. encode_pb_len_field(6, t.clip_name)
            .. encode_pb_len_field(7, t.clip_uuid)
    end
    payload = payload .. BT_CLIP_TAIL
    return M.encode_fields_blob(payload, 2)
end

-- ---------------------------------------------------------------------------
-- Clip-marker FieldsBlob (Sm2TiItemLockableBlob) — inverse of
-- drp_binary.decode_clip_markers. Schema is pinned by inbound-findings.md
-- §5 and verified against 111 real gold markers (drp_binary decoder tests).
--
-- One marker collection per blob; outer Fields TLV carries a single
-- "BlobData" field whose payload is [BE32 ver=10001][BE32 size][0x81][zstd]
-- wrapping the marker protobuf:
--
--   f2 LEN  = collection
--     repeated f1 LEN = one per marker:
--       f1 varint = frame
--       f2 LEN    = [BE32 ver=2][BE32 size] + f1 LEN color-message:
--           f1 varint = color value (drp_binary.MARKER_COLOR_VALUES)
--           f3 str    = note
--           f3 str    = duration (decimal string)
--           f3 str    = name
--           f6 str    = customData (omitted by Resolve when empty;
--                                   we always emit since clip identity
--                                   is the carrier and required)
-- ---------------------------------------------------------------------------

local function encode_marker_color_message(marker)
    local color_value = drp_binary.MARKER_COLOR_VALUES[marker.color]
    assert(color_value, "encode_marker_color_message: unknown color "
        .. tostring(marker.color)
        .. " (closed set: drp_binary.MARKER_COLOR_VALUES)")
    assert(type(marker.note) == "string",
        "encode_marker_color_message: marker.note must be string (may be empty)")
    -- Same rule as ClipMarker.new and drp_binary's decoder: duration >= 1
    -- (1 = point marker). Prior code accepted >= 0 here, which let a 0
    -- escape into the wire — drp_binary's decoder then dropped that
    -- marker on the round trip back in, silently breaking identity.
    -- Review HIGH E#4: one rule across decoder, model, encoder.
    assert(type(marker.duration) == "number" and marker.duration >= 1
        and marker.duration % 1 == 0,
        "encode_marker_color_message: marker.duration must be integer "
        .. ">= 1 (1 = point marker)")
    assert(type(marker.name) == "string" and marker.name ~= "",
        "encode_marker_color_message: marker.name required "
        .. "(Resolve rejects empty-name markers)")
    assert(type(marker.custom_data) == "string"
        and marker.custom_data ~= "",
        "encode_marker_color_message: marker.custom_data required for "
        .. "identity markers (this carrier IS the JVE clip.id)")
    return encode_pb_varint_field(1, color_value)
        .. encode_pb_len_field(3, marker.note)
        .. encode_pb_len_field(3, tostring(marker.duration))
        .. encode_pb_len_field(3, marker.name)
        .. encode_pb_len_field(6, marker.custom_data)
end

local function encode_marker_entry(marker)
    assert(type(marker.frame) == "number" and marker.frame >= 0
        and marker.frame % 1 == 0,
        "encode_marker_entry: marker.frame must be non-negative integer")
    local color_msg = encode_marker_color_message(marker)
    -- Inner record: [BE32 ver=2][BE32 inner_size] + f1 LEN color-message.
    local inner = encode_pb_len_field(1, color_msg)
    local record = M.write_be32(2) .. M.write_be32(#inner) .. inner
    -- Entry body: f1 varint frame, f2 LEN record. The outer f1 LEN tag
    -- wrapping each entry is emitted by encode_clip_markers below.
    return encode_pb_varint_field(1, marker.frame)
        .. encode_pb_len_field(2, record)
end

--- Encode a clip-marker collection to raw protobuf bytes (no FieldsBlob
--- wrapper). Inverse of drp_binary.decode_marker_protobuf.
--- @param markers table: array of {frame, color, name, note, duration, custom_data}
--- @return string: protobuf bytes
function M.encode_clip_markers(markers)
    assert(type(markers) == "table" and #markers >= 1,
        "encode_clip_markers: non-empty markers array required")
    local entries = {}
    for i, m in ipairs(markers) do
        entries[i] = encode_pb_len_field(1, encode_marker_entry(m))
    end
    local collection = table.concat(entries)
    return encode_pb_len_field(2, collection)
end

--- Encode a clip-marker collection to a hex FieldsBlob suitable for the
--- <FieldsBlob> child of a <Sm2TiItemLockableBlob>. Round-trips through
--- drp_binary.decode_clip_markers (semantic — zstd compression bytes are
--- not byte-identical to Resolve's output but decompress to the same
--- payload, which is what the decoder + Resolve's importer consume).
---
--- Inner wrapper version is 10001 per inbound-findings.md §5 (the value
--- Resolve writes for marker payloads); decoder is version-agnostic.
---
--- Outer Fields TLV: one "BlobData" field (0x000c payload) wrapping the
--- 9-byte-prefixed zstd frame. The 0x000c payload encoder requires payload
--- length >= 8 (encode_tlv_fields: payload header is BE32 aux + 1 byte
--- val, first 8 bytes of payload read as LE-double then ignored). A
--- single-marker payload is well above 8 bytes so this is never tight,
--- but the assertion is there in encode_value already.
---
--- @param markers table: array of marker tables (see encode_clip_markers)
--- @return string: hex-encoded FieldsBlob
function M.encode_clip_marker_fields_blob(markers)
    local protobuf = M.encode_clip_markers(markers)
    local inner = M.encode_fields_blob(protobuf, 10001)
    -- inner is hex; the TLV "BlobData" field carries raw bytes, so
    -- convert hex → bytes for the TLV payload.
    local inner_bytes = (inner:gsub("..", function(h)
        return string.char(tonumber(h, 16))
    end))
    local fields = M.encode_tlv_fields({
        { name = "BlobData", kind = "payload", value = inner_bytes },
    })
    -- Outer Fields TLV header: [BE32 version=1][BE32 field_count=1].
    local header = M.write_be32(1) .. M.write_be32(1)
    return to_hex(header .. fields)
end

return M
