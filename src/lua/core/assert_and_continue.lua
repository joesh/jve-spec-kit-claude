--- Loud-but-non-fatal assertion.
---
--- Mirrors `assert()` but does NOT throw. Use when a corrupted
--- invariant has a documented recovery in the same step (skip the
--- bad item, return a default, fall through to neutral state), but
--- you still want it surfaced LOUD — error-level log + Lua stack
--- trace — so the underlying bug gets fixed.
---
--- Example: persisted state references a row that's been deleted
--- out of band. `assert` would crash the app on every launch until
--- the project file is hand-repaired (see TimelineTabStrip.deserialize
--- + DeleteMasterClip missing `sequence_list_changed` history,
--- 2026-06-27). `assert_and_continue` logs the violation with a
--- trace and lets the caller drop the offending item.
---
--- Default policy is fail-fast (ENGINEERING.md 1.14). Use
--- `assert_and_continue` ONLY when the call site has a documented
--- "what we do when this fails" branch immediately following the
--- check. If there isn't one, use `assert`.
local log = require("core.logger").for_area("commands")

--- Return `cond` when truthy, otherwise log an ERROR-level message
--- with `string.format(fmt, ...)` and a Lua stack trace and return
--- nil. The caller is expected to test the result and take a
--- recovery path on nil.
return function(cond, fmt, ...)
    if cond then return cond end
    local msg = fmt or "assert_and_continue: condition failed (no message supplied)"
    if select("#", ...) > 0 then msg = string.format(msg, ...) end
    log.error("ASSERT-AND-CONTINUE: %s\n%s", msg, debug.traceback("", 2))
    return nil
end
