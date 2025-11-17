#!/usr/bin/env luajit

-- Regression coverage for ripple edits on imported FCP7 timelines.
-- Ensures importer produces structurally sound tracks and ripple shifts downstream clips.

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/core/?.lua"
    .. ";../src/lua/models/?.lua"
    .. ";../tests/?.lua"

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')

local function install_timeline_stub()
    local timeline_state = {
        playhead_time = 0,
        selected_clips = {},
        selected_edges = {},
        selected_gaps = {},
        viewport_start_time = 0,
        viewport_duration = 10000
    }
    local guard_depth = 0

    timeline_state.sequence_id = 'default_sequence'

    function timeline_state.get_sequence_id()
        return timeline_state.sequence_id
    end

    function timeline_state.get_playhead_time()
        return timeline_state.playhead_time
    end

    function timeline_state.set_playhead_time(ms)
        timeline_state.playhead_time = ms
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
        if sequence_id and sequence_id ~= "" then
            timeline_state.sequence_id = sequence_id
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

    function timeline_state.set_viewport_duration(ms)
        timeline_state.viewport_duration = ms
    end

    function timeline_state.capture_viewport()
        return {
            start_time = timeline_state.viewport_start_time,
            duration = timeline_state.viewport_duration,
        }
    end

    function timeline_state.restore_viewport(snapshot)
        if not snapshot then
            return
        end
        if snapshot.start_time then
            timeline_state.viewport_start_time = snapshot.start_time
        end
        if snapshot.duration then
            timeline_state.viewport_duration = snapshot.duration
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

local SCHEMA_SQL = [[
    CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        settings TEXT NOT NULL DEFAULT '{}'
    );

    CREATE TABLE sequences (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        name TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'timeline',
        frame_rate REAL NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        timecode_start INTEGER NOT NULL DEFAULT 0,
        playhead_time INTEGER NOT NULL DEFAULT 0,
        selected_clip_ids TEXT,
        selected_edge_infos TEXT,
        selected_gap_infos TEXT,
        viewport_start_time INTEGER NOT NULL DEFAULT 0,
        viewport_duration INTEGER NOT NULL DEFAULT 10000,
        mark_in_time INTEGER,
        mark_out_time INTEGER,
        current_sequence_number INTEGER
    );

    CREATE TABLE tracks (
        id TEXT PRIMARY KEY,
        sequence_id TEXT NOT NULL,
        name TEXT NOT NULL,
        track_type TEXT NOT NULL,
        track_index INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        locked INTEGER NOT NULL DEFAULT 0,
        muted INTEGER NOT NULL DEFAULT 0,
        soloed INTEGER NOT NULL DEFAULT 0,
        volume REAL NOT NULL DEFAULT 1.0,
        pan REAL NOT NULL DEFAULT 0.0
    );

    CREATE TABLE clips (
        id TEXT PRIMARY KEY,
        project_id TEXT,
        clip_kind TEXT NOT NULL DEFAULT 'timeline',
        name TEXT DEFAULT '',
        track_id TEXT,
        media_id TEXT,
        source_sequence_id TEXT,
        parent_clip_id TEXT,
        owner_sequence_id TEXT,
        start_time INTEGER NOT NULL,
        duration INTEGER NOT NULL,
        source_in INTEGER NOT NULL DEFAULT 0,
        source_out INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        offline INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT 0,
        modified_at INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE media (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        name TEXT NOT NULL,
        file_path TEXT UNIQUE NOT NULL,
        duration INTEGER NOT NULL,
        frame_rate REAL NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        audio_channels INTEGER NOT NULL DEFAULT 0,
        codec TEXT,
        created_at INTEGER,
        modified_at INTEGER,
        metadata TEXT DEFAULT '{}'
    );

    CREATE TABLE commands (
        id TEXT PRIMARY KEY,
        parent_id TEXT,
        parent_sequence_number INTEGER,
        sequence_number INTEGER UNIQUE NOT NULL,
        command_type TEXT NOT NULL,
        command_args TEXT,
        pre_hash TEXT,
        post_hash TEXT,
        timestamp INTEGER,
        playhead_time INTEGER DEFAULT 0,
        selected_clip_ids TEXT DEFAULT '[]',
        selected_edge_infos TEXT DEFAULT '[]',
        selected_gap_infos TEXT DEFAULT '[]',
        selected_clip_ids_pre TEXT DEFAULT '[]',
        selected_edge_infos_pre TEXT DEFAULT '[]',
        selected_gap_infos_pre TEXT DEFAULT '[]'
    );

    CREATE TABLE tag_namespaces (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL
    );

    INSERT OR IGNORE INTO tag_namespaces(id, display_name)
    VALUES('bin', 'Bins');

    CREATE TABLE tags (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        namespace_id TEXT NOT NULL,
        name TEXT NOT NULL,
        path TEXT NOT NULL,
        parent_id TEXT,
        sort_index INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
    );

    CREATE TABLE tag_assignments (
        tag_id TEXT NOT NULL,
        project_id TEXT NOT NULL,
        namespace_id TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        assigned_at INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(tag_id, entity_type, entity_id)
    );
]]

local function init_database(db_path)
    os.remove(db_path)
    assert(database.init(db_path))
    local db = database.get_connection()
    assert(db:exec(SCHEMA_SQL))
    assert(db:exec([[
        INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
        INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
        VALUES ('default_sequence', 'default_project', 'Default Sequence', 30.0, 1920, 1080);
    ]]))
    return db
