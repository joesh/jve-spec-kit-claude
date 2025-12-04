# Rational Migration & Critical Fixes - Completion Plan

**Status:** In Progress
**Created:** 2025-11-30
**Estimated Time:** 2.5 hours
**Branch:** timebase-rational-migration-attempt-4

## Executive Summary

This plan addresses 20 issues identified in code review:
- **5 Critical (Data Corruption Risk)** 🔴
- **10 High Priority** 🟠
- **5 Medium Priority** 🟡

The work preserves valuable architectural improvements (Qt bindings modularization, command manager refactoring) while fixing execution flaws that would cause data loss in production.

---

## Phase 1: Build Infrastructure (CRITICAL - 15 minutes)

### Task 1.1: Track qt_bindings refactor files ✓ CRITICAL
**Problem:** 12 untracked files in `src/lua/qt_bindings/` directory
**Impact:** Build fails for anyone checking out this branch

**Action:**
```bash
git add src/lua/qt_bindings/
git status  # Verify all 12 files tracked
```

**Files to track:**
- binding_macros.h
- control_bindings.cpp
- database_bindings.cpp (794 bytes)
- database_bindings.h
- dialog_bindings.cpp
- json_bindings.cpp
- layout_bindings.cpp
- menu_bindings.cpp
- misc_bindings.cpp
- signal_bindings.cpp
- view_bindings.cpp
- widget_bindings.cpp

**Verification:**
- `git ls-files src/lua/qt_bindings/` shows all 12 files
- CMakeLists.txt references these files in source list

---

## Phase 2: Database Integrity Fixes (CRITICAL - 30 minutes)

### Task 2.1: Fix SQL transaction rollback bug ✓ CRITICAL
**File:** `src/core/persistence/sql_executor.cpp:165-171`
**Issue:** Calling rollback after failed commit is undefined behavior

**Current (WRONG):**
```cpp
if (!database.commit()) {
    qCCritical(...);
    if (!database.rollback()) {  // ❌ Can't rollback after commit failure
        qCCritical(...);
    }
    return false;
}
```

**Fix:**
```cpp
if (!database.commit()) {
    qCCritical(jveSqlExecutor, "Failed to commit transaction: %s",
               qPrintable(database.lastError().text()));
    // Transaction already in error state - rollback is undefined behavior
    // Database driver will handle cleanup automatically
    return false;
}
```

**Testing:** Run `test_sql_transaction` to verify rollback still works on execution error.

---

### Task 2.2: Fix PRAGMA execution ✓ CRITICAL
**File:** `src/core/persistence/sql_executor.cpp:203-230`
**Issue:** PRAGMAs skipped entirely, so foreign keys never enabled, WAL mode never set

**Current approach (WRONG):**
```cpp
// Skip PRAGMA statements that can't be executed inside transactions
if (trimmed.toUpper().startsWith("PRAGMA ")) {
    qCDebug(..., "Skipping PRAGMA in transaction");
    continue;  // ❌ SKIPS ESSENTIAL DATABASE CONFIGURATION
}
```

**Fix - Split PRAGMA execution from transactional statements:**
```cpp
bool SqlExecutor::executeSqlScript(QSqlDatabase& database, const QString& scriptPath)
{
    QString script = loadScriptFromFile(scriptPath);
    if (script.isEmpty()) {
        qCWarning(jveSqlExecutor, "Script file is empty: %s", qPrintable(scriptPath));
        return false;
    }

    QStringList statements = parseStatementsFromScript(script);

    // Phase 1: Separate PRAGMAs from data statements
    QStringList pragmas;
    QStringList transactionalStatements;

    for (const QString& stmt : statements) {
        QString trimmed = stmt.trimmed();
        if (trimmed.toUpper().startsWith("PRAGMA ")) {
            pragmas.append(stmt);
        } else {
            transactionalStatements.append(stmt);
        }
    }

    // Phase 2: Execute PRAGMAs first (must be outside transaction)
    if (!pragmas.isEmpty()) {
        qCDebug(jveSqlExecutor, "Executing %d PRAGMA statements outside transaction", pragmas.size());
        if (!executeStatementBatch(database, pragmas, false)) {
            qCCritical(jveSqlExecutor, "Failed to execute PRAGMA statements");
            return false;
        }
    }

    // Phase 3: Execute data statements in transaction
    if (!transactionalStatements.isEmpty()) {
        qCDebug(jveSqlExecutor, "Executing %d statements in transaction", transactionalStatements.size());
        return executeStatementBatch(database, transactionalStatements, true);
    }

    return true;
}
```

