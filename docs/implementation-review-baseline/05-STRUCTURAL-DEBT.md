# 05-STRUCTURAL-DEBT

## Duplicate Implementations

### Selection Snapshot Logic
**Locations**:
- `src/lua/core/command_manager.lua:358-373` - `capture_pre_selection_for_command()`, `capture_post_selection_for_command()`
- `src/lua/core/command_state.lua:58-84` - `capture_selection_snapshot()`

**Evidence**:
```lua
-- command_manager.lua:358-364
local function capture_pre_selection_for_command(command)
    local scope = profile_scope.begin("command_manager.capture_selection_pre")
    local clips_json, edges_json, gaps_json = state_mgr.capture_selection_snapshot()
    command.selected_clip_ids_pre = clips_json
    command.selected_edge_infos_pre = edges_json
    command.selected_gap_infos_pre = gaps_json
    scope:finish()
end

-- command_manager.lua:367-373
local function capture_post_selection_for_command(command)
    local scope = profile_scope.begin("command_manager.capture_selection_post")
    local clips_json, edges_json, gaps_json = state_mgr.capture_selection_snapshot()
    command.selected_clip_ids = clips_json
    command.selected_edge_infos = edges_json
    command.selected_gap_infos = gaps_json
    scope:finish()
end
```

**Issue**: Identical logic except for target field names (`*_pre` vs no suffix). Could be unified with parameter.

---

### Timeline Mutation Application
**Locations**:
- `src/lua/core/command_manager.lua:1056-1076` - `execute_redo_command()` mutation logic
- `src/lua/core/command_manager.lua:1171-1191` - `execute_undo()` mutation logic

**Evidence**:
```lua
-- execute_redo_command (lines 1056-1076)
local mutations = cmd:get_parameter("__timeline_mutations")
local applied_mutations = false

if mutations and timeline_state.apply_mutations then
    if mutations.sequence_id or mutations.inserts or mutations.updates or mutations.deletes then
        applied_mutations = timeline_state.apply_mutations(mutations.sequence_id or reload_sequence_id, mutations)
    else
        for _, bucket in pairs(mutations) do
            if timeline_state.apply_mutations(bucket.sequence_id or reload_sequence_id, bucket) then
                applied_mutations = true
            end
        end
    end
end

if not applied_mutations and reload_sequence_id and reload_sequence_id ~= "" then
    timeline_state.reload_clips(reload_sequence_id)
end

-- execute_undo (lines 1171-1191)
local mutations = original_command:get_parameter("__timeline_mutations")
local applied_mutations = false

if mutations and timeline_state.apply_mutations then
     if mutations.sequence_id or mutations.inserts or mutations.updates or mutations.deletes then
        applied_mutations = timeline_state.apply_mutations(mutations.sequence_id or reload_sequence_id, mutations)
     else
        for _, bucket in pairs(mutations) do
             if timeline_state.apply_mutations(bucket.sequence_id or reload_sequence_id, bucket) then
                applied_mutations = true
             end
        end
     end
end

if not applied_mutations and reload_sequence_id and reload_sequence_id ~= "" then
     timeline_state.reload_clips(reload_sequence_id)
end
```

**Issue**: Exact duplication across undo/redo paths. Should be extracted to helper function.

---

### Sequence ID Extraction
**Locations**:
- `src/lua/core/command_manager.lua:195-205` - `extract_sequence_id()`
- `src/lua/core/command_manager.lua:1058` - Inline extraction in `execute_redo_command()`
- `src/lua/core/command_manager.lua:1173` - Inline extraction in `execute_undo()`

**Evidence**:
```lua
-- Function at line 195
local function extract_sequence_id(command)
    if not command then return nil end
    if command.get_parameter then
        local value = command:get_parameter("sequence_id")
        if value and value ~= "" then return value end
    end
    if command.parameters and command.parameters.sequence_id and command.parameters.sequence_id ~= "" then
        return command.parameters.sequence_id
    end
    return nil
end

-- Inline usage at line 1058
local reload_sequence_id = extract_sequence_id(cmd)

-- Inline usage at line 1173
local reload_sequence_id = extract_sequence_id(original_command)
```

**Issue**: Function exists but pattern suggests it was added later. No inconsistency but shows evolution.

---

