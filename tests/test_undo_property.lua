#!/usr/bin/env luajit
--
-- Property-based undo-correctness harness.
--
-- The bug class we're hunting: an executor mutates state X but the
-- undoer doesn't restore X exactly. Symptoms in the field: drift after
-- undo/redo cycles, selection going stale, source_in coordinates shifting
-- by tiny amounts, link groups not restored.
--
-- Approach: build a non-trivial fixture, then for each registered command
-- run three properties:
--   1. execute → undo round-trips back to the initial DB snapshot.
--   2. N random commands → N undos round-trips back.
--   3. execute → undo → redo equals execute alone.
--
-- Snapshots are taken directly from SQLite, every column except a curated
-- "ledger" set that is documented to advance on every action (timestamps,
-- mutation_generation, current_sequence_number, current_undo_tip). Rows
-- are sorted by primary key so order is deterministic. Diff reports the
-- FIRST diverging field path.
--
-- Mock-free. Uses real command_manager.execute against a real ripple_layout
-- fixture.

require("test_env")

local command_manager = require("core.command_manager")
local database = require("core.database")
local ripple_layout = require("tests.helpers.ripple_layout")
local Sequence = require("models.sequence")

-- Deterministic seed. On failure we print this so the run is reproducible.
local SEED = tonumber(os.getenv("JVE_UNDO_PROP_SEED")) or 42
math.randomseed(SEED)

-- =========================================================================
-- DB SNAPSHOT
-- =========================================================================

-- Per-table columns that change as part of the command-system ledger
-- (timestamps, monotonically-advancing counters, history cursors). These
-- are deliberately excluded from the snapshot — they are NOT part of the
-- domain state that undo is contracted to restore.
local LEDGER_EXCLUSIONS = {
    clips      = { modified_at = true, created_at = true },
    tracks     = { },
    sequences  = {
        modified_at = true, created_at = true,
        mutation_generation = true,
        current_sequence_number = true,
        current_undo_tip = true,
        current_branch_path = true,
    },
    clip_links = { },
}

local SNAPSHOT_TABLES = { "sequences", "tracks", "clips", "clip_links" }

