require("test_env")

local database = require("core.database")
local command_state = require("core.command_state")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

local function expect_error(label, fn, pattern)
    local ok, err = pcall(fn)
    if not ok then
        if pattern and not tostring(err):match(pattern) then
            fail_count = fail_count + 1
            print("FAIL (wrong error): " .. label .. " got: " .. tostring(err))
        else
            pass_count = pass_count + 1
        end
    else
        fail_count = fail_count + 1
        print("FAIL (expected error): " .. label)
    end
    return err
end

print("\n=== Command State Tests (T15) ===")

-- ============================================================
-- Database setup
-- ============================================================
local db_path = "/tmp/jve/test_command_state.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()

local now = os.time()
local project_id = "proj_cs_001"
local sequence_id = "seq_cs_001"
local track_id = "track_cs_001"

db:exec(string.format(
    "INSERT INTO projects (id, name, created_at, modified_at, settings) VALUES ('%s', 'TestProj', %d, %d, '{}')",
    project_id, now, now
))
db:exec(string.format(
    "INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at) VALUES ('%s', '%s', 'Seq1', 30, 1, 48000, 1920, 1080, %d, %d)",
    sequence_id, project_id, now, now
))
db:exec(string.format(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) VALUES ('%s', '%s', 'V1', 'VIDEO', 0, 1)",
    track_id, sequence_id
))

-- Helper: insert a clip with all required columns
local function insert_clip(id, opts)
    opts = opts or {}
    local stmt = db:prepare("INSERT OR REPLACE INTO clips (id, track_id, clip_kind, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled, offline, created_at, modified_at) VALUES (?, ?, 'timeline', ?, ?, ?, ?, 30, 1, 1, 0, ?, ?)")
    stmt:bind_value(1, id)
    stmt:bind_value(2, opts.track_id or track_id)
    stmt:bind_value(3, opts.start or 0)
    stmt:bind_value(4, opts.duration or 100)
    stmt:bind_value(5, opts.source_in or 0)
    stmt:bind_value(6, opts.source_out or (opts.duration or 100))
    stmt:bind_value(7, now)
    stmt:bind_value(8, now)
    local ok = stmt:exec()
    if not ok then
        local err_msg = "unknown"
        if stmt.last_error then
            err_msg = tostring(stmt:last_error())
        end
        stmt:finalize()
        error("clip insert failed for " .. id .. ": " .. err_msg)
    end
    stmt:finalize()
end

-- ============================================================
-- init
-- ============================================================
print("\n--- init ---")
do
    command_state.init(db)
    -- No error = success. Module-local state reset.
    check("init succeeds", true)
end

-- ============================================================
-- calculate_state_hash — no db
-- ============================================================
print("\n--- calculate_state_hash no db ---")
do
    command_state.init(nil)
    expect_error("no db → error", function()
        command_state.calculate_state_hash(project_id)
    end, "No database connection")
    command_state.init(db) -- restore
end