### Command Flag Checking
**Locations**:
- `src/lua/core/command_manager.lua:182-193` - `command_flag()`
- Multiple inline checks throughout file

**Evidence**:
```lua
-- Function at line 182
local function command_flag(command, property, param_key)
    if command[property] ~= nil then
        return command[property] and true or false
    end
    if command.get_parameter and param_key then
        local value = command:get_parameter(param_key)
        if value ~= nil then
            return value and true or false
        end
    end
    return false
end

-- Usage at line 560
local skip_selection_snapshot = command_flag(command, "skip_selection_snapshot", "__skip_selection_snapshot")

-- Usage at line 587
local suppress_noop_after = command_flag(command, "suppress_if_unchanged", "__suppress_if_unchanged")

-- Usage at line 627
local force_snapshot = command_flag(command, "force_snapshot", "__force_snapshot")
```

**Issue**: Inconsistent use of property vs parameter. Some checks inline, others via helper.

---

### Clip Query Construction
**Locations**:
- `src/lua/core/database.lua:693-708` - `load_clips()` query
- `src/lua/core/database.lua:743-757` - `load_clip_entry()` query

**Evidence**:
```sql
-- load_clips (lines 693-708)
SELECT c.id, c.project_id, s.project_id, c.clip_kind, c.name, c.track_id, c.media_id,
       c.source_sequence_id, c.parent_clip_id, c.owner_sequence_id,
       c.timeline_start_frame, c.duration_frames,
       c.source_in_frame, c.source_out_frame,
       c.enabled, c.offline, c.fps_numerator, c.fps_denominator, t.sequence_id,
       m.name, m.file_path,
       c.created_at, c.modified_at,
       s.fps_numerator, s.fps_denominator
FROM clips c
JOIN tracks t ON c.track_id = t.id
JOIN sequences s ON t.sequence_id = s.id
LEFT JOIN media m ON c.media_id = m.id
WHERE t.sequence_id = ?

-- load_clip_entry (lines 743-757)
SELECT c.id, c.project_id, s.project_id, c.clip_kind, c.name, c.track_id, c.media_id,
       c.source_sequence_id, c.parent_clip_id, c.owner_sequence_id,
       c.timeline_start_frame, c.duration_frames, c.source_in_frame, c.source_out_frame,
       c.enabled, c.offline, c.fps_numerator, c.fps_denominator,
       t.sequence_id, m.name, m.file_path,
       c.created_at, c.modified_at,
       s.fps_numerator, s.fps_denominator
FROM clips c
JOIN tracks t ON c.track_id = t.id
JOIN sequences s ON t.sequence_id = s.id
LEFT JOIN media m ON c.media_id = m.id
WHERE c.id = ?
```

**Issue**: Nearly identical SELECT clauses. Column order differs (line breaks). Both call `build_clip_from_query_row()`. Should use shared query fragment.

---

### Temp Gap Identifier Parsing
**Locations**:
- `src/lua/ui/timeline/state/timeline_core_state.lua:36-47` - `parse_temp_gap_identifier()`
- Likely duplicated in ripple code for gap materialization

**Evidence**:
```lua
-- timeline_core_state.lua:38-47
local function parse_temp_gap_identifier(clip_id)
    if type(clip_id) ~= "string" then return nil end
    if not clip_id:find("^" .. TEMP_GAP_PREFIX) then return nil end
    local payload = clip_id:sub(#TEMP_GAP_PREFIX + 1)
    local start_str, end_str = payload:match("_(%-?%d+)_(-?%d+)$")
    if not start_str or not end_str then return nil end
    local track_id = payload:sub(1, #payload - (#start_str + #end_str + 2))
    if not track_id or track_id == "" then return nil end
    return track_id, tonumber(start_str), tonumber(end_str)
end
```

**Issue**: Temp gap format `"temp_gap_{track_id}_{start}_{end}"` appears in multiple locations. Parsing logic should be centralized.

---

### Error Propagation Pattern
**Locations**:
- Multiple `xpcall` wrappers throughout `command_manager.lua`
- Lines 387-404, 1147-1158

