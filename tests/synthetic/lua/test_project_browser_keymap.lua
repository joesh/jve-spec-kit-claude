#!/usr/bin/env luajit

-- Test project_browser keymap: Return activates items by type.
-- All three item types must be covered: timeline, master_clip, bin.

package.path = package.path
    .. ";./tests/?.lua"
    .. ";./src/lua/?.lua"
    .. ";./src/lua/ui/?.lua"
    .. ";./src/lua/ui/project_browser/?.lua"

require("test_env")

local keymap = require("ui.project_browser.keymap")

local KEY_RETURN = 16777220
local KEY_ENTER = 16777221

-- Shared mock context builder
local function make_ctx(item, overrides)
    overrides = overrides or {}
    local activated = false
    local focused = false
    local expanded = overrides.initial_expanded or false
    local last_expand_state = nil

    local ctx = {
        get_selected_item = function() return item end,
        activate_sequence = function() activated = true end,
        focus_tree = function() focused = true end,
        resolve_tree_id = function(i) return i and i.tree_id or nil end,
        tree_widget = function() return {} end,
        controls = {
            IS_TREE_ITEM_EXPANDED = function(_, _) return expanded end,
            SET_TREE_ITEM_EXPANDED = function(_, _, state)
                expanded = state
                last_expand_state = state
            end,
        },
    }
    return ctx, function()
        return {
            activated = activated,
            focused = focused,
            expanded = expanded,
            last_expand_state = last_expand_state,
        }
    end
end

print("\n=== Project Browser Keymap Tests ===")

-- =========================================================================
-- Return on master_clip → activates (loads into source monitor)
-- =========================================================================
print("Test: Return on master_clip activates")
do
    local ctx, state = make_ctx({ type = "master_clip", clip_id = "mc1" })
    local handled = keymap.handle({ key = KEY_RETURN }, ctx)
    local s = state()
    assert(handled == true, "Return on master_clip must be handled")
    assert(s.activated, "master_clip must activate on Return")
    assert(s.focused, "focus_tree must be called after activation")
end

-- =========================================================================
-- Return on timeline → activates (loads into timeline panel)
-- =========================================================================
print("Test: Return on timeline activates")
do
    local ctx, state = make_ctx({ type = "timeline", id = "seq1" })
    local handled = keymap.handle({ key = KEY_RETURN }, ctx)
    local s = state()
    assert(handled == true, "Return on timeline must be handled")
    assert(s.activated, "timeline must activate on Return")
    assert(s.focused, "focus_tree must be called after activation")
end

-- =========================================================================
-- Return on bin → toggles expand/collapse (does NOT activate)
-- =========================================================================
print("Test: Return on bin toggles expand")
do
    local ctx, state = make_ctx({ type = "bin", id = "bin1", tree_id = "t_bin1" })
    local handled = keymap.handle({ key = KEY_RETURN }, ctx)
    local s = state()
    assert(handled == true, "Return on bin must be handled")
    assert(not s.activated, "bin must NOT activate on Return")
    assert(s.expanded == true, "bin must expand on first Return")
    assert(s.focused, "focus_tree must be called after toggle")
end

-- =========================================================================
-- Return on collapsed bin → expands; on expanded bin → collapses
-- =========================================================================
print("Test: Return toggles bin expand state")
do
    local ctx, state = make_ctx(
        { type = "bin", id = "bin2", tree_id = "t_bin2" },
        { initial_expanded = true })
    local handled = keymap.handle({ key = KEY_RETURN }, ctx)
    local s = state()
    assert(handled == true)
    assert(s.expanded == false, "expanded bin must collapse on Return")
end

-- =========================================================================
-- Enter key (numpad) also works
-- =========================================================================
print("Test: Enter (numpad) on master_clip activates")
do
    local ctx, state = make_ctx({ type = "master_clip", clip_id = "mc2" })
    local handled = keymap.handle({ key = KEY_ENTER }, ctx)
    local s = state()
    assert(handled == true, "Enter on master_clip must be handled")
    assert(s.activated, "master_clip must activate on Enter")
end

-- =========================================================================
-- Non-Return key → not handled
-- =========================================================================
print("Test: Non-Return key ignored")
do
    local ctx, _ = make_ctx({ type = "master_clip", clip_id = "mc3" })
    local handled = keymap.handle({ key = 65 }, ctx)  -- 'A'
    assert(handled == false, "non-Return key must not be handled")
end

-- =========================================================================
-- No selection → not handled
-- =========================================================================
print("Test: No selection → not handled")
do
    local ctx, _ = make_ctx(nil)
    local handled = keymap.handle({ key = KEY_RETURN }, ctx)
    assert(handled == false, "Return with no selection must not be handled")
end

-- =========================================================================
-- Numeric event (bare keycode, not table) still works
-- =========================================================================
print("Test: Numeric event (bare keycode)")
do
    local ctx, state = make_ctx({ type = "timeline", id = "seq2" })
    local handled = keymap.handle(KEY_RETURN, ctx)
    local s = state()
    assert(handled == true, "numeric keycode Return must be handled")
    assert(s.activated, "timeline must activate with numeric keycode")
end

print("\n✅ test_project_browser_keymap.lua passed")