**Rationale:**
- PRAGMAs like `foreign_keys=ON` must execute before BEGIN TRANSACTION
- Data modifications (CREATE, INSERT, UPDATE) need transaction protection
- Separating them preserves both safety and functionality

**Testing:** Verify foreign keys work by attempting to insert clip with non-existent track_id.

---

### Task 2.3: Add mutation validation ✓ HIGH PRIORITY
**File:** `src/lua/core/command_helper.lua:526-546`
**Issue:** No validation that clip_id exists before executing UPDATE

**Add before UPDATE preparation:**
```lua
if mut.type == "update" then
    -- Validate required fields
    if not mut.clip_id or mut.clip_id == "" then
        return false, "Mutation missing clip_id for UPDATE operation"
    end
    if not mut.timeline_start_frame then
        return false, string.format("Mutation for clip %s missing timeline_start_frame", mut.clip_id)
    end
    if not mut.duration_frames or mut.duration_frames <= 0 then
        return false, string.format("Mutation for clip %s has invalid duration: %s",
                                     mut.clip_id, tostring(mut.duration_frames))
    end

    local stmt = db:prepare([[
        UPDATE clips
        SET track_id = ?, timeline_start_frame = ?, duration_frames = ?,
            source_in_frame = ?, source_out_frame = ?, enabled = ?
        WHERE id = ?
    ]])
    -- ... rest of code
```

**Testing:** Create mutation with nil clip_id, verify error returned instead of silent failure.

---

## Phase 3: Clipboard Rational Serialization (CRITICAL - 45 minutes)

### Task 3.1: Implement Rational→JSON encoding ✓ CRITICAL
**File:** `src/lua/core/clipboard_actions.lua:1-20` (new helpers)
**Issue:** Rational objects (Lua tables with metatables) serialize as `{}` in JSON

**Create serialization helpers at top of file:**
```lua
local function serialize_rational(rational_obj)
    if not rational_obj then return nil end

    -- Rational objects have: frames, fps_numerator, fps_denominator
    -- Convert to plain table for JSON serialization
    return {
        frames = rational_obj.frames,
        num = rational_obj.fps_numerator,
        den = rational_obj.fps_denominator
    }
end

local function deserialize_rational(table_obj)
    if not table_obj or not table_obj.frames then return nil end

    local Rational = require("core.rational")
    return Rational.new(table_obj.frames, table_obj.num, table_obj.den)
end
```

**Fix copy operation (line 79-125):**
```lua
clip_payloads[#clip_payloads + 1] = {
    original_id = clip.id,
    track_id = clip.track_id,
    media_id = clip.media_id,
    parent_clip_id = clip.parent_clip_id,
    source_sequence_id = clip.source_sequence_id,
    owner_sequence_id = clip.owner_sequence_id,
    clip_kind = clip.clip_kind,

    -- Serialize Rational objects to plain tables for JSON
    timeline_start = serialize_rational(clip.timeline_start),
    duration = serialize_rational(clip.duration),
    source_in = serialize_rational(clip.source_in),
    source_out = serialize_rational(clip.source_out),

    name = clip.name,
    offline = clip.offline,
    copied_properties = load_clip_properties(clip.id)
}
```

**Update offset calculation to use serialized data:**
```lua
for _, entry in ipairs(clip_payloads) do
    entry.offset_frames = (entry.timeline_start and entry.timeline_start.frames or 0) - earliest_start_frame
end
```

**Testing:** Copy clip, inspect clipboard JSON, verify duration/timing fields present with frames/num/den.

---

### Task 3.2: Implement proper sequence frame rate detection ✓ CRITICAL
**File:** `src/lua/core/clipboard_actions.lua:140-160` (new function)
**Issue:** Hardcoded 30fps fallback wrong for 24fps, 25fps, 29.97fps projects

