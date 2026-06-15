require("test_env")

-- =============================================================================
-- T003 — DRT binary encoder round-trip (black-box, per blob type)
--
-- The encoder (`exporters.drt_binary`) must be the exact byte-inverse of the
-- importer's decoders (`importers.drp_binary`). For each blob type, encode a
-- DOMAIN value, decode it back with the REAL importer decoder, and assert the
-- value survives.
--
-- Expected values come from NLE/timecode/format domain rules — NTSC rates,
-- timecode math, retime semantics — NEVER by tracing the encoder.
-- =============================================================================

local enc = require("exporters.drt_binary")
local dec = require("importers.drp_binary")

-- IEEE-754 doubles reconstructed by the pure-Lua decoder can differ from the
-- input by up to ~1 ULP; compare doubles within a tight epsilon, ints exactly.
local function approx(a, b, eps)
    eps = eps or 1e-9
    return math.abs(a - b) <= eps * math.max(1, math.abs(a), math.abs(b))
end
local function check(cond, msg) assert(cond, msg) end

-- --- Domain constants ------------------------------------------------------
-- NTSC 23.976 fps is exactly 24000/1001; this is the canonical fractional
-- frame rate that breaks naive integer/locale handling.
local FR_23976 = 24000 / 1001            -- 23.976023976...
local FR_2997  = 30000 / 1001            -- 29.97
local SR_48K   = 48000                   -- audio sample rate

-- ===========================================================================
-- 1. Big-endian integers (write_be32 / write_be64)
--    Domain: DRP TLV headers store version + field counts as BE32; large
--    audio sample counts overflow 32 bits and use BE64.
-- ===========================================================================
do
    local n32 = 0x01020304                          -- 16909060, all 4 bytes distinct
    local rt32 = dec.read_be32(enc.write_be32(n32), 1)
    check(rt32 == n32, ("BE32 round-trip: got %s want %d"):format(tostring(rt32), n32))

    -- 1h of 48 kHz audio = 172,800,000 samples — well past 2^27, exercises 64-bit.
    local n64 = SR_48K * 3600
    local rt64 = dec.read_be64(enc.write_be64(n64), 1)
    check(rt64 == n64, ("BE64 round-trip: got %s want %d"):format(tostring(rt64), n64))
    print("  ✓ BE32 / BE64 integer round-trip")
end

