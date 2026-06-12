-- 012 Inspector Public API — facade contract, second-mount guard,
--   self-source early-return.
--
-- REPLACES (stub-heavy synthetic/lua/ test):
--   test_inspector_public_api_contract.lua
--
-- DOMAIN RULES PINNED:
--   DR-MOUNT-ONCE   A second call to inspector.mount() on the same process
--                   must raise an error containing "already mounted". Silent
--                   no-op or silent replace would leave the prior mount's
--                   widgets and signal handlers dangling (Qt keeps them alive
--                   through the C++ bindings; Lua GC can't reach them). The
--                   assert has been observed firing in TSO — this guards it.
--   DR-SELF-SOURCE  update_selection with source_panel_id == "inspector" must
--                   early-return without mutating mode — otherwise
--                   selection_hub → Inspector → selection_hub infinite-loops.
--   DR-THREE-EXPORTS The facade exports exactly {mount, update_selection,
--                   get_focus_widgets}. Any extra export reopens the 012
--                   rewrite's elimination of legacy accretion.
--
-- NOTE: DR-THREE-EXPORTS and DR-SELF-SOURCE are also covered by the
-- existing smoke_inspector_launch.lua (which runs before this test in the
-- integration suite). They are re-verified here for completeness and to
-- keep this file self-contained.
--
-- DROPPED scenarios (implementation details):
--   * Exact selection_binding.update_selection call path when source='timeline'
--     → mode='empty' — that's internal routing; the domain rule is the
--     self-source guard only.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        tests/synthetic/integration/inspector/test_012_inspector_public_api.lua

local qt_constants = require("core.qt_constants")
require("test_env")

print("=== test_012_inspector_public_api.lua ===")

-- ── DR-THREE-EXPORTS ───────────────────────────────────────────────────────
print("-- DR-THREE-EXPORTS: facade exports exactly {mount, update_selection, get_focus_widgets} --")
do
    -- Fresh load (no prior mount state).
    package.loaded["ui.inspector"] = nil
    local inspector = require("ui.inspector")

    local expected = { mount = true, update_selection = true, get_focus_widgets = true }
    local count = 0
    local unexpected = {}
    for k, v in pairs(inspector) do
        count = count + 1
        if not expected[k] then
            unexpected[#unexpected + 1] = k .. "=" .. type(v)
        end
    end
    assert(count == 3, string.format(
        "DR-THREE-EXPORTS: facade must export exactly 3 functions; found %d. "
        .. "Extras: %s",
        count, table.concat(unexpected, ", ")))
    assert(type(inspector.mount)            == "function", "mount must be a function")
    assert(type(inspector.update_selection) == "function", "update_selection must be a function")
    assert(type(inspector.get_focus_widgets)== "function", "get_focus_widgets must be a function")
    print("  PASS DR-THREE-EXPORTS")
end

-- ── DR-MOUNT-ONCE ──────────────────────────────────────────────────────────
print("-- DR-MOUNT-ONCE: second mount() raises 'already mounted' --")
do
    -- Reload a clean facade so mount() sees ui_state == nil.
    package.loaded["ui.inspector"] = nil
    local inspector = require("ui.inspector")

    local c1 = qt_constants.WIDGET.CREATE()
    assert(c1, "DR-MOUNT-ONCE: could not create first container")
    inspector.mount(c1)  -- first mount must succeed

    local c2 = qt_constants.WIDGET.CREATE()
    assert(c2, "DR-MOUNT-ONCE: could not create second container")
    local ok, err = pcall(inspector.mount, c2)

    assert(not ok,
        "DR-MOUNT-ONCE: second mount() must raise, not silently no-op or replace")
    assert(type(err) == "string" and err:find("already mounted"),
        string.format(
            "DR-MOUNT-ONCE: error must explain 'already mounted'; got: %s",
            tostring(err)))
    print("  PASS DR-MOUNT-ONCE")
end

-- ── DR-SELF-SOURCE ─────────────────────────────────────────────────────────
print("-- DR-SELF-SOURCE: update_selection with source='inspector' must not mutate state --")
do
    -- The mounted inspector from DR-MOUNT-ONCE is in empty mode. Verify
    -- source='inspector' does not change that.
    -- Re-require gives us the mounted instance (same module local ui_state).
    local inspector = require("ui.inspector")

    -- update_selection with source="inspector" must early-return. The
    -- domain invariant: mode stays at whatever it was before the call.
    -- We can't read mode directly (it's module-private), but we CAN
    -- verify that no error is raised AND that a subsequent legitimate
    -- update works normally.

    -- Self-source: must not crash, must not raise.
    local self_ok, self_err = pcall(inspector.update_selection,
        { { item_type = "timeline_clip", clip_id = "x" } }, "inspector")
    assert(self_ok, string.format(
        "DR-SELF-SOURCE: source='inspector' must not raise; got: %s",
        tostring(self_err)))

    -- Non-self source: must succeed (regression — make sure the guard
    -- doesn't accidentally block legitimate sources).
    local ok, err = pcall(inspector.update_selection, {}, "timeline")
    assert(ok, string.format(
        "DR-SELF-SOURCE: source='timeline' must not raise; got: %s",
        tostring(err)))

    print("  PASS DR-SELF-SOURCE")
end

print("\n✅ test_012_inspector_public_api.lua passed")
