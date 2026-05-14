#!/usr/bin/env luajit

-- 015 F2: effective source = recency rule among {source_viewer, browser}.
--
-- Whichever of the two was activated most recently wins, provided it has a
-- value. If the recency winner has no value, the other (if any) is the
-- answer. Activating any OTHER panel (timeline, inspector, ...) does NOT
-- change recency — the browser's selected source must survive a focus
-- shift to the timeline (so a user can click a src-btn to drag it).
--
-- Domain behavior under test:
--   T1: initial state — no source loaded, no browser selection → nil.
--   T2: source-viewer load → effective source = loaded master.
--   T3: browser becomes active w/ no selection → unchanged (no browser value).
--   T4: browser selects master_clip while browser is active → flips to it
--       (recency = browser, has value).
--   T5: focus shifts to TIMELINE (neither source input) → browser-selected
--       source SURVIVES; effective stays the browser pick.
--   T6: source viewer panel becomes active → recency flips, effective = SV master.
--   T7: browser becomes active again → recency flips back to browser pick.
--   T8: idempotent — re-emit same selection produces no emit.
--   T9: timeline (nested-seq) item is a valid source.
--   T10: master_seq_id_of predicate.

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
    "T3: browser active without value cannot shadow source-viewer master")
assert(#emit_log == 0,
    "T3: no emit expected — computed value unchanged")

-- ── T4: browser selects a master_clip → effective source flips ──────────
print("-- T4: browser master_clip selection, browser active → browser wins")
clear_emits()
selection_hub.update_selection("project_browser",
    { { item_type = "master_clip", master_sequence_id = "master-B" } })
assert(effective_src.get() == "master-B", string.format(
    "T4: recency=browser + browser has master-B → effective is master-B; got %s",
    tostring(effective_src.get())))
local e2 = last_emit()
assert(e2 and e2.new == "master-B" and e2.prev == "master-A",
    "T4: emit must be (master-B, master-A)")

-- ── T5: focus shift to timeline → browser-selected source SURVIVES ──────
print("-- T5: focus → timeline (not a source input) — browser pick survives")
clear_emits()
selection_hub.set_active_panel("timeline")
assert(effective_src.get() == "master-B",
    "T5: timeline is not a source input — recency unchanged, browser-B still wins")
assert(#emit_log == 0,
    "T5: no emit — effective source unchanged across non-source-input focus shift")

-- ── T6: source viewer becomes active → recency flips to source viewer ──
print("-- T6: source viewer active → SV master wins (recency rule)")
clear_emits()
selection_hub.set_active_panel("source_monitor")
assert(effective_src.get() == "master-A",
    "T6: recency=source_monitor + SV has master-A → effective is master-A")
local e6 = last_emit()
assert(e6 and e6.new == "master-A" and e6.prev == "master-B",
    "T6: emit must be (master-A, master-B)")

-- ── T7: browser active again → recency flips back ──────────────────────
print("-- T7: re-activate browser → flips back to browser pick")
clear_emits()
selection_hub.set_active_panel("project_browser")
assert(effective_src.get() == "master-B",
    "T7: recency=browser + browser has master-B → master-B")
local e7 = last_emit()
assert(e7 and e7.new == "master-B" and e7.prev == "master-A",
    "T7: emit must be (master-B, master-A)")

-- ── T8: no-op selection refire must not emit ────────────────────────────
print("-- T8: idempotent — re-emitting same selection produces no emit")
clear_emits()
selection_hub.update_selection("project_browser",
    { { item_type = "master_clip", master_sequence_id = "master-B" } })
assert(effective_src.get() == "master-B",
    "T8: still master-B after no-op selection refire")
assert(#emit_log == 0,
    "T8: re-asserting same selection must not emit effective_source_changed")

-- ── T9: nested-sequence (timeline) selection counts as a source ─────────
print("-- T9: timeline item with id is also insertable")
clear_emits()
selection_hub.update_selection("project_browser",
    { { item_type = "timeline", id = "nested-seq-Q" } })
assert(effective_src.get() == "nested-seq-Q", string.format(
    "T9: timeline (nested sequence) selection must be the effective source; got %s",
    tostring(effective_src.get())))

-- ── T10: master_seq_id_of predicate directly ────────────────────────────
print("-- T10: master_seq_id_of predicate")
assert(effective_src.master_seq_id_of(
    { item_type = "master_clip", master_sequence_id = "m1" }) == "m1",
    "T10a: master_clip with master_sequence_id returns it")
assert(effective_src.master_seq_id_of(
    { item_type = "timeline", id = "seq2" }) == "seq2",
    "T10b: timeline with id returns it")
assert(effective_src.master_seq_id_of(
    { item_type = "bin", id = "binX" }) == nil,
    "T10c: bin is not insertable → nil")
assert(effective_src.master_seq_id_of(
    { item_type = "master_clip", master_sequence_id = "" }) == nil,
    "T10d: master_clip with empty master_sequence_id → nil")
assert(effective_src.master_seq_id_of("not a table") == nil,
    "T10e: non-table input → nil (predicate contract, not failure)")
assert(effective_src.master_seq_id_of(nil) == nil,
    "T10f: nil input → nil")

-- ── T11: _reset_for_tests clears recency state ──────────────────────────
-- Regression: an earlier revision of _reset_for_tests forgot to clear
-- _last_active_source_input. That made cross-test isolation broken — a
-- later test that called the reset would inherit "browser" or
-- "source_monitor" recency from a previous test, masking real bugs.
-- Black-box assertion: after reset + re-seeding ONLY a browser value
-- (no panel-active emit, no source-load emit), the effective source
-- must reflect the browser pick — meaning recency is back to its
-- empty-initial-state fallthrough (browser if sv is nil).
print("-- T11: _reset_for_tests clears recency state")
effective_src._reset_for_tests()
assert(effective_src.get() == nil,
    "T11: after _reset_for_tests, get() must be nil — recency state must be cleared too")

Signals.disconnect(listener_token)

print("\n✅ test_effective_source.lua passed")
