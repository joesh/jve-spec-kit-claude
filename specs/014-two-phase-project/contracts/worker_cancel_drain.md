# Contract: Background-Worker Cancel-and-Drain

**Status**: NEW contract (extends existing `cancel_background_probe`) · **Spec ref**: FR-003, FR-003a · **Phase 1**

## Surface

A background worker that writes to the per-project DB MUST expose:

```lua
worker:cancel()                          -- sets cancel flag; returns immediately
worker:wait_for_drain(timeout_ms)        -- blocks; returns true if drained, false on timeout
```

Pre-switch handler protocol (called from a `project_will_change` handler):

```lua
local DRAIN_BUDGET_MS = 1000

worker:cancel()
local drained = worker:wait_for_drain(DRAIN_BUDGET_MS)
if not drained then
    log.warn("%s: cancel-and-drain exceeded %dms budget; %d writes discarded",
        worker_label, DRAIN_BUDGET_MS, worker:pending_count())
end
-- switch proceeds regardless
```

## Worker-side requirements

A cooperating worker MUST:

1. Check the cancel flag at every write boundary. If set, exit cleanly without writing.
2. Drain the in-flight write queue before exiting (each queued write either lands or is discarded with a count).
3. Maintain a `pending_count()` accessor for the diagnostic log line above.

## Drain budget rationale

- 1 second is comfortably longer than any single write should take (sub-millisecond for `set_project_setting`; a few ms for batch writes).
- 1 second is short enough that the user does not perceive the project switch as hung.
- A worker that exceeds 1s is buggy (likely an unbounded loop without a cancel check); the warning surfaces it for fixing.

## Coordination with Layer 2 validation

The drain budget is a hard cap, not an SLA. Workers that escape the drain (because their write fires AFTER the budget expires, e.g. a queued write that didn't get flushed in time) are caught by Layer 2 validation in `persist_now_validation.md`: the worker's write callback calls `assert_project_id_is_live(captured_project_id, ...)` and no-ops on mismatch. So a slow worker can't corrupt the new project's DB even if it misses the drain window.

## Existing worker mapping

`media_status.cancel_background_probe()` already exists at module scope. Phase 4 inspection task:

1. Verify the existing function sets a flag (vs. just stops queueing new work).
2. Add `wait_for_drain(timeout_ms)` if missing.
3. Add `pending_count()` accessor if missing.
4. Update existing call sites (the `project_changed` handler) to call cancel + wait_for_drain, then move that whole block to a `project_will_change` handler.

## Test contract

1. **Drain-success test**: worker has 5 in-flight writes, all complete within 100ms. Pre-switch handler calls cancel + wait_for_drain(1000). Asserts: `drained == true`, all 5 writes landed in outgoing DB, no warning logged.

2. **Drain-timeout test**: worker's write callback artificially blocks for 2000ms. Pre-switch handler calls cancel + wait_for_drain(1000). Asserts: `drained == false`, a warning was logged with the worker label and pending count, switch still proceeds.

3. **Stale-write safety net test**: drain times out, worker write fires AFTER switch, write callback calls `assert_project_id_is_live` with stale project_id. Asserts: write no-ops, warning logged (Layer 2), no `assert_project_exists` hard-fail.
