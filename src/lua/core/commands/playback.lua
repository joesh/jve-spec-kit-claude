--- Playback transport commands: TogglePlay, ShuttleForward, ShuttleReverse, ShuttleStop.
--
-- Non-undoable. All commands get the active engine from panel_manager.
-- ShuttleStop sets k_held state for K+J/K+L slow-play combos.
--
-- @file playback.lua
local M = {}

-- K key held state for K+J/K+L slow playback (shared across shuttle commands)
local k_held = false

function M.is_k_held()
    return k_held
end

function M.set_k_held(value)
    k_held = value
end

--- Get the PlaybackEngine for the currently active SequenceMonitor.
local function get_active_engine()
    local pm = require('ui.panel_manager')
    local sv = pm.get_active_sequence_monitor()
    if not sv then return nil end
    return sv.engine
end

--- Check if the active view has a sequence loaded and ready for playback.
local function ensure_playback_initialized()
    local pm = require('ui.panel_manager')
    local sv = pm.get_active_sequence_monitor()
    if not sv then return false end
    if not sv.sequence_id then return false end
    if sv.total_frames <= 0 then return false end
    return true
end

function M.register(executors, undoers, db)
    local function toggle_play_executor(command)
        if not ensure_playback_initialized() then return true end
        local engine = get_active_engine()
        if engine:is_playing() then
            engine:stop()
        else
            engine:play()
        end
        return true
    end

    local function shuttle_forward_executor(command)
        if not ensure_playback_initialized() then return true end
        local engine = get_active_engine()
        if k_held then
            engine:slow_play(1)   -- K+L = slow forward
        else
            engine:shuttle(1)     -- L = forward shuttle
        end
        return true
    end

    local function shuttle_reverse_executor(command)
        if not ensure_playback_initialized() then return true end
        local engine = get_active_engine()
        if k_held then
            engine:slow_play(-1)  -- K+J = slow reverse
        else
            engine:shuttle(-1)    -- J = reverse shuttle
        end
        return true
    end

    local function shuttle_stop_executor(command)
        k_held = true
        local engine = get_active_engine()
        if engine then engine:stop() end
        return true
    end

    local NON_UNDOABLE = { undoable = false, args = { project_id = {} } }

    return {
        TogglePlay = { executor = toggle_play_executor, spec = NON_UNDOABLE },
        ShuttleForward = { executor = shuttle_forward_executor, spec = NON_UNDOABLE },
        ShuttleReverse = { executor = shuttle_reverse_executor, spec = NON_UNDOABLE },
        ShuttleStop = { executor = shuttle_stop_executor, spec = NON_UNDOABLE },
    }
end

return M