**Evidence**:
```lua
-- Line 387-404 (execute_command_implementation)
local ok, result, err_msg = xpcall(
    executor,
    function(err)
        return debug.traceback(tostring(err), 2)
    end,
    command
)
if not ok then
    logger.error("command_manager", string.format("Executor failed (%s):\n%s", tostring(command and command.type), tostring(result)))
    last_error_message = tostring(result)
    scope:finish("executor_error")
    return false
end

-- Line 1147-1158 (execute_undo)
local ok, exec_result, extra = pcall(undoer, original_command)
if ok then
    local success, err_msg = normalize_executor_result(exec_result)
    if (not success) and (not err_msg or err_msg == "") and type(extra) == "string" then
        err_msg = extra
    end
    execution_success = success
    undo_error_message = err_msg or ""
else
    execution_success = false
    undo_error_message = tostring(exec_result)
end
```

**Issue**: Execute uses `xpcall` with traceback, undo uses `pcall` without. Inconsistent error handling.

---

## Dead Code

### Legacy Schema Migration
**Location**: `src/lua/core/command_manager.lua:158-180`

**Evidence**:
```lua
local function ensure_command_selection_columns()
    -- Delegated to database schema management in ideal world, keeping here for now
    -- but minimized.
    if not db then return end
    local pragma = db:prepare("PRAGMA table_info(commands)")
    if not pragma then return end

    local needed = {
        selected_clip_ids_pre = true, selected_edge_infos_pre = true,
        selected_gap_infos = true, selected_gap_infos_pre = true
    }
    
    if pragma:exec() then
        while pragma:next() do
            needed[pragma:value(1)] = nil
        end
    end
    pragma:finalize()

    for col, _ in pairs(needed) do
        db:exec("ALTER TABLE commands ADD COLUMN " .. col .. " TEXT DEFAULT '[]'")
    end
end
```

**Issue**: Comment says "keeping here for now". Schema v5.0 at `src/lua/schema.sql:171-192` already defines these columns. Migration code should be removed or moved to explicit migration system.

---

### Orphaned Test Commands
**Location**: `src/lua/core/command_manager.lua:405-409`

**Evidence**:
```lua
elseif command.type == "FastOperation" or
       command.type == "BatchOperation" or
       command.type == "ComplexOperation" then
    scope:finish("test_command")
    return true
```

**Issue**: Hardcoded test command types in production code. Should use test-only registry or mock system.

---

### Unused Parent ID Field
**Location**: `src/lua/schema.sql:173`

**Evidence**:
```sql
CREATE TABLE IF NOT EXISTS commands (
    id TEXT PRIMARY KEY,
    parent_id TEXT, -- For batch command relationships
    sequence_number INTEGER NOT NULL UNIQUE,
    ...
)
```

**Issue**: `parent_id` column defined but never queried. Batch commands use `parent_sequence_number` instead (line 177). Column appears orphaned.

---

### Redundant Stack State Initialization
**Location**: `src/lua/core/command_history.lua:66-79`

**Evidence**:
```lua
function M.reset()
    undo_stack_states = {
        [GLOBAL_STACK_ID] = {
            current_sequence_number = nil,
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
```

**Issue**: Module-level `undo_stack_states` initialized at line 18-25 with identical structure. `reset()` duplicates initialization. One should be removed or reference the other.

---

### Unused Timeline State Integration
**Location**: `src/lua/core/command_manager.lua:316-340`

**Evidence**:
```lua
-- Keep timeline_state IDs initialized so selection persistence doesn't assert during headless tests.
-- Only do this when the shared `core.database` connection matches this manager's DB handle.
local ok_db, db_module = pcall(require, "core.database")
local shared_conn = ok_db and db_module and db_module.get_connection and db_module.get_connection() or nil
if shared_conn and shared_conn == db then
    local seq_stmt = db:prepare("SELECT project_id FROM sequences WHERE id = ?")
    if seq_stmt then
        seq_stmt:bind_value(1, sequence_id)
        local found_project_id = nil
        if seq_stmt:exec() and seq_stmt:next() then
            found_project_id = seq_stmt:value(0)
        end
        seq_stmt:finalize()

        if found_project_id and found_project_id ~= "" then
            assert(found_project_id == project_id, ...)
            local ok_ts, timeline_state = pcall(require, "ui.timeline.timeline_state")
            if ok_ts and timeline_state and type(timeline_state.init) == "function" then
                timeline_state.init(sequence_id, project_id)
            end
        end
    end
end
```

**Issue**: Comment says "for headless tests" but production code path. Defensive `pcall` suggests uncertainty. If required, should not be optional. If test-only, should be in test harness.

