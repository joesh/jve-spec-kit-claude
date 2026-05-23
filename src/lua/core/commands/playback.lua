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

--- 017: the engine that receives transport commands. Single source of
--- truth: transport.engine_for_target(), driven by the user's selection
--- of source-monitor vs record-monitor. Returns nil when transport has
--- not been bootstrapped or nothing is loaded on the target side.
local function get_target_engine()
    local transport = require("core.playback.transport")
    if not transport.is_bootstrapped() then return nil end
    return transport.engine_for_target()
end

--- True iff the target engine has a sequence loaded. FR-027: when
--- nothing is loaded, the command layer makes Space a no-op rather than
--- asserting inside the engine. Per the PlaybackEngine lifecycle
--- invariant, `loaded_sequence_id ~= nil` ⟺ `_playback_controller ~= nil`,
--- so checking one is sufficient.
local function target_ready()
    local engine = get_target_engine()
    if engine == nil then return false end
    return engine.loaded_sequence_id ~= nil
end

function M.register(executors, undoers, db)
    local function sync_playing_state(playing)
        local ok, ts = pcall(require, 'ui.timeline.timeline_state')
        if ok and ts.set_is_playing then ts.set_is_playing(playing) end
    end

    local function toggle_play_executor(command)
        -- FR-027: target engine has nothing loaded → clean no-op (no error).
        if not target_ready() then return true end
        local engine = get_target_engine()
        assert(engine, "TogglePlay: engine is nil after target_ready")
        if engine:is_playing() then
            engine:stop()
            sync_playing_state(false)
        else
            engine:play()
            sync_playing_state(true)
        end
        return true
    end

    local function shuttle_forward_executor(command)
        if not target_ready() then return true end
        local engine = get_target_engine()
        assert(engine, "ShuttleForward: engine is nil after target_ready")
        if k_held then
            engine:slow_play(1)   -- K+L = slow forward
        else
            engine:shuttle(1)     -- L = forward shuttle
        end
        sync_playing_state(true)
        return true
    end

    local function shuttle_reverse_executor(command)
        if not target_ready() then return true end
        local engine = get_target_engine()
        assert(engine, "ShuttleReverse: engine is nil after target_ready")
        if k_held then
            engine:slow_play(-1)  -- K+J = slow reverse
        else
            engine:shuttle(-1)    -- J = reverse shuttle
        end
        sync_playing_state(true)
        return true
    end

    local function shuttle_stop_executor(command)
        k_held = true
        if target_ready() then
            local engine = get_target_engine()
            if engine:is_playing() then engine:stop() end
        end
        sync_playing_state(false)
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
