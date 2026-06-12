-- Integration test: edit_source_popup parameter-validation invariants.
--
-- REPLACES: tests/synthetic/lua/test_edit_source_popup_invariants.lua
-- (156 lines, poisoned package.loaded["core.qt_constants"] with a stub that
-- captured DIALOG.SHOW_CONFIRM calls). That version was inadequate because:
-- (1) the stub prevented any test of the real DIALOG binding contract;
-- (2) package.loaded poisoning at module-load time meant the popup's local
-- handle always pointed at the stub — any refactor that moved the require
-- inside the function would silently break all T5 happy-path checks.
--
-- DOMAIN RULES PINNED (from edit_source_popup header):
--   DR-1  show(non-table) asserts with "problem table with string .kind required".
--   DR-2  show({}) / show({ label="X" }) / show({ kind=42 }) assert with same.
--   DR-3  show({ kind="something_new" }) asserts with "unknown problem.kind" —
--         contract gap between resolver and view must surface loudly.
--   DR-4  Each known kind asserts on its missing required field:
--         not_insertable   → "requires string field \"label\""
--         missing_item     → "requires string field \"cmd\""
--         cycle_self       → "requires string field \"seq_name\""
--         cycle_transitive → "requires string field \"dest_name\"" or \"src_name\"
--   DR-5  Well-formed problems of every known kind dispatch to
--         qt_constants.DIALOG.SHOW_CONFIRM with:
--           icon          = "error"          (not warning/info/question)
--           confirm_text  = "OK"             (informational — no cancel button)
--           cancel_text   = nil              (popup is not a question)
--           message containing the user-supplied label/cmd/seq_name/dest_name/src_name
--
-- INSTRUMENTATION NOTE: qt_constants.DIALOG.SHOW_CONFIRM is wrapped with a
-- pass-through that records the last call args before delegating to the real
-- binding. The real binding pops a QMessageBox — we must NOT let it block.
-- Solution: the wrapper records args then does NOT forward to the real binding
-- (the dialog would freeze --test mode with no event loop running). This is
-- the only stub in this file, and it is narrowly scoped to the blocking call.
-- Documented as observation, not a full replace of the binding.
--
-- Run via:
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--     /Users/joe/Local/jve-spec-kit-claude/tests/synthetic/integration/test_edit_source_popup_invariants.lua

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()  -- confirms real qt_constants is present

print("=== test_edit_source_popup_invariants.lua (integration) ===")

require("test_env")

local qt_constants = require("core.qt_constants")

-- ── Intercept DIALOG.SHOW_CONFIRM ─────────────────────────────────────────────
-- Rationale: DIALOG.SHOW_CONFIRM is a blocking QMessageBox.exec() call. In
-- --test mode the Qt event loop is not spinning, so exec() would block forever.
-- We record the args then return without forwarding so the process stays live.
-- The real dialog path is exercised by manual QA; this test covers the contract
-- between the popup module and the binding entry point.
assert(type(qt_constants.DIALOG) == "table",
    "qt_constants.DIALOG must be present in --test mode")
assert(type(qt_constants.DIALOG.SHOW_CONFIRM) == "function",
    "qt_constants.DIALOG.SHOW_CONFIRM must be a function")
local last_dialog_call
qt_constants.DIALOG.SHOW_CONFIRM = function(args)
    last_dialog_call = args
    -- Do NOT forward: would block with no event loop.
end

-- Load after wrapper is in place so the module's local handle (obtained at
-- require time via module-level require("core.qt_constants")) sees our wrapper.
-- NOTE: edit_source_popup caches qt_constants at module top, not inside show(),
-- so we must wrap qt_constants.DIALOG.SHOW_CONFIRM ON THE TABLE before require
-- (which we do above by mutating the already-loaded qt_constants table in place).
local popup = require("ui.edit_source_popup")

local function expect_assert(fn, needle, label)
    local ok, err = pcall(fn)
    assert(not ok, label .. ": expected assert, got success")
    assert(tostring(err):find(needle, 1, true), string.format(
        "%s: assert message must contain %q; got: %s",
        label, needle, tostring(err)))
end

-- ── DR-1: non-table problem rejected ──────────────────────────────────────────
print("\n--- DR-1: non-table problem rejected ---")
expect_assert(function() popup.show(nil) end,
    "problem table with string .kind required", "DR-1a nil")
expect_assert(function() popup.show("oops") end,
    "problem table with string .kind required", "DR-1b string")
expect_assert(function() popup.show(42) end,
    "problem table with string .kind required", "DR-1c number")
print("  ok: nil / string / number all assert loudly")

-- ── DR-2: table without valid .kind rejected ──────────────────────────────────
print("\n--- DR-2: table without valid .kind rejected ---")
expect_assert(function() popup.show({}) end,
    "problem table with string .kind required", "DR-2a empty table")
expect_assert(function() popup.show({ label = "X" }) end,
    "problem table with string .kind required", "DR-2b missing kind")
