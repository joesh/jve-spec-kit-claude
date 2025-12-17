#!/usr/bin/env luajit

require("test_env")

local Rational = require("core.rational")
local renderer = require("ui.timeline.view.timeline_view_renderer")

local function get_upvalue(fn, target)
    for i = 1, 200 do
        local name, value = debug.getupvalue(fn, i)
        if not name then
            break
        end
        if name == target then
            return value
        end
    end
    return nil
end

local compute_implied_edges = get_upvalue(renderer.render, "compute_implied_edges")
assert(type(compute_implied_edges) == "function", "Failed to locate compute_implied_edges upvalue on timeline_view_renderer.render")

local fps_num, fps_den = 1000, 1
local zero = Rational.new(0, fps_num, fps_den)

-- Case 1: A clamped gap edge that is NOT selected should be returned as an implied edge.
do
    local clips = {
        clipA = {
            id = "clipA",
            track_id = "t1",
            timeline_start = Rational.new(1000, fps_num, fps_den),
            duration = Rational.new(100, fps_num, fps_den),
        }
    }

    local preview_data = {
        shifted_clips = {},
        shift_blocks = {},
        clamped_edges = {["clipA:gap_before"] = true},
    }

    local state_module = {
        get_track_clip_index = function(_track_id) return {} end,
    }

    local visible_tracks = {{id = "t1"}}
    local get_clip = function(id) return clips[id] end
    local selected_track_lookup = {}
    local selected_edge_lookup = {}
    local lead_edge = {edge_type = "gap_before"} -- "out"
    local global_delta = zero

    local implied = compute_implied_edges(
        preview_data,
        state_module,
        visible_tracks,
        get_clip,
        selected_track_lookup,
        selected_edge_lookup,
        zero,
        lead_edge,
        global_delta
    )

    local found = false
    for _, entry in ipairs(implied or {}) do
        if entry and entry.clip_id == "clipA" and entry.raw_edge_type == "gap_before" and entry.is_implied then
            found = true
            break
        end
    end
    assert(found, "Expected non-selected clamped gap edge to be returned as an implied edge")
end

-- Case 2: Shift blocks should produce implied edges for unselected tracks even when shifted_clips is empty.
do
    local clips_by_track = {
        t1 = {
            {id = "clip_t1_a", track_id = "t1", timeline_start = Rational.new(0, fps_num, fps_den), duration = Rational.new(500, fps_num, fps_den)},
        },
        t2 = {
            {id = "clip_t2_a", track_id = "t2", timeline_start = Rational.new(1000, fps_num, fps_den), duration = Rational.new(500, fps_num, fps_den)},
        }
    }

    local preview_data = {
        shifted_clips = {}, -- empty; rely on shift_blocks
        shift_blocks = {
            {start_frames = 1000, delta_frames = 200, track_id = "t2"}
        },
        clamped_edges = {},
    }

    local state_module = {
        get_track_clip_index = function(track_id) return clips_by_track[track_id] or {} end,
    }

    local visible_tracks = {{id = "t1"}, {id = "t2"}}
    local get_clip = function(id)
        for _, list in pairs(clips_by_track) do
            for _, clip in ipairs(list) do
                if clip.id == id then return clip end
            end
        end
        return nil
    end
    local selected_track_lookup = {t1 = true} -- only t2 should get implied
    local selected_edge_lookup = {}
    local lead_edge = {edge_type = "gap_before"} -- "out" => raw_edge_type should be gap_before for positive delta
    local global_delta = zero

    local implied = compute_implied_edges(
        preview_data,
        state_module,
        visible_tracks,
        get_clip,
        selected_track_lookup,
        selected_edge_lookup,
        zero,
        lead_edge,
        global_delta
    )

    local found_t2 = false
    for _, entry in ipairs(implied or {}) do
        if entry and entry.track_id == "t2" and entry.is_implied then
            found_t2 = true
            break
        end
    end
    assert(found_t2, "Expected shift_blocks to generate implied edges for unselected track t2")
end

print("✅ timeline_view_renderer implied edge generation covers clamped edges + shift blocks")

