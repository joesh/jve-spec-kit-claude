#!/usr/bin/env luajit
-- Retroactive test: Tab/Backtab in the keyboard dispatcher never returns
-- false from the Tab branch (which would let Qt's native focusNextPrevChild
-- cycle across panel boundaries). Per Joe's rule: Tab NEVER escapes one
-- panel to another.
--
-- The Tab branch MUST either:
--   - dispatch via registry (return true), or
--   - call qt_cycle_panel_focus on the focused panel widget (return true), or
--   - fall back to consume silently (return true).
-- The prior code had a `return false` fall-through that would trigger Qt
-- native cycling, causing Tab from Inspector to jump to timeline. This
-- source-inspection test guards that invariant at test time.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
local test_env = require("test_env")

print("=== keyboard_shortcuts: Tab branch never returns false ===\n")

local ks_path = test_env.resolve_repo_path("src/lua/core/keyboard_shortcuts.lua")
local fh = assert(io.open(ks_path, "r"), "cannot open " .. ks_path)
local src = fh:read("*a"); fh:close()

-- Extract the Tab branch: from the opening `if key == KEY.Tab or key == KEY.Backtab then`
-- to the matching `end` that closes it. This is a naive bracket-matcher — works
-- because the Tab branch is top-level inside handle_key_impl, so the first
-- `end` that returns us to handle_key_impl's indentation closes it.
local tab_branch_start, tab_branch_end
do
    local s = src:find("if key == KEY%.Tab or key == KEY%.Backtab then")
    assert(s, "could not locate Tab branch start in keyboard_shortcuts.lua")
    tab_branch_start = s
    -- Scan forward for `    end` (4-space-aligned) which closes the Tab branch.
    local next_end = src:find("\n    end\n", s)
    assert(next_end, "could not locate end of Tab branch")
    tab_branch_end = next_end + 8  -- include the "    end\n"
end

local tab_branch = src:sub(tab_branch_start, tab_branch_end)

local pass, fail = 0, 0
local function check(label, ok, msg) if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. label .. (msg and (": " .. msg) or "")) end end

-- The Tab branch must contain no standalone `return false` that would let
-- Qt's native focusNextPrevChild fire and escape the panel. Return-false on
-- Tab is forbidden under the panel-containment rule.
-- Allow `return false` ONLY in the floating-window text-input branch
-- (find_dialog's own field cycling — not a main-panel Tab).
local returns_false_count = 0
for line in tab_branch:gmatch("[^\n]+") do
    -- Skip comments
    local stripped = line:match("^%s*(.-)%s*$") or ""
    if not stripped:find("^%-%-") then
        if stripped:find("^return%s+false$") or stripped:find("^return%s+false%s*%-") then
            returns_false_count = returns_false_count + 1
        end
    end
end

-- Exactly ONE return false is allowed: the find_dialog floating-window
-- text-input case. That branch's preceding `if` mentions
-- `focus_outside_main_window and focus_is_text_input`. No more, no less.
check("Tab branch has at most one `return false` (the find_dialog case)",
    returns_false_count <= 1,
    "found " .. returns_false_count .. " return-false lines; each one is a panel-escape hazard")

-- The Tab branch must mention qt_cycle_panel_focus (our containment path).
check("Tab branch calls qt_cycle_panel_focus",
    tab_branch:find("qt_cycle_panel_focus") ~= nil,
    "expected qt_cycle_panel_focus (panel-local focus cycling) in Tab branch")

-- The Tab branch must mention focus_manager.focus_panel_widget — how we
-- resolve the focused panel's container widget to pass to cycle_panel_focus.
check("Tab branch calls focus_manager.focus_panel_widget",
    tab_branch:find("focus_panel_widget") ~= nil,
    "expected focus_panel_widget lookup in Tab branch")

-- focus_manager.focus_panel_widget must exist and be callable.
local focus_manager = require("ui.focus_manager")
check("focus_manager exposes focus_panel_widget",
    type(focus_manager.focus_panel_widget) == "function")
check("focus_manager.focus_panel_widget handles unknown panel_id cleanly",
    focus_manager.focus_panel_widget("nonexistent") == nil)

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_keyboard_tab_panel_containment.lua passed")
