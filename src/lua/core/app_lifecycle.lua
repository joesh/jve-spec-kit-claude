--- App lifecycle: process-level shutdown sequencing.
---
--- Owns the side-effects that run when Qt fires aboutToQuit. Lives in
--- core/ rather than ui/ because the work (flush DB caches, cancel
--- workers, release locks) is process-wide; UI just triggers it. The
--- extraction also makes shutdown unit-testable without Qt — the
--- previous home (ui/layout.lua) couldn't be exercised headlessly, so
--- bugs in the shutdown sequence (e.g. scroll-not-persisted) went
--- untested.
---
--- Wiring: main.cpp invokes _G.__jve_shutdown via aboutToQuit;
--- ui/layout.lua installs that global as a thin delegate to M.shutdown.

local log = require("core.logger").for_area("ui")

local M = {}

--- Run the full shutdown sequence. Order matters:
---   1. Cancel the background codec-probe worker BEFORE the DB flush.
---      The worker writes status rows; racing it against our flush
---      risks half-written records.
---   2. Persist the displayed-tab's scroll offsets to its sequences
---      row. The cache is the in-session source of truth and nothing
---      else writes it on quit — without this call the user's scroll
---      position evaporates on every shutdown.
---   3. Persist remaining per-sequence view-state (playhead, viewport,
---      marks, splitter ratio) for the displayed tab.
---   4. Flush media_status's pending status cache to the project setting.
---   5. Shut down the Resolve helper supervisor (idempotent if no
---      helper was ever spawned this session).
---   6. Release the project pidlock last so any sibling JVE that wakes
---      up immediately after sees the SHM as recoverable rather than
---      concurrently held by a dying PID.
function M.shutdown()
    log.event("app_lifecycle.shutdown: flushing state, cancelling workers")

    local media_status = require("core.media.media_status")
    media_status.cancel_background_probe()

    local timeline_state = require("ui.timeline.timeline_state")
    timeline_state.persist_scroll_offsets()
    timeline_state.persist_state_to_db(true)

    media_status.persist_now()

    local helper_supervisor = require("core.resolve_bridge.helper_supervisor")
    helper_supervisor.shutdown()

    require("core.project_open").release_current_pidlock()
end

return M