---

## Missed Unification Opportunities

### Mutation Application Helper
**Current**: Duplicated at lines 1056-1076 (redo) and 1171-1191 (undo) in `command_manager.lua`

**Proposed**:
```lua
local function apply_command_mutations(command, reload_sequence_id)
    local mutations = command:get_parameter("__timeline_mutations")
    local applied_mutations = false
    
    if mutations and timeline_state.apply_mutations then
        if mutations.sequence_id or mutations.inserts or mutations.updates or mutations.deletes then
            applied_mutations = timeline_state.apply_mutations(mutations.sequence_id or reload_sequence_id, mutations)
        else
            for _, bucket in pairs(mutations) do
                if timeline_state.apply_mutations(bucket.sequence_id or reload_sequence_id, bucket) then
                    applied_mutations = true
                end
            end
        end
    end
    
    if not applied_mutations and reload_sequence_id and reload_sequence_id ~= "" then
        timeline_state.reload_clips(reload_sequence_id)
    end
    
    return applied_mutations
end
```

**Usage**:
```lua
-- In execute_redo_command
apply_command_mutations(cmd, reload_sequence_id)

-- In execute_undo
apply_command_mutations(original_command, reload_sequence_id)
```

---

### Selection Capture Unification
**Current**: Separate `capture_pre_selection_for_command()` and `capture_post_selection_for_command()` at lines 358-373

**Proposed**:
```lua
local function capture_selection_for_command(command, is_pre)
    local scope = profile_scope.begin("command_manager.capture_selection_" .. (is_pre and "pre" or "post"))
    local clips_json, edges_json, gaps_json = state_mgr.capture_selection_snapshot()
    
    local suffix = is_pre and "_pre" or ""
    command["selected_clip_ids" .. suffix] = clips_json
    command["selected_edge_infos" .. suffix] = edges_json
    command["selected_gap_infos" .. suffix] = gaps_json
    
    scope:finish()
end
```

**Usage**:
```lua
capture_selection_for_command(command, true)  -- Pre-snapshot
capture_selection_for_command(command, false) -- Post-snapshot
```

---

### Clip Query Fragments
**Current**: Duplicate SELECT clauses in `database.lua:693-708` and `743-757`

**Proposed**:
```lua
local CLIP_SELECT_COLUMNS = [[
    c.id, c.project_id, s.project_id, c.clip_kind, c.name, c.track_id, c.media_id,
    c.source_sequence_id, c.parent_clip_id, c.owner_sequence_id,
    c.timeline_start_frame, c.duration_frames,
    c.source_in_frame, c.source_out_frame,
    c.enabled, c.offline, c.fps_numerator, c.fps_denominator, t.sequence_id,
    m.name, m.file_path,
    c.created_at, c.modified_at,
    s.fps_numerator, s.fps_denominator
]]

local CLIP_FROM_JOINS = [[
    FROM clips c
    JOIN tracks t ON c.track_id = t.id
    JOIN sequences s ON t.sequence_id = s.id
    LEFT JOIN media m ON c.media_id = m.id
]]

function M.load_clips(sequence_id)
    local query = db_connection:prepare(
        "SELECT " .. CLIP_SELECT_COLUMNS .. " " ..
        CLIP_FROM_JOINS ..
        "WHERE t.sequence_id = ? ORDER BY c.timeline_start_frame ASC"
    )
    ...
end

function M.load_clip_entry(clip_id)
    local query = db_connection:prepare(
        "SELECT " .. CLIP_SELECT_COLUMNS .. " " ..
        CLIP_FROM_JOINS ..
        "WHERE c.id = ? LIMIT 1"
    )
    ...
end
```

---

### Error Handler Consolidation
**Current**: `xpcall` with traceback at line 387, `pcall` without traceback at line 1147

**Proposed**:
```lua
local function safe_call_executor(executor, command, error_prefix)
    local ok, result, extra = xpcall(
        executor,
        function(err)
            return debug.traceback(tostring(err), 2)
        end,
        command
    )
    
    if not ok then
        logger.error("command_manager", string.format("%s failed (%s):\n%s", 
            error_prefix, 
            tostring(command and command.type), 
            tostring(result)))
        return false, tostring(result)
    end
    
    local success, err_msg = normalize_executor_result(result, command)
    if not success and not err_msg and type(extra) == "string" then
        err_msg = extra
    end
    
    return success, err_msg or ""
end
```