**Add sequence rate detection:**
```lua
local function get_active_sequence_rate()
    local timeline_state = require('ui.timeline.timeline_state')
    local database = require('core.database')
    local db = database.get_connection()

    if not db then
        print("WARNING: No database connection for sequence rate detection, defaulting to 30fps")
        return 30, 1
    end

    local sequence_id = timeline_state.get_sequence_id and timeline_state.get_sequence_id()
                        or "default_sequence"

    local query = db:prepare([[
        SELECT fps_numerator, fps_denominator
        FROM sequences
        WHERE id = ?
    ]])

    if not query then
        print("WARNING: Failed to prepare sequence rate query, defaulting to 30fps")
        return 30, 1
    end

    query:bind_value(1, sequence_id)
    if query:exec() and query:next() then
        local num = query:value(0)
        local den = query:value(1)
        query:finalize()

        -- Validate frame rate values
        if num and num > 0 and den and den > 0 then
            return num, den
        else
            print(string.format("WARNING: Invalid sequence frame rate %s/%s, defaulting to 30fps",
                                tostring(num), tostring(den)))
            return 30, 1
        end
    end

    query:finalize()
    print("WARNING: Sequence not found, defaulting to 30fps")
    return 30, 1
end
```

---

### Task 3.3: Fix clipboard paste Rational deserialization ✓ CRITICAL
**File:** `src/lua/core/clipboard_actions.lua:160-210`
**Issue:** Paste operation doesn't deserialize Rational objects from JSON

**Replace paste_timeline function:**
```lua
local function paste_timeline(payload)
    if payload.kind ~= "timeline_clips" then
        return false, "Clipboard doesn't contain timeline clips"
    end

    local timeline_state = require('ui.timeline.timeline_state')
    local uuid = require('core.uuid')
    local Command = require('core.command')
    local command_manager = require('core.command_manager')

    local project_id = (timeline_state.get_project_id and timeline_state.get_project_id())
        or payload.project_id or "default_project"

    local Rational = require("core.rational")
    local playhead_ms = (timeline_state.get_playhead_position and timeline_state.get_playhead_position()) or 0

    -- Get active sequence frame rate from database
    local seq_fps_num, seq_fps_den = get_active_sequence_rate()

    -- Convert playhead (milliseconds) to frames at sequence rate
    local playhead_frames = math.floor((playhead_ms / 1000.0) * (seq_fps_num / seq_fps_den))

    local clips = payload.clips or {}
    if #clips == 0 then
        return false, "Clipboard is empty"
    end

    local batch_specs = {}

    for _, clip_data in ipairs(clips) do
        if clip_data.track_id and (clip_data.media_id or clip_data.parent_clip_id) then

            -- Deserialize Rational objects from JSON tables
            local timeline_start = deserialize_rational(clip_data.timeline_start)
            local duration = deserialize_rational(clip_data.duration)
            local source_in = deserialize_rational(clip_data.source_in)
            local source_out = deserialize_rational(clip_data.source_out)

            if not timeline_start or not duration then
                print(string.format("WARNING: Skipping clip %s - missing timing data",
                                    clip_data.original_id or "unknown"))
                goto continue
            end

            -- Calculate offset from reference point
            local offset_frames = clip_data.offset_frames or 0
            local paste_start_frame = playhead_frames + offset_frames

            -- Create new Rational at paste position (preserving original clip's frame rate)
            local overwrite_time = Rational.new(
                paste_start_frame,
                timeline_start.num,
                timeline_start.den
            )

            local clip_id = uuid.generate()

            local spec = {
                type = "Overwrite",
                params = {
                    sequence_id = (timeline_state.get_sequence_id and timeline_state.get_sequence_id())
                                  or payload.sequence_id,
                    track_id = clip_data.track_id,
                    media_id = clip_data.media_id,
                    master_clip_id = clip_data.parent_clip_id,
                    overwrite_time = overwrite_time,
                    duration = duration,
                    source_in = source_in,
                    source_out = source_out,
                    clip_name = clip_data.name,
                    clip_id = clip_id,
                    copied_properties = clip_data.copied_properties,
                }
            }
            table.insert(batch_specs, spec)
        end
        ::continue::
    end

    -- Execute batch paste as single undo entry
    if #batch_specs > 0 then
        local command = Command.new({
            type = "BatchCommand",
            params = {
                commands_json = qt_json_encode(batch_specs)
            }
        })
        return command_manager.execute(command)
    end

    return false, "No valid clips to paste"
end
```

