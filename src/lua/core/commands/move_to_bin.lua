--- MoveToBin command - moves bins or clips to a target bin
--
-- Responsibilities:
-- - Move one or more entities (bins or clips) to a target bin
-- - Auto-detect entity type and route to appropriate implementation
-- - Track previous assignments for undo
--
-- @file move_to_bin.lua
local M = {}
local tag_service = require("core.tag_service")

local SPEC = {
    args = {
        entity_ids = { required = true },  -- array of bin or clip IDs
        target_bin_id = { kind = "string" },  -- nil = move to root (bins) or unassign (clips)
        project_id = { required = true, kind = "string" },
    },
    persisted = {
        -- Stored separately for undo since bins and clips restore differently
        bin_moves = {},   -- array of {bin_id, previous_parent_id}
        clip_moves = {},  -- map of clip_id -> previous_bin_id ("__unassigned__" sentinel for nil)
    },
}

-- Check if an ID refers to a bin (tag in 'bin' namespace)
local function is_bin_id(project_id, entity_id, bins_lookup)
    return bins_lookup[entity_id] ~= nil
end

-- Check if moving bin to target would create a cycle
local function would_create_cycle(bins, bin_id, target_id)
    if not target_id then
        return false  -- Moving to root can't create cycle
    end
    if target_id == bin_id then
        return true  -- Can't be own parent
    end

    -- Build parent lookup
    local parent_map = {}
    for _, bin in ipairs(bins) do
        parent_map[bin.id] = bin.parent_id
    end

    -- Walk up from target to check if we hit bin_id
    local current = target_id
    local visited = {}
    while current do
        if current == bin_id then
            return true  -- bin_id is ancestor of target
        end
        if visited[current] then
            break  -- Already have a cycle (shouldn't happen)
        end
        visited[current] = true
        current = parent_map[current]
    end

    return false
end

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["MoveToBin"] = function(command)
        local args = command:get_all_parameters()
        command:set_parameter("__skip_sequence_replay", true)

        local project_id = args.project_id
        local entity_ids = args.entity_ids
        local target_bin_id = args.target_bin_id

        if type(entity_ids) ~= "table" or #entity_ids == 0 then
            return true  -- no-op for empty list
        end

        -- Load current bins to detect entity types and validate
        local bins = tag_service.list(project_id)
        local bins_lookup = {}
        for _, bin in ipairs(bins) do
            bins_lookup[bin.id] = bin
        end

        -- Validate target exists (if specified)
        if target_bin_id and not bins_lookup[target_bin_id] then
            set_last_error("MoveToBin: target bin does not exist: " .. tostring(target_bin_id))
            return false
        end

        -- Separate bins from clips and capture previous state
        local bin_moves = {}  -- {bin_id, previous_parent_id}
        local clip_ids = {}
        local current_clip_assignments = tag_service.list_master_clip_assignments(project_id)
        local clip_moves = {}  -- clip_id -> previous_bin_id

        for _, entity_id in ipairs(entity_ids) do
            if is_bin_id(project_id, entity_id, bins_lookup) then
                local bin = bins_lookup[entity_id]
                if bin.parent_id ~= target_bin_id then
                    -- Validate no cycle
                    if would_create_cycle(bins, entity_id, target_bin_id) then
                        set_last_error("MoveToBin: cannot move bin into its own descendant")
                        return false
                    end
                    table.insert(bin_moves, {
                        bin_id = entity_id,
                        previous_parent_id = bin.parent_id,  -- may be nil
                    })
                end
            else
                -- Assume it's a clip
                local current_bin = current_clip_assignments[entity_id]
                if current_bin ~= target_bin_id then
                    table.insert(clip_ids, entity_id)
                    clip_moves[entity_id] = current_bin or "__unassigned__"
                end
            end
        end

        -- Store for undo
        command:set_parameter("bin_moves", bin_moves)
        command:set_parameter("clip_moves", clip_moves)

        -- Execute bin moves
        if #bin_moves > 0 then
            for _, move in ipairs(bin_moves) do
                bins_lookup[move.bin_id].parent_id = target_bin_id
            end
            local ok, err = tag_service.save_hierarchy(project_id, bins)
            if not ok then
                set_last_error("MoveToBin: failed to save bin hierarchy: " .. tostring(err))
                return false
            end
        end

        -- Execute clip moves
        if #clip_ids > 0 then
            local ok, err = tag_service.assign_master_clips(project_id, clip_ids, target_bin_id)
            if not ok then
                set_last_error("MoveToBin: failed to assign clips: " .. tostring(err))
                return false
            end
        end

        return true
    end

    command_undoers["MoveToBin"] = function(command)
        local args = command:get_all_parameters()

        local project_id = args.project_id
        local bin_moves = args.bin_moves or {}
        local clip_moves = args.clip_moves or {}

        -- Undo bin moves
        if #bin_moves > 0 then
            local bins = tag_service.list(project_id)
            local bins_lookup = {}
            for _, bin in ipairs(bins) do
                bins_lookup[bin.id] = bin
            end

            for _, move in ipairs(bin_moves) do
                if bins_lookup[move.bin_id] then
                    bins_lookup[move.bin_id].parent_id = move.previous_parent_id
                end
            end

            local ok, err = tag_service.save_hierarchy(project_id, bins)
            if not ok then
                set_last_error("UndoMoveToBin: failed to restore bin hierarchy: " .. tostring(err))
                return false
            end
        end

        -- Undo clip moves - group by previous bin for efficiency
        if next(clip_moves) then
            local by_bin = {}  -- bin_id -> {clip_ids}
            for clip_id, prev_bin in pairs(clip_moves) do
                local key = prev_bin  -- includes "__unassigned__" sentinel
                by_bin[key] = by_bin[key] or {}
                table.insert(by_bin[key], clip_id)
            end

            for bin_key, clip_ids in pairs(by_bin) do
                local actual_bin_id = (bin_key ~= "__unassigned__") and bin_key or nil
                local ok, err = tag_service.assign_master_clips(project_id, clip_ids, actual_bin_id)
                if not ok then
                    set_last_error("UndoMoveToBin: failed to restore clip assignments: " .. tostring(err))
                    return false
                end
            end
        end

        return true
    end

    return {
        executor = command_executors["MoveToBin"],
        undoer = command_undoers["MoveToBin"],
        spec = SPEC,
    }
end

return M
