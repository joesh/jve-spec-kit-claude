#!/usr/bin/env luajit

-- Regression: DRP parse_resolve_tracks must extract <LinkedItemSync> per
-- clip and surface it on clip_data.linked_item_sync. This is the V↔A
-- link-group ID Resolve writes for clips that share a sync chain
-- (chain icon in the Resolve UI). Two clips — one video, one audio —
-- with the same LinkedItemSync value are linked. Clips without a
-- LinkedItemSync value (or with <LinkedItemSync/>) are unlinked.
--
-- Domain behaviour:
--   - Importing a DRP that pairs a V clip and an A clip via
--     <LinkedItemSync>N</LinkedItemSync> produces ONE link group
--     containing both. Selecting one with Opt+Click extends to the
--     other.
--   - A duplicate video copy on a parallel track that has NO
--     LinkedItemSync element (the unsynced V duplicate) does NOT
--     join either of those groups. Opt+clicking it selects only
--     itself.
--
-- Bug history (2026-05-01):
--   importer_core's STEP 6 keyed link groups on (file_uuid,
--   timeline_start). Two V copies of the same shot on parallel
--   tracks pooled together (same media + same start), and the
--   genuine V↔A pair never pooled (different media files, slightly
--   different timeline starts). Opt+click on the timeline expanded
--   to the parallel V duplicate instead of the synced A. Fix: drive
--   linking off the source format's explicit link ID — DRP writes
--   it as <LinkedItemSync>.

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

-- 25 fps as little-endian IEEE-754 double (DRP format).
-- 25.0 = 0x4039000000000000 (BE) → "0000000000003940" (LE).
local FPS_25_LE_HEX = "0000000000003940"

-- ─────────────────────────────────────────────────────────────────────
-- Build a synthetic Sm2SequenceContainer with:
--   V1: clip name="ANCHOR" Start=100 LinkedItemSync=42  (linked V)
--   V2: clip name="ANCHOR" Start=100 LinkedItemSync absent (parallel duplicate, unlinked)
--   A1: clip name="ANCHOR" Start=98  LinkedItemSync=42  (linked A — pairs with V1)
--   A2: clip name="ANCHOR" Start=98  LinkedItemSync=<empty/> (isolated A, unlinked)
-- ─────────────────────────────────────────────────────────────────────

local function video_clip(start_frame, sync_child)
    local children = {
        text("Name", "ANCHOR"),
        text("Start", tostring(start_frame)),
        text("Duration", "100"),
        text("In", "0"),
        text("MediaFilePath", "/tmp/anchor.mov"),
        text("MediaFrameRate", FPS_25_LE_HEX),
        text("MediaStartTime", "0"),
        text("WasDisbanded", "false"),
        text("Flags", "0"),
    }
    if sync_child then table.insert(children, sync_child) end
    return elem("Sm2TiVideoClip", {}, children)
end