**Testing:**
1. Copy 3 clips from 24fps sequence
2. Paste into 30fps sequence
3. Verify timing preserved correctly
4. Check undo works (single undo removes all 3 clips)

---

## Phase 4: UUID & Debug Cleanup (HIGH PRIORITY - 20 minutes)

### Task 4.1: Document UUID collision detection removal
**File:** `src/core/common/uuid_generator.cpp:1-30` (add header comment)
**Issue:** Collision detection disabled without explanation

**Add documentation:**
```cpp
/*
 * UUID Collision Detection Status (2025-11-30)
 *
 * REMOVED: Global collision tracking via m_allGeneratedUuids set
 *
 * Rationale:
 * 1. Performance: QSet lookup is O(log n), set grew unbounded
 * 2. Memory: With 10K history limit, set consumed ~1MB per 100K UUIDs
 * 3. Collision probability: UUIDv5 uses SHA-1. For random 128-bit IDs:
 *    - Collision probability = n²/(2*2^128)
 *    - For 1 billion UUIDs: P < 1 in 2^98 (effectively zero)
 *    - For 1 million UUIDs: P < 1 in 2^108
 *
 * Risk Assessment:
 * - Acceptable for editor workload (< 1M entities per project lifetime)
 * - Database UNIQUE constraints provide backup protection
 * - SQLite will reject duplicate UUIDs with constraint error
 * - Error logged via jveDatabase category if collision occurs
 *
 * Monitoring:
 * - Generation statistics tracked via m_generationCounts
 * - Per-type history maintained (last 100 UUIDs per entity type)
 * - Performance metrics available via getPerformanceMetrics()
 *
 * Future: If collision detection needed for debugging, implement bloom filter
 * (95% accuracy, 1% memory footprint of exact set)
 */
```

**Alternative (if paranoid):** Restore lightweight collision detection with circular buffer:
```cpp
// uuid_generator.h
class UuidGenerator {
    static constexpr int COLLISION_CHECK_WINDOW = 10000;
    QList<QString> m_recentUuids;  // Circular buffer
    int m_recentUuidsHead = 0;

    // ... rest of class
};

// uuid_generator.cpp
bool UuidGenerator::checkForCollision(const QString& uuid) const
{
    return m_recentUuids.contains(uuid);
}

void UuidGenerator::recordGeneratedUuid(const QString& uuid, EntityType type)
{
    // ... existing per-type history code ...

    // Circular buffer for recent UUIDs
    if (m_recentUuids.size() < COLLISION_CHECK_WINDOW) {
        m_recentUuids.append(uuid);
    } else {
        m_recentUuids[m_recentUuidsHead] = uuid;
        m_recentUuidsHead = (m_recentUuidsHead + 1) % COLLISION_CHECK_WINDOW;
    }
}
```

**Testing:** Generate 1M UUIDs in loop, verify no duplicates reported.

---

### Task 4.2: Remove debug output from hot paths
**File:** `src/lua/core/command_helper.lua:526`
**Issue:** Debug print in mutation apply path (called on every clip modification)

**Change:**
```lua
-- REMOVE this line entirely (line 526):
print(string.format("DEBUG: Mutation %s id=%s start=%s dur=%s", ...))

-- Replace with conditional debug output:
if os.getenv("JVE_DEBUG_MUTATIONS") == "1" then
    print(string.format("DEBUG: Mutation %s id=%s start=%s dur=%s",
          mut.type, tostring(mut.clip_id),
          tostring(mut.timeline_start_frame),
          tostring(mut.duration_frames)))
end
```

**Testing:**
1. Execute any command that modifies clips
2. Verify no console output
3. Set `export JVE_DEBUG_MUTATIONS=1` and re-run
4. Verify debug output appears

---

## Phase 5: Medium Priority Fixes (30 minutes)

### Task 5.1: Fix duplicate field assignments
**File:** `src/lua/core/clip_mutator.lua:67, 343, 393`
**Issue:** Code maintains both `start_value` and `timeline_start` creating confusion

