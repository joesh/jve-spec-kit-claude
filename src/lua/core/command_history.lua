--- CommandHistory: Manages undo/redo stacks, sequence numbers, and position persistence
-- Extracted from command_manager.lua
local M = {}
local log = require("core.logger").for_area("commands")

-- Database connection
local db = nil

-- State tracking
local last_sequence_number = 0
local active_sequence_id = nil
local _active_project_id = nil  -- luacheck: ignore 231

-- Undo group tracking
local undo_group_stack = {}

local GLOBAL_STACK_ID = "global"
local TIMELINE_STACK_PREFIX = "timeline:"

M.GLOBAL_STACK_ID = GLOBAL_STACK_ID

local undo_stack_states = {
    [GLOBAL_STACK_ID] = {
        current_sequence_number = nil,
        current_branch_path = {},
        sequence_id = nil,
        position_initialized = false,
    }
}

local active_stack_id = GLOBAL_STACK_ID
local current_sequence_number = undo_stack_states[GLOBAL_STACK_ID].current_sequence_number
local current_branch_path = undo_stack_states[GLOBAL_STACK_ID].current_branch_path  -- luacheck: ignore 231

-- Registry that callers can use to route commands to specific undo stacks.
local command_stack_resolvers = {}

function M.init(database, sequence_id, project_id)
    db = database
    -- sequence_id is OPTIONAL: nil/empty means "no active sequence" (feature
    -- 010). The global stack still tracks project-scoped commands; per-sequence
    -- stacks exist per sequence and are reachable by name later.
    if sequence_id == "" then sequence_id = nil end
    if not project_id or project_id == "" then
        error("CommandHistory.init: project_id is required", 2)
    end
    active_sequence_id = sequence_id
    _active_project_id = project_id

    M.reset()

    -- Query last sequence number from database.
    -- MUST use MAX of ALL commands (including orphaned branches) to prevent
    -- UNIQUE constraint collisions. Orphaned commands still occupy sequence numbers
    -- and will eventually be accessible via a branch browser.
    M.refresh_last_sequence_number()

    local global_state = M.ensure_stack_state(GLOBAL_STACK_ID)
    global_state.sequence_id = active_sequence_id  -- may be nil
    M.set_active_stack(GLOBAL_STACK_ID, {sequence_id = active_sequence_id})
    M.load_global_cursor()
end

function M.reset()
    undo_stack_states = {
        [GLOBAL_STACK_ID] = {
            current_sequence_number = nil,
            current_branch_tip = nil,
            current_branch_path = {},
            sequence_id = nil,
            position_initialized = false,
        }
    }
    active_stack_id = GLOBAL_STACK_ID
    current_sequence_number = nil
    current_branch_path = undo_stack_states[GLOBAL_STACK_ID].current_branch_path
    last_sequence_number = 0
end

function M.ensure_stack_state(stack_id)
    stack_id = stack_id or GLOBAL_STACK_ID
    local state = undo_stack_states[stack_id]
    if not state then
        state = {
            -- `current_sequence_number` is where the user sits on the
            -- branch (HEAD). `current_branch_tip` is the leaf of the
            -- user's current branch. Redo walks from cursor toward tip
            -- following parent_sequence_number. A new commit at non-tip
            -- position advances BOTH cursor and tip, orphaning the prior
            -- subtree (preserved in the commands table for future
            -- branch-picker UI, unreachable via Cmd+Shift+Z).
            current_sequence_number = nil,
            current_branch_tip = nil,
            current_branch_path = {},
            sequence_id = nil,
            position_initialized = false,
            -- Optimistic-CAS baselines: the cursor values we last
            -- *confirmed* in the DB. Writes compare against these and
            -- assert on mismatch (sibling-session safety). Two fields
            -- because GLOBAL_STACK_ID's state carries both the
            -- project's global_undo_cursor AND the active-sequence's
            -- current_sequence_number via save_undo_position.
            persisted_seq_cursor = nil,
            persisted_global_cursor = nil,
        }
        undo_stack_states[stack_id] = state
    end
    return state
end

function M.apply_stack_state(stack_id)
    active_stack_id = stack_id or GLOBAL_STACK_ID
    local state = M.ensure_stack_state(active_stack_id)
    current_sequence_number = state.current_sequence_number
    current_branch_path = state.current_branch_path
    return state
end

function M.set_active_stack(stack_id, opts)
    local state = M.apply_stack_state(stack_id)
    if opts and opts.sequence_id then
        state.sequence_id = opts.sequence_id
    end
    if state.sequence_id and not state.position_initialized then
        M.initialize_stack_position_from_db(stack_id, state.sequence_id)
    end
end