-- ============================================================
-- calculate_state_hash — valid project
-- ============================================================
print("\n--- calculate_state_hash valid ---")
do
    local hash = command_state.calculate_state_hash(project_id)
    check("returns string", type(hash) == "string")
    check("8 hex chars", #hash == 8)
    check("valid hex", hash:match("^%x+$") ~= nil)
end

-- ============================================================
-- calculate_state_hash — deterministic
-- ============================================================
print("\n--- calculate_state_hash determinism ---")
do
    local h1 = command_state.calculate_state_hash(project_id)
    local h2 = command_state.calculate_state_hash(project_id)
    check("same project → same hash", h1 == h2)
end

-- ============================================================
-- calculate_state_hash — changes when data changes
-- ============================================================
print("\n--- calculate_state_hash sensitivity ---")
do
    local h_before = command_state.calculate_state_hash(project_id)

    -- Add a clip
    insert_clip("clip_cs_001")

    local h_after = command_state.calculate_state_hash(project_id)
    check("hash changes after clip insert", h_before ~= h_after)

    -- Modify clip
    local h_pre_mod = h_after
    local upd = db:prepare("UPDATE clips SET duration_frames = 200 WHERE id = ?")
    upd:bind_value(1, "clip_cs_001")
    upd:exec()
    upd:finalize()
    local h_post_mod = command_state.calculate_state_hash(project_id)
    check("hash changes after clip modify", h_pre_mod ~= h_post_mod)
end

-- ============================================================
-- calculate_state_hash — nonexistent project
-- ============================================================
print("\n--- calculate_state_hash nonexistent project ---")
do
    local h = command_state.calculate_state_hash("nonexistent_project")
    check("nonexistent → valid hash", type(h) == "string" and #h == 8)
    -- Empty data hashes to djb2 initial value (5381 with no input)
    -- Should be deterministic empty hash
    local h2 = command_state.calculate_state_hash("nonexistent_project")
    check("nonexistent → deterministic", h == h2)
end

-- ============================================================
-- calculate_state_hash — includes sequences, tracks, clips, media
-- ============================================================
print("\n--- calculate_state_hash covers all tables ---")
do
    local h1 = command_state.calculate_state_hash(project_id)

    -- Add media
    local m = db:prepare("INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, created_at, modified_at) VALUES (?, ?, 'test.mov', '/tmp/test.mov', 300, 30, 1, ?, ?)")
    m:bind_value(1, "media_cs_001")
    m:bind_value(2, project_id)
    m:bind_value(3, now)
    m:bind_value(4, now)
    m:exec()
    m:finalize()
    local h2 = command_state.calculate_state_hash(project_id)
    check("hash changes after media insert", h1 ~= h2)

    -- Add second track
    local t = db:prepare("INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled) VALUES (?, ?, 'A1', 'AUDIO', 1, 1)")
    t:bind_value(1, "track_cs_002")
    t:bind_value(2, sequence_id)
    t:exec()
    t:finalize()
    local h3 = command_state.calculate_state_hash(project_id)
    check("hash changes after track insert", h2 ~= h3)

    -- Modify sequence
    local s = db:prepare("UPDATE sequences SET playhead_frame = 42 WHERE id = ?")
    s:bind_value(1, sequence_id)
    s:exec()
    s:finalize()
    local h4 = command_state.calculate_state_hash(project_id)
    check("hash changes after sequence modify", h3 ~= h4)
end

-- ============================================================
-- update_command_hashes
-- ============================================================
print("\n--- update_command_hashes ---")
do
    local cmd = {}
    command_state.update_command_hashes(cmd, "abc123")
    check("pre_hash set", cmd.pre_hash == "abc123")
end

-- ============================================================
-- parse_temp_gap_identifier (tested via resolve_gap_clip_id indirectly,
-- but we test it via emit to see if edge resolution works)
-- ============================================================
print("\n--- temp gap identifier parsing ---")
do
    -- Insert a clip at a known position for gap resolution (after clip_cs_001 which is 0-200)
    insert_clip("clip_gap_test", {start = 300, duration = 50, source_out = 50})

    -- We can't call parse_temp_gap_identifier directly (it's local),
    -- but we can test it through capture_selection_snapshot/restore
    -- which use resolve_gap_clip_id internally.
    -- For now, test the format expectations documented in the code.
    -- The format is: "temp_gap_<track_id>_<start_frames>_<end_frames>"
    check("temp gap format documented", true)
end

-- ============================================================
-- capture_selection_snapshot — requires timeline_state mock
-- ============================================================
print("\n--- capture_selection_snapshot ---")
do
    -- Mock timeline_state
    local mock_timeline = {
        get_selected_clips = function()
            return {
                {id = "clip_a"},
                {id = "clip_b"},
            }
        end,
        get_selected_edges = function()
            return {}
        end,
        get_selected_gaps = function()
            return {}
        end,
    }
    package.loaded["ui.timeline.timeline_state"] = mock_timeline

    local clips_json, edges_json, gaps_json = command_state.capture_selection_snapshot()
    check("clips_json is string", type(clips_json) == "string")
    check("edges_json is string", type(edges_json) == "string")
    check("gaps_json is string", type(gaps_json) == "string")

    -- Decode clips
    local clips = _G.qt_json_decode(clips_json)
    check("2 clip ids captured", #clips == 2)
    check("clip_a captured", clips[1] == "clip_a")
    check("clip_b captured", clips[2] == "clip_b")

    -- Edges and gaps empty
    local edges = _G.qt_json_decode(edges_json)
    check("empty edges", #edges == 0)
    local gaps = _G.qt_json_decode(gaps_json)
    check("empty gaps", #gaps == 0)
end

-- ============================================================
-- capture_selection_snapshot — with edges
-- ============================================================
print("\n--- capture_selection_snapshot edges ---")
do
    local mock_timeline = {
        get_selected_clips = function() return {} end,
        get_selected_edges = function()
            return {
                {clip_id = "clip_e1", edge_type = "head", trim_type = "ripple"},
                {clip_id = "clip_e2", edge_type = "tail"},
            }
        end,
        get_selected_gaps = function() return {} end,
    }
    package.loaded["ui.timeline.timeline_state"] = mock_timeline

    local _, edges_json = command_state.capture_selection_snapshot()
    local edges = _G.qt_json_decode(edges_json)
    check("2 edges captured", #edges == 2)
    check("edge[1] clip_id", edges[1].clip_id == "clip_e1")
    check("edge[1] edge_type", edges[1].edge_type == "head")
    check("edge[1] trim_type", edges[1].trim_type == "ripple")
    check("edge[2] clip_id", edges[2].clip_id == "clip_e2")
    check("edge[2] edge_type", edges[2].edge_type == "tail")
end

-- ============================================================
-- capture_selection_snapshot — with gaps
-- ============================================================
print("\n--- capture_selection_snapshot gaps ---")
do
    local mock_timeline = {
        get_selected_clips = function() return {} end,
        get_selected_edges = function() return {} end,
        get_selected_gaps = function()
            return {
                {track_id = "t1", start_value = 100, duration = 50},
            }
        end,
    }
    package.loaded["ui.timeline.timeline_state"] = mock_timeline

    local _, _, gaps_json = command_state.capture_selection_snapshot()
    local gaps = _G.qt_json_decode(gaps_json)
    check("1 gap captured", #gaps == 1)
    check("gap track_id", gaps[1].track_id == "t1")
    check("gap start_value", gaps[1].start_value == 100)
    check("gap duration", gaps[1].duration == 50)
end

-- ============================================================
-- capture_selection_snapshot — nil/empty clips
-- ============================================================
print("\n--- capture_selection_snapshot nil clips ---")
do
    local mock_timeline = {
        get_selected_clips = function() return nil end,
        get_selected_edges = function() return nil end,
        get_selected_gaps = nil, -- method doesn't exist
    }
    package.loaded["ui.timeline.timeline_state"] = mock_timeline

    local clips_json, edges_json, gaps_json = command_state.capture_selection_snapshot()
    check("nil clips → empty json", clips_json == "[]")
    check("nil edges → empty json", edges_json == "[]")
    check("nil gaps → empty json", gaps_json == "[]")
end

-- ============================================================
-- capture_selection_snapshot — skips invalid entries
-- ============================================================
print("\n--- capture_selection_snapshot filters ---")
do
    -- Note: ipairs stops at nil holes — {nil, X, Y} iterates 0 elements.
    -- Test non-nil entries with missing fields instead.
    local mock_timeline = {
        get_selected_clips = function()
            return {
                {id = nil}, -- no id → skipped
                {}, -- no id → skipped
                {id = "valid_clip"},
            }
        end,
        get_selected_edges = function()
            return {
                {clip_id = nil, edge_type = "head"}, -- no clip_id → skipped
                {clip_id = "c1", edge_type = nil}, -- no edge_type → skipped
                {clip_id = "c2", edge_type = "tail"},
            }
        end,
        get_selected_gaps = function()
            return {
                {track_id = nil, start_value = 0, duration = 10}, -- no track_id → skipped
                {track_id = "t1", start_value = 0, duration = 10},
            }
        end,
    }
    package.loaded["ui.timeline.timeline_state"] = mock_timeline

    local clips_json, edges_json, gaps_json = command_state.capture_selection_snapshot()
    local clips = _G.qt_json_decode(clips_json)
    check("only valid clip captured", #clips == 1)
    check("valid clip = valid_clip", clips[1] == "valid_clip")

    local edges = _G.qt_json_decode(edges_json)
    check("only valid edge captured", #edges == 1)
    check("valid edge clip_id = c2", edges[1].clip_id == "c2")

    local gaps = _G.qt_json_decode(gaps_json)
    check("only valid gap captured", #gaps == 1)
end

-- ============================================================
-- capture_selection_snapshot — temp_gap_* edge resolution
-- ============================================================
print("\n--- temp gap edge resolution ---")
do
    -- clip_gap_test is at position 300, duration 50 → ends at 350
    -- A gap_after edge: query finds clip whose (start+duration) = gap start
    local mock_timeline = {
        get_selected_clips = function() return {} end,
        get_selected_edges = function()
            return {
                {clip_id = "temp_gap_" .. track_id .. "_350_400", edge_type = "gap_after"},
            }
        end,
        get_selected_gaps = function() return {} end,
    }
    package.loaded["ui.timeline.timeline_state"] = mock_timeline

    local _, edges_json, _ = command_state.capture_selection_snapshot()
    local edges = _G.qt_json_decode(edges_json)
    check("temp gap resolved", #edges == 1)
    -- The gap_after at frame 350 should resolve to the clip whose end = 350
    -- clip_gap_test starts at 300, duration 50 → end = 350
    check("resolved to real clip_id", edges[1].clip_id == "clip_gap_test")
end

-- ============================================================
-- restore_selection_from_serialized — clips
-- ============================================================
print("\n--- restore_selection clips ---")
do
    -- Create a clip we can load (after existing clips: cs_001 at 0-200, gap_test at 300-350)
    insert_clip("clip_restore_1", {start = 500})

    local restored_clips = nil
    local mock_selection_state = {
        set_selection = function(clips, _) restored_clips = clips end,
        restore_edge_selection = function() end,
        set_gap_selection = function() end,
    }
    package.loaded["ui.timeline.state.selection_state"] = mock_selection_state

    -- Mock timeline_state without get_sequence_id → bypass_persist=false
    local set_selection_called = false
    local mock_timeline = {
        set_selection = function(clips)
            set_selection_called = true
            restored_clips = clips
        end,
        set_gap_selection = function() end,
    }
    package.loaded["ui.timeline.timeline_state"] = mock_timeline

    local clips_json = _G.qt_json_encode({"clip_restore_1"})
    command_state.restore_selection_from_serialized(clips_json, "[]", "[]")
    check("set_selection called", set_selection_called)
    check("1 clip restored", restored_clips and #restored_clips == 1)
    check("clip id correct", restored_clips and restored_clips[1] and restored_clips[1].id == "clip_restore_1")
end

-- ============================================================
-- restore_selection_from_serialized — edges take priority over clips
-- ============================================================
print("\n--- restore_selection edge priority ---")
do
    local edge_called = false
    local clip_called = false

    local mock_timeline = {
        restore_edge_selection = function(edges, opts)
            edge_called = true
        end,
        set_selection = function() clip_called = true end,
        set_gap_selection = function() end,
    }
    package.loaded["ui.timeline.timeline_state"] = mock_timeline
    package.loaded["ui.timeline.state.selection_state"] = {
        set_selection = function() end,
        restore_edge_selection = function() end,
        set_gap_selection = function() end,
    }

    local edges_json = _G.qt_json_encode({{clip_id = "clip_restore_1", edge_type = "head"}})
    local clips_json = _G.qt_json_encode({"clip_restore_1"})
    command_state.restore_selection_from_serialized(clips_json, edges_json, "[]")
    check("edges take priority", edge_called)
    check("clips not called when edges present", not clip_called)
end

-- ============================================================
-- restore_selection_from_serialized — bypass_persist when no sequence
-- ============================================================
print("\n--- restore bypass_persist ---")
do
    local sel_state_called = false
    local mock_selection_state = {
        set_selection = function(clips, _) sel_state_called = true end,
        restore_edge_selection = function() end,
        set_gap_selection = function() end,
    }
    package.loaded["ui.timeline.state.selection_state"] = mock_selection_state

    -- timeline_state with get_sequence_id returning nil → bypass_persist=true
    local mock_timeline = {
        get_sequence_id = function() return nil end,
        set_selection = function() error("should not be called") end,
        set_gap_selection = function() end,
    }
    package.loaded["ui.timeline.timeline_state"] = mock_timeline

    local clips_json = _G.qt_json_encode({"clip_restore_1"})
    command_state.restore_selection_from_serialized(clips_json, "[]", "[]")
    check("bypass_persist uses selection_state directly", sel_state_called)
end

-- ============================================================
-- restore_selection_from_serialized — empty selection clears
-- ============================================================
print("\n--- restore empty clears ---")
do
    local clear_called = false
    local gap_clear_called = false
    local mock_timeline = {
        set_selection = function(clips) clear_called = (#clips == 0) end,
        set_gap_selection = function(gaps) gap_clear_called = (#gaps == 0) end,
    }
    package.loaded["ui.timeline.timeline_state"] = mock_timeline
    package.loaded["ui.timeline.state.selection_state"] = {
        set_selection = function() end,
        restore_edge_selection = function() end,
        set_gap_selection = function() end,
    }

    command_state.restore_selection_from_serialized("[]", "[]", "[]")
    check("empty clips → clear selection", clear_called)
    check("empty gaps → clear gaps", gap_clear_called)
end

-- ============================================================
-- restore_selection_from_serialized — nil/empty json
-- ============================================================
print("\n--- restore nil json ---")
do
    local clear_called = false
    local mock_timeline = {
        set_selection = function(clips) clear_called = true end,
        set_gap_selection = function() end,
    }
    package.loaded["ui.timeline.timeline_state"] = mock_timeline
    package.loaded["ui.timeline.state.selection_state"] = {
        set_selection = function() end,
        restore_edge_selection = function() end,
        set_gap_selection = function() end,
    }

    command_state.restore_selection_from_serialized(nil, nil, nil)
    check("nil json → clear", clear_called)

    clear_called = false
    command_state.restore_selection_from_serialized("", "", "")
    check("empty string json → clear", clear_called)
end

-- ============================================================
-- restore_selection_from_serialized — nonexistent clips skipped
-- ============================================================
print("\n--- restore nonexistent clips ---")
do
    local restored = nil
    local mock_timeline = {
        set_selection = function(clips) restored = clips end,
        set_gap_selection = function() end,
    }
    package.loaded["ui.timeline.timeline_state"] = mock_timeline
    package.loaded["ui.timeline.state.selection_state"] = {
        set_selection = function() end,
        restore_edge_selection = function() end,
        set_gap_selection = function() end,
    }

    local clips_json = _G.qt_json_encode({"nonexistent_clip_xyz"})
    command_state.restore_selection_from_serialized(clips_json, "[]", "[]")
    -- Nonexistent clip → safe_load_clip returns nil → skipped → empty selection → clear
    check("nonexistent clips → clear", restored and #restored == 0)
end

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n=== Command State: %d passed, %d failed ===", pass_count, fail_count))
if fail_count > 0 then
    os.exit(1)
end
print("✅ test_command_state.lua passed")