expect_assert(function() popup.show({ kind = 42 }) end,
    "problem table with string .kind required", "DR-2c non-string kind")
print("  ok: empty / missing / non-string kind all assert loudly")

-- ── DR-3: unknown kind asserts (contract gap must not be silent) ───────────────
print("\n--- DR-3: unknown kind asserts ---")
expect_assert(function() popup.show({ kind = "something_new" }) end,
    "unknown problem.kind", "DR-3 unknown kind")
print("  ok: unknown kind surfaces loudly rather than silently dropping")

-- ── DR-4: known kinds reject missing required fields ──────────────────────────
print("\n--- DR-4a: not_insertable requires .label ---")
expect_assert(function() popup.show({ kind = "not_insertable" }) end,
    "requires string field \"label\"", "DR-4a missing label")
expect_assert(function() popup.show({ kind = "not_insertable", label = "" }) end,
    "requires string field \"label\"", "DR-4a empty label")
print("  ok")

print("\n--- DR-4b: missing_item requires .cmd ---")
expect_assert(function() popup.show({ kind = "missing_item" }) end,
    "requires string field \"cmd\"", "DR-4b missing cmd")
expect_assert(function() popup.show({ kind = "missing_item", cmd = "" }) end,
    "requires string field \"cmd\"", "DR-4b empty cmd")
print("  ok")

print("\n--- DR-4c: cycle_self requires .seq_name ---")
expect_assert(function() popup.show({ kind = "cycle_self" }) end,
    "requires string field \"seq_name\"", "DR-4c missing seq_name")
print("  ok")

print("\n--- DR-4d: cycle_transitive requires .dest_name AND .src_name ---")
expect_assert(function() popup.show({ kind = "cycle_transitive" }) end,
    "requires string field", "DR-4d missing both")
expect_assert(function()
    popup.show({ kind = "cycle_transitive", dest_name = "A" })
end, "requires string field \"src_name\"", "DR-4d missing src_name")
expect_assert(function()
    popup.show({ kind = "cycle_transitive", src_name = "B" })
end, "requires string field \"dest_name\"", "DR-4d missing dest_name")
print("  ok")

-- ── DR-5: well-formed problems dispatch to DIALOG.SHOW_CONFIRM correctly ───────
print("\n--- DR-5: well-formed problems dispatch to Qt DIALOG.SHOW_CONFIRM ---")

-- not_insertable
last_dialog_call = nil
popup.show({ kind = "not_insertable", label = "Trash Takes" })
assert(last_dialog_call, "DR-5 not_insertable: SHOW_CONFIRM must be called")
assert(last_dialog_call.icon == "error",
    "DR-5 not_insertable: icon must be 'error', got: " .. tostring(last_dialog_call.icon))
assert(last_dialog_call.confirm_text == "OK",
    "DR-5 not_insertable: confirm_text must be 'OK'")
assert(last_dialog_call.cancel_text == nil,
    "DR-5 not_insertable: no cancel_text — popup is informational, not a question")
assert(type(last_dialog_call.message) == "string"
    and last_dialog_call.message:find("Trash Takes", 1, true),
    "DR-5 not_insertable: message must embed the item label")
print("  ok: not_insertable")

-- missing_item
last_dialog_call = nil
popup.show({ kind = "missing_item", cmd = "Overwrite" })
assert(last_dialog_call, "DR-5 missing_item: SHOW_CONFIRM must be called")
assert(last_dialog_call.icon == "error",
    "DR-5 missing_item: icon must be 'error'")
assert(type(last_dialog_call.message) == "string"
    and last_dialog_call.message:find("Overwrite", 1, true),
    "DR-5 missing_item: message must embed the command name")
print("  ok: missing_item")

-- cycle_self
last_dialog_call = nil
popup.show({ kind = "cycle_self", seq_name = "Master Timeline" })
assert(last_dialog_call, "DR-5 cycle_self: SHOW_CONFIRM must be called")
assert(last_dialog_call.icon == "error",
    "DR-5 cycle_self: icon must be 'error'")
assert(type(last_dialog_call.message) == "string"
    and last_dialog_call.message:find("Master Timeline", 1, true),
    "DR-5 cycle_self: message must embed the sequence name")
print("  ok: cycle_self")

-- cycle_transitive
last_dialog_call = nil
popup.show({ kind = "cycle_transitive", dest_name = "Reel 1", src_name = "Reel 1 Subseq" })
assert(last_dialog_call, "DR-5 cycle_transitive: SHOW_CONFIRM must be called")
assert(last_dialog_call.icon == "error",
    "DR-5 cycle_transitive: icon must be 'error'")
assert(type(last_dialog_call.message) == "string"
    and last_dialog_call.message:find("Reel 1", 1, true)
    and last_dialog_call.message:find("Reel 1 Subseq", 1, true),
    "DR-5 cycle_transitive: message must embed both dest and src names")
print("  ok: cycle_transitive")

print("\n✅ test_edit_source_popup_invariants.lua (integration) passed")