local function audio_clip(start_frame, media_ref, sync_child)
    local children = {
        text("Name", "ANCHOR"),
        text("Start", tostring(start_frame)),
        text("Duration", "100"),
        text("In", "0"),
        text("MediaFilePath", "/tmp/anchor.wav"),
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

local v_track = track(0, {
    video_clip(100, text("LinkedItemSync", "42")),                  -- V1: linked
    video_clip(100, nil),                                           -- V2: no LinkedItemSync element at all
})
local a_track = track(1, {
    audio_clip(98, "audio-ref-1", text("LinkedItemSync", "42")),    -- A1: linked (pairs with V1)
    audio_clip(98, "audio-ref-1", elem("LinkedItemSync", {}, "")),  -- A2: empty <LinkedItemSync/>
})

local seq_elem = elem("Sm2SequenceContainer", {}, { v_track, a_track })

-- Sample rate map keyed by MediaRef: required for AUDIO clips.
local media_ref_sample_rate_map = { ["audio-ref-1"] = 48000 }
local media_ref_path_map        = { ["audio-ref-1"] = "/tmp/anchor.wav" }
local media_ref_name_map        = { ["audio-ref-1"] = "anchor.wav" }

local v_tracks, a_tracks = drp.parse_resolve_tracks(
    seq_elem, 25,
    media_ref_path_map, media_ref_name_map, media_ref_sample_rate_map)

assert(#v_tracks == 1, string.format("expected 1 video track, got %d", #v_tracks))
assert(#a_tracks == 1, string.format("expected 1 audio track, got %d", #a_tracks))
assert(#v_tracks[1].clips == 2, string.format(
    "expected 2 video clips, got %d", #v_tracks[1].clips))
assert(#a_tracks[1].clips == 2, string.format(
    "expected 2 audio clips, got %d", #a_tracks[1].clips))

local v1 = v_tracks[1].clips[1]   -- V with sync, name=ANCHOR  (linked V)
local v2 = v_tracks[1].clips[2]   -- V without LinkedItemSync   (unlinked dup)
local a1 = a_tracks[1].clips[1]   -- A with sync, name=ANCHOR  (linked A — pairs with V1)
local a2 = a_tracks[1].clips[2]   -- A with empty <LinkedItemSync/>

-- Domain-level assertions about pair-key behaviour — the test does
-- not look at how the parser encodes the key, only at equality and
-- presence semantics that downstream link-group construction relies
-- on (Rule 2.34: test domain behaviour, not implementation).

-- An unlinked clip surfaces nil, not a sentinel. Importer_core must
-- be able to skip it cheaply (presence check, not value compare).
assert(v2.linked_item_sync == nil,
    "V duplicate without <LinkedItemSync> must surface nil")
assert(a2.linked_item_sync == nil,
    "A clip with empty <LinkedItemSync/> must surface nil")
print("  ✓ Clips without LinkedItemSync surface nil")

-- A V/A pair that share parent-take ID and shot name surface the
-- same opaque key — that's what makes importer_core put them in one
-- link group.
assert(v1.linked_item_sync ~= nil and a1.linked_item_sync ~= nil,
    "linked V and A must surface non-nil keys")
assert(v1.linked_item_sync == a1.linked_item_sync, string.format(
    "linked V and A must share a pair key (got V=%s, A=%s)",
    tostring(v1.linked_item_sync), tostring(a1.linked_item_sync)))
print("  ✓ Linked V/A pair shares a key")

-- The unlinked V duplicate must not collide with the linked clips'
-- key — otherwise opt+click would expand to it.
assert(v2.linked_item_sync ~= v1.linked_item_sync,
    "unlinked V duplicate must not share the linked V's key")
print("  ✓ Unlinked V duplicate has a distinct (nil) key")

-- =========================================================================
-- Test 7: Multi-shot take — same LinkedItemSync, different names.
-- Two adjacent shots from one continuous take share the parent-take
-- ID but Resolve treats them as TWO independent V↔A pairs.
-- =========================================================================
local function v_clip_named(name, start_frame, sync_val)
    local children = {
        text("Name", name),
        text("Start", tostring(start_frame)),
        text("Duration", "100"),
        text("In", "0"),
        text("MediaFilePath", "/tmp/" .. name .. ".mov"),
        text("MediaFrameRate", FPS_25_LE_HEX),
        text("MediaStartTime", "0"),
        text("WasDisbanded", "false"),
        text("Flags", "0"),
        text("LinkedItemSync", tostring(sync_val)),
    }
    return elem("Sm2TiVideoClip", {}, children)
end
local function a_clip_named(name, start_frame, ref, sync_val)
    local children = {
        text("Name", name),
        text("Start", tostring(start_frame)),
        text("Duration", "100"),
        text("In", "0"),
        text("MediaFilePath", "/tmp/" .. name .. ".wav"),
        text("MediaRef", ref),
        text("MediaStartTime", "0"),
        text("WasDisbanded", "false"),
        text("Flags", "0"),
        text("LinkedItemSync", tostring(sync_val)),
    }
    return elem("Sm2TiAudioClip", {}, children)
end

local multi_v = track(0, {
    v_clip_named("SHOT_A", 200, 99),
    v_clip_named("SHOT_B", 300, 99),
})
local multi_a = track(1, {
    a_clip_named("SHOT_A", 200, "ref-shot-a", 99),
    a_clip_named("SHOT_B", 300, "ref-shot-b", 99),
})
local multi_seq = elem("Sm2SequenceContainer", {}, { multi_v, multi_a })

local m_v_tracks, m_a_tracks = drp.parse_resolve_tracks(
    multi_seq, 25,
    { ["ref-shot-a"] = "/tmp/SHOT_A.wav", ["ref-shot-b"] = "/tmp/SHOT_B.wav" },
    { ["ref-shot-a"] = "SHOT_A.wav",      ["ref-shot-b"] = "SHOT_B.wav" },
    { ["ref-shot-a"] = 48000,             ["ref-shot-b"] = 48000 })

local m_v_a, m_v_b = m_v_tracks[1].clips[1], m_v_tracks[1].clips[2]
local m_a_a, m_a_b = m_a_tracks[1].clips[1], m_a_tracks[1].clips[2]

-- Domain guarantee: SHOT_A and SHOT_B must not collapse into one
-- group despite sharing parent-take ID. Resolve renders this as two
-- independent V↔A pairs (chain icon per shot), and opt+click must
-- only expand within a shot.
assert(m_v_a.linked_item_sync == m_a_a.linked_item_sync,
    "V SHOT_A and A SHOT_A must share a pair key")
assert(m_v_b.linked_item_sync == m_a_b.linked_item_sync,
    "V SHOT_B and A SHOT_B must share a pair key")
assert(m_v_a.linked_item_sync ~= m_v_b.linked_item_sync,
    "shots from one parent take must produce distinct pair keys per shot name")
print("  ✓ Multi-shot take: shared parent ID + different shot name → independent pairs")

-- =========================================================================
-- Test 8: Fail-fast on malformed inputs (Rule 1.14, Rule 2.32 —
-- assert-based failure paths must be exercised via pcall).
-- =========================================================================

-- Non-numeric LinkedItemSync content must crash with an actionable
-- error that names the offending clip and the bad value.
local bad_sync_seq = elem("Sm2SequenceContainer", {}, {
    track(0, {
        video_clip(100, text("LinkedItemSync", "not-a-number")),
    }),
})
local ok, err = pcall(drp.parse_resolve_tracks, bad_sync_seq, 25, {}, {}, {})
assert(not ok, "non-numeric LinkedItemSync must error")
assert(tostring(err):find("LinkedItemSync"), string.format(
    "error message must mention LinkedItemSync (got: %s)", tostring(err)))
assert(tostring(err):find("ANCHOR"), string.format(
    "error message must name the offending clip (got: %s)", tostring(err)))
print("  ✓ Non-numeric <LinkedItemSync> fails fast with actionable message")

-- Clip name containing the pair-key separator must crash — pair-key
-- composition would otherwise be ambiguous.
local UNIT_SEP = "\x1F"
local hostile_v = elem("Sm2TiVideoClip", {}, {
    text("Name", "EVIL" .. UNIT_SEP .. "NAME"),
    text("Start", "100"),
    text("Duration", "100"),
    text("In", "0"),
    text("MediaFilePath", "/tmp/evil.mov"),
    text("MediaFrameRate", FPS_25_LE_HEX),
    text("MediaStartTime", "0"),
    text("WasDisbanded", "false"),
    text("Flags", "0"),
    text("LinkedItemSync", "99"),
})
local hostile_seq = elem("Sm2SequenceContainer", {}, {
    track(0, { hostile_v }),
})
ok, err = pcall(drp.parse_resolve_tracks, hostile_seq, 25, {}, {}, {})
assert(not ok, "clip name containing pair-key separator must error")
assert(tostring(err):find("separator") or tostring(err):find("ambiguous"),
    "error must explain the collision (got: " .. tostring(err) .. ")")
print("  ✓ Clip name containing pair-key separator fails fast")

print("✅ test_drp_linked_item_sync.lua passed")
