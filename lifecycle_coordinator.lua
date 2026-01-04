-- Golden Test 2: Boilerplate-Dominated Lifecycle Coordinator
-- This file should be REJECTED by the analyzer (no nucleus, no leverage point)
-- Reason: All logic is lifecycle/setup/wiring code without semantic center

local M = {}
local state = {}
local callbacks = {}

-- Lifecycle: initialization boilerplate
function M.init()
    state.initialized = false
    state.ready = false
    state.loading = true
    callbacks = {}
end

-- Lifecycle: registration boilerplate
function M.register_callback(name, fn)
    if not callbacks[name] then
        callbacks[name] = {}
    end
    table.insert(callbacks[name], fn)
end

-- Lifecycle: notification boilerplate
local function notify_callbacks(name, ...)
    if callbacks[name] then
        for _, fn in ipairs(callbacks[name]) do
            fn(...)
        end
    end
end

-- Lifecycle: setup boilerplate
function M.setup()
    if state.initialized then
        return
    end

    state.initialized = true
    notify_callbacks('setup_complete')
end

-- Lifecycle: teardown boilerplate
function M.teardown()
    state.initialized = false
    state.ready = false
    callbacks = {}
    notify_callbacks('teardown_complete')
end

-- Lifecycle: ready check boilerplate
function M.is_ready()
    return state.ready and state.initialized
end

-- Lifecycle: state setter boilerplate
function M.set_ready(ready)
    state.ready = ready
    if ready then
        notify_callbacks('ready_changed', true)
    else
        notify_callbacks('ready_changed', false)
    end
end

-- Lifecycle: loading check boilerplate
function M.is_loading()
    return state.loading
end

-- Lifecycle: loading setter boilerplate
function M.set_loading(loading)
    state.loading = loading
    notify_callbacks('loading_changed', loading)
end

return M