**Decision:**
- **Database schema uses:** `timeline_start_frame` (integer, frames)
- **Lua hydrated objects use:** `timeline_start` (Rational object)
- **DEPRECATED:** `start_value` (legacy field)

**Changes:**
```lua
-- Line 67 - Remove start_value fallback:
local function plan_update(row, original)
    return {
        type = "update",
        clip_id = row.id,
        track_id = row.track_id,
        timeline_start_frame = get_frames(row.timeline_start),  -- Remove "or row.start_value"
        duration_frames = get_frames(row.duration),
        -- ... rest
    }
end

-- Line 343 - Remove start_value assignment:
row.timeline_start = target_start
-- DELETE: row.start_value = target_start

-- Line 393 - Remove start_value assignment:
{
    timeline_start = target_right_start,
    -- DELETE: start_value = target_right_start,
    duration = right_duration,
    -- ... rest
}
```

**Testing:** Clip occlusion test should still pass after removing start_value references.

---

### Task 5.2: Fix command_history JSON dependency
**File:** `src/lua/core/command_history.lua:304-318`
**Issue:** Trying to require qt_constants for JSON decode (wrong module)

**Fix:**
```lua
function M.find_latest_child_command(parent_sequence)
    if not db then
        return nil
    end

    local query = db:prepare([[
        SELECT sequence_number, command_type, command_args
        FROM commands
        WHERE parent_sequence_number IS ? OR (parent_sequence_number IS NULL AND ? = 0)
        ORDER BY sequence_number DESC
        LIMIT 1
    ]])

    if not query then
        return nil
    end

    query:bind_value(1, parent_sequence)
    query:bind_value(2, parent_sequence)

    local command = nil
    local json = require("dkjson")  -- FIX: Use dkjson (already used elsewhere)

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
                print(string.format("WARNING: Failed to decode command args JSON: %s", tostring(decoded)))
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
```

**Testing:** Execute command, undo, redo - verify redo finds correct child command.

---

### Task 5.3: Add error logging to command registry
**File:** `src/lua/core/command_registry.lua:52-66`
**Issue:** Module loading failures silent, no diagnostic info

**Fix:**
```lua
function M.load_command_module(command_type)
    -- Convert CamelCase to snake_case for file path
    local filename = command_type:gsub("%u", function(c) return "_" .. c:lower() end):sub(2)
    local module_path = "core.commands." .. filename

    local status, mod = pcall(require, module_path)
    if not status then
        print(string.format("ERROR: Failed to load command module '%s': %s",
                            module_path, tostring(mod)))
        return false
    end

    if type(mod) ~= "table" then
        print(string.format("ERROR: Command module '%s' did not return a table (got %s)",
                            module_path, type(mod)))
        return false
    end

    if not mod.register then
        print(string.format("ERROR: Command module '%s' missing register() function", module_path))
        return false
    end

    local registered = mod.register(command_executors, command_undoers, db, error_handler)
    if not registered then
        print(string.format("ERROR: Command module '%s' register() returned nil", module_path))
        return false
    end

    if not registered.executor then
        print(string.format("ERROR: Command module '%s' register() missing executor function", module_path))
        return false
    end

    M.register_executor(command_type, registered.executor, registered.undoer)
    print(string.format("INFO: Loaded command module '%s'", command_type))
    return true
end
```

**Testing:** Trigger auto-load of command (e.g., execute ImportMedia), verify log shows module load.

---

### Task 5.4: Fix CMakeLists.txt test integration
**File:** `CMakeLists.txt:154-184`
**Issue:** Tests not integrated with CTest, run on every build (slow)

**Replace:**
```cmake
# Unit tests
add_executable(test_sql_transaction tests/unit/test_sql_transaction.cpp)
target_link_libraries(test_sql_transaction JVECore Qt6::Test Qt6::Sql)
target_link_directories(test_sql_transaction PRIVATE ${LUAJIT_LIBRARY_DIRS})
set_target_properties(test_sql_transaction PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
)
add_test(NAME test_sql_transaction COMMAND test_sql_transaction)

# Lua test suite integration
add_test(NAME lua_regression_suite
    COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_lua_tests.sh
    WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
)
set_tests_properties(lua_regression_suite PROPERTIES
    TIMEOUT 300  # 5 minutes max
    LABELS "regression"
)

# Optional: Run Lua tests during build (disabled by default)
option(RUN_LUA_TESTS_ON_BUILD "Run Lua tests as part of default build target" OFF)
if(RUN_LUA_TESTS_ON_BUILD)
    add_custom_target(run_lua_tests ALL
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/run_lua_tests.sh
        WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
        COMMENT "Running Lua regression tests..."
        DEPENDS JVEEditor  # Only run if build succeeds
        VERBATIM
    )
endif()
```

