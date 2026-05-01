#!/usr/bin/env luajit

-- Regression: parse_resolve_tracks must surface a V↔A pair key on
-- clip_data.linked_item_sync that captures Resolve's per-shot
-- linkage. <LinkedItemSync> alone is a parent-take ID — it's
-- shared across multiple shot-named segments produced by source-
-- side blading, so the pair key combines the sync value with the
-- clip name.
--
-- Domain behaviour the rest of the importer relies on:
--   1. A V clip and an A clip with the same parent-take ID and
--      shot name surface the same opaque key (so importer_core
--      pools them in one clip_links group; Opt+Click on the
--      timeline expands V↔A within the shot).
--   2. A clip with no <LinkedItemSync> (or `<LinkedItemSync/>`)
--      surfaces nil — a parallel-track grade copy or an isolated
--      audio chunk forms no link group.
--   3. Two adjacent shots from one continuous take share the
--      parent-take ID but produce DISTINCT pair keys (Resolve
--      renders each as its own chain icon).
--   4. Malformed input (non-numeric sync, name containing the
--      key separator) crashes loudly (Rule 1.14).

require("test_env")

local drp = require("importers.drp_importer")

print("=== test_drp_linked_item_sync.lua ===")

-- ─────────────────────────────────────────────────────────────────────
-- Element-tree helpers matching qt_xml_parse's output shape
-- ─────────────────────────────────────────────────────────────────────
local function elem(tag, attrs, children_or_text)
    local e = { tag = tag, attrs = attrs or {}, children = {}, text = "" }
    if type(children_or_text) == "string" then
        e.text = children_or_text
    elseif type(children_or_text) == "table" then
        e.children = children_or_text
    end
    return e
end
local function text(tag, t) return elem(tag, {}, t) end

-- 25 fps as little-endian IEEE-754 double (DRP <MediaFrameRate> format).
-- 25.0 = 0x4039000000000000 (BE) → "0000000000003940" (LE).
local FPS_25_LE_HEX = "0000000000003940"

-- ASCII Unit Separator — the parser uses this internally between the
-- sync value and the clip name. Tests reference it only to construct
-- the hostile-input fail-fast case at the bottom.
local UNIT_SEP = "\x1F"

local function video_clip(clip_name, start_frame, sync_child)
    local children = {
        text("Name", clip_name),
        text("Start", tostring(start_frame)),
        text("Duration", "100"),
        text("In", "0"),
        text("MediaFilePath", "/tmp/" .. clip_name .. ".mov"),
        text("MediaFrameRate", FPS_25_LE_HEX),
        text("MediaStartTime", "0"),
        text("WasDisbanded", "false"),
        text("Flags", "0"),
    }
    if sync_child then table.insert(children, sync_child) end
    return elem("Sm2TiVideoClip", {}, children)
end

local function audio_clip(clip_name, start_frame, media_ref, sync_child)
    local children = {
        text("Name", clip_name),
        text("Start", tostring(start_frame)),
        text("Duration", "100"),
        text("In", "0"),
        text("MediaFilePath", "/tmp/" .. clip_name .. ".wav"),
        text("MediaRef", media_ref),
        text("MediaStartTime", "0"),
        text("WasDisbanded", "false"),
        text("Flags", "0"),
    }
    if sync_child then table.insert(children, sync_child) end
    return elem("Sm2TiAudioClip", {}, children)
end

local function track(track_type_value, clips)
    -- track_type_value: 0 = VIDEO, 1 = AUDIO (matches DRP <Type>).
    local items_children = {}
    for _, c in ipairs(clips) do
        table.insert(items_children, elem("Element", {}, { c }))
    end
    return elem("Sm2TiTrack", {}, {
        text("Type", tostring(track_type_value)),
        elem("Items", {}, items_children),
    })
end

-- =========================================================================
-- Single-shot V↔A pair + an unlinked V duplicate + an unlinked A chunk
-- =========================================================================
-- Synthetic Sm2SequenceContainer:
--   V row 1: name="ANCHOR" Start=100 LinkedItemSync=42         (linked V)
--   V row 2: name="ANCHOR" Start=100 (no <LinkedItemSync>)     (unlinked dup)
--   A row 1: name="ANCHOR" Start=98  LinkedItemSync=42         (linked A — pairs V row 1)
--   A row 2: name="ANCHOR" Start=98  <LinkedItemSync/>         (isolated A)

local single_shot_seq = elem("Sm2SequenceContainer", {}, {
    track(0, {
        video_clip("ANCHOR", 100, text("LinkedItemSync", "42")),
        video_clip("ANCHOR", 100, nil),
    }),
    track(1, {
        audio_clip("ANCHOR", 98, "audio-ref-1", text("LinkedItemSync", "42")),
        audio_clip("ANCHOR", 98, "audio-ref-1", elem("LinkedItemSync", {}, "")),
    }),
})

local v_tracks, a_tracks = drp.parse_resolve_tracks(
    single_shot_seq, 25,
    { ["audio-ref-1"] = "/tmp/ANCHOR.wav" },
    { ["audio-ref-1"] = "ANCHOR.wav" },
    { ["audio-ref-1"] = 48000 })

assert(#v_tracks == 1 and #a_tracks == 1,
    "expected 1 video track and 1 audio track")
