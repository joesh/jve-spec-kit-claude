-- ElidingLabel must pair its visual clipping with a tooltip carrying the
-- full string, so a user who can't read the elided tail can hover to see
-- what was clipped. When the text fits, the tooltip must be absent (no
-- hover noise for unclipped labels).
--
-- Background: SequenceMonitor's grade-status strip used to push the whole
-- monitor wider whenever the status string ("⟳ Syncing grades from
-- Resolve…", grade badges) exceeded the gap between the two timecodes.
-- The fix is to use ElidingLabel and to make elide+tooltip intrinsic to
-- the widget itself so every caller of CREATE_ELIDING_LABEL benefits.
--
-- The widget computes elide AND tooltip inside reelide(), which fires on
-- two paths: (a) setFullText (i.e. SET_TEXT), and (b) resizeEvent during
-- layout. This test exercises (a) at two widths — the deterministic path
-- on an unshown widget. Path (b) is covered in production by the Inspector
-- header layout and by SequenceMonitor's TC row geometry.
--
-- Runs inside ./build/bin/jve --test (Qt bindings required).

local qt = require("core.qt_constants")

print("=== test_eliding_label_tooltip ===")

local LONG = "⟳ Syncing grades from Resolve…"
local SHORT = "OK"

-- Order matters: SIZE first so the widget's contentsRect is the target
-- width before setFullText runs reelide(). QWidget::resize() updates
-- geometry synchronously, so the next setFullText elides against the
-- current rect immediately (no event-loop pump required).

-- Narrow + long: rendered text MUST differ from full AND tooltip MUST
-- carry the full string.
local narrow = qt.WIDGET.CREATE_ELIDING_LABEL("")
assert(narrow, "CREATE_ELIDING_LABEL returned nil")
qt.PROPERTIES.SET_SIZE(narrow, 40, 20)
qt.PROPERTIES.SET_TEXT(narrow, LONG)

local rendered = qt.PROPERTIES.GET_TEXT(narrow)
local tip = qt.PROPERTIES.GET_TOOLTIP(narrow)
assert(rendered ~= LONG,
    "narrow rendered text must differ from full: got " .. tostring(rendered))
assert(tip == LONG,
    "narrow tooltip must carry full text. expected=" .. LONG ..
    " got=" .. tostring(tip))

-- Wide + short: rendered text MUST equal full AND tooltip MUST be empty
-- (no hover noise for unclipped labels).
local wide = qt.WIDGET.CREATE_ELIDING_LABEL("")
assert(wide, "CREATE_ELIDING_LABEL returned nil")
qt.PROPERTIES.SET_SIZE(wide, 400, 20)
qt.PROPERTIES.SET_TEXT(wide, SHORT)

local rendered2 = qt.PROPERTIES.GET_TEXT(wide)
local tip2 = qt.PROPERTIES.GET_TOOLTIP(wide)
assert(rendered2 == SHORT,
    "wide rendered text must equal full: got " .. tostring(rendered2))
assert(tip2 == nil or tip2 == "",
    "wide tooltip must be empty for unclipped label: got " .. tostring(tip2))

-- Re-setText path: a previously-tooltipped widget that gets a string that
-- now fits MUST clear its tooltip. Reelide is the single authority — there
-- must be no stale tooltip from a prior elide.
qt.PROPERTIES.SET_TEXT(narrow, SHORT)
local tip3 = qt.PROPERTIES.GET_TOOLTIP(narrow)
assert(tip3 == nil or tip3 == "",
    "re-setText with short string must clear tooltip: got " .. tostring(tip3))

print("✅ test_eliding_label_tooltip.lua passed")
