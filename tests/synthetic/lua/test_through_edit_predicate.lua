-- Unit: FR-001 through-edit detection predicate (spec 025).
--
-- DOMAIN RULE: two adjacent clips on the same track form a *through-edit*
-- (an editorially-invisible cut) when ALL hold:
--   1. they come from the same source — the same master sequence the clip was
--      drawn from (clip.sequence_id, the "source tape"),
--   2. they are flush on the timeline (left ends exactly where right begins),
--   3. their source frames are contiguous (left.source_out == right.source_in;
--      source_out is exclusive, so equality means no source frames skipped),
--   4. if both carry audio subframe precision, the subframes are continuous.
--
-- Source IDENTITY is the master sequence, NOT the master layer track. The
-- master layer (master_layer_track_id / master_audio_track_id) is a per-clip
-- angle/stream selector; NULL is the ordinary "default layer" value, so two
-- ordinary clips (both NULL) from one master sequence ARE the same source.
-- Only a *different explicit* layer (multicam angle, split channel) breaks it.
-- A clip with no source sequence (gap / generator) is never a through-edit.
--
-- Expected truth values come from these NLE domain rules, not from tracing
-- the implementation. Pure predicate over clip property objects — no DB.

require("test_env")
local through_edit = require("core.through_edit")

print("=== test_through_edit_predicate.lua ===")

-- A flush, same-source, contiguous video pair as it actually appears after a
-- split: both halves share one master sequence ("seqM"), both on the default
-- layer (master_layer_track_id NULL — the real-world case for ordinary media),
-- non-trivial source marks (120..240 then 240..360) and a non-zero timeline
-- origin (1000) so the arithmetic exercises coordinate math, not zeros.
local function video_pair()
    local a = {
        sequence_id = "seqM",
        master_layer_track_id = nil, master_audio_track_id = nil,
        sequence_start = 1000, duration = 120,
        source_in = 120, source_out = 240,
        source_in_subframe = nil, source_out_subframe = nil,
    }
    local b = {
        sequence_id = "seqM",
        master_layer_track_id = nil, master_audio_track_id = nil,
        sequence_start = 1120, duration = 120,
        source_in = 240, source_out = 360,
        source_in_subframe = nil, source_out_subframe = nil,
    }
    return a, b
end

-- (a) same master sequence, DEFAULT layer (NULL master ids) + flush +
-- contiguous → through-edit. This is the ordinary post-split case and the one
-- that real projects always hit (no clip carries a non-NULL master layer).
do
    local a, b = video_pair()
    assert(through_edit.is_through_edit(a, b, "video") == true,
        "flush, same-master-sequence, default-layer, contiguous pair must be a through-edit")
    print("  PASS: NULL-layer same-source contiguous pair → true")
end

-- (b) same master sequence but DIFFERENT explicit master layer → not a
-- through-edit (multicam angle / split channel switch at the cut).
do
    local a, b = video_pair()
    a.master_layer_track_id = "angleA"
    b.master_layer_track_id = "angleB"
    assert(through_edit.is_through_edit(a, b, "video") == false,
        "different explicit master layer (multicam/split) must NOT be a through-edit")
    print("  PASS: different explicit layer → false")
end

-- (c) DIFFERENT master sequence (different source tape) → not a through-edit,
-- even if frames happen to line up.
do
    local a, b = video_pair()
    b.sequence_id = "seqOther"
    assert(through_edit.is_through_edit(a, b, "video") == false,
        "different master sequence must NOT be a through-edit")
    print("  PASS: different source sequence → false")
end

-- (d) same source but a SOURCE gap (frames skipped) → not a through-edit
do
    local a, b = video_pair()
    b.source_in = 245  -- 5-frame source discontinuity at the cut
    b.source_out = 365
    assert(through_edit.is_through_edit(a, b, "video") == false,
        "source-frame gap must NOT be a through-edit")
    print("  PASS: source gap → false")
end

-- (e) same source but a TIMELINE gap (not flush) → not a through-edit
do
    local a, b = video_pair()
    b.sequence_start = 1130  -- 10-frame timeline gap after the left clip
    assert(through_edit.is_through_edit(a, b, "video") == false,
        "timeline gap (not flush) must NOT be a through-edit")
    print("  PASS: timeline gap → false")
end

-- (f) audio pair: same master sequence, default audio layer (NULL), with
-- continuous subframes → through-edit; a subframe break → not.
do
    local a = {
        sequence_id = "seqA",
        master_layer_track_id = nil, master_audio_track_id = nil,
        sequence_start = 500, duration = 240,
        source_in = 48000, source_out = 48240,
        source_in_subframe = 0, source_out_subframe = 17,
    }
    local b = {
        sequence_id = "seqA",
        master_layer_track_id = nil, master_audio_track_id = nil,
        sequence_start = 740, duration = 240,
        source_in = 48240, source_out = 48480,
        source_in_subframe = 17, source_out_subframe = 0,
    }
    assert(through_edit.is_through_edit(a, b, "audio") == true,
        "audio pair, same master sequence, default layer, continuous subframes → true")

    -- subframe discontinuity breaks it
    b.source_in_subframe = 19
    assert(through_edit.is_through_edit(a, b, "audio") == false,
        "audio subframe mismatch must NOT be a through-edit")
    print("  PASS: audio subframe continuity respected")
end

-- (g) clip with no source sequence (gap/generator) → never a through-edit
do
    local a, b = video_pair()
    a.sequence_id = nil  -- a gap has no source sequence
    assert(through_edit.is_through_edit(a, b, "video") == false,
        "source-less (gap/generator) clip must NOT be a through-edit")
    print("  PASS: source-less clip → false")
end

-- (h) unknown track kind is an invariant violation → assert. (Reached only
-- once source identity matches, so use a genuine same-source pair.)
do
    local a, b = video_pair()
    local ok, err = pcall(through_edit.is_through_edit, a, b, "subtitle")
    assert(not ok, "unknown track kind must assert")
    assert(tostring(err):find("through_edit"), "assert names the module")
    print("  PASS: unknown kind asserts")
end

print("✅ test_through_edit_predicate.lua passed")