function M.set_current_sequence_number(value)
    current_sequence_number = value
    local state = M.ensure_stack_state(active_stack_id)
    state.current_sequence_number = value
    state.position_initialized = true
end

-- Set the leaf of the user's current branch on a SPECIFIC stack. Commit
-- paths call this with the new command's sequence_number (which also
-- becomes the cursor). The stack must be passed explicitly because the
-- *active* stack at commit time can differ from the stack the command
-- actually lands on — e.g. SetClipProperty has sequence_id in its spec
-- so the active stack is per-sequence, but the executor never sets the
-- sequence_id parameter so the command's stored sequence_id column is
-- NULL and the command lands on GLOBAL. Tip must go onto GLOBAL there,
-- not the active per-seq stack.
function M.set_branch_tip_on_stack(stack_id, value)
    local state = M.ensure_stack_state(stack_id or GLOBAL_STACK_ID)
    state.current_branch_tip = value
end

function M.get_current_branch_tip()
    local state = M.ensure_stack_state(active_stack_id)
    return state.current_branch_tip
end

function M.get_current_sequence_number()
    return current_sequence_number
end

function M.get_last_sequence_number()
    return last_sequence_number
end

--- Re-read MAX(sequence_number) from DB. Called on init and after UNIQUE collisions.
function M.refresh_last_sequence_number()
    assert(db, "refresh_last_sequence_number: no database connection (init not called?)")
    local query = db:prepare("SELECT MAX(sequence_number) FROM commands")
    assert(query, "refresh_last_sequence_number: failed to prepare MAX query (schema mismatch?)")
    if query:exec() and query:next() then
        local db_max = query:value(0) or 0
        if db_max > last_sequence_number then
            log.warn("refresh_last_sequence_number: DB MAX=%d > cached=%d (stale WAL or concurrent session)",
                db_max, last_sequence_number)
            last_sequence_number = db_max
        end
    end
    query:finalize()
end

function M.increment_sequence_number()
    last_sequence_number = last_sequence_number + 1
    -- `cursor` is the undo-position for the active stack (where the user
    -- currently sits in the undo history), not the allocator counter.
    -- These are independent: the allocator only goes up; the cursor moves
    -- with undo/redo.
    log.event("Allocated sequence_number %d (stack=%s cursor=%s)",
        last_sequence_number,
        tostring(active_stack_id),
        tostring(current_sequence_number))
    return last_sequence_number
end

function M.decrement_sequence_number()
    last_sequence_number = last_sequence_number - 1
end

function M.get_current_stack_id()
    return active_stack_id
end

function M.get_current_stack_sequence_id(fallback_to_active_sequence)
    local state = M.ensure_stack_state(active_stack_id)
    if state.sequence_id and state.sequence_id ~= "" then
        return state.sequence_id
    end
    if fallback_to_active_sequence then
        return active_sequence_id
    end
    return nil
end

function M.stack_id_for_sequence(sequence_id)
    if not sequence_id or sequence_id == "" then
        return GLOBAL_STACK_ID
    end
    return TIMELINE_STACK_PREFIX .. sequence_id
end

function M.resolve_stack_for_command(command)
    if command.stack_id then
        if type(command.stack_id) == "string" then
            return command.stack_id, nil
        elseif type(command.stack_id) == "table" then
            return command.stack_id.stack_id or GLOBAL_STACK_ID, command.stack_id
        end
    end

    local resolver = command_stack_resolvers[command.type]
    if resolver then
        local ok, stack_info = pcall(resolver, command)
        if ok and stack_info then
            if type(stack_info) == "string" then
                return stack_info, nil
            elseif type(stack_info) == "table" then
                return stack_info.stack_id or GLOBAL_STACK_ID, stack_info
            end
        elseif not ok then
            log.warn("Stack resolver for %s threw error: %s",
                tostring(command.type), tostring(stack_info))
        end
    end

    if command.get_parameter then
        local sequence_param = command:get_parameter("sequence_id")
        if sequence_param and sequence_param ~= "" then
            return M.stack_id_for_sequence(sequence_param), {sequence_id = sequence_param}
        end
    end

    return GLOBAL_STACK_ID, nil
end

function M.load_sequence_undo_position(sequence_id)
    assert(db, "load_sequence_undo_position: no database connection")
    if not sequence_id or sequence_id == "" then
        return nil, nil, false
    end

    local query = db:prepare([[
        SELECT current_sequence_number, current_undo_tip
        FROM sequences
        WHERE id = ?
    ]])
    assert(query, "load_sequence_undo_position: failed to prepare query (schema mismatch?)")

    query:bind_value(1, sequence_id)
    local has_row = false
    local cursor_value, tip_value = nil, nil
    if query:exec() and query:next() then
        has_row = true
        cursor_value = query:value(0)
        tip_value = query:value(1)
    end
    query:finalize()
    return cursor_value, tip_value, has_row
