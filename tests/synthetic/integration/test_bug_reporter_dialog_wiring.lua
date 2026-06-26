-- Feature 027 T006: submission dialog state + handler wiring.
--
-- The dialog is a thin view bound to a state model (Constitution I
-- MVC). The state owns:
--   - title (required for Submit to enable)
--   - description
--   - text_only flag
-- The Submit handler reads state, asks the report_bug command to
-- package, and (Phase A) reveals the resulting zip in Finder. Cancel
-- closes without exporting.
--
-- We don't hit Finder in tests — T014b's reveal binding writes the zip
-- path to JVE_BUG_REPORT_REVEAL_HOOK when set. Sentinel file existence
-- + content is what this test inspects.
--
-- Black-box; MUST run via --test mode (absolute script path).

print("=== test_bug_reporter_dialog_wiring.lua ===")

require("test_env")

local function require_or_red(modname, task)
    local ok, mod = pcall(require, modname)
    if not ok then
        error("RED — " .. modname .. " unloadable (" .. task .. " not landed): " .. tostring(mod))
    end
    return mod
end

-- The reveal binding (T014b) consults JVE_BUG_REPORT_REVEAL_HOOK on
-- every call. Production code MUST branch on the env var, never on a
-- compile-time "test mode" flag (no sentinel-in-production pollution).
-- The env var MUST be exported by the test invoker BEFORE launching
-- jve (Lua has no setenv in stdlib; we don't add one just to wire a
-- test hook). Canonical invocation:
--   JVE_BUG_REPORT_REVEAL_HOOK=/tmp/jve_test_reveal.txt \
--     ./build/bin/jve.app/Contents/MacOS/jve --test \
--     "$(pwd)/tests/synthetic/lua/test_bug_reporter_dialog_wiring.lua"
local sentinel_path = os.getenv("JVE_BUG_REPORT_REVEAL_HOOK")
assert(sentinel_path and #sentinel_path > 0,
    "JVE_BUG_REPORT_REVEAL_HOOK must be exported before launching --test for this test")
os.remove(sentinel_path)

require_or_red("bug_reporter", "T011")
local submission_state  = require_or_red("bug_reporter.ui.submission_state", "T012")
local submission_dialog = require_or_red("bug_reporter.ui.submission_dialog", "T013")
local report_bug        = require_or_red("core.commands.report_bug", "T014c")

-- Wire a main window so capture_manual can resolve its grab target.
local main_window = qt_constants.WIDGET.CREATE_MAIN_WINDOW()
qt_set_object_name(main_window, "JVEMainWindow")
qt_constants.PROPERTIES.SET_SIZE(main_window, 1400, 900)
qt_constants.DISPLAY.SHOW(main_window)
qt_constants.CONTROL.PROCESS_EVENTS()

-- Drive synthetic frames so slideshow.mp4 is producible — see T005.
local bug_reporter_init = require("bug_reporter")
for _ = 1, 3 do
    bug_reporter_init.capture_screenshot()
end

-- (1) is_submittable starts false (no title), becomes true on set_title.
local state = submission_state.new()
assert(state:is_submittable() == false,
    "empty-title state must NOT be submittable — Submit button stays disabled until the user types a title (FR-004)")

state:set_title("Triggered from the dialog wiring test")
assert(state:is_submittable() == true,
    "non-empty title must flip is_submittable to true")

-- (2) Cancel handler closes dialog without invoking submit.
local wrapper_cancelled = submission_dialog.create(state)
assert(wrapper_cancelled and wrapper_cancelled.on_cancel,
    "submission_dialog.create must return a wrapper exposing on_cancel handler")
wrapper_cancelled.on_cancel()
assert(io.open(sentinel_path, "r") == nil,
    "Cancel must NOT trigger reveal_in_finder — sentinel file should not exist after cancel")

-- (3) Submit handler with text_only=false produces a zip whose listing
-- includes slideshow.mp4.
state:set_text_only(false)
local result = report_bug.submit(state)
assert(result and result.ok, "report_bug.submit failed: " .. tostring(result and result.error))

local hooked_path
do
    local f = io.open(sentinel_path, "r")
    assert(f, "Submit must write the zip path to the reveal sentinel — file missing at " .. sentinel_path)
    hooked_path = f:read("*l")
    f:close()
end
assert(hooked_path and hooked_path:match("%.zip$"),
    "reveal sentinel contents must be a .zip path, got: " .. tostring(hooked_path))

local function zip_lists(path, basename)
    local pipe = io.popen("unzip -l '" .. path:gsub("'", "'\\''") .. "' 2>/dev/null")
    local body = pipe:read("*a")
    pipe:close()
    return body:find(basename, 1, true) ~= nil
end

assert(zip_lists(hooked_path, "capture.json"), "zip missing capture.json")
assert(zip_lists(hooked_path, "slideshow.mp4"),
    "text_only=false but zip is missing slideshow.mp4")

-- (4) Toggle text_only on, re-submit, verify slideshow.mp4 absent.
os.remove(sentinel_path)
state:set_text_only(true)
local result2 = report_bug.submit(state)
assert(result2 and result2.ok, "second submit failed: " .. tostring(result2 and result2.error))

local hooked_path2
do
    local f = io.open(sentinel_path, "r")
    assert(f, "second Submit must rewrite the reveal sentinel")
    hooked_path2 = f:read("*l")
    f:close()
end
assert(zip_lists(hooked_path2, "capture.json"), "text_only zip missing capture.json")
assert(not zip_lists(hooked_path2, "slideshow.mp4"),
    "text_only=true but slideshow.mp4 still present in zip — FR-006 broken")

os.remove(sentinel_path)
print("✅ test_bug_reporter_dialog_wiring.lua passed")
