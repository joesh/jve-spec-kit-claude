--- Change token — idempotency key for state-changing helper verbs.
--- Spec 023 T017, FR-008.
---
--- Shape: `{ project_id, sequence_id, mutation_generation }`. The helper's
--- ledger compares tokens by structural equality; a re-sent request bearing
--- an already-applied token returns the prior result without re-running the
--- state change. `protocol.idempotency_key` converts a token into the
--- per-verb wire key.
---
--- `mutation_generation` is the per-sequence monotonic counter from
--- `sequences.mutation_generation` (FU-2, project_mutation_generation_
--- semantics). Bumping it on a user action invalidates any prior
--- idempotency replay slot for that sequence.

local M = {}

local function assert_string(label, value)
    assert(type(value) == "string" and value ~= "",
        string.format("change_token: %s required (non-empty string), got %s",
            label, tostring(value)))
end

--- Build a change token from its three fields.
function M.build(project_id, sequence_id, mutation_generation)
    assert_string("project_id", project_id)
    assert_string("sequence_id", sequence_id)
    assert(type(mutation_generation) == "number"
        and mutation_generation == math.floor(mutation_generation)
        and mutation_generation >= 0,
        string.format("change_token: mutation_generation required "
            .. "(non-negative integer), got %s",
            tostring(mutation_generation)))
    return {
        project_id = project_id,
        sequence_id = sequence_id,
        mutation_generation = mutation_generation,
    }
end

--- Structural equality of two tokens.
function M.equals(a, b)
    assert(type(a) == "table" and type(b) == "table",
        "change_token.equals: two token tables required")
    return a.project_id == b.project_id
        and a.sequence_id == b.sequence_id
        and a.mutation_generation == b.mutation_generation
end

return M