-- ===========================================================================
-- 2. Little-endian IEEE-754 double (encode_le_double)
--    Domain: <MediaFrameRate>, <FrameRate> store fps as an LE double in hex.
-- ===========================================================================
do
    for _, fr in ipairs({ FR_23976, FR_2997, 25.0, 24.0, 59.94 }) do
        local hex = enc.encode_le_double(fr)
        check(#hex == 16, ("encode_le_double must yield 16 hex chars (8 bytes), got %d"):format(#hex))
        -- decode via BOTH importer paths (FFI and pure-Lua) — both must agree.
        check(approx(dec.decode_le_double_pure(hex), fr), "LE double (pure) round-trip: " .. fr)
        check(approx(dec.decode_hex_double_at(hex, 0), fr), "LE double (ffi) round-trip: " .. fr)
    end
    print("  ✓ LE IEEE-754 double round-trip (fractional NTSC rates)")
end

-- ===========================================================================
-- 3. Sub-frame fraction as |hex (encode_le_double in [0,1))
--    Domain: BWF audio lands between video frames; the <Start>|hex tail encodes
--    that fractional-frame offset as an LE double in [0,1). One 48 kHz sample
--    at 23.976 fps is a real, tiny, non-trivial sub-frame value.
-- ===========================================================================
do
    local one_sample_frac = FR_23976 / SR_48K       -- ≈ 0.00049950 frame
    for _, frac in ipairs({ 0.5, 0.25, one_sample_frac, 0.999999 }) do
        local hex = enc.encode_le_double(frac)
        local back = dec.decode_hex_double_at(hex, 0)
        check(back >= 0 and back < 1.0, "sub-frame must stay in [0,1): " .. frac)
        check(approx(back, frac), ("sub-frame round-trip: got %.12f want %.12f"):format(back, frac))
    end
    print("  ✓ sub-frame |hex fraction round-trip")
end

-- ===========================================================================
-- 4. Resolution (encode_resolution → two LE doubles)
--    Domain: <Resolution> packs width then height as adjacent LE doubles.
-- ===========================================================================
do
    for _, wh in ipairs({ {1920,1080}, {4096,2160}, {2048,858} }) do  -- HD, DCI-4K, 2.39:1
        local hex = enc.encode_resolution(wh[1], wh[2])
        local w, h = dec.decode_hex_resolution(hex)
        check(w == wh[1] and h == wh[2],
            ("resolution round-trip: got %sx%s want %dx%d"):format(tostring(w), tostring(h), wh[1], wh[2]))
    end
    print("  ✓ resolution round-trip")
end

-- ===========================================================================
-- 5. TLV fields (encode_tlv_fields ↔ decode_tlv_fields)
--    Domain: the generic DRP field container. Mixed int + double fields with
--    UTF-16BE ASCII names. Use values that exercise both type encodings.
-- ===========================================================================
do
    -- A small int field and a double field (the two type classes the encoder
    -- must emit). Names are the real DRP field names for a video Time blob.
    local fields_in = {
        { name = "NumFrames", kind = "int",    value = 86486 },   -- > 1h of frames
        { name = "FrameRate", kind = "double", value = FR_23976 },
    }
    local bytes = enc.encode_tlv_fields(fields_in)
    -- decode_tlv_fields(bytes, header_size, field_count): no header here.
    local fields_out = dec.decode_tlv_fields(bytes, 0, #fields_in)
    check(fields_out ~= nil, "decode_tlv_fields returned nil")
    check(fields_out.NumFrames == 86486, "TLV int field round-trip")
    check(approx(fields_out.FrameRate, FR_23976), "TLV double field round-trip")
    print("  ✓ TLV fields round-trip (int + double)")
end

-- ===========================================================================
-- 6. BtVideoInfo Time blob (encode_bt_video_time ↔ decode_bt_video_time)
--    Domain: master-clip video duration. num_frames + fractional rate + UUID.
-- ===========================================================================
do
    local t_in = {
        num_frames = 86486,
        frame_rate = FR_23976,
        unique_id  = "7f133edb-6645-48c3-97c6-812f5b00a9e8",
    }
    local hex = enc.encode_bt_video_time(t_in)
    local t_out = dec.decode_bt_video_time(hex)
    check(t_out ~= nil, "decode_bt_video_time returned nil")
    check(t_out.num_frames == t_in.num_frames, "bt_video_time num_frames round-trip")
    check(approx(t_out.frame_rate, t_in.frame_rate), "bt_video_time frame_rate round-trip")
    check(t_out.unique_id == t_in.unique_id, "bt_video_time unique_id round-trip")
    check(t_out.timecode == nil, "bt_video_time omits Timecode for zero-origin media")
    print("  ✓ BtVideoInfo Time blob round-trip (5-field, zero-origin)")
end

-- 6b. Non-zero-origin media carries a Timecode field (6-field shape) — the
--     source-TC origin Resolve needs to map a trimmed clip's <In>.
do
    local t_in = {
        num_frames = 86486,
        frame_rate = FR_23976,
        unique_id  = "7f133edb-6645-48c3-97c6-812f5b00a9e8",
        timecode   = "01:00:00:00",
    }
    local hex = enc.encode_bt_video_time(t_in)
    local t_out = dec.decode_bt_video_time(hex)
    check(t_out ~= nil, "decode_bt_video_time (6-field) returned nil")
    check(t_out.num_frames == t_in.num_frames, "6-field num_frames round-trip")
    check(t_out.timecode == t_in.timecode, "6-field Timecode round-trip")
    print("  ✓ BtVideoInfo Time blob round-trip (6-field, non-zero origin)")
end

-- ===========================================================================
-- 7. MediaTimemapBA speed ramp (encode_media_timemap ↔ decode_media_timemap)
--    Domain: a 50% slow-motion clip plays 2.0s of source over 4.0s of timeline.
--    The retime curve is linear from (0,0) to (x_max, y_max). speed = y/x.
--    Also cover a reverse clip (source runs high→low).
-- ===========================================================================
do
    -- Forward 50% slow-mo.
    local slow = {
        y_max = 2.0,           -- source seconds consumed
        x_max = 4.0,           -- timeline seconds occupied
        is_reverse = false,
        unique_id = "11111111-2222-3333-4444-555555555555",
        keyframes = { { x = 0.0, y = 0.0 }, { x = 4.0, y = 2.0 } },
    }
    local hex = enc.encode_media_timemap(slow)
    local out = dec.decode_media_timemap(hex)
    check(out ~= nil, "decode_media_timemap returned nil (forward)")
    check(approx(out.y_max, slow.y_max) and approx(out.x_max, slow.x_max),
        "media_timemap extents round-trip")
    check(approx(out.speed_ratio, slow.y_max / slow.x_max),
        ("media_timemap speed_ratio: got %s want %.6f"):format(tostring(out.speed_ratio), slow.y_max/slow.x_max))
    check(out.is_reverse == false, "media_timemap forward not flagged reverse")

    -- Reverse: source runs from y_max down to 0 across the timeline.
    local rev = {
        y_max = 3.0,
        x_max = 3.0,
        is_reverse = true,
        unique_id = "66666666-7777-8888-9999-aaaaaaaaaaaa",
        keyframes = { { x = 0.0, y = 3.0 }, { x = 3.0, y = 0.0 } },
    }
    local rout = dec.decode_media_timemap(enc.encode_media_timemap(rev))
    check(rout ~= nil, "decode_media_timemap returned nil (reverse)")
    check(rout.is_reverse == true, "media_timemap reverse detected from keyframe slope")
    print("  ✓ MediaTimemapBA speed-ramp round-trip (forward + reverse)")
end

print("✅ test_drt_writer_roundtrip.lua passed")