assert(#v_tracks[1].clips == 2 and #a_tracks[1].clips == 2,
    "expected 2 clips per track")

local linked_v   = v_tracks[1].clips[1]
local unlinked_v = v_tracks[1].clips[2]
local linked_a   = a_tracks[1].clips[1]
local isolated_a = a_tracks[1].clips[2]

-- The test asserts only equality / presence semantics that downstream
-- link-group construction relies on. It does not look at the encoded
-- form of the key (Rule 2.34: test domain behaviour, not implementation).

assert(unlinked_v.linked_item_sync == nil,
    "V duplicate without <LinkedItemSync> must surface nil")
assert(isolated_a.linked_item_sync == nil,
    "A clip with empty <LinkedItemSync/> must surface nil")
print("  ✓ Clips without LinkedItemSync surface nil")

assert(linked_v.linked_item_sync ~= nil and linked_a.linked_item_sync ~= nil,
    "linked V and A must surface non-nil keys")
assert(linked_v.linked_item_sync == linked_a.linked_item_sync, string.format(
    "linked V and A must share a pair key (got V=%s, A=%s)",
    tostring(linked_v.linked_item_sync), tostring(linked_a.linked_item_sync)))
print("  ✓ Linked V/A pair shares a key")

assert(unlinked_v.linked_item_sync ~= linked_v.linked_item_sync,
    "unlinked V duplicate must not share the linked V's key")
print("  ✓ Unlinked V duplicate has a distinct (nil) key")

-- =========================================================================
-- Multi-shot take: shared parent-take ID, distinct shot names
-- =========================================================================
-- Two adjacent shots bladed from one continuous capture. Both shots'
-- V and A halves carry the same <LinkedItemSync>, but Resolve treats
-- them as two independent V↔A pairs (chain icon per shot) — so the
-- pair keys must differ across shot names.

local multi_shot_seq = elem("Sm2SequenceContainer", {}, {
    track(0, {
        video_clip("SHOT_A", 200, text("LinkedItemSync", "99")),
        video_clip("SHOT_B", 300, text("LinkedItemSync", "99")),
    }),
    track(1, {
        audio_clip("SHOT_A", 200, "ref-shot-a", text("LinkedItemSync", "99")),
        audio_clip("SHOT_B", 300, "ref-shot-b", text("LinkedItemSync", "99")),
    }),
})

local mv_tracks, ma_tracks = drp.parse_resolve_tracks(
    multi_shot_seq, 25,
    { ["ref-shot-a"] = "/tmp/SHOT_A.wav", ["ref-shot-b"] = "/tmp/SHOT_B.wav" },
    { ["ref-shot-a"] = "SHOT_A.wav",      ["ref-shot-b"] = "SHOT_B.wav" },
    { ["ref-shot-a"] = 48000,             ["ref-shot-b"] = 48000 })

local shot_a_video = mv_tracks[1].clips[1]
local shot_b_video = mv_tracks[1].clips[2]
local shot_a_audio = ma_tracks[1].clips[1]
local shot_b_audio = ma_tracks[1].clips[2]

assert(shot_a_video.linked_item_sync == shot_a_audio.linked_item_sync,
    "SHOT_A video and audio must share a pair key")
assert(shot_b_video.linked_item_sync == shot_b_audio.linked_item_sync,
    "SHOT_B video and audio must share a pair key")
assert(shot_a_video.linked_item_sync ~= shot_b_video.linked_item_sync,
    "shots from one parent take must produce distinct pair keys per shot name")
print("  ✓ Multi-shot take: shared parent ID + different shot name → independent pairs")

-- =========================================================================
-- Fail-fast on malformed inputs (Rule 1.14, Rule 2.32)
-- =========================================================================

-- Non-numeric LinkedItemSync content must crash with an actionable
-- error that names the offending clip and the bad value.
local non_numeric_seq = elem("Sm2SequenceContainer", {}, {
    track(0, {
        video_clip("ANCHOR", 100, text("LinkedItemSync", "not-a-number")),
    }),
})
local ok, err = pcall(drp.parse_resolve_tracks, non_numeric_seq, 25, {}, {}, {})
assert(not ok, "non-numeric LinkedItemSync must error")
assert(tostring(err):find("LinkedItemSync"), string.format(
    "error message must mention LinkedItemSync (got: %s)", tostring(err)))
assert(tostring(err):find("ANCHOR"), string.format(
    "error message must name the offending clip (got: %s)", tostring(err)))
print("  ✓ Non-numeric <LinkedItemSync> fails fast with actionable message")

-- Clip name containing the pair-key separator must crash — pair-key
-- composition would otherwise be ambiguous.
local hostile_seq = elem("Sm2SequenceContainer", {}, {
    track(0, {
        video_clip("EVIL" .. UNIT_SEP .. "NAME", 100,
            text("LinkedItemSync", "99")),
    }),
})
ok, err = pcall(drp.parse_resolve_tracks, hostile_seq, 25, {}, {}, {})
assert(not ok, "clip name containing pair-key separator must error")
assert(tostring(err):find("separator") or tostring(err):find("ambiguous"),
    "error must explain the collision (got: " .. tostring(err) .. ")")
print("  ✓ Clip name containing pair-key separator fails fast")

print("✅ test_drp_linked_item_sync.lua passed")