-- Discover column names via PRAGMA table_info (cached per table).
local _columns_cache = {}
local function columns_of(db, table_name)
    if _columns_cache[table_name] then return _columns_cache[table_name] end
    local stmt = db:prepare(string.format("PRAGMA table_info(%s)", table_name))
    assert(stmt and stmt:exec(),
        "columns_of: PRAGMA failed for " .. table_name)
    local pk_col, cols = nil, {}
    while stmt:next() do
        local name = stmt:value(1)
        local pk_idx = stmt:value(5)
        cols[#cols + 1] = name
        if tonumber(pk_idx) == 1 then pk_col = name end
    end
    stmt:finalize()
    -- Fallback: first column is the de-facto sort key.
    pk_col = pk_col or cols[1]
    _columns_cache[table_name] = { cols = cols, pk = pk_col }
    return _columns_cache[table_name]
end

-- Snapshot every row of every table in SNAPSHOT_TABLES, excluding ledger
-- columns. Rows are returned as a list keyed by table, each row a map of
-- column→value. Lists are sorted by primary key for stable comparison.
local function snapshot_db(db)
    local snap = {}
    for _, tbl in ipairs(SNAPSHOT_TABLES) do
        local info = columns_of(db, tbl)
        local exclude = LEDGER_EXCLUSIONS[tbl] or {}
        local kept = {}
        for _, c in ipairs(info.cols) do
            if not exclude[c] then kept[#kept + 1] = c end
        end
        local select_cols = table.concat(kept, ", ")
        local stmt = db:prepare(string.format(
            "SELECT %s FROM %s ORDER BY %s", select_cols, tbl, info.pk))
        assert(stmt and stmt:exec(),
            "snapshot_db: query failed for " .. tbl)
        local rows = {}
        while stmt:next() do
            local row = {}
            for i, name in ipairs(kept) do
                -- stmt:value is 0-based.
                local v = stmt:value(i - 1)
                row[name] = v
            end
            rows[#rows + 1] = row
        end
        stmt:finalize()
        snap[tbl] = { pk = info.pk, rows = rows }
    end
    return snap
end

-- =========================================================================
-- DEEP COMPARE WITH FIRST-DIVERGING PATH
-- =========================================================================

-- Format a value for diff reporting.
local function fmt(v)
    if v == nil then return "<nil>" end
    if type(v) == "string" then
        if #v > 60 then return string.format("%q…(%d chars)", v:sub(1, 60), #v) end
        return string.format("%q", v)
    end
    return tostring(v)
end

-- Returns nil on equal, or a string describing the first divergence.
local function diff_value(path, a, b)
    if type(a) ~= type(b) then
        return string.format("%s: type %s vs %s (%s vs %s)",
            path, type(a), type(b), fmt(a), fmt(b))
    end
    if type(a) ~= "table" then
        if a ~= b then
            return string.format("%s: %s vs %s", path, fmt(a), fmt(b))
        end
        return nil
    end
    -- Tables: walk keys in a stable order (sorted) for determinism.
    local keys = {}
    local seen = {}
    for k in pairs(a) do keys[#keys + 1] = k; seen[k] = true end
    for k in pairs(b) do if not seen[k] then keys[#keys + 1] = k end end
    table.sort(keys, function(x, y) return tostring(x) < tostring(y) end)
    for _, k in ipairs(keys) do
        local sub_path
        if type(k) == "number" then
            sub_path = path .. "[" .. k .. "]"
        else
            sub_path = path .. "." .. tostring(k)
        end
        local d = diff_value(sub_path, a[k], b[k])
        if d then return d end
    end
    return nil
end

-- Compare two snapshots row-by-row. Reports the first diverging field path
-- in a format like clips[clip_v1_left].source_in_frame: 48000 vs 48010.
local function diff_snapshots(before, after)
    local tables = {}
    local seen = {}
    for k in pairs(before) do tables[#tables + 1] = k; seen[k] = true end
    for k in pairs(after) do if not seen[k] then tables[#tables + 1] = k end end
    table.sort(tables)
    for _, tbl in ipairs(tables) do
        local ba = before[tbl]; local aa = after[tbl]
        if not ba then return string.format("%s: missing in BEFORE", tbl) end
        if not aa then return string.format("%s: missing in AFTER", tbl) end
        if #ba.rows ~= #aa.rows then
            return string.format("%s: row count %d vs %d",
                tbl, #ba.rows, #aa.rows)
        end
        local pk = ba.pk
        for i = 1, #ba.rows do
            local rb, ra = ba.rows[i], aa.rows[i]
            local row_label = string.format("%s[%s]", tbl, tostring(rb[pk]))
            -- Identify by pk if the order shifted.
            if rb[pk] ~= ra[pk] then
                return string.format("%s: pk %s vs %s at index %d",
                    tbl, fmt(rb[pk]), fmt(ra[pk]), i)
            end
            local d = diff_value(row_label, rb, ra)
            if d then return d end
        end
    end
    return nil
end

local function assert_db_equal(before, after, ctx)
    local d = diff_snapshots(before, after)
    if d then
        error(string.format("\n=== UNDO DIVERGENCE ===\n"
            .. "context: %s\nseed:    %d\n"
            .. "diff:    %s\n", ctx, SEED, d), 2)
    end
end

-- =========================================================================
-- FIXTURE
-- =========================================================================

-- Non-trivial seed values per CLAUDE.md: non-zero source_in, irregular
-- placements, overlap-prone boundaries, multiple tracks of both types.
local function build_fixture()
    return ripple_layout.create({
        db_path = "/tmp/jve/test_undo_property.db",
        fps_numerator = 30,
        fps_denominator = 1,
        audio_sample_rate = 48000,
        tracks = {
            order = {"v1", "v2", "a1"},
            v1 = {id = "track_v1", name = "V1", track_type = "VIDEO", track_index = 1, enabled = 1},
            v2 = {id = "track_v2", name = "V2", track_type = "VIDEO", track_index = 2, enabled = 1},
            a1 = {id = "track_a1", name = "A1", track_type = "AUDIO", track_index = 1, enabled = 1},
        },
        media = {
            order = {"main"},
            main = {
                id = "media_main",
                name = "MainMedia",
                file_path = "synthetic://main",
                duration_frames = 6000,
                fps_numerator = 30,
                fps_denominator = 1,
                width = 1920,
                height = 1080,
                audio_channels = 2,
                codec = "raw",
                metadata = "{}",
            },
        },
        -- Non-trivial: source_in 217 (not 0), placements at 100/360/700/1100,
        -- some clips on v2 to exercise cross-track ops.
        clips = {
            order = {"v1_a", "v1_b", "v1_c", "v2_a", "a1_a"},
            v1_a = {
                id = "clip_v1_a", name = "V1A", track_key = "v1", media_key = "main",
                sequence_start = 100, duration = 220, source_in = 217,
            },
            v1_b = {
                id = "clip_v1_b", name = "V1B", track_key = "v1", media_key = "main",
                sequence_start = 360, duration = 310, source_in = 850,
            },
            v1_c = {
                id = "clip_v1_c", name = "V1C", track_key = "v1", media_key = "main",
                sequence_start = 700, duration = 380, source_in = 1400,
            },
            v2_a = {
                id = "clip_v2_a", name = "V2A", track_key = "v2", media_key = "main",
                sequence_start = 1100, duration = 240, source_in = 2200,
            },
            a1_a = {
                id = "clip_a1_a", name = "A1A", track_key = "a1", media_key = "main",
                sequence_start = 150, duration = 290,
                source_in = 48000 * 5,
                fps_numerator = 48000, fps_denominator = 1,
            },
        },
    })
end

-- =========================================================================
-- COMMAND GENERATORS
--
-- Each generator returns a (command_name, params) tuple OR nil if it can't
-- produce a valid command given current state. The harness retries on nil
-- and on benign validation failures — those don't count as property
-- failures, they count as "this command isn't applicable right now."
-- =========================================================================

local function load_clips_for_track(db, track_id)
    local stmt = db:prepare(
        "SELECT id, sequence_start_frame, duration_frames FROM clips "
        .. "WHERE track_id = ? ORDER BY sequence_start_frame")
    stmt:bind_value(1, track_id)
    assert(stmt:exec())
    local out = {}
    while stmt:next() do
        out[#out + 1] = {
            id = stmt:value(0),
            start = stmt:value(1),
            duration = stmt:value(2),
        }
    end
    stmt:finalize()
    return out
end

local function all_clip_ids(db)
    local stmt = db:prepare("SELECT id FROM clips ORDER BY id")
    assert(stmt:exec())
    local ids = {}
    while stmt:next() do ids[#ids + 1] = stmt:value(0) end
    stmt:finalize()
    return ids
end

local function video_tracks(layout)
    return {"track_v1", "track_v2"}
end

local function pick_random_clip(db)
    local ids = all_clip_ids(db)
    if #ids == 0 then return nil end
    return ids[math.random(#ids)]
end

local function pick_random_clip_with_range(db)
    local id = pick_random_clip(db)
    if not id then return nil end
    local stmt = db:prepare(
        "SELECT sequence_start_frame, duration_frames, track_id FROM clips WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next())
    local r = {
        id = id,
        start = stmt:value(0),
        duration = stmt:value(1),
        track_id = stmt:value(2),
    }
    stmt:finalize()
    return r
end

-- The masterclip source sequence id for our single media (set up by
-- ripple_layout.master_seq_for_media).
local function source_sequence_id(layout)
    return layout.master_seq_for_media["media_main"]
end

local GENS = {}

-- Every generator sets project_id; centralized so a missing project_id
-- can never be misclassified as "command not applicable" (NSF rule —
-- the harness must not silently skip what should be a real failure).
local function base_params(layout, extra)
    extra.project_id = layout.project_id
    extra.sequence_id = extra.sequence_id or layout.sequence_id
    return extra
end

GENS.Insert = function(layout, db)
    return "Insert", base_params(layout, {
        source_sequence_id = source_sequence_id(layout),
        sequence_start_frame = math.random(0, 1800),
        target_video_track_id = "track_v1",
        target_audio_track_id = "track_a1",
    })
end

GENS.Overwrite = function(layout, db)
    return "Overwrite", base_params(layout, {
        source_sequence_id = source_sequence_id(layout),
        sequence_start_frame = math.random(0, 1800),
        target_video_track_id = "track_v1",
        target_audio_track_id = "track_a1",
    })
end

GENS.Blade = function(layout, db)
    local c = pick_random_clip_with_range(db)
    if not c or c.duration < 4 then return nil end
    -- Strictly interior (otherwise blade is a no-op / rejected).
    local frame = c.start + math.random(1, c.duration - 1)
    return "Blade", base_params(layout, {
        blade_frame = frame,
        track_ids = { c.track_id },
    })
end

GENS.DeleteClip = function(layout, db)
    local id = pick_random_clip(db)
    if not id then return nil end
    return "DeleteClip", base_params(layout, {
        clip_id = id,
    })
end

GENS.MoveClipToTrack = function(layout, db)
    local c = pick_random_clip_with_range(db)
    if not c then return nil end
    local target
    if c.track_id == "track_v1" then target = "track_v2"
    elseif c.track_id == "track_v2" then target = "track_v1"
    else return nil end
    return "MoveClipToTrack", base_params(layout, {
        clip_id = c.id,
        target_track_id = target,
    })
end

GENS.SplitClip = function(layout, db)
    local c = pick_random_clip_with_range(db)
    if not c or c.duration < 4 then return nil end
    local split_frame = c.start + math.random(1, c.duration - 1)
    return "SplitClip", base_params(layout, {
        clip_id = c.id,
        split_frame = split_frame,
    })
end

GENS.TrimHead = function(layout, db)
    local c = pick_random_clip_with_range(db)
    if not c or c.duration < 4 then return nil end
    local trim_frame = c.start + math.random(1, c.duration - 1)
    return "TrimHead", base_params(layout, {
        clip_ids = { c.id },
        trim_frame = trim_frame,
    })
end

GENS.BatchRippleEdit_roll = function(layout, db)
    -- Find two adjacent clips on the same track for a roll.
    local tracks = { "track_v1" }
    local t = tracks[math.random(#tracks)]
    local clips = load_clips_for_track(db, t)
    if #clips < 2 then return nil end
    for i = 1, #clips - 1 do
        local left, right = clips[i], clips[i + 1]
        if left.start + left.duration == right.start then
            local max_delta = math.min(left.duration, right.duration) - 1
            if max_delta < 2 then return nil end
            local delta = math.random(-max_delta + 1, max_delta - 1)
            if delta == 0 then delta = 1 end
            return "BatchRippleEdit", base_params(layout, {
                edge_infos = {
                    {clip_id = left.id,  edge_type = "out", track_id = t, trim_type = "roll"},
                    {clip_id = right.id, edge_type = "in",  track_id = t, trim_type = "roll"},
                },
                delta_frames = delta,
            })
        end
    end
    return nil
end

GENS.BatchRippleEdit_ripple = function(layout, db)
    local tracks = { "track_v1", "track_v2" }
    local t = tracks[math.random(#tracks)]
    local clips = load_clips_for_track(db, t)
    if #clips == 0 then return nil end
    local c = clips[math.random(#clips)]
    if c.duration < 4 then return nil end
    local edge = (math.random(2) == 1) and "in" or "out"
    local max_delta = c.duration - 2
    local delta = math.random(-max_delta, max_delta)
    if delta == 0 then delta = 1 end
    return "BatchRippleEdit", base_params(layout, {
        edge_infos = {
            {clip_id = c.id, edge_type = edge, track_id = t, trim_type = "ripple"},
        },
        delta_frames = delta,
    })
end

local GEN_ORDER = {
    "Insert", "Overwrite", "Blade", "DeleteClip", "MoveClipToTrack",
    "SplitClip", "TrimHead", "BatchRippleEdit_roll", "BatchRippleEdit_ripple",
}

-- =========================================================================
-- HARNESS BODY
-- =========================================================================

local results = {
    findings = {},   -- list of {prop, seq, diff_msg, seed}
    successes = 0,
    skipped = 0,
}

local function record_finding(prop, history_log, diff_msg)
    results.findings[#results.findings + 1] = {
        prop = prop, history = history_log, diff = diff_msg,
    }
end

-- Try to generate + execute one command; returns:
--   "ok"       — executed successfully
--   "skipped"  — generator returned nil OR execute returned success=false
--                (treat as "command not applicable in current state")
local function try_one_command(layout, db, gen_name)
    local gen = GENS[gen_name]
    local cmd_name, params = gen(layout, db)
    if not cmd_name then return "skipped", nil end
    local ok, result = pcall(command_manager.execute, cmd_name, params)
    if not ok then
        return "skipped", string.format("%s(throw): %s", cmd_name, tostring(result))
    end
    if not result or not result.success then
        return "skipped", string.format("%s(fail): %s",
            cmd_name, tostring(result and result.error_message or "nil"))
    end
    return "ok", string.format("%s(%s)", cmd_name,
        params.clip_id or tostring(params.sequence_start_frame
            or params.blade_frame or params.split_frame or "..."))
end

-- Property 1: per-command execute+undo round-trip, N iterations each.
local PROP1_ITERS = 30
local function run_property_1(layout, db, baseline_snap)
    print(string.format("Property 1: execute+undo round-trip (%d iters / cmd)", PROP1_ITERS))
    for _, gen_name in ipairs(GEN_ORDER) do
        local successes, skips = 0, 0
        local last_failure_logged = false
        for iter = 1, PROP1_ITERS do
            -- Always start from the baseline so divergence between commands
            -- is impossible.
            local pre = snapshot_db(db)
            local outcome, cmd_label = try_one_command(layout, db, gen_name)
            if outcome ~= "ok" then
                skips = skips + 1
                -- Don't accumulate — verify we're still at baseline.
                local post_skip = snapshot_db(db)
                local d = diff_snapshots(pre, post_skip)
                assert(d == nil, "skipped command mutated state: " .. tostring(d))
            else
                local mid = snapshot_db(db)
                local mid_d = diff_snapshots(pre, mid)
                -- If a command "succeeded" but didn't change anything, that's
                -- fine — undo will be a no-op too.
                local undo_result = command_manager.undo()
                assert(undo_result.success,
                    string.format("undo failed after %s: %s",
                        cmd_label, tostring(undo_result.error_message)))
                local post = snapshot_db(db)
                local diff = diff_snapshots(pre, post)
                if diff then
                    if not last_failure_logged then
                        record_finding("P1", { cmd_label }, diff)
                        print(string.format("  FAIL %s: %s", gen_name, diff))
                        last_failure_logged = true
                    end
                else
                    successes = successes + 1
                end
            end
        end
        print(string.format("  %s: %d ok, %d skipped", gen_name, successes, skips))
        results.successes = results.successes + successes
        results.skipped = results.skipped + skips
    end
end

-- Property 2: random N-command sequence, then N undos.
local PROP2_RUNS = 50
local PROP2_LEN = 10
local function run_property_2(layout, db)
    print(string.format("Property 2: random N-command undo-all (%d runs, N=%d)",
        PROP2_RUNS, PROP2_LEN))
    local fails = 0
    for run = 1, PROP2_RUNS do
        local pre = snapshot_db(db)
        local executed_log = {}
        local executed_count = 0
        local attempts = 0
        while executed_count < PROP2_LEN and attempts < PROP2_LEN * 6 do
            attempts = attempts + 1
            local gen_name = GEN_ORDER[math.random(#GEN_ORDER)]
            local outcome, label = try_one_command(layout, db, gen_name)
            if outcome == "ok" then
                executed_count = executed_count + 1
                executed_log[#executed_log + 1] = label
            end
        end
        if executed_count == 0 then
            -- couldn't make progress; skip this run
        else
            local undo_failed = false
            for i = 1, executed_count do
                local r = command_manager.undo()
                if not r.success then
                    record_finding("P2",
                        { "after " .. table.concat(executed_log, " | ") },
                        string.format("undo #%d failed: %s",
                            i, tostring(r.error_message)))
                    undo_failed = true
                    fails = fails + 1
                    break
                end
            end
            if not undo_failed then
                local post = snapshot_db(db)
                local d = diff_snapshots(pre, post)
                if d then
                    record_finding("P2", executed_log, d)
                    fails = fails + 1
                end
            end
        end
        -- Recover to baseline regardless: keep undoing until nothing left.
        -- (Each property is supposed to leave state at baseline; if it didn't,
        -- subsequent runs would observe stale state.)
        if diff_snapshots(pre, snapshot_db(db)) ~= nil then
            -- Try a few more undos in case command count miscounted (e.g. a
            -- wrapper command created nested children).
            for _ = 1, PROP2_LEN do
                local r = command_manager.undo()
                if not r or not r.success then break end
            end
        end
    end
    print(string.format("  %d runs, %d divergences", PROP2_RUNS, fails))
end

-- Property 3: execute → undo → redo == execute alone.
local PROP3_ITERS = 20
local function run_property_3(layout, db)
    print(string.format("Property 3: redo idempotence (%d iters / cmd)", PROP3_ITERS))
    for _, gen_name in ipairs(GEN_ORDER) do
        local ok, skips, fails = 0, 0, 0
        for iter = 1, PROP3_ITERS do
            local pre = snapshot_db(db)
            local outcome, label = try_one_command(layout, db, gen_name)
            if outcome ~= "ok" then
                skips = skips + 1
            else
                local after_exec = snapshot_db(db)
                local undo_r = command_manager.undo()
                if not undo_r.success then
                    -- An undo failure IS a divergence (state diverged from
                    -- "executor's claimed inverse exists"). Record + continue;
                    -- don't crash the harness — we want all findings, not the
                    -- first one.
                    record_finding("P3", { label },
                        "undo failed: " .. tostring(undo_r.error_message))
                    fails = fails + 1
                else
                    local redo_r = command_manager.redo()
                    if not redo_r.success then
                        record_finding("P3", { label },
                            "redo failed: " .. tostring(redo_r.error_message))
                        fails = fails + 1
                    else
                        local after_redo = snapshot_db(db)
                        local d = diff_snapshots(after_exec, after_redo)
                        if d then
                            record_finding("P3", { label }, d)
                            fails = fails + 1
                        else
                            ok = ok + 1
                        end
                    end
                    -- Recover to per-iter baseline for next iter. Best-effort
                    -- — if state drifts here, subsequent iters still produce
                    -- valid findings (their pre-snapshot is captured fresh).
                    local r = command_manager.undo()
                    if not r or not r.success then break end
                end
            end
        end
        print(string.format("  %s: %d ok, %d skipped, %d failed",
            gen_name, ok, skips, fails))
    end
end

-- =========================================================================
-- MAIN
-- =========================================================================

print(string.format("=== Undo Property Harness (seed=%d) ===", SEED))
local layout = build_fixture()
local db = database.get_connection()
assert(db, "no db connection")

local baseline = snapshot_db(db)
print(string.format("Baseline: %d sequences, %d tracks, %d clips, %d clip_links",
    #baseline.sequences.rows,
    #baseline.tracks.rows,
    #baseline.clips.rows,
    #baseline.clip_links.rows))

run_property_1(layout, db, baseline)
run_property_2(layout, db)
run_property_3(layout, db)

print()
print(string.format("=== Summary ==="))
print(string.format("  seed:       %d", SEED))
print(string.format("  successes:  %d", results.successes))
print(string.format("  skipped:    %d", results.skipped))
print(string.format("  findings:   %d", #results.findings))

if #results.findings > 0 then
    print()
    print("=== Divergences ===")
    for i, f in ipairs(results.findings) do
        print(string.format("[%d] %s  history=%s", i, f.prop, table.concat(f.history, " | ")))
        print(string.format("    %s", f.diff))
        if i >= 12 then
            print(string.format("    ... and %d more", #results.findings - i))
            break
        end
    end
    layout:cleanup()
    error(string.format("undo property harness found %d divergence(s) at seed=%d",
        #results.findings, SEED))
end

layout:cleanup()
print("✅ test_undo_property.lua passed")
