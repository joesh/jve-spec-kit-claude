--- Ripple test runner: human-readable ASCII timeline DSL.
--
-- Format:
--   before = [[
--     V1: [A 0-100][B 100-400][C 400-600]
--     A1: [D 0-600][E 600-800]
--   ]]
--   drag = "B out -50"          -- or "B out -50, D out -50"
--   after = [[
--     V1: [A 0-100][B 100-350][C 350-550]
--     A1: [D 0-600][E 550-750]
--   ]]
--
-- Track names: V* = VIDEO, A* = AUDIO
-- Clips: [Name start-end]  (source_in auto-assigned as start*2 to avoid trivial zeros)
-- Gaps: implicit where no clip covers a range

local M = {}

local command_manager = require("core.command_manager")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

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

--- Parse drag string: "B out -50" or "B out -50, D out -50"
local function parse_drag(text)
    local edges = {}
    for part in text:gmatch("[^,]+") do
        local name, edge_type, delta = part:match("^%s*(%S+)%s+(%S+)%s+([%-]?%d+)%s*$")
        assert(name and edge_type and delta,
            "ripple_test_runner: can't parse drag: '" .. part .. "' (expected 'ClipName edge delta')")
        table.insert(edges, {clip_name = name, edge_type = edge_type, delta = tonumber(delta)})
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

    -- Build layout
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
    local edge_infos = {}
    for _, edge in ipairs(drag_edges) do
        local track_id = clip_to_track[edge.clip_name]
        assert(track_id, "drag: clip " .. edge.clip_name .. " not found in layout")
        table.insert(edge_infos, {
            clip_id = "clip_" .. edge.clip_name,
            edge_type = edge.edge_type,
            trim_type = "ripple",
            track_id = track_id,
        })
    end

    -- Execute
    local result = command_manager.execute("BatchRippleEdit", {
        project_id = layout.project_id,
        sequence_id = layout.sequence_id,
        edge_infos = edge_infos,
        delta_frames = delta,
    })
    assert(result.success, test.name .. ": BatchRippleEdit failed: " .. tostring(result.error_message))

    -- Verify after-state
    local failures = {}
    for track_name, clips in pairs(after_tracks) do
        for _, clip in ipairs(clips) do
            local clip_id = "clip_" .. clip.name
            local c = Clip.load_optional(clip_id)
            if not c then
                -- Clip might have been deleted (trimmed to zero)
                if clip.start ~= clip.end_pos then
                    table.insert(failures, string.format(
                        "%s: clip %s not found (expected %d-%d)", track_name, clip.name, clip.start, clip.end_pos))
                end
            else
                local expected_dur = clip.end_pos - clip.start
                if c.timeline_start ~= clip.start then
                    table.insert(failures, string.format(
                        "%s: %s start expected %d, got %d", track_name, clip.name, clip.start, c.timeline_start))
                end
                if c.duration ~= expected_dur then
                    table.insert(failures, string.format(
                        "%s: %s duration expected %d, got %d", track_name, clip.name, expected_dur, c.duration))
                end
            end
        end
    end

    layout:cleanup()

    if #failures > 0 then
        error(test.name .. " FAILED:\n  " .. table.concat(failures, "\n  "))
    end
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
