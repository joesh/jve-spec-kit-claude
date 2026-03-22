#!/usr/bin/env luajit

-- DRP EffectFiltersBA volume decode: verify dB extraction from known blobs.
-- Test DRP "volume blob decoder.drp" has 3 clips: 0dB, -6dB, -12dB.

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";./?.lua"
    .. ";./?/init.lua"

require("test_env")

local drp = require("importers.drp_importer")

-- =========================================================================
-- Test 1: Empty/nil EffectFiltersBA → nil (decode failure, caller decides)
-- =========================================================================
assert(drp.decode_effect_filters_volume_db("") == nil,
    "empty string should decode to nil")
assert(drp.decode_effect_filters_volume_db(nil) == nil,
    "nil should decode to nil")
print("  ✓ Empty/nil EffectFiltersBA → nil")

-- =========================================================================
-- Test 2: Short blob → nil (too short to contain volume field)
-- =========================================================================
assert(drp.decode_effect_filters_volume_db("00000002000000") == nil,
    "short blob should decode to nil")
print("  ✓ Short blob → nil")

-- =========================================================================
-- Test 3: Known -6dB blob from test DRP (audio clip 2, Start=86424)
-- =========================================================================
local hex_minus_6db = "0000000200000020800a1d087c38004a0f085f1a0b0a091100000000000018c04a004a004a004a00"
local db_val = drp.decode_effect_filters_volume_db(hex_minus_6db)
assert(math.abs(db_val - (-6.0)) < 0.001,
    string.format("-6dB blob: expected -6.0, got %s", tostring(db_val)))
print("  ✓ Known blob → -6.0 dB")

-- =========================================================================
-- Test 4: Known -12dB blob from test DRP (audio clip 3, Start=86448)
-- =========================================================================
local hex_minus_12db = "0000000200000020800a1d087c38004a0f085f1a0b0a091100000000000028c04a004a004a004a00"
db_val = drp.decode_effect_filters_volume_db(hex_minus_12db)
assert(math.abs(db_val - (-12.0)) < 0.001,
    string.format("-12dB blob: expected -12.0, got %s", tostring(db_val)))
print("  ✓ Known blob → -12.0 dB")

-- =========================================================================
-- Test 5: dB → linear conversion (what drp_importer does at import time)
-- =========================================================================
local function db_to_linear(db) return math.pow(10, db / 20) end

-- 0 dB = 1.0 linear
assert(math.abs(db_to_linear(0.0) - 1.0) < 0.0001,
    "0 dB should be 1.0 linear")

-- -6 dB ≈ 0.501187
local linear_6 = db_to_linear(-6.0)
assert(math.abs(linear_6 - 0.501187) < 0.001,
    string.format("-6 dB should be ~0.501187, got %s", tostring(linear_6)))

-- -12 dB ≈ 0.251189
local linear_12 = db_to_linear(-12.0)
assert(math.abs(linear_12 - 0.251189) < 0.001,
    string.format("-12 dB should be ~0.251189, got %s", tostring(linear_12)))

-- -inf dB = 0.0 (silence)
assert(db_to_linear(-200) < 0.00001, "-200 dB should be effectively zero")

print("  ✓ dB → linear conversion: 0dB=1.0, -6dB≈0.501, -12dB≈0.251")

-- =========================================================================
-- Test 6: Full-blob FieldsBlob from audio clips (NOT EffectFiltersBA) still
-- works with the other decoders — volume decoder only reads EffectFiltersBA
-- =========================================================================
-- Audio clip FieldsBlob (clip 1 at Start=86400, 0dB) — no volume marker present
local audio_fields_blob = "00000002000000548128b52ffd2069550200d2c50f17b027ad01ac74134b531468b62dd9841c5036c59a379202814421288fd32c09d1c2d3688dc813b588c8d4b467d2bc763079cbf41e51c3d72fa0f8a150a50a02004c54229e3924"
local fb_db = drp.decode_effect_filters_volume_db(audio_fields_blob)
assert(fb_db == nil, "FieldsBlob (no marker) should return nil, got " .. tostring(fb_db))
print("  ✓ FieldsBlob without volume marker correctly returns nil")

-- =========================================================================
-- Test 7: No volume marker → nil
-- =========================================================================
local no_marker = string.rep("00", 40)  -- 80 hex chars of zeros, no marker
local nm_db = drp.decode_effect_filters_volume_db(no_marker)
assert(nm_db == nil, "blob without marker should return nil, got " .. tostring(nm_db))
print("  ✓ Blob without volume marker correctly returns nil")

-- =========================================================================
-- Test 7b: Multi-effect blob (92 bytes) with volume at -35dB
-- =========================================================================
local multi_fx_blob = "00000002000000598128b52ffd20557d020064040a53087c38004a0f085f1a0b0a091100000000008041c04a0f0861c064404a0f0862af039c4e0a3d61404a004a1808641a140a123a104049db866ab91397c052c0000000000002004098699b63"
local multi_db = drp.decode_effect_filters_volume_db(multi_fx_blob)
assert(multi_db, "multi-effect blob should decode volume, got nil")
assert(math.abs(multi_db - (-35.0)) < 0.001,
    string.format("multi-effect blob: expected -35.0, got %s", tostring(multi_db)))
print("  ✓ Multi-effect blob (92 bytes) → -35.0 dB")

-- =========================================================================
-- Test 8: Extreme dB values — verify dB→linear conversion at boundaries
-- =========================================================================
-- -96dB (near silence, common meter floor)
local linear_96 = db_to_linear(-96.0)
assert(linear_96 > 0 and linear_96 < 0.00002,
    string.format("-96 dB should be near-zero positive, got %s", tostring(linear_96)))

-- +12dB (Resolve max boost)
local linear_plus12 = db_to_linear(12.0)
assert(math.abs(linear_plus12 - 3.981) < 0.01,
    string.format("+12 dB should be ~3.981, got %s", tostring(linear_plus12)))

-- +24dB (assert boundary in importer)
local linear_plus24 = db_to_linear(24.0)
assert(math.abs(linear_plus24 - 15.849) < 0.01,
    string.format("+24 dB should be ~15.849, got %s", tostring(linear_plus24)))

print("  ✓ Extreme dB values: -96dB≈0, +12dB≈3.98, +24dB≈15.85")

print("✅ test_drp_volume_decode.lua passed")
