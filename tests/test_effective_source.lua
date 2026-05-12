#!/usr/bin/env luajit

-- 015 F2: effective source = browser-selected master_clip (when browser
-- is the active panel) OR source-viewer loaded master (otherwise).
--
-- Domain behavior under test:
--   T1: initial state — no source loaded, no browser selection → nil.
--   T2: source-viewer load → effective source updates to loaded master.
--   T3: browser becomes active w/ no selection → effective source unchanged.
--   T4: browser-selected master_clip → effective source flips to that clip.
--   T5: panel switches away from browser → effective source reverts to
--       source-viewer's master.
--   T6: panel switches back to browser → effective source flips again.
--   T7: spurious selection_hub fires that don't change the computed value
--       do NOT emit effective_source_changed.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local Signals       = require("core.signals")
local selection_hub = require("ui.selection_hub")
local effective_src = require("core.effective_source")

print("=== test_effective_source.lua ===")

-- Clean signal handlers from any prior test setup so our listener counts
-- emits accurately.
local emit_log = {}
local listener_token = Signals.connect("effective_source_changed",
    function(new_id, prev_id)
        emit_log[#emit_log + 1] = { new = new_id, prev = prev_id }
    end)

local function clear_emits()
    emit_log = {}
end

local function last_emit()
    return emit_log[#emit_log]
end

-- NOTE: don't call selection_hub._reset_for_tests() — it wipes the
-- subscription effective_source registered at require-time. Instead
-- put the hub in a known state via its public API.
selection_hub.set_active_panel("timeline")  -- not browser; clears _browser_master
clear_emits()

-- ── T1: nothing set ─────────────────────────────────────────────────────
print("\n-- T1: empty state")
assert(effective_src.get() == nil,
    "T1: get() must be nil when no source loaded and no browser selection")

-- ── T2: source viewer loads a master ────────────────────────────────────
print("-- T2: source viewer load updates effective source")
clear_emits()
Signals.emit("source_loaded_changed", "master-A", nil)
assert(effective_src.get() == "master-A", string.format(
    "T2: get() must follow source_viewer load; got %s",
    tostring(effective_src.get())))
local e = last_emit()
assert(e and e.new == "master-A" and e.prev == nil,
    "T2: effective_source_changed must emit (master-A, nil)")
assert(#emit_log == 1, "T2: exactly one emit expected")

-- ── T3: browser becomes active with no master_clip selected ─────────────
print("-- T3: browser active, no selection — effective source unchanged")
clear_emits()
selection_hub.update_selection("project_browser", {})
selection_hub.set_active_panel("project_browser")
assert(effective_src.get() == "master-A",
    "T3: browser active without master_clip selection must NOT shadow source-viewer master")
assert(#emit_log == 0,
    "T3: no emit expected — computed value unchanged")

-- ── T4: browser selects a master_clip → effective source flips ──────────
-- Use the real shape that browser_state.normalize_master_clip emits:
--   item_type = "master_clip"; master_sequence_id is the field that names
--   the master sequence. (Earlier draft of this test invented a {type,
--   clip_id} shape that doesn't exist in the selection plumbing — rule
--   2.34: don't derive expected values from your own model.)
print("-- T4: browser master_clip selection wins")
clear_emits()
selection_hub.update_selection("project_browser",
    { { item_type = "master_clip", master_sequence_id = "master-B" } })
assert(effective_src.get() == "master-B", string.format(
    "T4: browser master_clip overrides source viewer; got %s",
    tostring(effective_src.get())))
local e2 = last_emit()
assert(e2 and e2.new == "master-B" and e2.prev == "master-A",
    "T4: emit must be (master-B, master-A)")

-- ── T5: switch active panel back to timeline → reverts to source-viewer ─
print("-- T5: leaving browser reverts to source-viewer master")
clear_emits()
selection_hub.set_active_panel("timeline")
assert(effective_src.get() == "master-A",
    "T5: with browser inactive, source-viewer master is effective")
local e5 = last_emit()
assert(e5 and e5.new == "master-A" and e5.prev == "master-B",
    "T5: emit must be (master-A, master-B)")

-- ── T6: switch back to browser — selection still there → flips again ───
print("-- T6: re-activating browser restores browser-master priority")
clear_emits()
selection_hub.set_active_panel("project_browser")
assert(effective_src.get() == "master-B",
    "T6: browser active with master-B selected → effective is master-B")
local e6 = last_emit()
assert(e6 and e6.new == "master-B" and e6.prev == "master-A",
    "T6: emit must be (master-B, master-A)")

-- ── T7: no-op selection refire must not emit ─────────────────────────────
print("-- T7: idempotent — re-emitting same selection produces no emit")
clear_emits()
selection_hub.update_selection("project_browser",
    { { item_type = "master_clip", master_sequence_id = "master-B" } })
assert(effective_src.get() == "master-B",
    "T7: still master-B after no-op selection refire")
assert(#emit_log == 0,
    "T7: re-asserting same selection must not emit effective_source_changed")

-- ── T8: nested-sequence (timeline) selection counts as a source ─────────
print("-- T8: timeline item with id is also insertable")
clear_emits()
selection_hub.set_active_panel("timeline")   -- clear browser-source first
selection_hub.update_selection("project_browser",
    { { item_type = "timeline", id = "nested-seq-Q" } })
selection_hub.set_active_panel("project_browser")
assert(effective_src.get() == "nested-seq-Q", string.format(
    "T8: timeline (nested sequence) selection must be the effective source; got %s",
    tostring(effective_src.get())))

-- ── T9: master_seq_id_of predicate directly ─────────────────────────────
print("-- T9: master_seq_id_of predicate")
assert(effective_src.master_seq_id_of(
    { item_type = "master_clip", master_sequence_id = "m1" }) == "m1",
    "T9a: master_clip with master_sequence_id returns it")
assert(effective_src.master_seq_id_of(
    { item_type = "timeline", id = "seq2" }) == "seq2",
    "T9b: timeline with id returns it")
assert(effective_src.master_seq_id_of(
    { item_type = "bin", id = "binX" }) == nil,
    "T9c: bin is not insertable → nil")
assert(effective_src.master_seq_id_of(
    { item_type = "master_clip", master_sequence_id = "" }) == nil,
    "T9d: master_clip with empty master_sequence_id → nil")
assert(effective_src.master_seq_id_of("not a table") == nil,
    "T9e: non-table input → nil (predicate contract, not failure)")
assert(effective_src.master_seq_id_of(nil) == nil,
    "T9f: nil input → nil")

Signals.disconnect(listener_token)

print("\n✅ test_effective_source.lua passed")
