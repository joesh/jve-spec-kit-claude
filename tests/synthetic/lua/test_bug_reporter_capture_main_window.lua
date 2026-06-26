-- Feature 027 T004: screenshot capture targets the JVE main window,
-- never whichever transient dialog happens to be focused.
--
-- Why this matters: a user pressing F12 typically triggers from within
-- a sub-dialog (about-box, codec-error sheet, etc.). The legacy code
-- called qApp->activeWindow() — that's the focused top-level, which is
-- the sub-dialog. The captured frame ended up being a 400×300 picture
-- of the dialog itself, useless for diagnosing what was going wrong in
-- the timeline beneath. This test pins the invariant: capture frames
-- come from the main window regardless of what else is shown.
--
-- Black-box: asserts "the captured pixmap is at least 1000 px wide",
-- which is true for the JVE main window (1200×900 default) and never
-- true for any small dialog.
--
-- MUST run via `./build/bin/jve.app/Contents/MacOS/jve --test <absolute>`
-- because it exercises real Qt widgets + the C++ grab_window binding.

print("=== test_bug_reporter_capture_main_window.lua ===")

require("test_env")

-- Loader guard: T010b adds qpixmap_width as a new binding. Until then,
-- emit a RED message naming the missing piece rather than letting Lua
-- crash with "attempt to call a nil value".
if type(_G.qpixmap_width) ~= "function" then
    error("RED — qpixmap_width binding missing (T010b not landed)")
end

-- Build the JVE main window so lua_grab_window has something to find by
-- objectName. T010a sets `objectName = "JVEMainWindow"` on this widget.
local main_window = qt_constants.WIDGET.CREATE_MAIN_WINDOW()
qt_constants.PROPERTIES.SET_SIZE(main_window, 1400, 900)
qt_constants.DISPLAY.SHOW(main_window)

-- Open an auxiliary dialog so it becomes the focused top-level (this is
-- the misdirection trap the legacy grab_window fell into).
local dialog = qt_constants.DIALOG.CREATE(main_window, "Auxiliary modal", false)
qt_constants.PROPERTIES.SET_SIZE(dialog, 398, 292)
qt_constants.DISPLAY.SHOW(dialog)

-- Let the windowserver assign geometry + focus.
qt_constants.APP.PROCESS_EVENTS()

-- Trigger capture through the same path F12's 1 Hz timer uses.
local bug_reporter = require("bug_reporter")
bug_reporter.capture_screenshot()

local cap = require("bug_reporter.capture_manager")
local ring = cap.screenshot_ring_buffer
assert(ring and #ring > 0, "capture_screenshot did not record any frame in the ring buffer")

local latest = ring[#ring]
assert(latest.image, "ring entry has no pixmap — grab_window returned nil")

local width = qpixmap_width(latest.image)
local height = qpixmap_height(latest.image)

assert(width >= 1000,
    string.format(
        "captured frame is %dx%d — that's the auxiliary dialog (398x292), not the main window. " ..
        "lua_grab_window must look up the widget whose objectName=='JVEMainWindow', not " ..
        "qApp->activeWindow(). T010a sets the objectName; T010b changes the grab path.",
        width, height))

print("✅ test_bug_reporter_capture_main_window.lua passed (captured " ..
    width .. "x" .. height .. " from main window)")
