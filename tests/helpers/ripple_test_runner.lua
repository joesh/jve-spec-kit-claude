--- Ripple test runner: human-readable ASCII timeline DSL.
--
-- Format:
--   before = [[
--     V1: [A 0-100][B 100-400][C 400-600]
--     A1: [D 0-600][E 600-800]
--   ]]
--   drag = "B out -50"                    -- ripple (default)
--   drag = "B out roll -50, C in roll -50" -- roll (explicit trim_type)
--   after = [[
--     V1: [A 0-100][B 100-350][C 350-550]
--     A1: [D 0-600][E 550-750]
--   ]]
--
-- Track names: V* = VIDEO, A* = AUDIO
-- Clips: [Name start-end]  (source_in auto-assigned as start*2+100 to avoid trivial zeros)
-- Gaps: implicit where no clip covers a range
--
-- Options:
--   verify_undo = true  — undo after verification, check before-state restored (default: true)
--   verify_source_in = true — check source_in changes correctly (default: true)
--   validate = true — run project_validator between operations (default: true)

local M = {}

local command_manager = require("core.command_manager")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")
local validator = require("tests.helpers.project_validator")

--- Parse a timeline string into {track_name = {{name, start, end_pos}, ...}}
local function parse_timeline(text)
    local tracks = {}
    local track_order = {}
    for line in text:gmatch("[^\n]+") do
        local track_name, body = line:match("^%s*(%S+):%s*(.+)%s*$")
        if track_name and body then
            local clips = {}
            for name, s, e in body:gmatch("%[(%S+)%s+(%d+)-(%d+)%]") do
                table.insert(clips, {name = name, start = tonumber(s), end_pos = tonumber(e)})
            end
            tracks[track_name] = clips
            table.insert(track_order, track_name)
        end
    end
    return tracks, track_order
end

