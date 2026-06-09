-- Round-trip the DRT-side identity marker encoder through the production
-- DRP decoder. Domain truth: a JVE-authored identity marker carries the
-- exact clip.id Resolve will read back via TimelineItem:GetMarkerByCustomData
-- after the helper's import_timeline + idempotent _stamp_marker_safe pass.
--
-- Encoder verified by decode(encode(x)) == x against the same drp_binary
-- module Resolve's importer reads at parse_resolve_markers. The identity-
-- marker shape comes from the shared exporters.drt_identity_marker module
-- (single Lua source) and must match the Python helper's _IDENTITY_MARKER_*
-- — drift there breaks idempotent re-stamp.
--
-- Runs via `jve --test` because the encoder requires qt_zstd_compress and
-- the decoder requires qt_zstd_decompress.

require("test_env")  -- path setup (side-effect only)
local drt_binary      = require("exporters.drt_binary")
local drp_binary      = require("importers.drp_binary")
local identity_marker = require("exporters.drt_identity_marker")

local function assert_marker_eq(got, want, label)
    assert(got.frame == want.frame,
        string.format("%s: frame %s != %s", label, got.frame, want.frame))
    assert(got.color == want.color,
        string.format("%s: color %q != %q", label, got.color, want.color))
    assert(got.name == want.name,
        string.format("%s: name %q != %q", label, got.name, want.name))
    assert(got.note == want.note,
        string.format("%s: note %q != %q", label, got.note, want.note))
    assert(got.duration == want.duration,
        string.format("%s: duration %s != %s",
            label, got.duration, want.duration))
    assert(got.custom_data == want.custom_data,
        string.format("%s: custom_data %q != %q",
            label, got.custom_data, want.custom_data))
end

-- ─── Happy path: single identity marker ─────────────────────────────────────
do
    local clip_id = "11111111-2222-3333-4444-555555555555"
    local want = identity_marker.for_clip(clip_id)
    local hex = drt_binary.encode_clip_marker_fields_blob({ want })
    assert(type(hex) == "string" and #hex > 0,
        "encoder must return non-empty hex string")
    assert(hex:match("^[0-9a-f]+$"),
        "encoder must return lowercase hex (matches Resolve convention)")
    local got = drp_binary.decode_clip_markers(hex)
    assert(type(got) == "table" and #got == 1,
        "decoder must recover exactly one marker, got " ..
        (got and tostring(#got) or "nil"))
    assert_marker_eq(got[1], want, "identity_marker")
end

-- ─── ASCII clip-id customData (the only customData JVE ever emits) ──────────
do
    -- Resolve item DbId form (used both ways: Sm2Ti DbId on file side,
    -- live customData on API side).
    local clip_id = "abc12345-6789-abcd-ef01-234567890abc"
    local want = identity_marker.for_clip(clip_id)
    local hex = drt_binary.encode_clip_marker_fields_blob({ want })
    local got = drp_binary.decode_clip_markers(hex)
    assert_marker_eq(got[1], want, "uuid_form_clip_id")
end

-- ─── Multi-marker collection (defensive — single is the production case
-- but the schema supports many; encoder must walk all entries) ──────────────
do
    local markers = {
        identity_marker.for_clip("clip-A"),
        identity_marker.for_clip("clip-B-with-longer-id-1234567890"),
        identity_marker.for_clip("c"),
    }
    local hex = drt_binary.encode_clip_marker_fields_blob(markers)
    local got = drp_binary.decode_clip_markers(hex)
    assert(#got == 3, "expected 3 markers, got " .. tostring(#got))
    for i, want in ipairs(markers) do
        assert_marker_eq(got[i], want, "multi[" .. i .. "]")
    end
end

-- ─── Closed-set guard on color ──────────────────────────────────────────────
do
    local ok, err = pcall(drt_binary.encode_clip_marker_fields_blob, {
        { frame = 0, color = "Mauve", name = "x", note = "",
          duration = 1, custom_data = "id" },
    })
    assert(not ok, "expected color-rejection")
    assert(err:find("unknown color"),
        "expected 'unknown color' in error, got " .. tostring(err))
end

-- ─── Empty custom_data refused (identity marker IS the clip.id carrier) ────
do
    local ok, err = pcall(drt_binary.encode_clip_marker_fields_blob, {
        { frame = 0, color = "Purple", name = "x", note = "",
          duration = 1, custom_data = "" },
    })
    assert(not ok, "expected empty-custom_data rejection")
    assert(err:find("custom_data required"),
        "expected 'custom_data required' in error, got " .. tostring(err))
end

-- ─── Empty name refused (Resolve rejects empty-name markers — drp_binary.lua:802) ─
do
    local ok, err = pcall(drt_binary.encode_clip_marker_fields_blob, {
        { frame = 0, color = "Purple", name = "", note = "",
          duration = 1, custom_data = "id" },
    })
    assert(not ok, "expected empty-name rejection")
    assert(err:find("name required"),
        "expected 'name required' in error, got " .. tostring(err))
end

-- ─── Empty collection refused (caller bug — never author an empty blob) ────
do
    local ok, err = pcall(drt_binary.encode_clip_marker_fields_blob, {})
    assert(not ok, "expected empty-collection rejection")
    assert(err:find("non%-empty"),
        "expected 'non-empty' in error, got " .. tostring(err))
end

print("✅ test_drt_clip_marker_encode.lua passed (7 cases)")
