# Contract: Stale-`project_id` Validation

**Status**: tightened existing contract + new helper · **Spec ref**: FR-005, FR-006 · **Phase 1**

## Two-layer validation model

The validation strategy has two layers, complementary and both permanent:

### Layer 1 — `assert_project_exists(project_id)` — fail-loud at API boundary

Already exists at `core/database.lua:1493`. Called by every public DB function that takes a `project_id` argument.

```lua
local function assert_project_exists(project_id)
    assert(project_id and project_id ~= "", "assert_project_exists: project_id is required")
    assert(db_connection, "assert_project_exists: no database connection")
    local sole_id = M.get_current_project_id()  -- asserts exactly 1 project
    assert(sole_id == project_id, string.format(
        "assert_project_exists: project_id '%s' != sole project '%s' in '%s'. "
        .. "Stale project_id after project switch?",
        tostring(project_id), tostring(sole_id), tostring(db_path)))
end
```

**Behavior**: hard-asserts on mismatch. Catches direct API misuse — caller passed an ID that doesn't match the live DB.

**Coverage requirement (FR-005)**: every public function in `database.lua` that writes and takes a `project_id` argument MUST call `assert_project_exists` directly or transitively.

**Today's coverage** (verified during Phase 0 research):
- `M.get_project_settings(project_id)` calls `assert_project_exists` directly.
- `M.set_project_setting(project_id, key, value)` calls `M.get_project_settings` first — transitively covered.
- `M.set_project_settings(project_id, settings)` — coverage status TBD; verify in Phase 4.

**Audit task (Phase 4)**: enumerate every export of `database.lua` that takes a `project_id` arg. Missing coverage gets a direct call added.

### Layer 2 — `assert_project_id_is_live(cached_id, caller_label)` — log-and-no-op for module-local caches

NEW helper. For modules that cache `current_project_id` at module scope (only `media_status` today; see FR-006).

```lua
-- Helpers declared before the public function so the closures resolve
-- to the locals (Lua scoping: a local must be in scope at the point
-- the enclosing function's body is parsed, not just when called).

local function stale_check_possible(cached_id)
    return cached_id and cached_id ~= "" and db_connection ~= nil
end

local function log_stale_project_violation(caller_label, cached_id, live_id)
    local log = require("core.logger").for_area("database")
    log.error(
        "%s: stale project_id (cached=%s, live=%s) — no-op-ing write\n%s",
        caller_label,
        tostring(cached_id),
        tostring(live_id),
        debug.traceback("", 2))
end

--- Returns true when the cached project_id matches the live DB; false
--- otherwise. On mismatch logs a JVE_ASSERT-style stack trace at error
--- level and the caller MUST no-op its write.
---
--- Catches the stale-cache pattern where a deferred-work callback
--- reads a module-local cached project_id after a project switch.
--- Logs (rather than asserts) because this race is an expected mode
--- of the contract — the cancellation-or-validation path from FR-003.
--- Layer 1 (`assert_project_exists`) catches CALLER bugs; this layer
--- catches TIMING bugs.
---
--- @param cached_id string|nil  module's cached project_id
--- @param caller_label string   e.g. "media_status.persist_now"
--- @return boolean is_live
function M.assert_project_id_is_live(cached_id, caller_label)
    if not stale_check_possible(cached_id) then return false end
    local live_id = M.get_current_project_id()
    if live_id == cached_id then return true end
    log_stale_project_violation(caller_label, cached_id, live_id)
    return false
end
```

**Behavior**: returns boolean. On mismatch: logs at `log.error` level (the "broken invariant" tier per CLAUDE.md logger usage; the trace is JVE_ASSERT-equivalent per FR-008) and returns false. Caller no-ops its write.

**Why log-not-assert** (rationale for the rule-VI deviation, recorded in plan.md Complexity Tracking): deferred-work callbacks firing after a project switch with stale cached state is an EXPECTED mode — the cancellation-or-validation contract from FR-003. Hard-asserting here would re-create the bug this feature exists to fix (the C++ callback bridge silently swallowing assertions).

**Distinction from Layer 1**: Layer 1 hard-asserts because it's catching a CALLER bug (someone passed a wrong ID through a public API). Layer 2 logs-and-returns because it's catching a TIMING bug (cache went stale during a legitimate project switch — the caller couldn't have known at scheduling time).

## Caller usage pattern (Layer 2)

Helpers above, public function below. The body of `M.persist_now` reads as a three-step algorithm: short-circuit on missing prerequisites, validate, persist.

```lua
-- in media_status.lua

local function has_pending_persist_state()
    return current_project_id and get_database().has_connection()
end

local function project_id_is_live()
    return get_database().assert_project_id_is_live(
        current_project_id, "media_status.persist_now")
end

local function flush_status_cache_to_db()
    local map = build_persist_map()
    get_database().set_project_setting(current_project_id, DB_SETTING_KEY, map)
end

function M.persist_now()
    if not has_pending_persist_state() then return end
    if not project_id_is_live() then return end
    flush_status_cache_to_db()
end
```

## Permanence

Both layers are permanent (clarification answer 2: defense in depth). The validation stays after the `project_will_change` contract is in place. Cost: one extra DB query per persist call. Benefit: any future module that re-introduces the bug fails loud immediately.

## Test contract

1. **Layer 1 coverage test**: every export of `database.lua` taking a `project_id` arg has either a direct call to `assert_project_exists` or a transitive call (via another covered function). Verify by greppable evidence + integration.

2. **Layer 2 stale-cache test**: register a fake module that caches `project_id`. Trigger a switch P1 → P2 such that the fake module's cache is still P1. Call its persist function — assert: warning logged with stack trace, no DB write happened, no hard assert fired.

3. **Layer 2 happy-path test**: same fake module, no switch happens, cached id matches live. Call persist — assert: write succeeded, no warning logged.