--- Parse drag string.
-- Formats:
--   "B out -50"                        — ripple (default trim_type)
--   "B out roll -50, C in roll -50"    — explicit trim_type per edge
--   "B out -50, C in -50"             — ripple (default)
-- The trim_type keyword is optional; if absent, defaults to "ripple".
local function parse_drag(text)
    local edges = {}
    for part in text:gmatch("[^,]+") do
        -- Try 4-token: "ClipName edge trim_type delta"
        local name, edge_type, trim_type, delta =
            part:match("^%s*(%S+)%s+(%S+)%s+(%a+)%s+([%-]?%d+)%s*$")
        if not name then
            -- Try 3-token: "ClipName edge delta" (trim_type defaults to "ripple")
            name, edge_type, delta =
                part:match("^%s*(%S+)%s+(%S+)%s+([%-]?%d+)%s*$")
            trim_type = "ripple"
        end
        assert(name and edge_type and delta,
            "ripple_test_runner: can't parse drag: '" .. part ..
            "' (expected 'ClipName edge [roll|ripple] delta')")
        assert(trim_type == "roll" or trim_type == "ripple",
            "ripple_test_runner: trim_type must be 'roll' or 'ripple', got '" .. trim_type .. "'")
        table.insert(edges, {
            clip_name = name,
            edge_type = edge_type,
            trim_type = trim_type,
            delta = tonumber(delta),
        })
    end
    assert(#edges > 0, "ripple_test_runner: empty drag string")
    -- BatchRippleEdit uses a single delta_frames. All edges must specify the same delta.
    local delta = edges[1].delta
    for i = 2, #edges do
        assert(edges[i].delta == delta,
            "ripple_test_runner: BatchRippleEdit uses one delta for all edges (got " ..
            edges[1].delta .. " and " .. edges[i].delta .. "). " ..
            "Asymmetric trim uses different edge TYPES (in vs out), not different deltas.")
    end
    return edges, delta
end

--- Build ripple_layout config from parsed before-state
local function build_layout(before_tracks, track_order, db_path)
    local tracks_cfg = {order = {}}
    local clips_cfg = {order = {}}
    local clip_to_track = {}

    for idx, track_name in ipairs(track_order) do
        local track_key = track_name:lower()
        local track_type = track_name:match("^[Vv]") and "VIDEO" or "AUDIO"
        local track_id = "track_" .. track_key
        tracks_cfg[track_key] = {
            id = track_id,
            name = track_name,
            track_type = track_type,
            track_index = idx,
            enabled = 1,
        }
        table.insert(tracks_cfg.order, track_key)

        for _, clip in ipairs(before_tracks[track_name]) do
            local clip_id = "clip_" .. clip.name
            local duration = clip.end_pos - clip.start
            assert(duration > 0,
                string.format("ripple_test_runner: clip %s has non-positive duration (%d-%d)",
                    clip.name, clip.start, clip.end_pos))
            -- source_in: use non-trivial value derived from clip name hash
            local source_in = clip.start * 2 + 100
            clips_cfg[clip.name] = {
                id = clip_id,
                name = clip.name,
                track_key = track_key,
                media_key = "main",
                timeline_start = clip.start,
                duration = duration,
                source_in = source_in,
            }
            table.insert(clips_cfg.order, clip.name)
            clip_to_track[clip.name] = track_id
        end
    end

    local layout = ripple_layout.create({
        db_path = db_path,
        tracks = tracks_cfg,
        clips = clips_cfg,
    })

    return layout, clip_to_track
end

--- Verify clip positions match expected after-state.
-- @return table Array of failure messages (empty = all passed)
local function verify_after_state(after_tracks)
    local failures = {}
    for track_name, clips in pairs(after_tracks) do
        for _, clip in ipairs(clips) do
            local clip_id = "clip_" .. clip.name
            local c = Clip.load_optional(clip_id)
            if not c then
                if clip.start ~= clip.end_pos then
                    table.insert(failures, string.format(
                        "%s: clip %s not found (expected %d-%d)",
                        track_name, clip.name, clip.start, clip.end_pos))
                end
            else
                local expected_dur = clip.end_pos - clip.start
                if c.timeline_start ~= clip.start then
                    table.insert(failures, string.format(
                        "%s: %s start expected %d, got %d",
                        track_name, clip.name, clip.start, c.timeline_start))
                end
                if c.duration ~= expected_dur then
                    table.insert(failures, string.format(
                        "%s: %s duration expected %d, got %d",
                        track_name, clip.name, expected_dur, c.duration))
                end
            end
        end
    end
    return failures
end

--- Verify source_in changed correctly for in-edge trims (skip clamped ops).
local function verify_source_in_changes(failures, drag_edges, before_tracks, before_source_ins, delta)
    for _, edge in ipairs(drag_edges) do
        if edge.edge_type == "in" then
            local c = Clip.load_optional("clip_" .. edge.clip_name)
            if c and before_source_ins[edge.clip_name] then
                local before_clip = nil
                for _, clips in pairs(before_tracks) do
                    for _, bc in ipairs(clips) do
                        if bc.name == edge.clip_name then before_clip = bc; break end
                    end
                    if before_clip then break end
                end
                if before_clip then
                    local expected_dur = (before_clip.end_pos - before_clip.start) - delta
                    if c.duration == expected_dur then
                        local expected_source_in = before_source_ins[edge.clip_name] + delta
                        if c.source_in ~= expected_source_in then
                            table.insert(failures, string.format(
                                "%s: source_in expected %d, got %d (before=%d, delta=%d)",
                                edge.clip_name, expected_source_in, c.source_in,
                                before_source_ins[edge.clip_name], delta))
                        end
                    end
                end
            end
        end
    end
end

--- Execute undo and verify before-state is fully restored.
-- @return table Array of failure messages (empty = all passed)
local function verify_undo_round_trip(test_name, before_tracks, before_source_ins, do_validate, layout)
    local undo_result = command_manager.undo()
    assert(undo_result.success, test_name .. ": undo failed: " .. tostring(undo_result.error_message))

    if do_validate then
        validator.assert_valid(layout.db, nil, layout.sequence_id,
            test_name .. " after undo")
    end

    local undo_failures = {}
    for track_name, clips in pairs(before_tracks) do
        for _, clip in ipairs(clips) do
            local clip_id = "clip_" .. clip.name
            local c = Clip.load(clip_id)
            assert(c, test_name .. ": undo: clip " .. clip.name .. " missing after undo")
            if c.timeline_start ~= clip.start then
                table.insert(undo_failures, string.format(
                    "%s: %s start expected %d, got %d (undo)",
                    track_name, clip.name, clip.start, c.timeline_start))
            end
            local expected_dur = clip.end_pos - clip.start
            if c.duration ~= expected_dur then
                table.insert(undo_failures, string.format(
                    "%s: %s duration expected %d, got %d (undo)",
                    track_name, clip.name, expected_dur, c.duration))
            end
            if before_source_ins[clip.name] and c.source_in ~= before_source_ins[clip.name] then
                table.insert(undo_failures, string.format(
                    "%s: source_in expected %d, got %d (undo)",
                    clip.name, before_source_ins[clip.name], c.source_in))
            end
        end
    end
    return undo_failures
end

--- Run a single ripple test case
--- @param test table {name, before, drag, after}
function M.run(test)
    assert(test.name, "ripple_test_runner: test missing 'name'")
    assert(test.before, "ripple_test_runner: test missing 'before'")
    assert(test.drag, "ripple_test_runner: test missing 'drag'")
    assert(test.after, "ripple_test_runner: test missing 'after'")

    local db_path = "/tmp/jve/ripple_dsl_" .. test.name:gsub("%s+", "_"):gsub("[^%w_]", "") .. ".db"

    -- Parse
    local before_tracks, track_order = parse_timeline(test.before)
    local drag_edges, delta = parse_drag(test.drag)
    local after_tracks = parse_timeline(test.after)

    -- Build layout (auto-inits timeline_state — matches production path)
    local layout, clip_to_track = build_layout(before_tracks, track_order, db_path)

    -- Verify before-state
    for _, clips in pairs(before_tracks) do
        for _, clip in ipairs(clips) do
            local c = Clip.load("clip_" .. clip.name)
            assert(c, "setup: clip " .. clip.name .. " not found")
            assert(c.timeline_start == clip.start,
                string.format("setup: %s start expected %d, got %d", clip.name, clip.start, c.timeline_start))
            local expected_dur = clip.end_pos - clip.start
            assert(c.duration == expected_dur,
                string.format("setup: %s duration expected %d, got %d", clip.name, expected_dur, c.duration))
        end
    end

    -- Build edge_infos
    -- gap_before/gap_after are translated to gap clip references:
    --   gap_after on clip X → gap clip's "in" edge (gap starts at clip X's end)
    --   gap_before on clip Y → gap clip's "out" edge (gap ends at clip Y's start)
    local edge_infos = {}
    for _, edge in ipairs(drag_edges) do
        local track_id = clip_to_track[edge.clip_name]
        assert(track_id, "drag: clip " .. edge.clip_name .. " not found in layout")

        if edge.edge_type == "gap_after" or edge.edge_type == "gap_before" then
            -- Find the clip's position to compute gap clip ID
            local clip_data = Clip.load("clip_" .. edge.clip_name)
            assert(clip_data, "drag: clip " .. edge.clip_name .. " not in DB")
            local gap_start, gap_edge_type
            if edge.edge_type == "gap_after" then
                gap_start = clip_data.timeline_start + clip_data.duration
                gap_edge_type = "in"
            else -- gap_before
                -- Gap starts at previous clip's end on the same track.
                local prev_clip_end = 0
                for tn, clips_list in pairs(before_tracks) do
                    local tid = "track_" .. tn:lower()
                    if tid == track_id then
                        for _, c in ipairs(clips_list) do
                            local c_end = c.end_pos
                            if c_end <= clip_data.timeline_start and c_end > prev_clip_end then
                                prev_clip_end = c_end
                            end
                        end
                    end
                end
                gap_start = prev_clip_end
                gap_edge_type = "out"
            end
            local gap_id = string.format("gap_%s_%d", track_id, gap_start)
            table.insert(edge_infos, {
                clip_id = gap_id,
                edge_type = gap_edge_type,
                trim_type = edge.trim_type,
                track_id = track_id,
            })
        else
            table.insert(edge_infos, {
                clip_id = "clip_" .. edge.clip_name,
                edge_type = edge.edge_type,
                trim_type = edge.trim_type,
                track_id = track_id,
            })
        end
    end

    -- Capture before-state source_in values for undo verification
    local before_source_ins = {}
    for _, clips in pairs(before_tracks) do
        for _, clip in ipairs(clips) do
            local c = Clip.load("clip_" .. clip.name)
            if c then
                before_source_ins[clip.name] = c.source_in
            end
        end
    end

    -- Options (defaults)
    local verify_undo = test.verify_undo ~= false  -- default true
    local verify_source_in = test.verify_source_in ~= false  -- default true
    local do_validate = test.validate ~= false  -- default true

    -- Execute
    local result = command_manager.execute("BatchRippleEdit", {
        project_id = layout.project_id,
        sequence_id = layout.sequence_id,
        edge_infos = edge_infos,
        delta_frames = delta,
    })
    assert(result.success, test.name .. ": BatchRippleEdit failed: " .. tostring(result.error_message))

    -- Run project validator after execute
    if do_validate then
        validator.assert_valid(layout.db, nil, layout.sequence_id,
            test.name .. " after execute")
    end

    -- Verify after-state: timeline_start and duration match expected
    local failures = verify_after_state(after_tracks)

    -- Verify source_in changes for edited clips (skip when delta was clamped)
    if verify_source_in then
        verify_source_in_changes(failures, drag_edges, before_tracks, before_source_ins, delta)
    end

    if #failures > 0 then
        layout:cleanup()
        error(test.name .. " FAILED:\n  " .. table.concat(failures, "\n  "))
    end

    -- Undo round-trip: verify before-state is fully restored
    if verify_undo then
        local undo_failures = verify_undo_round_trip(
            test.name, before_tracks, before_source_ins, do_validate, layout)
        if #undo_failures > 0 then
            layout:cleanup()
            error(test.name .. " UNDO FAILED:\n  " .. table.concat(undo_failures, "\n  "))
        end
    end

    layout:cleanup()
end

--- Run all tests in a list, report results
function M.run_all(tests)
    local passed = 0
    local failed = 0
    local errors = {}
    for _, test in ipairs(tests) do
        local ok, err = pcall(M.run, test)
        if ok then
            passed = passed + 1
            print("  " .. test.name .. " — passed")
        else
            failed = failed + 1
            table.insert(errors, err)
            print("  " .. test.name .. " — FAILED")
        end
    end
    if failed > 0 then
        print("")
        for _, err in ipairs(errors) do
            print("  " .. err)
        end
        print("")
    end
    return passed, failed
end

return M
