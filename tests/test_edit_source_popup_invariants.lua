#!/usr/bin/env luajit

-- ENGINEERING.md 2.32: every assert-based failure path on a new code path
-- MUST be exercised via pcall(), and the assert message MUST be actionable
-- (mentions the function name and the offending value / field).
--
-- edit_source_popup.show is the UI layer that turns the resolver's
-- structured `problem` table into a user-visible popup. Any drift between
-- the resolver's contract (which fields are set for which kind) and the
-- popup's expectation MUST fail loudly so the contract gap is obvious
-- from the stack trace.
--
-- Domain behavior under test:
--   T1: non-table problem rejected
--   T2: problem without .kind rejected
--   T3: unknown problem.kind rejected — the popup must never silently
--       drop a contract violation between resolver and view
--   T4: each known kind requires its data fields:
--       not_insertable   → label
--       missing_item     → cmd
--       cycle_self       → seq_name
--       cycle_transitive → dest_name, src_name
--
-- This test does NOT exercise the actual Qt popup — that needs a real
-- main window. It exercises only the parameter-validation layer, which
-- is where NSF lives for this module.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

-- Stub core.qt_constants BEFORE loading edit_source_popup. The popup
-- requires qt_constants at module load to bind the DIALOG.SHOW_CONFIRM
-- entry point; in headless tests no Qt is available and we want to
-- capture the call rather than actually pop a dialog. The stub must be
-- in place before the require so the popup's local handle points at
-- our table.
local last_call = nil
package.loaded["core.qt_constants"] = {
    DIALOG = {
        SHOW_CONFIRM = function(args) last_call = args end,
    },
}

local popup = require("ui.edit_source_popup")

print("=== test_edit_source_popup_invariants.lua ===")

local function expect_assert(fn, needle, label)
    local ok, err = pcall(fn)
    assert(not ok, label .. ": expected assert, got success")
    assert(tostring(err):find(needle, 1, true), string.format(
        "%s: assert message must contain %q; got: %s",
        label, needle, tostring(err)))
end

-- ── T1: non-table problem rejected ──────────────────────────────────────
print("-- T1: non-table problem rejected")
expect_assert(function() popup.show(nil) end,
    "problem table with string .kind required",
    "T1a nil")
expect_assert(function() popup.show("oops") end,
    "problem table with string .kind required",
    "T1b string")
expect_assert(function() popup.show(42) end,
    "problem table with string .kind required",
    "T1c number")

-- ── T2: problem without .kind rejected ──────────────────────────────────
print("-- T2: problem without .kind rejected")
expect_assert(function() popup.show({}) end,
    "problem table with string .kind required",
    "T2a empty table")
expect_assert(function() popup.show({ label = "X" }) end,
    "problem table with string .kind required",
    "T2b missing kind")
expect_assert(function() popup.show({ kind = 42 }) end,
    "problem table with string .kind required",
    "T2c non-string kind")

-- ── T3: unknown problem.kind rejected ───────────────────────────────────
print("-- T3: unknown kind rejected — contract gap must surface")
expect_assert(function() popup.show({ kind = "something_new" }) end,
    "unknown problem.kind",
    "T3 unknown kind")

-- ── T4a: not_insertable requires .label ─────────────────────────────────
print("-- T4a: not_insertable requires label")
expect_assert(function() popup.show({ kind = "not_insertable" }) end,
    "requires string field \"label\"",
    "T4a missing label")
expect_assert(function() popup.show({ kind = "not_insertable", label = "" }) end,
    "requires string field \"label\"",
    "T4a empty label")

-- ── T4b: missing_item requires .cmd ─────────────────────────────────────
print("-- T4b: missing_item requires cmd")
expect_assert(function() popup.show({ kind = "missing_item" }) end,
    "requires string field \"cmd\"",
    "T4b missing cmd")
expect_assert(function() popup.show({ kind = "missing_item", cmd = "" }) end,
    "requires string field \"cmd\"",
    "T4b empty cmd")

-- ── T4c: cycle_self requires .seq_name ──────────────────────────────────
print("-- T4c: cycle_self requires seq_name")
expect_assert(function() popup.show({ kind = "cycle_self" }) end,
    "requires string field \"seq_name\"",
    "T4c missing seq_name")

-- ── T4d: cycle_transitive requires .dest_name and .src_name ─────────────
print("-- T4d: cycle_transitive requires dest_name AND src_name")
expect_assert(function() popup.show({ kind = "cycle_transitive" }) end,
    "requires string field",
    "T4d missing both")
expect_assert(function() popup.show({ kind = "cycle_transitive", dest_name = "A" }) end,
    "requires string field \"src_name\"",
    "T4d missing src_name")
expect_assert(function() popup.show({ kind = "cycle_transitive", src_name = "B" }) end,
    "requires string field \"dest_name\"",
    "T4d missing dest_name")

-- ── T5: well-formed problems pass and dispatch to SHOW_CONFIRM ──────────
-- This confirms the happy path of every kind reaches the Qt binding with
-- icon="error" + a single OK button (no Cancel — popup is informational).
print("-- T5: well-formed problems dispatch to Qt with error icon")

last_call = nil
popup.show({ kind = "not_insertable", label = "Trash Takes" })
assert(last_call and last_call.icon == "error",
    "T5 not_insertable: icon must be 'error'")
assert(last_call.confirm_text == "OK",
    "T5 not_insertable: confirm_text must be 'OK'")
assert(last_call.cancel_text == nil,
    "T5 not_insertable: no cancel button (informational, not a question)")
assert(last_call.message:find("Trash Takes", 1, true),
    "T5 not_insertable: message must embed the item label")

last_call = nil
popup.show({ kind = "missing_item", cmd = "Overwrite" })
assert(last_call.message:find("Overwrite", 1, true),
    "T5 missing_item: message must embed the command name")

last_call = nil
popup.show({ kind = "cycle_self", seq_name = "Master Timeline" })
assert(last_call.message:find("Master Timeline", 1, true),
    "T5 cycle_self: message must embed the sequence name")

last_call = nil
popup.show({ kind = "cycle_transitive",
             dest_name = "Reel 1",
             src_name  = "Reel 1 Subseq" })
assert(last_call.message:find("Reel 1", 1, true)
   and last_call.message:find("Reel 1 Subseq", 1, true),
    "T5 cycle_transitive: message must embed both dest and src names")

print("\n✅ test_edit_source_popup_invariants.lua passed")
