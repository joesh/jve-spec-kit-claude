#!/usr/bin/env luajit

-- Regression coverage for ripple edits on imported FCP7 timelines.
-- Ensures importer produces structurally sound tracks and ripple shifts downstream clips.

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/core/?.lua"
    .. ";../src/lua/models/?.lua"
    .. ";../tests/?.lua"

local test_env = require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')

local function install_timeline_stub()
    local timeline_state = {
        playhead_value = 0,
        playhead_position = 0,
        selected_clips = {},
        selected_edges = {},
        selected_gaps = {},
        viewport_start_value = 0,
        viewport_duration_frames_value = 10000,
        sequence_frame_rate = nil,
    }
    local guard_depth = 0

    timeline_state.sequence_id = 'default_sequence'

    local function refresh_sequence_frame_rate(sequence_id)
        local db = database.get_connection()
        assert(db, "timeline_state: database not initialized")
        local stmt = db:prepare("SELECT fps_numerator, fps_denominator FROM sequences WHERE id = ?")
        assert(stmt, "timeline_state: failed to prepare frame rate lookup")
        stmt:bind_value(1, sequence_id)
        assert(stmt:exec() and stmt:next(),
            string.format("timeline_state: missing sequence %s", tostring(sequence_id)))
        local num = stmt:value(0) or 0
        local den = stmt:value(1) or 1
        stmt:finalize()
        assert(num > 0 and den > 0, "timeline_state: invalid frame rate")
        timeline_state.sequence_frame_rate = num / den
    end

    function timeline_state.get_sequence_id()
        return timeline_state.sequence_id
    end

    function timeline_state.get_playhead_position()
        return timeline_state.playhead_position
    end

    function timeline_state.get_sequence_frame_rate()
        if not timeline_state.sequence_frame_rate then
            refresh_sequence_frame_rate(timeline_state.sequence_id)
        end
        return timeline_state.sequence_frame_rate
    end

    function timeline_state.set_playhead_position(ms)
        timeline_state.playhead_position = ms
    end

    function timeline_state.get_selected_clips()
        return timeline_state.selected_clips
    end

    function timeline_state.get_selected_edges()
        return timeline_state.selected_edges
    end

    function timeline_state.set_selection(clips)
        timeline_state.selected_clips = clips or {}
    end

    function timeline_state.set_edge_selection(edges)
        timeline_state.selected_edges = edges or {}
    end

    function timeline_state.set_gap_selection(gaps)
        timeline_state.selected_gaps = gaps or {}
    end

    function timeline_state.normalize_edge_selection() end
    function timeline_state.reload_clips(sequence_id)
        if sequence_id and sequence_id ~= '' then
            timeline_state.sequence_id = sequence_id
            refresh_sequence_frame_rate(sequence_id)
        end
    end
    function timeline_state.persist_state_to_db() end

    function timeline_state.apply_mutations()
        return true
    end

    function timeline_state.consume_mutation_failure()
        return nil
    end

    function timeline_state.set_viewport_start_time(ms)
        timeline_state.viewport_start_time = ms
    end

    function timeline_state.set_viewport_duration_frames_value(ms)
        timeline_state.viewport_duration_frames_value = ms
    end

    function timeline_state.capture_viewport()
        return {
            start_time = timeline_state.viewport_start_time,
            duration_value = timeline_state.viewport_duration_frames_value,
        }
    end

    function timeline_state.restore_viewport(snapshot)
        if not snapshot then
            return
        end
        if snapshot.start_time then
            timeline_state.viewport_start_time = snapshot.start_time
        end
        if snapshot.duration or snapshot.duration_value then
            timeline_state.viewport_duration_frames_value = snapshot.duration_value or snapshot.duration
        end
    end

    function timeline_state.push_viewport_guard()
        guard_depth = guard_depth + 1
        return guard_depth
    end

    function timeline_state.pop_viewport_guard()
        if guard_depth > 0 then
            guard_depth = guard_depth - 1
        end
        return guard_depth
    end

    package.loaded['ui.timeline.timeline_state'] = timeline_state
end

install_timeline_stub()

local SCHEMA_SQL = require('import_schema')
local function init_database(db_path)
    os.remove(db_path)
    assert(database.init(db_path))
    local db = database.get_connection()
    assert(db:exec(SCHEMA_SQL))
    assert(db:exec([[
        INSERT INTO projects (id, name, created_at, modified_at)
        VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));
        INSERT INTO sequences (
            id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_rate,
            width, height,
            view_start_frame, view_duration_frames, playhead_frame,
            selected_clip_ids, selected_edge_infos, selected_gap_infos,
            current_sequence_number, created_at, modified_at
        )
        VALUES (
            'default_sequence', 'default_project', 'Default Sequence', 'timeline',
            30, 1, 48000,
            1920, 1080,
            0, 10000, 0,
            '[]', '[]', '[]',
            0, strftime('%s','now'), strftime('%s','now')
        );
    ]]))
    return db
end

local function import_fixture(db_path)
    local db = init_database(db_path)
    command_manager.init('default_sequence', 'default_project')

    local import_cmd = Command.create("ImportFCP7XML", "default_project")
    import_cmd:set_parameter("xml_path", test_env.resolve_repo_path("tests/fixtures/resolve/sample_timeline_fcp7xml.xml"))
    import_cmd:set_parameter("project_id", "default_project")

    local result = command_manager.execute(import_cmd)
    assert(result.success, result.error_message or "ImportFCP7XML failed")

    local import_command = command_manager.get_last_command('default_project')
    assert(import_command, "Import command not recorded")

    local created_sequence_ids = import_command:get_parameter("created_sequence_ids")
    assert(type(created_sequence_ids) == "table" and #created_sequence_ids >= 1,
        "Importer did not record created sequence IDs")

    local sequence_id = created_sequence_ids[1]
    return db, sequence_id
