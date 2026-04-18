require('test_env')

-- Region derivation: given a command's captured timeline mutations,
-- compute the change region (time range + track set) the viewport policy
-- should surface on undo/redo. Pure function — no UI, no DB. Domain:
-- "the region affected by this command" is the union of all clip extents
-- touched (inserts, updates, deletes), both pre-state and post-state.

local viewport_policy = require("ui.timeline.viewport_policy")

-- Helper: build a fake command with a given mutations payload.
-- Matches the contract of real Command objects (has :get_parameter).
local function make_command(mutations)
    return {
        type = "FakeCommand",
        get_parameter = function(self, key)
            if key == "__timeline_mutations" then return mutations end
            return nil
        end,
    }
end

local function set_equal(set_table, expected_list)
    local seen = {}
    for _, v in ipairs(expected_list) do seen[v] = false end
    local count = 0
    for track_id, _ in pairs(set_table) do
        if seen[track_id] == nil then
            return false, string.format("unexpected track %s", track_id)
        end
        seen[track_id] = true
        count = count + 1
    end
    if count ~= #expected_list then
        return false, string.format("got %d tracks, expected %d", count, #expected_list)
    end
    for _, v in ipairs(expected_list) do
        if not seen[v] then
            return false, string.format("missing track %s", v)
        end
    end
    return true
end

print("=== Region derivation from __timeline_mutations ===")

-- -----------------------------------------------------------------------
-- 1. Single insert on one track
-- -----------------------------------------------------------------------
do
    local cmd = make_command({
        sequence_id = "seq1",
        inserts = {
            { track_id = "v1", timeline_start_frame = 100, duration_frames = 300 },
        },
        updates = {},
        deletes = {},
    })
    local region = viewport_policy.derive_change_region(cmd)
    assert(region ~= nil, "insert must produce a region")
    assert(region.time_range.start_frame == 100,
        string.format("insert region starts at clip.timeline_start=100, got %s",
            tostring(region.time_range.start_frame)))
    assert(region.time_range.end_frame == 400,
        string.format("insert region ends at clip.timeline_start+duration=400, got %s",
            tostring(region.time_range.end_frame)))
    local ok, err = set_equal(region.track_set, {"v1"})
    assert(ok, "insert region tracks must be {v1}: " .. (err or ""))
    print("  1. single-insert region [100, 400] × {v1} ✓")
end

-- -----------------------------------------------------------------------
-- 2. Multiple inserts on different tracks: region spans union
-- -----------------------------------------------------------------------
do
    local cmd = make_command({
        sequence_id = "seq1",
        inserts = {
            { track_id = "v1", timeline_start_frame = 100, duration_frames = 200 }, -- 100-300
            { track_id = "a1", timeline_start_frame = 250, duration_frames = 500 }, -- 250-750
        },
        updates = {},
        deletes = {},
    })
    local region = viewport_policy.derive_change_region(cmd)
    assert(region.time_range.start_frame == 100, "spans earliest: 100")
    assert(region.time_range.end_frame == 750, "spans latest: 750")
    local ok = set_equal(region.track_set, {"v1", "a1"})
    assert(ok, "tracks must be {v1, a1}")
    print("  2. multi-track insert region [100, 750] × {v1, a1} ✓")
end

-- -----------------------------------------------------------------------
-- 3. Update where the clip moved to a different track:
--    region must include BOTH the pre-track and post-track.
-- -----------------------------------------------------------------------
do
    local cmd = make_command({
        sequence_id = "seq1",
        inserts = {},
        updates = {
            {
                track_id = "v2",
                timeline_start_frame = 500,
                duration_frames = 100,
                previous = { track_id = "v1", timeline_start = 100, duration = 100 },
            },
        },
        deletes = {},
    })
    local region = viewport_policy.derive_change_region(cmd)
    assert(region.time_range.start_frame == 100,
        "region covers pre-state frame 100")
    assert(region.time_range.end_frame == 600,
        "region covers post-state frame 600")
    local ok = set_equal(region.track_set, {"v1", "v2"})
    assert(ok, "tracks must be {v1, v2} (pre + post)")
    print("  3. track-move update region [100, 600] × {v1, v2} ✓")
end

-- -----------------------------------------------------------------------
-- 4. Delete: region uses `previous` row's coordinates.
-- -----------------------------------------------------------------------
do
    local cmd = make_command({
        sequence_id = "seq1",
        inserts = {},
        updates = {},
        deletes = {
            { previous = { track_id = "a2", timeline_start = 1000, duration = 250 } },
        },
    })
    local region = viewport_policy.derive_change_region(cmd)
    assert(region.time_range.start_frame == 1000)
    assert(region.time_range.end_frame == 1250)
    local ok = set_equal(region.track_set, {"a2"})
    assert(ok, "delete track from previous.track_id")
    print("  4. delete region [1000, 1250] × {a2} ✓")
end

-- -----------------------------------------------------------------------
-- 5. Multi-bucket mutations (keyed by sequence_id): region unions across
--    all buckets. Shape used by commands that touch multiple sequences.
-- -----------------------------------------------------------------------
do
    local cmd = make_command({
        seqA = {
            sequence_id = "seqA",
            inserts = {
                { track_id = "v1", timeline_start_frame = 50, duration_frames = 100 },
            },
            updates = {},
            deletes = {},
        },
        seqB = {
            sequence_id = "seqB",
            inserts = {
                { track_id = "v2", timeline_start_frame = 800, duration_frames = 100 },
            },
            updates = {},
            deletes = {},
        },
    })
    local region = viewport_policy.derive_change_region(cmd)
    assert(region.time_range.start_frame == 50)
    assert(region.time_range.end_frame == 900)
    local ok = set_equal(region.track_set, {"v1", "v2"})
    assert(ok, "union of tracks across buckets")
    print("  5. multi-bucket region unions ✓")
end

-- -----------------------------------------------------------------------
-- 6. Empty mutations: returns nil so caller falls back to surface_playhead.
-- -----------------------------------------------------------------------
do
    local cmd = make_command({
        sequence_id = "seq1",
        inserts = {},
        updates = {},
        deletes = {},
    })
    local region = viewport_policy.derive_change_region(cmd)
    assert(region == nil, "empty mutations must return nil (fall back to playhead)")
    print("  6. empty mutations → nil ✓")
end

-- -----------------------------------------------------------------------
-- 7. Command with no __timeline_mutations at all: returns nil.
-- -----------------------------------------------------------------------
do
    local cmd = {
        type = "SetPlayhead",
        get_parameter = function() return nil end,
    }
    local region = viewport_policy.derive_change_region(cmd)
    assert(region == nil, "missing mutations → nil")
    print("  7. missing mutations → nil ✓")
end

-- -----------------------------------------------------------------------
-- 8. Partial/malformed mutations: the mutation protocol legitimately
-- ships deletes as raw clip_id strings in some paths (timeline_state
-- delete-by-id; command_helper gather_deletes), and wrappers may forward
-- partial records. Region derivation is best-effort — it unions
-- whatever extents it can read and silently skips entries without them.
-- The result is a smaller-but-correct region, not a failure.
-- -----------------------------------------------------------------------
do
    -- Deletes as raw clip_id strings (timeline_state.apply_mutations shape)
    -- mixed with a full insert. Region = just the insert.
    local cmd = make_command({
        sequence_id = "seq1",
        inserts = {
            { track_id = "v1", timeline_start_frame = 100, duration_frames = 200 },
        },
        updates = {},
        deletes = { "clip_id_a", "clip_id_b" },
    })
    local region = viewport_policy.derive_change_region(cmd)
    assert(region, "region derived from the insert alone")
    assert(region.time_range.start_frame == 100 and region.time_range.end_frame == 300,
        "string-shaped deletes skipped; region covers only the insert")
    print("  8a. string-shaped deletes skipped, insert still surfaced ✓")
end

do
    -- Update without `previous`: the new-state half still contributes.
    local cmd = make_command({
        sequence_id = "seq1",
        inserts = {},
        updates = {
            { track_id = "v1", timeline_start_frame = 500, duration_frames = 100 },
        },
        deletes = {},
    })
    local region = viewport_policy.derive_change_region(cmd)
    assert(region and region.time_range.start_frame == 500
        and region.time_range.end_frame == 600,
        "update without previous contributes its new state only")
    print("  8b. update without `previous` → new state still contributes ✓")
end

do
    -- All-unreadable payload → derivation returns nil so the policy
    -- falls back to surface_playhead (same as empty mutations).
    local cmd = make_command({
        sequence_id = "seq1",
        inserts = {},
        updates = {},
        deletes = { "clip_a", "clip_b" },
    })
    local region = viewport_policy.derive_change_region(cmd)
    assert(region == nil,
        "all-unreadable mutations → nil (caller falls back to playhead)")
    print("  8c. all-unreadable payload → nil ✓")
end

-- -----------------------------------------------------------------------
-- 9. Rich-record delete mutations carry track/timeline/duration on the
-- mutation itself (not just clip_id strings), so region derivation
-- works both on forward execute (write delete) and on redo (re-write
-- delete). The mutation protocol accepts both shapes; callers with
-- the clip's full state (DeleteClip, AddClipsToSequence undo path)
-- pass records.
-- -----------------------------------------------------------------------
do
    local cmd = make_command({
        sequence_id = "seq1",
        inserts = {},
        updates = {},
        deletes = {
            { clip_id = "deleted_A", track_id = "v1", timeline_start = 4000, duration = 300 },
            { clip_id = "deleted_B", track_id = "a1", timeline_start = 4100, duration = 250 },
        },
    })
    local region = viewport_policy.derive_change_region(cmd)
    assert(region, "rich delete records must yield a region")
    assert(region.time_range.start_frame == 4000, "spans earliest delete.timeline_start")
    assert(region.time_range.end_frame == 4350, "spans latest delete.timeline_start+duration")
    local set_equal_ok = set_equal(region.track_set, {"v1", "a1"})
    assert(set_equal_ok, "rich deletes track both affected tracks")
    print("  9. rich delete records (clip_id + track + timeline + duration) → region ✓")
end

print("\n✅ test_viewport_policy_region_derivation.lua passed")
