local M = {}

local database = require("core.database")
local json = require("dkjson")
local logger = require("core.logger")

function M.hydrate_executed_mutations_if_missing(command)
    if not command or not command.get_parameter then
        error("BatchRippleEdit undo: invalid command handle")
    end

    local function append_bulk_shifts(target)
        local bulk = command:get_parameter("bulk_shifts")
        if type(bulk) ~= "table" or #bulk == 0 then
            return target
        end

        local base = {}
        local bulks = {}
        local seen = {}

        local function key_for(entry)
            return string.format("%s:%s:%s",
                tostring(entry.track_id or ""),
                tostring(entry.first_clip_id or ""),
                tostring(entry.shift_frames or ""))
        end

        for _, entry in ipairs(target) do
            if type(entry) == "table" and entry.type == "bulk_shift" then
                local key = key_for(entry)
                seen[key] = true
                table.insert(bulks, entry)
            else
                table.insert(base, entry)
            end
        end

        for _, entry in ipairs(bulk) do
            if type(entry) == "table" and entry.type == "bulk_shift" then
                local key = key_for(entry)
                if not seen[key] then
                    seen[key] = true
                    table.insert(bulks, entry)
                end
            end
        end

        local pre = {}
        local post = {}
        for _, entry in ipairs(bulks) do
            local frames = tonumber(entry.shift_frames) or 0
            if frames > 0 then
                table.insert(pre, entry)
            elseif frames < 0 then
                table.insert(post, entry)
            end
        end

        local rebuilt = {}
        for _, entry in ipairs(pre) do
            table.insert(rebuilt, entry)
        end
        for _, entry in ipairs(base) do
            table.insert(rebuilt, entry)
        end
        for _, entry in ipairs(post) do
            table.insert(rebuilt, entry)
        end

        return rebuilt
    end

    local executed = command:get_parameter("executed_mutations")
    if type(executed) == "table" and next(executed) ~= nil then
        return append_bulk_shifts(executed)
    end

    local originals = command:get_parameter("original_states")
    if type(originals) ~= "table" or next(originals) == nil then
        error("BatchRippleEdit undo: command missing executed_mutations and original_states")
    end
    local ordered = command:get_parameter("executed_mutation_order")

    local conn = database.get_connection()
    if not conn then
        error("BatchRippleEdit undo: no database connection available to hydrate mutations")
    end

    local sequence_id = command:get_parameter("sequence_id")
    local project_id = command.project_id or command:get_parameter("project_id") or "default_project"

    local function normalized_state(state)
        local copy = {}
        for k, v in pairs(state) do
            copy[k] = v
        end
        copy.project_id = copy.project_id or project_id
        copy.clip_kind = copy.clip_kind or "timeline"
        copy.owner_sequence_id = copy.owner_sequence_id or copy.track_sequence_id or sequence_id
        copy.track_sequence_id = copy.track_sequence_id or copy.owner_sequence_id
        return copy
    end

    local function clip_exists(clip_id)
        if not clip_id or clip_id == "" then
            return false
        end
        local stmt = conn:prepare("SELECT 1 FROM clips WHERE id = ? LIMIT 1")
        if not stmt then
            error("BatchRippleEdit undo: failed to inspect clip existence")
        end
        stmt:bind_value(1, clip_id)
        local exists = stmt:exec() and stmt:next()
        stmt:finalize()
        return exists
    end

    local rebuilt = {}
    if type(ordered) == "table" and #ordered > 0 then
        for _, entry in ipairs(ordered) do
            if type(entry) == "table" and entry.clip_id and entry.type then
                if entry.type == "insert" then
                    table.insert(rebuilt, {type = "insert", clip_id = entry.clip_id})
                elseif entry.type == "update" or entry.type == "delete" then
                    local state = originals[entry.clip_id]
                    if type(state) ~= "table" then
                        error("BatchRippleEdit undo: missing original state for " .. tostring(entry.clip_id))
                    end
                    table.insert(rebuilt, {
                        type = entry.type,
                        clip_id = entry.clip_id,
                        previous = normalized_state(state)
                    })
                end
            end
        end
    else
        for _, state in pairs(originals) do
            if type(state) == "table" and state.id then
                local prev = normalized_state(state)
                local tag = clip_exists(state.id) and "update" or "delete"
                table.insert(rebuilt, {
                    type = tag,
                    clip_id = state.id,
                    previous = prev
                })
            end
        end
    end

    if #rebuilt == 0 then
        error("BatchRippleEdit undo: unable to hydrate executed_mutations (no original states)")
    end

    rebuilt = append_bulk_shifts(rebuilt)
    command:set_parameter("executed_mutations", rebuilt)

    if command.sequence_number then
        local params = command.parameters or {}
        local encoded = json.encode(params)
        local stmt = conn:prepare("UPDATE commands SET command_args = ? WHERE sequence_number = ?")
        if stmt then
            stmt:bind_value(1, encoded)
            stmt:bind_value(2, command.sequence_number)
            if not stmt:exec() then
                logger.warn("ripple", string.format("Failed to persist hydrated executed_mutations for sequence %s", tostring(command.sequence_number)))
            end
            stmt:finalize()
        end
    end

    return rebuilt
end

return M

