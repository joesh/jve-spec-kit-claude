-- models/cycle.lua — feature 013
--
-- Responsibilities:
-- - would_create_cycle(owner_seq_id, candidate_nested_seq_id): return true iff
--   adding a clip row { owner_sequence_id=owner, sequence_id=candidate }
--   would create a direct or transitive cycle in the containment DAG.
--
-- Algorithm: depth-first walk of the sub-graph reachable from candidate via
-- clips.sequence_id. If owner appears in that reachable set (including
-- as candidate itself), adding this edge closes a cycle. Uncached; runs at
-- mutation time per research.md §3. O(|reachable from candidate|); real
-- projects rarely exceed depth 3.
--
-- Master sequences never appear as "owner" in clips (clips must be kind='sequence'), so their subtree
-- is terminal: no outgoing sequence_id edges.

local database = require("core.database")

local M = {}

--- Return true iff { owner_sequence_id=owner_seq_id, sequence_id=candidate_target_id }
--- would create a cycle. Refuse to add the clip in that case.
function M.would_create_cycle(owner_seq_id, candidate_target_id)
    assert(owner_seq_id and owner_seq_id ~= "",
        "would_create_cycle: owner_seq_id is required")
    assert(candidate_target_id and candidate_target_id ~= "",
        "would_create_cycle: candidate_target_id is required")

    -- Self-reference is always a cycle; short-circuit before any DB work.
    if owner_seq_id == candidate_target_id then
        return true
    end

    local db = database.get_connection()
    local stmt = db:prepare(
        "SELECT sequence_id FROM clips WHERE owner_sequence_id = ?")
    assert(stmt, "would_create_cycle: failed to prepare traversal query")

    local visited = { [candidate_target_id] = true }
    local stack = { candidate_target_id }

    while #stack > 0 do
        local cur = table.remove(stack)
        if cur == owner_seq_id then
            stmt:finalize()
            return true
        end
        stmt:reset()
        stmt:bind_value(1, cur)
        assert(stmt:exec(), "would_create_cycle: exec failed for sequence " .. cur)
        while stmt:next() do
            local child = stmt:value(0)
            if child and not visited[child] then
                visited[child] = true
                stack[#stack + 1] = child
            end
        end
    end
    stmt:finalize()
    return false
end

return M