end

function M.initialize_stack_position_from_db(stack_id, sequence_id)
    if not sequence_id or sequence_id == "" then
        return
    end

    local saved_value, saved_tip, has_row = M.load_sequence_undo_position(sequence_id)
    local state = M.ensure_stack_state(stack_id)
    -- Seed CAS baseline from the raw DB column. Subsequent save_undo_position
    -- calls will use this as the expected-prev value. Captured BEFORE the
    -- orphan-repair path below so a stale row gets caught next save.
    state.persisted_seq_cursor = has_row and saved_value or nil
    -- Seed the in-memory tip from DB. nil/0 is "no branch tip recorded" —
    -- equivalent to "user is at the leaf (or no history)". Real tip values
    -- only appear after a commit (which sets cursor=tip=new_seq_number).
    if has_row and saved_tip and saved_tip > 0 then
        state.current_branch_tip = saved_tip
    else
        state.current_branch_tip = nil
    end

    -- NSF: Validate that saved cursor points to an existing command
    -- If orphaned (e.g., commands table was cleared), reset to actual last command
    if saved_value and saved_value > 0 then
        local check = db:prepare("SELECT 1 FROM commands WHERE sequence_number = ?")
        assert(check, "initialize_stack_position_from_db: failed to prepare orphan check query")
        check:bind_value(1, saved_value)
        local exists = check:exec() and check:next()
        check:finalize()
        if not exists then
            log.warn("Orphaned undo cursor: sequence %s has current_sequence_number=%d but command doesn't exist. Resetting to %s.",
                sequence_id, saved_value, last_sequence_number > 0 and tostring(last_sequence_number) or "nil")
            saved_value = last_sequence_number > 0 and last_sequence_number or nil
            -- Persist the orphan-repair. CAS against the stale value we
            -- just read (state.persisted_seq_cursor) — load_sequence_undo_position
            -- always seeded it above when has_row is true, which it must
            -- be here (we observed saved_value > 0). If the row was
            -- moved by a sibling writer between the read and now, fail
            -- loudly rather than silently overwrite.
            assert(state.persisted_seq_cursor ~= nil, string.format(
                "initialize_stack_position_from_db: orphan-repair entered with "
                .. "no CAS baseline for sequence %s (load_sequence_undo_position "
                .. "should have seeded persisted_seq_cursor; row existence is "
                .. "implied by saved_value=%s > 0)", sequence_id, tostring(saved_value)))
            local fix = assert(db:prepare(
                "UPDATE sequences SET current_sequence_number = ? WHERE id = ? AND current_sequence_number = ?"),
                "initialize_stack_position_from_db: failed to prepare orphan fix query")
            fix:bind_value(1, saved_value or 0)
            fix:bind_value(2, sequence_id)
            fix:bind_value(3, state.persisted_seq_cursor)
            local ok = fix:exec()
            fix:finalize()
            assert(ok, string.format(
                "initialize_stack_position_from_db: failed to persist orphan fix for sequence %s",
                sequence_id))
            assert(db:changes() == 1, string.format(
                "initialize_stack_position_from_db: orphan-repair UPDATE for sequence %s "
                .. "found cursor changed by another writer (expected_prev=%s). Re-init required.",
                sequence_id, tostring(state.persisted_seq_cursor)))
            state.persisted_seq_cursor = saved_value or 0
        end
        M.set_current_sequence_number(saved_value)
    elseif saved_value == 0 then
        M.set_current_sequence_number(nil)
    elseif has_row then
        if last_sequence_number > 0 then
            M.set_current_sequence_number(last_sequence_number)
        else
            M.set_current_sequence_number(nil)
        end
    else
        M.set_current_sequence_number(nil)
    end

    state.position_initialized = true
end

-- Invalidate the optimistic-CAS baselines so the next write is a
-- first-touch (unguarded, baseline-seeding) write. Call this from paths
-- that just rolled the DB back to a savepoint — the rollback unwinds
-- any in-progress cursor write but `persisted_*_cursor` is pure in-memory
-- state that the savepoint can't touch, so the next CAS would compare
-- against a stale "we wrote X" value and assert.
function M.invalidate_cas_baseline()
    for _, state in pairs(undo_stack_states) do
        state.persisted_seq_cursor = nil
        state.persisted_global_cursor = nil
    end
end