end

local function import_fixture(db_path)
    local db = init_database(db_path)
    command_manager.init(db, 'default_sequence', 'default_project')

    local import_cmd = Command.create("ImportFCP7XML", "default_project")
    import_cmd:set_parameter("xml_path", "fixtures/resolve/sample_timeline_fcp7xml.xml")
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
    local track_stmt = db:prepare([[
        SELECT id, track_type, track_index
        FROM tracks
        WHERE sequence_id = ?
        ORDER BY track_type ASC, track_index ASC
    ]])
    track_stmt:bind_value(1, sequence_id)
    assert(track_stmt:exec(), "Failed to query tracks")

    local tracks_by_type = {}
    local track_ids = {}

    while track_stmt:next() do
        local track_id = track_stmt:value(0)
        local track_type = track_stmt:value(1)
        local track_index = tonumber(track_stmt:value(2)) or 0

        assert(track_index >= 1, string.format("Track %s has invalid index %d", track_id, track_index))

        tracks_by_type[track_type] = tracks_by_type[track_type] or {}
        table.insert(tracks_by_type[track_type], track_index)
        track_ids[#track_ids + 1] = track_id
    end
    track_stmt:finalize()

    assert(#track_ids > 0, "Importer created no tracks")

    for track_type, indices in pairs(tracks_by_type) do
        table.sort(indices)
        for expected, actual in ipairs(indices) do
            assert(actual == expected,
                string.format("Track indices for %s are not contiguous (expected %d, got %d)", track_type, expected, actual))
        end
    end

    for _, track_id in ipairs(track_ids) do
        local clip_stmt = db:prepare([[
            SELECT id, start_time, duration, owner_sequence_id
            FROM clips
            WHERE track_id = ?
            ORDER BY start_time ASC
        ]])
        clip_stmt:bind_value(1, track_id)
        assert(clip_stmt:exec(), "Failed to query clips for track " .. tostring(track_id))

        local previous_end = nil
        while clip_stmt:next() do
            local clip_id = clip_stmt:value(0)
            local start_time = clip_stmt:value(1)
            local duration = clip_stmt:value(2)
            local owner_sequence_id = clip_stmt:value(3)

            assert(owner_sequence_id == sequence_id,
                string.format("Clip %s references sequence %s (expected %s)",
                    clip_id, tostring(owner_sequence_id), tostring(sequence_id)))

            if previous_end then
                assert(start_time >= previous_end,
                    string.format("Track %s overlaps: clip %s starts at %d before previous end %d",
                        track_id, clip_id, start_time, previous_end))
            end
            previous_end = start_time + duration
        end
        clip_stmt:finalize()
    end
end

local function fetch_video_clips(db, sequence_id)
    local stmt = db:prepare([[
        SELECT c.id, c.track_id, c.start_time, c.duration
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        WHERE t.sequence_id = ? AND t.track_type = 'VIDEO'
        ORDER BY c.start_time ASC
    ]])
    stmt:bind_value(1, sequence_id)
    assert(stmt:exec(), "Failed to load video clips")

    local clips = {}
    while stmt:next() do
        clips[#clips + 1] = {
            id = stmt:value(0),
            track_id = stmt:value(1),
            start_time = stmt:value(2),
            duration = stmt:value(3)
        }
    end
    stmt:finalize()
    return clips
end

local function fetch_clip_state(db, clip_id)
    local stmt = db:prepare("SELECT start_time, duration FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec(), "Failed to query clip state for " .. tostring(clip_id))
    local state = nil
    if stmt:next() then
        state = {
            start_time = stmt:value(0),
            duration = stmt:value(1)
        }
    end
    stmt:finalize()
    return state
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

    local expected_target_duration = target_duration + delta
    assert(expected_target_duration > 0, "Ripple delta would delete target clip")

    local expected_downstream_start = downstream.start_time + delta

    local ripple_cmd = Command.create("RippleEdit", "default_project")
    ripple_cmd:set_parameter("edge_info", {
        clip_id = target.id,
        edge_type = "out",
        track_id = target.track_id
    })
    ripple_cmd:set_parameter("delta_ms", delta)
    ripple_cmd:set_parameter("sequence_id", sequence_id)

    local ripple_result = command_manager.execute(ripple_cmd)
    assert(ripple_result.success, ripple_result.error_message or "RippleEdit failed on imported clip")

    local target_after = fetch_clip_state(db, target.id)
    local downstream_after = fetch_clip_state(db, downstream.id)
    assert(target_after, "Target clip missing after ripple execution")
    assert(downstream_after, "Downstream clip missing after ripple execution")

    assert(target_after.duration == expected_target_duration,
        string.format("Clip %s duration mismatch after ripple: expected %d, got %d",
            target.id, expected_target_duration, target_after.duration))

    assert(downstream_after.start_time == expected_downstream_start,
        string.format("Clip %s start mismatch after ripple: expected %d, got %d",
            downstream.id, expected_downstream_start, downstream_after.start_time))

    print(string.format("✅ RippleEdit shifted downstream clip for case index %d (delta %dms)", clip_index, delta))
end

print("✅ RippleEdit on imported timeline shifts downstream clips correctly across cases")