**Usage:**
- Default: `make` builds without running tests
- Run tests: `ctest` or `make test`
- Enable build-time tests: `cmake -DRUN_LUA_TESTS_ON_BUILD=ON ..`

**Testing:** Run `ctest -V` to verify both C++ and Lua tests discovered.

---

### Task 5.5: Fix test_sql_transaction file handling
**File:** `tests/unit/test_sql_transaction.cpp:28-52`
**Issue:** QTemporaryFile closes before execution, file deleted

**Fix:**
```cpp
void testTransactionRollback()
{
    // Setup in-memory DB
    QString dbName = "test_transaction_db";
    {
        QSqlDatabase db = QSqlDatabase::addDatabase("QSQLITE", dbName);
        db.setDatabaseName(":memory:");
        QVERIFY(db.open());

        QSqlQuery query(db);
        QVERIFY(query.exec("CREATE TABLE test (id INTEGER PRIMARY KEY, val TEXT);"));
    }

    QSqlDatabase db = QSqlDatabase::database(dbName);

    // Create script file
    QTemporaryFile scriptFile;
    scriptFile.setAutoRemove(false);  // FIX: Don't delete until we're done

    if (!scriptFile.open()) {
        QFAIL("Failed to open temporary file");
    }
    QString scriptPath = scriptFile.fileName();

    QTextStream stream(&scriptFile);
    stream << "INSERT INTO test (id, val) VALUES (1, 'A');\n";
    stream << "---- GO ----\n";
    stream << "INSERT INTO test (id, val) VALUES (2, 'B');\n";
    stream << "---- GO ----\n";
    stream << "INSERT INTO test (id, val) VALUES (1, 'C');\n"; // Duplicate key
    stream.flush();
    scriptFile.close();

    // Execute - should fail on duplicate key
    bool success = SqlExecutor::executeSqlScript(db, scriptPath);
    QVERIFY(!success);

    // Verify rollback - no data should be committed
    QSqlQuery query(db);
    QVERIFY(query.exec("SELECT COUNT(*) FROM test;"));
    QVERIFY(query.next());
    int count = query.value(0).toInt();
    QCOMPARE(count, 0);  // Transaction rolled back

    // Cleanup
    QFile::remove(scriptPath);
}
```

**Testing:** Run `./bin/test_sql_transaction` - should pass.

---

## Phase 6: Verification (30 minutes)

### Task 6.1: Build verification
```bash
cd /Users/joe/Local/jve-spec-kit-claude
make clean
make -j8

# Expected output:
# - All 12 qt_bindings/*.cpp files compile
# - JVECore library links successfully
# - JVEEditor executable links successfully
# - test_sql_transaction executable created
# - No compilation errors

# Verify files exist:
ls -lh bin/JVEEditor
ls -lh bin/test_sql_transaction
```

---

### Task 6.2: Unit test verification
```bash
./bin/test_sql_transaction

# Expected output:
# ********* Start testing of TestSqlTransaction *********
# ...
# PASS   : TestSqlTransaction::testTransactionRollback()
# ...
# Totals: 1 passed, 0 failed, 0 skipped, 0 blacklisted
# ********* Finished testing of TestSqlTransaction *********

# Verify via CTest:
ctest -R test_sql_transaction -V
```

---

### Task 6.3: Lua regression tests
```bash
./scripts/run_lua_tests.sh

# Critical tests to verify:
# - test_clipboard_timeline.lua (copy/paste with Rational)
#   → Verifies serialize_rational/deserialize_rational work
# - test_batch_ripple_*.lua (all batch ripple variants)
#   → Verifies mutation validation and constraint logic
# - test_branching_after_undo.lua (command history)
#   → Verifies JSON decode fix in command_history.lua

# Check for failures:
echo "Exit code: $?"  # Should be 0

# Run via CTest:
ctest -R lua_regression_suite -V
```

