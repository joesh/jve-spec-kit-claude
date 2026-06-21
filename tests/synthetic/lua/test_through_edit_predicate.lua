-- Unit: FR-001 through-edit detection predicate (spec 025).
--
-- DOMAIN RULE: two adjacent clips on the same track form a *through-edit*
-- (an editorially-invisible cut) when ALL hold:
--   1. they reference the same master source track,
--   2. they are flush on the timeline (left ends exactly where right begins),
--   3. their source frames are contiguous (left.source_out == right.source_in;
--      source_out is exclusive, so equality means no source frames skipped),
--   4. if both carry audio subframe precision, the subframes are continuous.
--
-- Same master *sequence* but a different *track* (multicam angle, split
-- channel) is NOT a through-edit. A clip with no master source track
-- (gap / generator) is never a through-edit.
--
-- Expected truth values come from these NLE domain rules, not from tracing
-- the implementation. Pure predicate over clip property objects — no DB.

require("test_env")
local through_edit = require("core.through_edit")

print("=== test_through_edit_predicate.lua ===")

-- A flush, same-source, contiguous video pair. Non-trivial source marks
-- (120..240 then 240..360) and a non-zero timeline origin (1000) so the
-- arithmetic actually exercises coordinate math, not zeros.
local function video_pair()
    local a = {
        master_layer_track_id = "mv1", master_audio_track_id = nil,
        sequence_start = 1000, duration = 120,
        source_in = 120, source_out = 240,
        source_in_subframe = nil, source_out_subframe = nil,
    }
    local b = {
        master_layer_track_id = "mv1", master_audio_track_id = nil,
        sequence_start = 1120, duration = 120,
        source_in = 240, source_out = 360,
        source_in_subframe = nil, source_out_subframe = nil,
    }
    return a, b
end

-- (a) same master track + flush + contiguous → through-edit
do
    local a, b = video_pair()
    assert(through_edit.is_through_edit(a, b, "video") == true,
        "flush, same-source, contiguous video pair must be a through-edit")
    print("  PASS: contiguous same-source pair → true")
end

-- (b) same master *sequence* but DIFFERENT master track → not a through-edit
do
    local a, b = video_pair()
    b.master_layer_track_id = "mv2"  -- a different angle/track of the same source
    assert(through_edit.is_through_edit(a, b, "video") == false,
        "different master track (multicam/split) must NOT be a through-edit")
    print("  PASS: different master track → false")
end

-- (c) same master track but a SOURCE gap (frames skipped) → not a through-edit
do
    local a, b = video_pair()
    b.source_in = 245  -- 5-frame source discontinuity at the cut
    b.source_out = 365
    assert(through_edit.is_through_edit(a, b, "video") == false,
        "source-frame gap must NOT be a through-edit")
    print("  PASS: source gap → false")
end

-- (d) same master track but a TIMELINE gap (not flush) → not a through-edit
do
    local a, b = video_pair()
    b.sequence_start = 1130  -- 10-frame timeline gap after the left clip
    assert(through_edit.is_through_edit(a, b, "video") == false,
        "timeline gap (not flush) must NOT be a through-edit")
    print("  PASS: timeline gap → false")
end

-- (e) audio pair keyed on master_audio_track_id, with continuous subframes
do
    local a = {
        master_layer_track_id = nil, master_audio_track_id = "ma1",
        sequence_start = 500, duration = 240,
        source_in = 48000, source_out = 48240,
        source_in_subframe = 0, source_out_subframe = 17,
    }
    local b = {
        master_layer_track_id = nil, master_audio_track_id = "ma1",
        sequence_start = 740, duration = 240,
        source_in = 48240, source_out = 48480,
        source_in_subframe = 17, source_out_subframe = 0,
    }
    assert(through_edit.is_through_edit(a, b, "audio") == true,
        "audio pair, same master_audio_track_id, continuous subframes → true")

    -- subframe discontinuity breaks it
    b.source_in_subframe = 19
    assert(through_edit.is_through_edit(a, b, "audio") == false,
        "audio subframe mismatch must NOT be a through-edit")
    print("  PASS: audio subframe continuity respected")
end

-- (f) master-less clip (gap/generator) → never a through-edit
do
    local a, b = video_pair()
    a.master_layer_track_id = nil  -- a gap has no master source track
    assert(through_edit.is_through_edit(a, b, "video") == false,
        "master-less (gap/generator) clip must NOT be a through-edit")
    print("  PASS: master-less clip → false")
end

-- (g) unknown track kind is an invariant violation → assert
do
    local a, b = video_pair()
    local ok, err = pcall(through_edit.is_through_edit, a, b, "subtitle")
    assert(not ok, "unknown track kind must assert")
    assert(tostring(err):find("through_edit"), "assert names the module")
    print("  PASS: unknown kind asserts")
end

print("✅ test_through_edit_predicate.lua passed")
