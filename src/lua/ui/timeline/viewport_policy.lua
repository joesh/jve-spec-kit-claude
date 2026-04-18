--- Viewport-surfacing policy applied after an interactive user action.
--
-- Responsibilities:
-- - Provide a single chokepoint that decides how the timeline viewport
--   should move in response to a completed user action.
-- - Default (execute): surface the playhead (ensure it's visible,
--   centered when possible).
-- - Undo/Redo: surface the "change region" — the time range + track set
--   affected by the command — so the user sees the thing that moved
--   instead of wherever the playhead happened to be.
--
-- Non-goals:
-- - This module does not fire on every internal nested dispatch. Pass 2's
--   single chokepoint is command_manager.execute_interactive (and the
--   undo/redo ceremonies) — nested dispatches from inside executors call
--   plain M.execute and never trigger the policy.
--
-- Invariants:
-- - derive_change_region is a pure function. Given the same command, it
--   returns the same region. It does not consult timeline_state, the DB,
--   or any other global.
-- - derive_change_region returns nil when the command carries no
--   __timeline_mutations payload (marks, playhead moves, non-clip
--   commands). Callers fall back to surface_playhead in that case.
--
-- @file viewport_policy.lua
local M = {}

-- Union accumulator for region bounds. Grows with each observed clip
-- extent. Call finish() to get {start_frame, end_frame} or nil if empty.
local function new_bounds()
    return {
        min = nil,
        max = nil,
        observe = function(self, start_frame, end_frame)
            assert(type(start_frame) == "number" and type(end_frame) == "number",
                "viewport_policy: bounds observe requires numbers")
            if self.min == nil or start_frame < self.min then self.min = start_frame end
            if self.max == nil or end_frame > self.max then self.max = end_frame end
        end,
        finish = function(self)
            if self.min == nil then return nil end
            return { start_frame = self.min, end_frame = self.max }
        end,
    }
end

-- Extract timeline coordinates + track_id from a mutation record. Handles
-- two shapes:
--   - new-state form (inserts, updates): uses timeline_start_frame / duration_frames
--   - pre-state form (previous row for updates/deletes): uses
--     timeline_start / duration (no _frame suffix; matches the DB row
--     column naming that clip_mutator.plan_update preserves in `previous`)
local function read_timeline_extent(record)
    local start_frame = record.timeline_start_frame or record.timeline_start
    local dur = record.duration_frames or record.duration
    if type(start_frame) ~= "number" or type(dur) ~= "number" then
        return nil, nil, nil
    end
    return start_frame, start_frame + dur, record.track_id
end

-- Fold one mutation (insert/update/delete) into the bounds accumulator +
-- track set. Updates contribute BOTH the new state AND `previous` so
-- track moves surface both the source and destination. Deletes contribute
-- only `previous`.
local function fold_mutation(kind, record, bounds, tracks)
    if kind == "insert" then
        local s, e, t = read_timeline_extent(record)
        if s then bounds:observe(s, e); if t then tracks[t] = true end end
    elseif kind == "update" then
        local s, e, t = read_timeline_extent(record)
        if s then bounds:observe(s, e); if t then tracks[t] = true end end
        if record.previous then
            local ps, pe, pt = read_timeline_extent(record.previous)
            if ps then bounds:observe(ps, pe); if pt then tracks[pt] = true end end
        end
    elseif kind == "delete" then
        if record.previous then
            local ps, pe, pt = read_timeline_extent(record.previous)
            if ps then bounds:observe(ps, pe); if pt then tracks[pt] = true end end
        end
    end
end

-- Walk a single bucket ({sequence_id, inserts, updates, deletes}) and
-- fold every mutation into bounds + tracks.
local function fold_bucket(bucket, bounds, tracks)
    if type(bucket) ~= "table" then return end
    for _, rec in ipairs(bucket.inserts or {}) do fold_mutation("insert", rec, bounds, tracks) end
    for _, rec in ipairs(bucket.updates or {}) do fold_mutation("update", rec, bounds, tracks) end
    for _, rec in ipairs(bucket.deletes or {}) do fold_mutation("delete", rec, bounds, tracks) end
end

--- Compute the change region for a completed command.
-- Returns { time_range = {start_frame, end_frame}, track_set = {id=true,…} }
-- on success, or nil if the command carries no timeline mutations (the
-- caller should fall back to surfacing the playhead).
function M.derive_change_region(command)
    assert(command and type(command) == "table" and type(command.get_parameter) == "function",
        "viewport_policy.derive_change_region: command with :get_parameter required")
    local mutations = command:get_parameter("__timeline_mutations")
    if type(mutations) ~= "table" then return nil end

    local bounds = new_bounds()
    local tracks = {}

    -- Single-bucket shape: the mutations table itself is one bucket, with
    -- top-level inserts/updates/deletes keys. Multi-bucket shape: each
    -- value is itself a bucket keyed by sequence_id. Distinguish by the
    -- presence of any top-level bucket fields.
    if mutations.inserts or mutations.updates or mutations.deletes or mutations.sequence_id then
        fold_bucket(mutations, bounds, tracks)
    else
        for _, bucket in pairs(mutations) do
            fold_bucket(bucket, bounds, tracks)
        end
    end

    local time_range = bounds:finish()
    if time_range == nil then return nil end
    return { time_range = time_range, track_set = tracks }
end

--- Apply the viewport-surfacing policy after a completed user action.
--
-- Called from command_manager.execute_interactive (event="execute") and
-- from the undo/redo ceremonies (event="undo"/"redo"). Executes exactly
-- once per user-visible action — nested dispatches inside command
-- executors go through plain M.execute and don't trigger this.
--
-- Policy:
--   - execute → ensure the playhead is visible in the viewport.
--   - undo/redo → if the command carries a change region (via
--     __timeline_mutations, including wrapper-forwarded mutations),
--     surface that region. Otherwise fall back to surfacing the playhead
--     (covers SetPlayhead, mark commands, and other non-clip actions).
function M.apply_post_command(event, command)
    assert(event == "execute" or event == "undo" or event == "redo",
        "viewport_policy.apply_post_command: unknown event " .. tostring(event))
    assert(command and type(command.get_parameter) == "function",
        "viewport_policy.apply_post_command: command with :get_parameter required")

    local ts = require("ui.timeline.timeline_state")

    if event == "undo" or event == "redo" then
        local region = M.derive_change_region(command)
        if region and region.time_range then
            if ts.surface_range then
                ts.surface_range(region.time_range.start_frame, region.time_range.end_frame)
            end
            -- Vertical axis: emit a signal so the timeline_view can
            -- scroll affected tracks into view. The view owns its
            -- vertical scroll offset as instance state, so we can't
            -- mutate it from the state layer — pub/sub via Signals is
            -- the plumbing that matches the project's MVC rule (views
            -- pull, they aren't pushed at).
            if region.track_set and next(region.track_set) ~= nil then
                local track_ids = {}
                for id, _ in pairs(region.track_set) do
                    table.insert(track_ids, id)
                end
                table.sort(track_ids)  -- deterministic order for testability
                local ok_sig, Signals = pcall(require, "core.signals")
                if ok_sig and Signals and Signals.emit then
                    Signals.emit("viewport_surface_tracks", track_ids)
                end
            end
            return
        end
    end

    if ts.surface_playhead then
        ts.surface_playhead()
    end
end

return M