**Usage**:
```lua
-- In execute_command_implementation
local success, error_message = safe_call_executor(executor, command, "Executor")

-- In execute_undo
local success, error_message = safe_call_executor(undoer, original_command, "Undoer")
```

---

### Temp Gap Identifier Module
**Current**: Parsing logic in `timeline_core_state.lua:38-47`, likely duplicated in ripple code

**Proposed**: Create `src/lua/core/temp_gap_utils.lua`
```lua
local M = {}

M.PREFIX = "temp_gap_"

function M.build_id(track_id, start_frames, end_frames)
    return string.format("%s%s_%d_%d", M.PREFIX, track_id, start_frames, end_frames)
end

function M.parse_id(clip_id)
    if type(clip_id) ~= "string" then return nil end
    if not clip_id:find("^" .. M.PREFIX) then return nil end
    
    local payload = clip_id:sub(#M.PREFIX + 1)
    local start_str, end_str = payload:match("_(%-?%d+)_(-?%d+)$")
    if not start_str or not end_str then return nil end
    
    local track_id = payload:sub(1, #payload - (#start_str + #end_str + 2))
    if not track_id or track_id == "" then return nil end
    
    return track_id, tonumber(start_str), tonumber(end_str)
end

function M.is_temp_gap(clip_id)
    return type(clip_id) == "string" and clip_id:find("^" .. M.PREFIX) ~= nil
end

return M
```

**Usage**:
```lua
-- timeline_core_state.lua
local temp_gap = require("core.temp_gap_utils")
local track_id, start_frames, end_frames = temp_gap.parse_id(edge.clip_id)

-- batch_ripple_edit.lua
local temp_id = temp_gap.build_id(track_id, start_frames, end_frames)
```

---

### Transaction Management Helper
**Current**: BEGIN/COMMIT/ROLLBACK scattered throughout `command_manager.lua`

**Proposed**:
```lua
local function with_transaction(db_conn, callback)
    local begin_tx = db_conn:prepare("BEGIN TRANSACTION")
    if not (begin_tx and begin_tx:exec()) then
        if begin_tx then begin_tx:finalize() end
        return false, "Failed to begin transaction"
    end
    begin_tx:finalize()
    
    local ok, result = pcall(callback)
    
    if ok then
        local commit_ok = db_conn:exec("COMMIT")
        if not commit_ok then
            db_conn:exec("ROLLBACK")
            return false, "Failed to commit transaction"
        end
        return true, result
    else
        db_conn:exec("ROLLBACK")
        return false, tostring(result)
    end
end
```

**Usage**:
```lua
local tx_ok, tx_result = with_transaction(db, function()
    -- Execute command implementation
    -- Capture snapshots
    -- Persist command
    return {success = true, result_data = ...}
end)
```

---

### Command Listener Notification
**Current**: Repeated listener notification blocks at lines 651-658, 1078-1083, 1199-1203

**Proposed**:
```lua
local function notify_command_lifecycle(event_type, command, extra_data)
    local event = {
        event = event_type,
        command = command,
        project_id = command.project_id,
        sequence_number = command.sequence_number
    }
    
    if extra_data then
        for k, v in pairs(extra_data) do
            event[k] = v
        end
    end
    
    notify_command_event(event)
end
```

**Usage**:
```lua
-- After execute
notify_command_lifecycle("executed", command)

-- After undo
notify_command_lifecycle("undo", original_command)

-- After redo
notify_command_lifecycle("redo", cmd)
```

---

## Summary Statistics

### Duplication
- **7 identified duplications**
- Largest: 20-line mutation application block (×2)
- Most fragile: SQL query columns (58 columns ×2)

### Dead Code
- **5 identified segments**
- Largest: 25-line timeline state integration (unclear purpose)
- Most misleading: Test command types in production executor

### Unification Opportunities
- **8 proposed extractions**
- Highest impact: Transaction management (used 3+ times)
- Cleanest win: Temp gap identifier module (clear interface)

### Maintenance Risk
- Selection capture: Low (simple duplication)
- Mutation application: Medium (complex logic, easy to diverge)
- Clip queries: High (schema changes break both)
- Error handling: High (inconsistent traceback capture)