end

local function assert_import_invariants(db, sequence_id)
    local tracks = database.load_tracks(sequence_id)
    local tracks_by_type = {}
    local track_ids = {}
    for _, track in ipairs(tracks) do
        assert(track.track_index >= 1, string.format("Track %s has invalid index %d", track.id, track.track_index))
        tracks_by_type[track.track_type] = tracks_by_type[track.track_type] or {}
        table.insert(tracks_by_type[track.track_type], track.track_index)
        track_ids[#track_ids + 1] = track.id
    end

    assert(#track_ids > 0, "Importer created no tracks")

    for track_type, indices in pairs(tracks_by_type) do
        table.sort(indices)
        for expected, actual in ipairs(indices) do
            assert(actual == expected,
                string.format("Track indices for %s are not contiguous (expected %d, got %d)", track_type, expected, actual))
        end
    end

    local clips = database.load_clips(sequence_id)
    table.sort(clips, function(a, b) return a.timeline_start < b.timeline_start end)

    for _, clip in ipairs(clips) do
        assert(clip.owner_sequence_id == sequence_id,
            string.format("Clip %s references sequence %s (expected %s)",
                clip.id, tostring(clip.owner_sequence_id), tostring(sequence_id)))
    end

    local clips_by_track = {}
    for _, clip in ipairs(clips) do
        local bucket = clips_by_track[clip.track_id] or {}
        bucket[#bucket + 1] = clip
        clips_by_track[clip.track_id] = bucket
    end

    for track_id, track_clips in pairs(clips_by_track) do
        table.sort(track_clips, function(a, b) return a.timeline_start < b.timeline_start end)
        local previous_end = nil
        for _, clip in ipairs(track_clips) do
            local start_value = clip.timeline_start
            local duration = clip.duration
            if previous_end then
                assert(start_value >= previous_end,
                    string.format("Track %s overlaps: clip %s starts at %d before previous end %d",
                        track_id, clip.id, start_value, previous_end))
            end
            previous_end = start_value + duration
        end
    end
end

local function fetch_video_clips(db, sequence_id)
    local tracks = database.load_tracks(sequence_id)
    local video_track_ids = {}
    for _, track in ipairs(tracks) do
        if track.track_type == "VIDEO" then
            video_track_ids[track.id] = true
        end
    end

    local clips = database.load_clips(sequence_id)
    local videos = {}
    for _, clip in ipairs(clips) do
        if video_track_ids[clip.track_id] then
            table.insert(videos, clip)
        end
    end

    table.sort(videos, function(a, b) return a.timeline_start < b.timeline_start end)
    return videos
end

local function fetch_clip_state(db, clip_id)
    local entry = database.load_clip_entry(clip_id)
    if not entry then
        return nil
    end
    return {
        start_value = entry.timeline_start,
        duration = entry.duration
    }
end

print("=== Imported Timeline Ripple Regression ===\n")

local CLIP_CASES = {1, 5, 10}

for _, clip_index in ipairs(CLIP_CASES) do
    local db_path = string.format("/tmp/jve/test_imported_ripple_case_%d.db", clip_index)
    local db, sequence_id = import_fixture(db_path)
    assert_import_invariants(db, sequence_id)

    local clips = fetch_video_clips(db, sequence_id)
    assert(#clips >= clip_index + 1,
        string.format("Not enough clips (%d) to test index %d", #clips, clip_index))

    local target = clips[clip_index]
    local downstream = clips[clip_index + 1]

    local target_duration = target.duration
    assert(target_duration > 1, "Target clip too short for ripple test")

    local delta = -math.min(200, math.floor(target_duration / 2))
    if delta >= 0 then
        delta = -1
    end

    local ripple_cmd = Command.create("RippleEdit", "default_project")
    ripple_cmd:set_parameter("edge_info", {
        clip_id = target.id,
        edge_type = "out",
        track_id = target.track_id
    })
    ripple_cmd:set_parameter("delta_frames", delta)
    ripple_cmd:set_parameter("sequence_id", sequence_id)

    local ripple_result = command_manager.execute(ripple_cmd)
    assert(ripple_result.success, ripple_result.error_message or "RippleEdit failed on imported clip")

    local target_after = fetch_clip_state(db, target.id)
    local downstream_after = fetch_clip_state(db, downstream.id)
    assert(target_after, "Target clip missing after ripple execution")
    assert(downstream_after, "Downstream clip missing after ripple execution")

    local delta_applied = target_after.duration - target_duration
    assert(delta_applied < 0, "Ripple should shorten target clip")
    assert(downstream_after.start_value == downstream.timeline_start + delta_applied,
        string.format("Clip %s start mismatch after ripple: expected %d, got %d",
            downstream.id, downstream.timeline_start + delta_applied, downstream_after.start_value))

    print(string.format("✅ RippleEdit shifted downstream clip for case index %d (applied delta %d)", clip_index, delta_applied))
end

print("✅ RippleEdit on imported timeline shifts downstream clips correctly across cases")
