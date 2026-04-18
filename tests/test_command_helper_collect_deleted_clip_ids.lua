require('test_env')

-- collect_deleted_clip_ids walks a command's __timeline_mutations and
-- returns the set of clip_ids the command marks for deletion. Must
-- recognize both mutation-bucket shapes (single-bucket with top-level
-- inserts/updates/deletes, multi-bucket keyed by sequence_id) and both
-- delete-entry shapes (rich-record {clip_id, track_id, ...} and legacy
-- clip_id string). This is the read-side dual of add_delete_mutation
-- and must stay in sync with the shapes that writer produces.

local command_helper = require("core.command_helper")

local function make_command(mutations)
    return {
        type = "FakeCommand",
        get_parameter = function(self, key)
            if key == "__timeline_mutations" then return mutations end
            return nil
        end,
    }
end

local function count(set)
    local n = 0
    for _ in pairs(set) do n = n + 1 end
    return n
end

print("=== command_helper.collect_deleted_clip_ids ===")

-- -----------------------------------------------------------------------
-- 1. No mutations → empty set (not nil; callers should be able to
-- iterate without a guard).
-- -----------------------------------------------------------------------
do
    local set = command_helper.collect_deleted_clip_ids(make_command(nil))
    assert(type(set) == "table" and count(set) == 0,
        "nil mutations → empty set")
    print("  1. no mutations → empty set ✓")
end

-- -----------------------------------------------------------------------
-- 2. Single-bucket with legacy string deletes.
-- -----------------------------------------------------------------------
do
    local set = command_helper.collect_deleted_clip_ids(make_command({
        sequence_id = "seq1",
        inserts = {},
        updates = {},
        deletes = { "clip_a", "clip_b" },
    }))
    assert(set["clip_a"] and set["clip_b"] and count(set) == 2,
        "both legacy string deletes collected")
    print("  2. single-bucket, legacy strings ✓")
end

-- -----------------------------------------------------------------------
-- 3. Single-bucket with rich-record deletes.
-- -----------------------------------------------------------------------
do
    local set = command_helper.collect_deleted_clip_ids(make_command({
        sequence_id = "seq1",
        inserts = {},
        updates = {},
        deletes = {
            { clip_id = "clip_x", track_id = "v1", timeline_start = 0, duration = 100 },
            { clip_id = "clip_y", track_id = "v1", timeline_start = 100, duration = 50 },
        },
    }))
    assert(set["clip_x"] and set["clip_y"] and count(set) == 2,
        "rich-record deletes collected via .clip_id")
    print("  3. single-bucket, rich records ✓")
end

-- -----------------------------------------------------------------------
-- 4. Multi-bucket with mixed-shape deletes across sequences.
-- -----------------------------------------------------------------------
do
    local set = command_helper.collect_deleted_clip_ids(make_command({
        seqA = {
            sequence_id = "seqA",
            inserts = {}, updates = {},
            deletes = { "legacy_string_A" },
        },
        seqB = {
            sequence_id = "seqB",
            inserts = {}, updates = {},
            deletes = { { clip_id = "rich_B", track_id = "a1", timeline_start = 0, duration = 10 } },
        },
    }))
    assert(set["legacy_string_A"] and set["rich_B"] and count(set) == 2,
        "multi-bucket unions both shapes")
    print("  4. multi-bucket, mixed shapes ✓")
end

-- -----------------------------------------------------------------------
-- 5. Inserts/updates never contribute. Only bucket.deletes matters.
-- -----------------------------------------------------------------------
do
    local set = command_helper.collect_deleted_clip_ids(make_command({
        sequence_id = "seq1",
        inserts = { { track_id = "v1", timeline_start_frame = 0, duration_frames = 10 } },
        updates = { { clip_id = "upd", track_id = "v1", timeline_start_frame = 0, duration_frames = 10,
                      previous = { track_id = "v1", timeline_start = 0, duration = 10 } } },
        deletes = {},
    }))
    assert(count(set) == 0, "no deletes → empty set regardless of inserts/updates")
    print("  5. inserts/updates don't contribute ✓")
end

-- -----------------------------------------------------------------------
-- 6. Malformed entries (nil clip_id, non-string) are skipped silently.
-- Derivation is best-effort — producers shouldn't emit these, but a
-- partial payload shouldn't crash a selection-restore path.
-- -----------------------------------------------------------------------
do
    local set = command_helper.collect_deleted_clip_ids(make_command({
        sequence_id = "seq1",
        inserts = {}, updates = {},
        deletes = {
            { clip_id = "real" },
            { track_id = "v1" },        -- record without clip_id
            "",                          -- empty string
            42,                          -- non-string
        },
    }))
    assert(set["real"] and count(set) == 1,
        "only the well-formed entry is collected")
    print("  6. malformed entries skipped ✓")
end

print("\n✅ test_command_helper_collect_deleted_clip_ids.lua passed")
