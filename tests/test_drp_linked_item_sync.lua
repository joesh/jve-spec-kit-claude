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

-- =========================================================================
-- Test 1: V clip with explicit <LinkedItemSync>42</LinkedItemSync>
-- =========================================================================
local v1 = v_tracks[1].clips[1]
assert(v1.linked_item_sync == 42, string.format(
    "V1 linked_item_sync: expected 42, got %s", tostring(v1.linked_item_sync)))
print("  ✓ V clip with <LinkedItemSync>42</LinkedItemSync> → linked_item_sync = 42")

-- =========================================================================
-- Test 2: V duplicate with NO <LinkedItemSync> element at all
-- =========================================================================
local v2 = v_tracks[1].clips[2]
assert(v2.linked_item_sync == nil, string.format(
    "V2 linked_item_sync: expected nil, got %s", tostring(v2.linked_item_sync)))
print("  ✓ V clip without <LinkedItemSync> element → linked_item_sync = nil")

-- =========================================================================
-- Test 3: A clip with explicit <LinkedItemSync>42</LinkedItemSync>
-- =========================================================================
local a1 = a_tracks[1].clips[1]
assert(a1.linked_item_sync == 42, string.format(
    "A1 linked_item_sync: expected 42, got %s", tostring(a1.linked_item_sync)))
print("  ✓ A clip with <LinkedItemSync>42</LinkedItemSync> → linked_item_sync = 42")

-- =========================================================================
-- Test 4: A clip with empty <LinkedItemSync/>
-- =========================================================================
local a2 = a_tracks[1].clips[2]
assert(a2.linked_item_sync == nil, string.format(
    "A2 linked_item_sync: expected nil, got %s", tostring(a2.linked_item_sync)))
print("  ✓ A clip with empty <LinkedItemSync/> → linked_item_sync = nil")

-- =========================================================================
-- Test 5: V1 (linked) and A1 (linked) share the same link ID
-- =========================================================================
assert(v1.linked_item_sync == a1.linked_item_sync, string.format(
    "V1 (%s) and A1 (%s) should share linked_item_sync",
    tostring(v1.linked_item_sync), tostring(a1.linked_item_sync)))
print("  ✓ V1 and A1 share the same linked_item_sync value (=> linked pair)")

-- =========================================================================
-- Test 6: V2 (parallel duplicate) does NOT match V1/A1's link ID
-- =========================================================================
assert(v2.linked_item_sync ~= v1.linked_item_sync,
    "V2 (parallel duplicate) must not share V1's link ID")
assert(v2.linked_item_sync ~= a1.linked_item_sync,
    "V2 (parallel duplicate) must not share A1's link ID")
print("  ✓ V2 (unlinked duplicate) does not match V1/A1 link ID")

print("✅ test_drp_linked_item_sync.lua passed")