---

### Task 6.4: Manual integration test
```bash
./bin/JVEEditor

# Test sequence:
# 1. Import media
#    - Should succeed (foreign keys enabled via PRAGMA)
#    - Check logs for "PRAGMA" execution messages
#
# 2. Create clips on timeline
#    - Drag media to timeline
#    - Verify clips appear with correct duration
#
# 3. Copy clips (Cmd+C)
#    - Select 2-3 clips
#    - Copy to clipboard
#    - Check logs for serialization (if debug enabled)
#
# 4. Paste clips (Cmd+V)
#    - Move playhead to different position
#    - Paste
#    - Verify clips appear at correct time
#    - Verify timing preserved (check clip durations match originals)
#
# 5. Undo/redo paste
#    - Cmd+Z to undo paste
#    - Verify all pasted clips removed (single undo)
#    - Cmd+Shift+Z to redo
#    - Verify clips restored
#
# 6. Check database integrity
sqlite3 /path/to/your/project.jve "PRAGMA integrity_check;"
# Should output: ok

sqlite3 /path/to/your/project.jve "PRAGMA foreign_key_check;"
# Should output: (empty - no violations)
```

---

### Task 6.5: Performance verification
```bash
# Check for debug output spam:
./bin/JVEEditor 2>&1 | grep -i "DEBUG: Mutation"
# Should output: (empty)

# Create 100 clips and modify them - no debug spam should appear

# Monitor memory usage (UUID collision detection):
# Should NOT grow unbounded like old m_allGeneratedUuids set
```

---

## Success Criteria

**All must pass before merge:**

- [ ] Build completes without errors (`make clean && make -j8`)
- [ ] All qt_bindings files tracked in git
- [ ] Unit test passes (`./bin/test_sql_transaction`)
- [ ] Lua regression suite passes (`./scripts/run_lua_tests.sh`)
- [ ] PRAGMA statements execute (verify foreign keys via constraint test)
- [ ] Copy/paste preserves clip timing across different frame rates
- [ ] No debug output in production (mutation spam eliminated)
- [ ] Database integrity check passes
- [ ] Manual smoke test completes all 6 steps

**Code review verification:**
- [ ] No rollback after failed commit
- [ ] No Rational objects serialized directly to JSON
- [ ] No unvalidated mutation UPDATEs
- [ ] No hardcoded 30fps assumptions in clipboard
- [ ] No silent module load failures
- [ ] No duplicate field assignments (start_value removed)

---

## Risk Assessment

**Low Risk:**
- Qt bindings refactor (already tested in previous commit)
- Command registry error logging (additive change)
- CMakeLists.txt test integration (build system only)

**Medium Risk:**
- PRAGMA execution split (requires testing foreign key constraints)
- Mutation validation (could block valid operations if overly strict)
- Duplicate field removal (ensure no code depends on start_value)

**High Risk:**
- Clipboard serialization (complex, touches multiple systems)
- Sequence frame rate detection (database query in hot path)
- Transaction rollback fix (subtle database driver behavior)

**Mitigation:**
- Comprehensive test suite run before merge
- Manual integration test covers all critical paths
- Database integrity check verifies no corruption
- Can revert entire branch if issues found

---

## Timeline

- **Phase 1 (Build):** 15 minutes
- **Phase 2 (Database):** 30 minutes
- **Phase 3 (Clipboard):** 45 minutes
- **Phase 4 (Cleanup):** 20 minutes
- **Phase 5 (Medium Priority):** 30 minutes
- **Phase 6 (Verification):** 30 minutes

**Total: ~2.5 hours focused work**

---

## Notes

**Architectural Wins Preserved:**
- Qt bindings modularization (4,617 → 257 lines in main file)
- Command manager split (registry/history/state separation)
- Net code reduction (-4,477 lines)

**Technical Debt Eliminated:**
- Rational→JSON serialization infrastructure complete
- Sequence frame rate detection centralized
- Mutation validation prevents silent failures
- PRAGMA execution properly separated from transactions

**Documentation Added:**
- UUID collision detection rationale
- Clipboard serialization helpers
- Error messages for all failure modes
