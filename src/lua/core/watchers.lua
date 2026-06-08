--- Watchers: Per-entity pub/sub notification system.
--- Replaces global broadcasts (e.g. content_changed) with targeted
--- notifications for specific entities (clips, sequences, tracks, media).
---
--- @module core.watchers
local M = {}

local log = require("core.logger").for_area("ui")
local uuid = require("uuid")

-- { [key: string] = { { id = token, callback = function }, ... } }
local subscribers = {}

-- { [key: string] = { full_refresh = boolean, fields = { [field: string] = true }, ... } }
local pending_notifications = {}

--- Watch an entity key.
--- Supported keys: "clip:<id>", "sequence:<id>", "track:<id>", "media:<id>"
--- @param key string The entity key to watch.
--- @param callback function The function to call when the entity mutates.
--- @return string opaque token for unwatch
function M.watch(key, callback)
    assert(type(key) == "string" and key ~= "", "watchers.watch: key must be a non-empty string")
    assert(type(callback) == "function", "watchers.watch: callback must be a function")
    
    local token = uuid.generate()
    if not subscribers[key] then
        subscribers[key] = {}
    end
    table.insert(subscribers[key], { id = token, callback = callback })
    
    return token
end

--- Unwatch an entity using a token returned by watch().
--- @param token string The token to unregister.
function M.unwatch(token)
    assert(type(token) == "string" and token ~= "", "watchers.unwatch: token must be a non-empty string")
    for key, subs in pairs(subscribers) do
        for i, sub in ipairs(subs) do
            if sub.id == token then
                table.remove(subs, i)
                -- Clean up empty lists
                if #subs == 0 then
                    subscribers[key] = nil
                end
                return
            end
        end
    end
end

--- Notify subscribers that an entity changed.
--- Safe to call from anywhere; callbacks are executed synchronously.
--- Unwatching during a notify is safe (we iterate a copy of the list).
--- @param key string The entity key that mutated.
--- @param event_data table|nil Optional data about the mutation.
function M.notify(key, event_data)
    assert(type(key) == "string" and key ~= "", "watchers.notify: key must be a non-empty string")
    
    local subs = subscribers[key]
    if not subs then return end
    
    -- Iterate a copy to allow safe unwatch() during the callback
    local current_subs = {}
    for _, sub in ipairs(subs) do
        table.insert(current_subs, sub)
    end
    
    for _, sub in ipairs(current_subs) do
        -- Double check it hasn't been removed during this notification loop
        local still_exists = false
        if subscribers[key] then
            for _, existing in ipairs(subscribers[key]) do
                if existing.id == sub.id then
                    still_exists = true
                    break
                end
            end
        end
        if still_exists then
            local ok, err = pcall(sub.callback, event_data)
            if not ok then
                log.error("watchers.notify: callback error for key %s: %s", key, tostring(err))
            end
        end
    end
end

--- Queue a notification to fire after the current command transaction commits.
--- Safe to call from anywhere; if no command is executing, fires immediately.
--- @param key string The entity key that mutated.
--- @param event_data table|nil Optional data about the mutation.
function M.queue_notify(key, event_data)
    assert(type(key) == "string" and key ~= "", "watchers.queue_notify: key must be a non-empty string")
    
    -- Use package.loaded to avoid circular dependency if possible, or lazy require
    local cm = package.loaded["core.command_manager"]
    if not cm or not cm.is_executing() then
        M.notify(key, event_data)
        return
    end
    
    if not pending_notifications[key] then
        pending_notifications[key] = { full_refresh = false, fields = {} }
    end
    
    local pending = pending_notifications[key]
    
    if not event_data then
        pending.full_refresh = true
    else
        -- Merge field-level info if present
        if event_data.fields then
            for _, field in ipairs(event_data.fields) do
                pending.fields[field] = true
            end
        end
        -- Merge other event_data keys (e.g. kind = "playhead")
        for k, v in pairs(event_data) do
            if k ~= "fields" then
                pending[k] = v
            end
        end
    end
end

--- Flush all queued notifications. Called by command_manager.
function M.flush()
    local pending = pending_notifications
    pending_notifications = {}
    
    -- Sort keys for deterministic execution in tests
    local keys = {}
    for key, _ in pairs(pending) do table.insert(keys, key) end
    table.sort(keys)
    
    for _, key in ipairs(keys) do
        local data = pending[key]
        local event_data = nil
        
        if not data.full_refresh then
            event_data = {}
            local has_data = false
            for k, v in pairs(data) do
                if k == "fields" then
                    local field_list = {}
                    for f, _ in pairs(v) do
                        table.insert(field_list, f)
                    end
                    if #field_list > 0 then
                        event_data.fields = field_list
                        has_data = true
                    end
                elseif k ~= "full_refresh" then
                    event_data[k] = v
                    has_data = true
                end
            end
            if not has_data then event_data = nil end
        end
        
        M.notify(key, event_data)
    end
end

--- Discard all queued notifications. Called by command_manager on rollback.
function M.discard()
    pending_notifications = {}
end

-- ---------------------------------------------------------------------------
-- Model Helpers (DRY)
-- ---------------------------------------------------------------------------

function M.notify_clip(id, owner_sequence_id)
    assert(id and id ~= "", "watchers.notify_clip: id required")
    M.queue_notify("clip:" .. id)
    if owner_sequence_id and owner_sequence_id ~= "" then
        M.queue_notify("sequence:" .. owner_sequence_id)
    end
end

function M.notify_track(id, sequence_id)
    assert(id and id ~= "", "watchers.notify_track: id required")
    M.queue_notify("track:" .. id)
    if sequence_id and sequence_id ~= "" then
        M.queue_notify("sequence:" .. sequence_id)
    end
end

function M.notify_sequence(id)
    assert(id and id ~= "", "watchers.notify_sequence: id required")
    M.queue_notify("sequence:" .. id)
end

function M.notify_media(id)
    assert(id and id ~= "", "watchers.notify_media: id required")
    M.queue_notify("media:" .. id)
end

--- Clear all watchers (useful for test isolation).
function M.clear_all()
    subscribers = {}
    pending_notifications = {}
end

return M