-- Save current undo position to database (persists across sessions).
--
-- Uses optimistic CAS: the UPDATE's WHERE clause pins the expected previous
-- column value to `state.persisted_seq_cursor`. If a sibling session (or
-- direct DB poke) moved the cursor since we last read/wrote, db:changes()
-- returns 0 and we assert with context so the caller can re-read and
-- recover. Silent last-write-wins would let two sessions desync the
-- cursor and resurface stale-redo bugs.
function M.save_undo_position()
    assert(db, "CommandHistory.save_undo_position: no database connection")

    local sequence_id = M.get_current_stack_sequence_id(true)
    assert(sequence_id and sequence_id ~= "",
        "CommandHistory.save_undo_position: no active sequence_id")

    local state = M.ensure_stack_state(active_stack_id)
    local expected_prev = state.persisted_seq_cursor
    local new_cursor = current_sequence_number or 0
    -- Persist tip atomically with cursor in the same UPDATE. nil tip
    -- means "no branch leaf recorded" → write 0 (column DEFAULT). Commit
    -- paths set state.current_branch_tip before this call; undo/redo
    -- paths leave it alone (tip stays at the last commit's leaf).
    local new_tip = state.current_branch_tip or 0

    -- First-touch (no baseline): unguarded write + seed baseline. We accept
    -- a tiny first-write race in exchange for not forcing every caller to
    -- load first. From the second write onward CAS protects against
    -- sibling-session drift, which is the case that actually bites.
    local sql, has_prev =
        "UPDATE sequences SET current_sequence_number = ?, current_undo_tip = ? WHERE id = ?",
        false
    if expected_prev ~= nil then
        sql = "UPDATE sequences SET current_sequence_number = ?, current_undo_tip = ? "
            .. "WHERE id = ? AND current_sequence_number = ?"
        has_prev = true
    end

    local update = assert(db:prepare(sql),
        "CommandHistory.save_undo_position: failed to prepare update")
    update:bind_value(1, new_cursor)
    update:bind_value(2, new_tip)
    update:bind_value(3, sequence_id)
    if has_prev then update:bind_value(4, expected_prev) end
    local exec_ok = update:exec()
    update:finalize()
    assert(exec_ok, string.format(
        "CommandHistory.save_undo_position: UPDATE failed for sequence %s",
        tostring(sequence_id)))

    if has_prev then
        assert(db:changes() == 1, string.format(
            "CommandHistory.save_undo_position: cursor moved by another writer "
            .. "(sequence=%s expected_prev=%s new=%d). Re-read DB and retry.",
            tostring(sequence_id), tostring(expected_prev), new_cursor))
    end

    state.persisted_seq_cursor = new_cursor
    return true
end

function M.find_latest_child_command(parent_sequence)
    assert(db, "find_latest_child_command: no database connection")

    local query = db:prepare([[
        SELECT sequence_number, command_type, command_args
        FROM commands
        WHERE parent_sequence_number IS ? OR (parent_sequence_number IS NULL AND ? = 0)
        ORDER BY sequence_number DESC
        LIMIT 1
    ]])
    assert(query, "find_latest_child_command: failed to prepare query (schema mismatch?)")

    query:bind_value(1, parent_sequence)
    query:bind_value(2, parent_sequence)

    local command = nil
    local json = require("dkjson")  -- Use dkjson (already used elsewhere in codebase)

    local ok = query:exec()
    if ok and query:next() then
        local args_json = query:value(2)
        local args = nil

        -- Decode JSON if present
        if args_json and args_json ~= "" then
            local decode_ok, decoded = pcall(json.decode, args_json)
            if decode_ok then
                args = decoded
            else
                log.warn("Failed to decode command args JSON: %s", tostring(decoded))
            end
        end

        command = {
            sequence_number = query:value(0),
            command_type = query:value(1),
            command_args = args
        }
    end
    query:finalize()
    return command
end

--- Find all sequence_numbers in an undo group, bounded by a cursor position.
-- @param group_id  The undo_group_id to match
-- @param up_to_seq  Only include sequence_numbers <= this value (for undo)
--                   Pass nil to include all members (for redo, caller filters)
-- @param after_seq  Only include sequence_numbers > this value (for redo)
--                   Pass nil to skip lower bound (for undo)
-- @return array of sequence_numbers (DESC when up_to_seq set, ASC when after_seq set)
function M.find_group_members(group_id, up_to_seq, after_seq)
    assert(db, "find_group_members: no database connection")
    if not group_id then
        return {}
    end
    local sql
    local bind_count
    if up_to_seq and after_seq then
        sql = [[SELECT sequence_number FROM commands
                WHERE undo_group_id = ? AND sequence_number <= ? AND sequence_number > ?
                ORDER BY sequence_number DESC]]
        bind_count = 3
    elseif up_to_seq then
        sql = [[SELECT sequence_number FROM commands
                WHERE undo_group_id = ? AND sequence_number <= ?
                ORDER BY sequence_number DESC]]
        bind_count = 2
    elseif after_seq then
        sql = [[SELECT sequence_number FROM commands
                WHERE undo_group_id = ? AND sequence_number > ?
                ORDER BY sequence_number ASC]]
        bind_count = 2
    else
        sql = [[SELECT sequence_number FROM commands
                WHERE undo_group_id = ?
                ORDER BY sequence_number DESC]]
        bind_count = 1
    end
    local query = db:prepare(sql)
    assert(query, "find_group_members: failed to prepare SQL (schema mismatch?)")
    query:bind_value(1, group_id)
    if bind_count == 3 then
        query:bind_value(2, up_to_seq)
        query:bind_value(3, after_seq)
    elseif bind_count == 2 then
        query:bind_value(2, up_to_seq or after_seq)
    end
    local results = {}
    if query:exec() then
        while query:next() do
            results[#results + 1] = query:value(0)
        end
    end
    query:finalize()
    return results
end

-- Undo group management (Emacs-style)
-- group_id is optional - if not provided, a unique ID is generated
-- When called from within a command executor, pass the parent command's sequence_number
function M.begin_undo_group(label, group_id)
    if not group_id then
        -- Allocate from the sequence number counter to guarantee uniqueness
        -- with automatic undo_group_ids (which are also sequence numbers).
        last_sequence_number = last_sequence_number + 1
        group_id = last_sequence_number
    end
    table.insert(undo_group_stack, {
        id = group_id,
        label = label or ("group_" .. tostring(group_id)),
        cursor_on_entry = current_sequence_number  -- Save cursor for rollback
    })
    log.event("Begin undo group %s: %s", tostring(group_id), label or "")
    return group_id
end

function M.end_undo_group()
    if #undo_group_stack == 0 then
        -- NSF-OK: mismatch can happen if error unwinds during group; callers handle nil return
        log.warn("end_undo_group called with no active group")
        return nil
    end
    local group = table.remove(undo_group_stack)
    log.event("End undo group %s: %s", tostring(group.id), group.label)
    return group.id
end

function M.get_current_undo_group_id()
    if #undo_group_stack == 0 then
        return nil
    end
    -- Nested groups collapse into outer group (Emacs semantics)
    return undo_group_stack[1].id
end

function M.get_undo_group_cursor_on_entry()
    if #undo_group_stack == 0 then
        return nil
    end
    -- Return cursor position from outermost group (Emacs semantics)
    return undo_group_stack[1].cursor_on_entry
end

--- Mark the current undo group as aborted. Subsequent execute() calls will be rejected.
function M.mark_undo_group_aborted()
    if #undo_group_stack > 0 then
        undo_group_stack[#undo_group_stack].aborted = true
        log.event("Undo group %s marked aborted", tostring(undo_group_stack[#undo_group_stack].id))
    end
end

--- Check if the current undo group has been aborted by a failed command.
function M.is_undo_group_aborted()
    if #undo_group_stack == 0 then return false end
    return undo_group_stack[#undo_group_stack].aborted == true
end

-- ==========================================================================
-- Per-Sequence Undo: Global cursor management
-- ==========================================================================

--- Get the global cursor from the projects table.
function M.get_global_cursor()
    local global_state = M.ensure_stack_state(GLOBAL_STACK_ID)
    return global_state.current_sequence_number
end

--- Set the global cursor (in-memory + DB persistence).
--
-- Uses optimistic CAS against `global_state.persisted_global_cursor`: a sibling
-- session (or external write) that moved the cursor since our last
-- confirmed value causes db:changes()=0 and we assert. Silent overwrite
-- would let two sessions stomp each other's global cursor.
function M.set_global_cursor(value)
    assert(db, "set_global_cursor: no database connection")
    assert(_active_project_id and _active_project_id ~= "",
        "set_global_cursor: no active project_id")
    local global_state = M.ensure_stack_state(GLOBAL_STACK_ID)
    local expected_prev = global_state.persisted_global_cursor
    local new_cursor = value or 0
    -- Persist tip atomically with cursor (single UPDATE). Commit paths
    -- set state.current_branch_tip on GLOBAL_STACK_ID before this call;
    -- undo/redo paths leave it alone so the tip stays at the last
    -- commit's leaf and remains redoable.
    local new_tip = global_state.current_branch_tip or 0

    -- First-touch (no baseline) = unguarded write that seeds the baseline;
    -- from the second write onward CAS guards against sibling-session
    -- drift. projects.global_undo_cursor is NOT NULL DEFAULT 0, so once
    -- load_global_cursor has run, expected_prev is a real number.
    local sql, has_prev =
        "UPDATE projects SET global_undo_cursor = ?, global_undo_tip = ? WHERE id = ?",
        false
    if expected_prev ~= nil then
        sql = "UPDATE projects SET global_undo_cursor = ?, global_undo_tip = ? "
            .. "WHERE id = ? AND global_undo_cursor = ?"
        has_prev = true
    end

    local update = assert(db:prepare(sql),
        "set_global_cursor: failed to prepare UPDATE")
    update:bind_value(1, new_cursor)
    update:bind_value(2, new_tip)
    update:bind_value(3, _active_project_id)
    if has_prev then update:bind_value(4, expected_prev) end
    local exec_ok = update:exec()
    update:finalize()
    assert(exec_ok, string.format(
        "set_global_cursor: UPDATE failed for project %s", _active_project_id))

    if has_prev then
        assert(db:changes() == 1, string.format(
            "set_global_cursor: cursor moved by another writer "
            .. "(project=%s expected_prev=%s new=%d). Re-read DB and retry.",
            _active_project_id, tostring(expected_prev), new_cursor))
    end

    global_state.current_sequence_number = value
    global_state.position_initialized = true
    global_state.persisted_global_cursor = new_cursor
end

--- Load the global cursor from the projects table on init.
--
-- Seeds `persisted_global_cursor` from the DB column verbatim — that is the
-- value against which the next set_global_cursor will CAS. Note that
-- in-memory `current_sequence_number` uses nil-for-zero semantics ("no
-- commands undone yet"), but `persisted_global_cursor` mirrors the raw column
-- so the CAS matches whatever is actually on disk.
function M.load_global_cursor()
    assert(db, "load_global_cursor: no database connection")
    assert(_active_project_id and _active_project_id ~= "",
        "load_global_cursor: no active project_id")
    local query = db:prepare(
        "SELECT global_undo_cursor, global_undo_tip FROM projects WHERE id = ?")
    assert(query, "load_global_cursor: failed to prepare SELECT")
    query:bind_value(1, _active_project_id)
    assert(query:exec(), "load_global_cursor: SELECT failed")
    local global_state = M.ensure_stack_state(GLOBAL_STACK_ID)
    assert(query:next(), string.format(
        "load_global_cursor: no project row for id=%s", _active_project_id))
    local cursor_val = query:value(0)
    local tip_val = query:value(1)
    if cursor_val and cursor_val > 0 then
        global_state.current_sequence_number = cursor_val
    else
        global_state.current_sequence_number = nil
    end
    if tip_val and tip_val > 0 then
        global_state.current_branch_tip = tip_val
    else
        global_state.current_branch_tip = nil
    end
    global_state.persisted_global_cursor = cursor_val or 0
    global_state.position_initialized = true
    query:finalize()
end

-- ==========================================================================
-- Per-Sequence Undo: Merged view for undo/redo walk
-- ==========================================================================

--- Get the cursor for a specific sequence's stack.
function M.get_sequence_cursor(sequence_id)
    if not sequence_id then return nil end
    local stack_id = M.stack_id_for_sequence(sequence_id)
    local state = undo_stack_states[stack_id]
    if state then
        return state.current_sequence_number
    end
    return nil
end

--- Find the next command to undo in the merged view (active sequence + global).
-- Returns the command row with the highest timestamp among:
--   - Active sequence's command at its cursor
--   - Global command at the global cursor
-- @param active_seq_id string: active sequence ID
-- @return table|nil: {sequence_number, command_type, sequence_id, timestamp, undo_group_id} or nil
function M.find_merged_undo_target(active_seq_id)
    if not db then return nil end

    local seq_cursor = M.get_sequence_cursor(active_seq_id)
    local global_cursor = M.get_global_cursor()

    -- Fetches are scope-filtered: a sequence cursor can hold a value
    -- pointing at a global command (move_cursor_for_undo follows
    -- parent_sequence_number across stacks). Without the filter, that
    -- cross-stack placeholder would be picked as a sequence-stack target.
    local function parse_row(q, cursor)
        local ts = q:value(3)
        assert(ts, string.format(
            "find_merged_undo_target: command at seq=%d has NULL timestamp", cursor))
        return {
            sequence_number = q:value(0),
            command_type    = q:value(1),
            sequence_id     = q:value(2),
            timestamp       = ts,
            undo_group_id   = q:value(4),
        }
    end

    local function fetch_sequence_command_at(cursor)
        assert(active_seq_id and active_seq_id ~= "",
            "find_merged_undo_target: sequence fetch requires active_seq_id")
        local q = db:prepare([[
            SELECT sequence_number, command_type, sequence_id, timestamp, undo_group_id
            FROM commands WHERE sequence_number = ?
              AND sequence_id = ?
              AND command_type NOT LIKE 'Undo%'
        ]])
        assert(q, "find_merged_undo_target: failed to prepare sequence query")
        q:bind_value(1, cursor)
        q:bind_value(2, active_seq_id)
        local cmd
        if q:exec() and q:next() then cmd = parse_row(q, cursor) end
        q:finalize()
        return cmd
    end

    local function fetch_global_command_at(cursor)
        local q = db:prepare([[
            SELECT sequence_number, command_type, sequence_id, timestamp, undo_group_id
            FROM commands WHERE sequence_number = ?
              AND sequence_id IS NULL
              AND command_type NOT LIKE 'Undo%'
        ]])
        assert(q, "find_merged_undo_target: failed to prepare global query")
        q:bind_value(1, cursor)
        local cmd
        if q:exec() and q:next() then cmd = parse_row(q, cursor) end
        q:finalize()
        return cmd
    end

    local seq_cmd, global_cmd
    if seq_cursor and seq_cursor > 0 and active_seq_id and active_seq_id ~= "" then
        seq_cmd = fetch_sequence_command_at(seq_cursor)
    end
    if global_cursor and global_cursor > 0 then
        global_cmd = fetch_global_command_at(global_cursor)
    end

    -- Pick by sequence_number (monotonically assigned; timestamps only
    -- have second resolution, so same-second commands would tie-break
    -- wrong if compared by timestamp alone).
    if not seq_cmd then return global_cmd end
    if not global_cmd then return seq_cmd end
    if seq_cmd.sequence_number >= global_cmd.sequence_number then
        return seq_cmd
    end
    return global_cmd
end

--- Find the next command to redo in the merged view.
--
-- The redo target on each scope (per-sequence, global) is the immediate
-- child of `cursor` on the path toward `tip`. Walking the parent chain
-- from tip toward cursor and returning the node whose parent == cursor
-- gives that child deterministically — branches that the user moved
-- away from (orphans) are NOT reachable because they aren't on the
-- cursor→tip path.
--
-- @param active_seq_id string: active sequence ID
-- @return table|nil: {sequence_number, command_type, sequence_id, timestamp, undo_group_id}
function M.find_merged_redo_target(active_seq_id)
    if not db then return nil end

    -- Compute (cursor, tip) for both scopes.
    local seq_cursor = M.get_sequence_cursor(active_seq_id) or 0
    local global_cursor = M.get_global_cursor() or 0

    local seq_state = active_seq_id and undo_stack_states[M.stack_id_for_sequence(active_seq_id)]
    local seq_tip = seq_state and seq_state.current_branch_tip or 0
    local global_tip = undo_stack_states[GLOBAL_STACK_ID]
        and undo_stack_states[GLOBAL_STACK_ID].current_branch_tip or 0

    -- Walk the parent chain from `tip` upward, collecting only rows that
    -- match this scope (per-seq sequence_id OR global sequence_id IS NULL).
    -- Cross-scope ancestors are walked THROUGH but not collected — a
    -- per-sequence chain often roots at a global command (Import,
    -- RelinkClips, etc.); the per-seq scope's "branch" is the subsequence
    -- of scope-matching commands within the parent chain.
    --
    -- Once the walk completes (root reached), the redo target is:
    --   * cursor == 0: the deepest scope-matching command (last in collected
    --                  list; closest to root) — nothing applied yet on this
    --                  scope, redo the first.
    --   * cursor == N: the scope-matching command immediately above N in the
    --                  collected list (closer to tip). If N isn't in the
    --                  list, the cursor sits on a stale path — return nil
    --                  (no valid redo).
    local function fetch_command_row(seq_num)
        local q = assert(db:prepare([[
            SELECT sequence_number, parent_sequence_number, command_type,
                   sequence_id, timestamp, undo_group_id
            FROM commands WHERE sequence_number = ?
        ]]), "find_merged_redo_target: failed to prepare row fetch")
        q:bind_value(1, seq_num)
        local row = nil
        if q:exec() and q:next() then
            row = {
                sequence_number = q:value(0),
                parent          = q:value(1),
                command_type    = q:value(2),
                sequence_id     = q:value(3),
                timestamp       = q:value(4),
                undo_group_id   = q:value(5),
            }
        end
        q:finalize()
        return row
    end

    local function pack(row)
        return {
            sequence_number = row.sequence_number,
            command_type    = row.command_type,
            sequence_id     = row.sequence_id,
            timestamp       = assert(row.timestamp, string.format(
                "find_merged_redo_target: row at seq=%d has NULL timestamp",
                row.sequence_number)),
            undo_group_id   = row.undo_group_id,
        }
    end

    -- Walk tip→root collecting scope-matching rows in tip-first order.
    -- The redo target is the scope-matching row whose
    -- `parent_sequence_number == cursor`. The cursor can validly point at
    -- a row on a DIFFERENT scope (because parent_sequence_number forms a
    -- single tree across scopes — the global cursor often lands on a
    -- per-sequence command after undoing a global command whose parent
    -- was on the sequence stack, and vice versa). So we match by parent
    -- equality, not by position-in-collected.
    --
    -- cursor==0 case: any row whose parent_sequence_number IS NULL or 0
    -- counts (root of the tree). Among multiple such candidates on the
    -- path (rare; would require multiple scope-matching rows that all
    -- root the tree), prefer the one closest to tip — that's the user's
    -- current branch.
    local function find_child_toward_tip(cursor, tip, scope_matches)
        if tip == 0 or tip <= cursor then return nil end
        local seq = tip
        while seq and seq > 0 do
            local row = fetch_command_row(seq)
            if not row then break end
            local parent = row.parent or 0
            if scope_matches(row)
                and not row.command_type:match("^Undo")
                and parent == cursor then
                return pack(row)
            end
            seq = row.parent  -- nil when row.parent is NULL → loop exits
        end
        return nil
    end

    local function seq_scope(row) return row.sequence_id == active_seq_id end
    local function global_scope(row) return row.sequence_id == nil end

    local seq_child = active_seq_id
        and find_child_toward_tip(seq_cursor, seq_tip, seq_scope)
        or nil
    local global_child = find_child_toward_tip(global_cursor, global_tip, global_scope)

    -- Merge tie-break: both candidates are now legitimate on-branch
    -- redos (the orphan-resurrection class is gone). Picking the lower
    -- sequence_number matches the pre-tip behavior and is the small
    -- ergonomic question we deferred — fix later if the asymmetry with
    -- find_merged_undo_target bites in practice.
    if seq_child and global_child then
        if global_child.sequence_number < seq_child.sequence_number then
            return global_child
        else
            return seq_child
        end
    end
    return seq_child or global_child
end

--- Move the appropriate cursor after an undo.
-- If the command is sequence-scoped, move the sequence cursor.
-- If the command is global (sequence_id IS NULL), move the global cursor.
function M.move_cursor_for_undo(cmd)
    assert(cmd, "move_cursor_for_undo: cmd required")
    assert(cmd.sequence_number, string.format(
        "move_cursor_for_undo: cmd missing sequence_number (type=%s)",
        tostring(cmd.type)))
    -- parent_sequence_number can be nil (undoing the very first command)
    if cmd.sequence_id then
        local stack_id = M.stack_id_for_sequence(cmd.sequence_id)
        local state = M.ensure_stack_state(stack_id)
        state.current_sequence_number = cmd.parent_sequence_number
        state.position_initialized = true
        if stack_id == active_stack_id then
            current_sequence_number = cmd.parent_sequence_number
        end
    else
        M.set_global_cursor(cmd.parent_sequence_number)
    end
end

--- Move the appropriate cursor after a redo.
function M.move_cursor_for_redo(cmd)
    assert(cmd, "move_cursor_for_redo: cmd required")
    assert(cmd.sequence_number, string.format(
        "move_cursor_for_redo: cmd missing sequence_number (type=%s)",
        tostring(cmd.type)))
    if cmd.sequence_id then
        local stack_id = M.stack_id_for_sequence(cmd.sequence_id)
        local state = M.ensure_stack_state(stack_id)
        state.current_sequence_number = cmd.sequence_number
        state.position_initialized = true
        if stack_id == active_stack_id then
            current_sequence_number = cmd.sequence_number
        end
    else
        M.set_global_cursor(cmd.sequence_number)
    end
end

--- sequence_number of the most recent done command in the merged view
--- (active sequence + global), or 0 if nothing can be undone. Uses the
--- same scope filter as find_merged_undo_target so a jump loop can't
--- overrun what M.undo() consumes.
function M.merged_current_sequence_number(active_seq_id)
    local target = M.find_merged_undo_target(active_seq_id)
    return target and target.sequence_number or 0
end

--- Check if undo is possible in the merged view.
function M.can_undo_merged(active_seq_id)
    return M.find_merged_undo_target(active_seq_id) ~= nil
end

--- Check if redo is possible in the merged view.
function M.can_redo_merged(active_seq_id)
    return M.find_merged_redo_target(active_seq_id) ~= nil
end

--- Get the active sequence ID.
function M.get_active_sequence_id()
    return active_sequence_id
end

return M
