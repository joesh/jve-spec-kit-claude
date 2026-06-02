#!/usr/bin/env luajit

-- Regression coverage for ripple edits on imported FCP7 timelines.
-- Ensures importer produces structurally sound tracks and ripple shifts
-- downstream clips. Iterates over 3 clip indices against a single
-- imported timeline (ripple is applied + observed, no reset between cases —
-- each iteration recomputes its own baseline from current DB state).

require('test_env')
local ui       = require('integration.ui_test_env')
local test_env = require('test_env')

print("=== Imported Timeline Ripple Regression ===\n")

local DB = "/tmp/jve/test_imported_ripple.jvp"
local _, info = ui.launch({
    db_path      = DB,
    project_name = "Default Project",
})

local command_manager = require('core.command_manager')
local database        = require('core.database')
local timeline_state  = require('ui.timeline.timeline_state')
local Command         = require('command')

-- Import the fixture timeline.
local import_cmd = Command.create("ImportFCP7XML", info.project.id)
import_cmd:set_parameter("xml_path",
    test_env.require_fixture("tests/fixtures/resolve/sample_timeline_fcp7xml.xml"))
import_cmd:set_parameter("project_id", info.project.id)

local import_result = command_manager.execute(import_cmd)
assert(import_result.success,
    import_result.error_message or "ImportFCP7XML failed")

local import_record = command_manager.get_last_command(info.project.id)
local created_sequence_ids = import_record:get_parameter("created_sequence_ids")
assert(type(created_sequence_ids) == "table" and #created_sequence_ids >= 1,
    "Importer did not record created sequence IDs")
local sequence_id = created_sequence_ids[1]

timeline_state.init(sequence_id, info.project.id)
command_manager.activate_timeline_stack(sequence_id)

-- ─── Import invariants (importer correctness) ──────────────────────────
local function assert_import_invariants()
    local tracks = database.load_tracks(sequence_id)
    local tracks_by_type = {}
    for _, t in ipairs(tracks) do
        assert(t.track_index >= 1,
            string.format("Track %s has invalid index %d", t.id, t.track_index))
        tracks_by_type[t.track_type] = tracks_by_type[t.track_type] or {}
        table.insert(tracks_by_type[t.track_type], t.track_index)
    end
    assert(#tracks > 0, "Importer created no tracks")
    for ttype, indices in pairs(tracks_by_type) do
        table.sort(indices)
        for expected, actual in ipairs(indices) do
            assert(actual == expected, string.format(
                "Track indices for %s not contiguous (expected %d, got %d)",
                ttype, expected, actual))
        end
    end

    local clips = database.load_clips(sequence_id)
    for _, clip in ipairs(clips) do
        assert(clip.owner_sequence_id == sequence_id,
            string.format("Clip %s references sequence %s (expected %s)",
                clip.id, tostring(clip.owner_sequence_id), tostring(sequence_id)))
    end

    -- Per-track non-overlap.
    local by_track = {}
    for _, c in ipairs(clips) do
        by_track[c.track_id] = by_track[c.track_id] or {}
        table.insert(by_track[c.track_id], c)
    end
    for track_id, list in pairs(by_track) do
        table.sort(list, function(a, b) return a.sequence_start < b.sequence_start end)
        local prev_end
        for _, c in ipairs(list) do
            if prev_end then
                assert(c.sequence_start >= prev_end, string.format(
                    "Track %s overlaps at clip %s (starts %d, prev ended %d)",
                    track_id, c.id, c.sequence_start, prev_end))
            end
            prev_end = c.sequence_start + c.duration
        end
    end
end

assert_import_invariants()

-- ─── Ripple per case ───────────────────────────────────────────────────
local function video_clips()
    local tracks = database.load_tracks(sequence_id)
    local video_track_ids = {}
    for _, t in ipairs(tracks) do
        if t.track_type == "VIDEO" then video_track_ids[t.id] = true end
    end
    local out = {}
    for _, c in ipairs(database.load_clips(sequence_id)) do
        if video_track_ids[c.track_id] then table.insert(out, c) end
    end
    table.sort(out, function(a, b) return a.sequence_start < b.sequence_start end)
    return out
end

local function clip_state(clip_id)
    local entry = database.load_clip_entry(clip_id)
    if not entry then return nil end
    return { start_value = entry.sequence_start, duration = entry.duration }
end

for _, clip_index in ipairs({1, 5, 10}) do
    local clips = video_clips()
    assert(#clips >= clip_index + 1, string.format(
        "Not enough clips (%d) to test index %d", #clips, clip_index))
    local target = clips[clip_index]
    local downstream = clips[clip_index + 1]
    local target_duration = target.duration
    assert(target_duration > 1, "Target clip too short for ripple test")

    local delta = -math.min(200, math.floor(target_duration / 2))
    if delta >= 0 then delta = -1 end

    local ripple_cmd = Command.create("BatchRippleEdit", info.project.id)
    ripple_cmd:set_parameter("edge_infos", {
        { clip_id = target.id, edge_type = "out",
          track_id = target.track_id, trim_type = "ripple" },
    })
    ripple_cmd:set_parameter("delta_frames", delta)
    ripple_cmd:set_parameter("sequence_id", sequence_id)

    local rr = command_manager.execute(ripple_cmd)
    assert(rr.success, rr.error_message or "RippleEdit failed on imported clip")

    local target_after = clip_state(target.id)
    local downstream_after = clip_state(downstream.id)
    assert(target_after, "Target clip missing after ripple")
    assert(downstream_after, "Downstream clip missing after ripple")

    local delta_applied = target_after.duration - target_duration
    assert(delta_applied < 0, "Ripple should shorten target clip")
    assert(downstream_after.start_value == downstream.sequence_start + delta_applied,
        string.format(
            "Clip %s start mismatch after ripple: expected %d, got %d",
            downstream.id,
            downstream.sequence_start + delta_applied,
            downstream_after.start_value))

    print(string.format(
        "  RippleEdit shifted downstream clip for case index %d (applied delta %d)",
        clip_index, delta_applied))
end

print("✅ RippleEdit on imported timeline shifts downstream clips correctly across cases")
