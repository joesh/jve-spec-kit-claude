-- Regression: DRP parse_resolve_tracks attaches linked_item_sync from
-- <LinkedItemSync> so importer_core STEP 6 can group V+A clips into link
-- groups without relying on a (file_uuid, timeline_start) heuristic.
--
-- Domain behavior:
--   - Every Sm2TiVideoClip and Sm2TiAudioClip carries a <LinkedItemSync>
--     element. When the element is empty (whitespace-only) the clip is
--     unlinked and linked_item_sync must be nil. When it contains an
--     integer value (e.g. "-1944") that is the link-group key shared by
--     all clips in the linked pair.
--   - All clips in the same V+A pair carry the same non-nil integer text
--     as their linked_item_sync value.
--   - An unlinked clip (empty <LinkedItemSync/>) yields linked_item_sync=nil.

require("test_env")

local drp = require("importers.drp_importer")

print("=== test_drp_linked_item_sync.lua ===")

-- ─────────────────────────────────────────────────────────────────────
-- Minimal element-tree helpers matching qt_xml_parse's output shape.
-- text always defaults to "" to match how the real parser populates nodes.
-- ─────────────────────────────────────────────────────────────────────
local function elem(tag, text_or_children, extra_children)
    local e = { tag = tag, attrs = {}, children = {}, text = "" }
    if type(text_or_children) == "string" then
        e.text = text_or_children
        e.children = extra_children or {}
    elseif type(text_or_children) == "table" then
        e.children = text_or_children
    end
    return e
end

-- DRP track body: Track > Items > Element > Clip
local function wrap_clips(clips)
    local items = {}
    for _, c in ipairs(clips) do
        table.insert(items, elem("Element", { c }))
    end
    return elem("Items", items)
end

local MEDIA_FRAME_RATE_25 = "00000000000039400000000000000000"  -- 25fps LE IEEE754
local AUDIO_UUID = "aabbccdd-1234-5678-abcd-ef0123456789"

local function make_video_clip(name, start, dur, lis_text)
    return elem("Sm2TiVideoClip", {
        elem("Name",           name),
        elem("Start",          tostring(start)),
        elem("Duration",       tostring(dur)),
        elem("In",             ""),
        elem("MediaFilePath",  "/test/" .. name .. ".mov"),
        elem("MediaFrameRate", MEDIA_FRAME_RATE_25),
        elem("LinkedItemSync", lis_text),
    })
end

-- Audio clips require MediaRef + sample-rate map to pass the native_rate check.
local function make_audio_clip(name, start, dur, lis_text)
    return elem("Sm2TiAudioClip", {
        elem("Name",           name),
        elem("Start",          tostring(start)),
        elem("Duration",       tostring(dur)),
        elem("In",             ""),
        elem("MediaRef",       AUDIO_UUID),
        elem("MediaFilePath",  "/test/" .. name .. ".wav"),
        elem("MediaFrameRate", MEDIA_FRAME_RATE_25),
        elem("LinkedItemSync", lis_text),
    })
end

-- ─────────────────────────────────────────────────────────────────────
-- Synthetic sequence:
--   V track: linked clip at frame 100 (LinkedItemSync="-1944")
--            + unlinked clip at frame 200 (LinkedItemSync="")
--   A track: linked clip at frame 100 (LinkedItemSync="-1944")
-- ─────────────────────────────────────────────────────────────────────
local seq_elem = elem("Sequence", {
    elem("Sm2TiTrack", {
        elem("Type", "0"),  -- 0 = VIDEO
        wrap_clips({
            make_video_clip("linked_vid",   100, 25, "-1944"),
            make_video_clip("unlinked_vid", 200, 25, ""),
        }),
    }),
    elem("Sm2TiTrack", {
        elem("Type", "1"),  -- 1 = AUDIO
        wrap_clips({
            make_audio_clip("linked_aud", 100, 25, "-1944"),
        }),
    }),
})

-- Provide path + sample-rate maps so audio clips aren't skipped as "nested sequences".
local media_ref_path_map     = { [AUDIO_UUID] = "/test/linked_aud.wav" }
local media_ref_sample_rate_map = { [AUDIO_UUID] = 48000 }

local video_tracks, audio_tracks = drp.parse_resolve_tracks(
    seq_elem, 25.0, media_ref_path_map, nil, media_ref_sample_rate_map)

assert(#video_tracks == 1,
    "expected 1 video track, got " .. tostring(#video_tracks))
assert(#audio_tracks == 1,
    "expected 1 audio track, got " .. tostring(#audio_tracks))
assert(#video_tracks[1].clips == 2,
    "expected 2 video clips, got " .. tostring(#video_tracks[1].clips))
assert(#audio_tracks[1].clips == 1,
    "expected 1 audio clip, got " .. tostring(#audio_tracks[1].clips))

local vid_linked   = video_tracks[1].clips[1]  -- start=100, lis="-1944"
local vid_unlinked = video_tracks[1].clips[2]  -- start=200, lis=""
local aud_linked   = audio_tracks[1].clips[1]  -- start=100, lis="-1944"

-- Linked clips must carry the shared key.
assert(vid_linked.linked_item_sync == "-1944",
    "linked video clip must have linked_item_sync='-1944', got: "
    .. tostring(vid_linked.linked_item_sync))

assert(aud_linked.linked_item_sync == "-1944",
    "linked audio clip must have linked_item_sync='-1944', got: "
    .. tostring(aud_linked.linked_item_sync))

assert(vid_linked.linked_item_sync == aud_linked.linked_item_sync,
    "linked V and A clips must share the same linked_item_sync value")

-- Unlinked clip must have nil.
assert(vid_unlinked.linked_item_sync == nil,
    "unlinked video clip must have linked_item_sync=nil, got: "
    .. tostring(vid_unlinked.linked_item_sync))

print(string.format("  ✓ linked video  clip: linked_item_sync=%q", vid_linked.linked_item_sync))
print(string.format("  ✓ linked audio  clip: linked_item_sync=%q", aud_linked.linked_item_sync))
print("  ✓ unlinked video clip: linked_item_sync=nil")

print("\n✅ test_drp_linked_item_sync.lua passed")
