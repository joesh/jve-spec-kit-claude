-- Spec 023 — BtVideoInfo/BtAudioInfo <Clip> blob encoder
-- (drt_binary.encode_bt_clip_blob).
--
-- The Clip blob is what Resolve binds media by on DRT import
-- (live-dissected 2026-06-10, VM Resolve 20.3: a JVE DRT whose Clip
-- blob carried a stale directory imported with srcS=None even though
-- the XML MediaFilePath was valid; the reference Resolve export with
-- the correct directory linked, including into a clean media pool).
--
-- Wire schema (from the decompressed reference export):
--   protobuf — f1 LEN directory, f2 LEN filename, f3 LEN ctime-style
--   date string, f5 LEN codec ('avc1' video / 'AAC' audio),
--   video-only: f6 LEN clip display name, f7 LEN uuid string;
--   then an opaque varint tail captured from the reference (f13 …),
--   wrapped in the version-2 FieldsBlob frame (zstd).
--
-- Black-box: encode, then decode with the IMPORTER's codec
-- (decode_fields_blob_bytes + decode_protobuf_varint) and assert the
-- fields read back — expected values are the inputs, never traced from
-- the encoder.

require("test_env")
local enc = require("exporters.drt_binary")
local dec = require("importers.drp_binary")

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== encode_bt_clip_blob Tests ===")

local DIR  = "/Volumes/My Shared Files/jve-spec-kit-claude/tests/fixtures/media"
local FILE = "A005_C052_0925BL_001.mp4"
local DATE = "Tue Jan 13 01:44:18 2026"
local UUID = "ab0ac1ed-042b-40b9-a9ab-f82306fca300"
-- Source-file mtime in µs. The tail's f13 carries it verbatim; f15/f18 are the
-- media-type markers (video 4/16384, audio 2/32768 — research D4a).
local MTIME = 1775764733195782

-- Decode the protobuf varint tail (multi-byte field tags) into {field=value}.
-- Domain schema, not encoder code.
local function read_varint_tail(tail)
    local out, pos = {}, 1
    while pos <= #tail do
        local tag, after_tag = dec.decode_protobuf_varint(tail, pos)
        local field_no = math.floor(tag / 8)
        local wire = tag % 8
        if wire ~= 0 then break end  -- only varint fields in this tail
        local val, after_val = dec.decode_protobuf_varint(tail, after_tag)
        out[field_no] = val
        pos = after_val
    end
    return out
end

-- Minimal protobuf LEN-field walker (domain schema, not encoder code).
local function read_len_fields(payload)
    local fields, pos = {}, 1
    while pos <= #payload do
        local tag = payload:byte(pos)
        local field_no = math.floor(tag / 8)
        local wire = tag % 8
        if wire == 2 then -- LEN
            local len, data_pos = dec.decode_protobuf_varint(payload, pos + 1)
            fields[field_no] = payload:sub(data_pos, data_pos + len - 1)
            pos = data_pos + len
        else
            -- first non-LEN field starts the opaque tail
            fields.tail = payload:sub(pos)
            break
        end
    end
    return fields
end

-- ─── video blob ─────────────────────────────────────────────────────
do
    local hex = enc.encode_bt_clip_blob({
        directory = DIR, filename = FILE, date = DATE, mtime_us = MTIME,
        codec = "avc1", clip_name = FILE, clip_uuid = UUID,
    })
    check("video: hex string returned",
        type(hex) == "string" and hex:match("^%x+$") ~= nil)
    local payload = dec.decode_fields_blob_bytes(dec.hex_to_bytes(hex))
    check("video: fields-blob frame round-trips through the importer",
        type(payload) == "string" and #payload > 0)
    local f = read_len_fields(payload)
    check("video: f1 directory", f[1] == DIR)
    check("video: f2 filename", f[2] == FILE)
    check("video: f3 date", f[3] == DATE)
    check("video: f5 codec", f[5] == "avc1")
    check("video: f6 clip name", f[6] == FILE)
    check("video: f7 uuid", f[7] == UUID)
    check("video: tail present and starts at f13 varint",
        type(f.tail) == "string" and f.tail:byte(1) == 0x68)
    -- The importer's mtime decoder reads f13 back from the whole blob.
    check("video: f13 mtime round-trips", dec.decode_bt_clip_mtime(hex) == MTIME)
    local tail = read_varint_tail(f.tail)
    check("video: f13 = mtime", tail[13] == MTIME)
    check("video: f15 = 4 (video media-type)", tail[15] == 4)
    check("video: f16 = 100 (constant)", tail[16] == 100)
    check("video: f18 = 16384 (video media-type)", tail[18] == 16384)
end

-- ─── audio blob (no name/uuid fields) ───────────────────────────────
do
    local hex = enc.encode_bt_clip_blob({
        directory = DIR, filename = FILE, date = DATE, mtime_us = MTIME,
        codec = "AAC",
    })
    local payload = dec.decode_fields_blob_bytes(dec.hex_to_bytes(hex))
    local f = read_len_fields(payload)
    check("audio: f1 directory", f[1] == DIR)
    check("audio: f5 codec", f[5] == "AAC")
    check("audio: no f6/f7", f[6] == nil and f[7] == nil)
    check("audio: tail present", type(f.tail) == "string" and f.tail:byte(1) == 0x68)
    local tail = read_varint_tail(f.tail)
    check("audio: f13 = mtime", tail[13] == MTIME)
    check("audio: f15 = 2 (audio media-type)", tail[15] == 2)
    check("audio: f18 = 32768 (audio media-type)", tail[18] == 32768)
end

-- ─── frame header: declared size is the byte count AFTER the 8-byte
-- header (0x81 marker + zstd frame), NOT the decompressed payload size.
-- Live-dissected 2026-06-10 (VM Resolve 20.3): Resolve reads exactly
-- declared_size bytes; a decompressed-size value truncates/overreads the
-- zstd frame and the pool item materializes broken (' import', no path).
-- Reference export: video len_field=195 == #(0x81+zstd); decompressed=208.
do
    local hex = enc.encode_bt_clip_blob({
        directory = DIR, filename = FILE, date = DATE, mtime_us = MTIME,
        codec = "avc1", clip_name = FILE, clip_uuid = UUID,
    })
    local raw = dec.hex_to_bytes(hex)
    local declared = ((raw:byte(5) * 256 + raw:byte(6)) * 256
        + raw:byte(7)) * 256 + raw:byte(8)
    check("video: declared size == bytes after header (marker + zstd)",
        declared == #raw - 8)
end

-- ─── error paths ────────────────────────────────────────────────────
do
    local ok = pcall(enc.encode_bt_clip_blob,
        { filename = FILE, date = DATE, codec = "AAC", mtime_us = MTIME })
    check("missing directory asserts", not ok)
    local ok_mtime = pcall(enc.encode_bt_clip_blob,
        { directory = DIR, filename = FILE, date = DATE, codec = "AAC" })
    check("missing mtime_us asserts", not ok_mtime)
    local ok2 = pcall(enc.encode_bt_clip_blob,
        { directory = DIR, filename = FILE, date = DATE,
          codec = "avc1", clip_name = FILE }) -- name without uuid
    check("clip_name without clip_uuid asserts", not ok2)
end

print(string.format("\n%d passed, %d failed", pass, fail))
assert(fail == 0, "test_encode_bt_clip_blob.lua had failures")
print("✅ test_encode_bt_clip_blob.lua passed")
