# Contract: `project_will_change` signal

**Status**: NEW signal · **Spec ref**: FR-001, FR-002, FR-004, FR-009 · **Phase 1**

## Surface

```lua
-- Subscribe (mirror of project_changed)
local conn_id = Signals.connect("project_will_change", function(outgoing_project_id)
    -- handler body
end, priority)  -- priority is optional; default 100

-- Unsubscribe
Signals.disconnect(conn_id)

-- Emit (called only by core/project_open.lua and core/commands/new_project.lua)
Signals.emit("project_will_change", outgoing_project_id_or_nil)
```

## Payload

| Param | Type | Description |
|---|---|---|
| `outgoing_project_id` | `string \| nil` | Project ID the user is leaving. `nil` only for cold start (no prior project). |

## Emit-time invariants

When `Signals.emit("project_will_change", ...)` is called, ALL of the following MUST hold:

1. `outgoing_project_id == database.get_current_project_id()` (or both are nil for cold start).
2. The outgoing project's DB connection is the live connection.
3. `database.init(new_path)` has NOT yet been called for the incoming project.
4. The incoming project_id is NOT yet observable through any database API.

## Handler contract

A `project_will_change` handler:

- **MAY** write to the outgoing project's DB (e.g. `database.set_project_setting(outgoing_project_id, ...)`).
- **MAY** cancel pending Qt single-shot timers it scheduled (set flags, call cancel APIs).
- **MAY** signal cancellation to background workers and wait for drain (see `worker_cancel_drain.md`).
- **MUST NOT** attempt to write to the incoming project (it doesn't exist).
- **MUST NOT** block longer than the drain budget (1000ms for worker drain; sub-millisecond for everything else).
- **MUST NOT** raise an unrecoverable exception (see "Error policy" below).

## Handler ordering

Handlers fire in priority-ascending order, matching `project_changed` semantics. Default priority is 100 when unspecified. Priority bands used in this codebase:

- 1–9: dispatcher-level setup (currently unused; reserved).
- 10–19: hot-path consumers that must run early (e.g. playback stop at priority 10).
- 20–49: caches and debounced-writer flush (e.g. `media_status` at priority 12).
- 50–99: secondary cleanup and cancellation.
- 100+: default; UI cleanup.

For `project_will_change`, the `media_status` flush handler lands at priority 12 — matching its existing `project_changed` priority — so pre-switch flush runs before secondary handlers.

## Error policy

A handler that raises is logged via the Lua-callback bridge per `lua_callback_bridge.md` (stack trace + continue). The dispatcher continues with the next handler. **The switch is never blocked by a single handler error.**

Rationale: the outgoing project may be about to be deleted/replaced; halting on the outgoing project leaves the editor in a half-switched, unusable state.

## Test contract

The signal MUST have these black-box tests (FR-010):

1. **Ordering test**: register a `project_will_change` handler that records `database.get_current_project_id()`; register a `project_changed` handler that does the same. Trigger a switch P1 → P2. Assert: pre-handler observed P1, post-handler observed P2.

2. **Pre-flush test**: media_status writes a status entry for P1 (in-memory only, debounced); user switches to P2; assert P1's DB has the persisted status entry, P2's DB does not.

3. **Cold-start test**: trigger `none → P1` switch; assert pre-handler runs with `outgoing_project_id == nil`; no handler errors.

4. **Close-without-replacement test**: `P1 → none`; assert pre-handler runs with `outgoing == P1`; flush completes; post-handler runs with `incoming == nil`.

5. **Handler-error isolation test**: register two pre-handlers, the first throws an error; assert second still runs, switch completes, error was logged with stack trace.
