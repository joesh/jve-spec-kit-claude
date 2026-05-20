#!/usr/bin/env luajit

-- 015 F2: effective source — PRECEDENCE rule (not recency).
--
--   1. If project_browser is the active panel AND its selection has an
--      insertable item, that item is the source.
--   2. Otherwise: whatever sequence is loaded in the source viewer
--      (may be nil = no source).
--
-- "Active panel" comes from selection_hub — the currently focused panel,
-- not a sticky historical state. Click into the timeline and the browser
-- stops "owning" the source the instant focus moves, even if a selection
-- persists in the browser.
--
-- Domain behavior under test:
--   T1: empty state → nil.
--   T2: source-viewer load → effective = loaded master (rule 2).
--   T3: browser becomes active with EMPTY selection → still source viewer
--       (rule 1's selection precondition fails → fall through to rule 2).
--   T4: browser becomes active with master_clip selected → flips to it
--       (rule 1 applies).
--   T5: focus shifts to TIMELINE — browser is NO LONGER active. Rule 2
--       takes over, source viewer wins. REGRESSION from the bug: the
--       prior recency-based algorithm would have left the browser's pick
--       in force, so F10 with the rec sequence selected in the browser
--       and timeline focused returned the rec id and tripped the cycle
--       guard inside _place_shared.
--   T6: source_monitor active — same as T5, source viewer wins.
--   T7: re-activate browser → rule 1 applies again.
--   T8: idempotent — re-emitting same selection produces no emit.
--   T9: timeline (nested-sequence) item is a valid source.
--   T10: master_seq_id_of predicate.
--   T11: _reset_for_tests clears state.
--   T12: pick_for_edit — missing_item (no source at all).
--   T13: pick_for_edit — not_insertable (browser active w/ bin).
--   T14: pick_for_edit — cycle_self (source == destination).
--   T15: pick_for_edit — happy path returns seq id.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local Signals       = require("core.signals")
local selection_hub = require("ui.selection_hub")
local effective_src = require("core.effective_source")

print("=== test_effective_source.lua ===")

local emit_log = {}
local listener_token = Signals.connect("effective_source_changed",
    function(new_id, prev_id)
        emit_log[#emit_log + 1] = { new = new_id, prev = prev_id }
    end)

local function clear_emits() emit_log = {} end
local function last_emit()   return emit_log[#emit_log] end

-- Bring the hub to a known state without wiping our subscription.
selection_hub.set_active_panel("timeline")
selection_hub.update_selection("project_browser", {})
clear_emits()

-- ── T1: empty state ─────────────────────────────────────────────────────
print("\n-- T1: empty state")
effective_src._reset_for_tests()
assert(effective_src.get() == nil,
    "T1: get() must be nil when nothing is loaded or selected")

-- ── T2: source viewer load updates effective source ─────────────────────
print("-- T2: source viewer load updates effective source")
clear_emits()
Signals.emit("source_loaded_changed", "master-A", nil)
assert(effective_src.get() == "master-A", string.format(
    "T2: source viewer load → effective; got %s",
    tostring(effective_src.get())))
local e = last_emit()
assert(e and e.new == "master-A" and e.prev == nil,
    "T2: emit (master-A, nil)")

-- ── T3: browser active w/ empty selection → source viewer wins ──────────
print("-- T3: browser active + empty selection → fall through to source viewer")
clear_emits()
selection_hub.update_selection("project_browser", {})
selection_hub.set_active_panel("project_browser")
assert(effective_src.get() == "master-A",
    "T3: empty browser selection must not shadow source-viewer master")
assert(#emit_log == 0, "T3: no emit — computed value unchanged")

-- ── T4: browser active + master_clip selected → browser wins ────────────
print("-- T4: browser active + master_clip selected → rule 1")
clear_emits()
selection_hub.update_selection("project_browser",
    { { item_type = "master_clip", master_sequence_id = "master-B" } })
assert(effective_src.get() == "master-B", string.format(
    "T4: browser-active + insertable item → that item; got %s",
    tostring(effective_src.get())))
local e2 = last_emit()
assert(e2 and e2.new == "master-B" and e2.prev == "master-A",
    "T4: emit (master-B, master-A)")

-- ── T5: focus → timeline; source viewer wins (regression) ───────────────
print("-- T5: focus → timeline (not browser) — source viewer wins")
clear_emits()
selection_hub.set_active_panel("timeline")
assert(effective_src.get() == "master-A", string.format(
    "T5: browser not active → rule 2 — source viewer master-A wins; got %s",
    tostring(effective_src.get())))
local e5 = last_emit()
assert(e5 and e5.new == "master-A" and e5.prev == "master-B",
    "T5: emit (master-A, master-B) — precedence flipped on focus shift")

-- ── T6: source_monitor active — also not browser, source viewer wins ────
print("-- T6: source_monitor active — rule 2 applies")
clear_emits()
selection_hub.set_active_panel("source_monitor")
assert(effective_src.get() == "master-A",
    "T6: source_monitor isn't browser → source viewer wins")
assert(#emit_log == 0, "T6: no emit — already master-A")

-- ── T7: re-activate browser → rule 1 applies again ──────────────────────
print("-- T7: re-activate browser → rule 1 applies again")
clear_emits()
selection_hub.set_active_panel("project_browser")
assert(effective_src.get() == "master-B",
    "T7: browser active again w/ master-B selected → master-B")
local e7 = last_emit()
assert(e7 and e7.new == "master-B" and e7.prev == "master-A",
    "T7: emit (master-B, master-A)")

-- ── T8: idempotent re-selection produces no emit ────────────────────────
print("-- T8: idempotent — re-emitting same selection produces no emit")
clear_emits()
selection_hub.update_selection("project_browser",
    { { item_type = "master_clip", master_sequence_id = "master-B" } })
assert(effective_src.get() == "master-B", "T8: still master-B")
assert(#emit_log == 0, "T8: no emit on no-op re-selection")

-- ── T9: timeline (nested-sequence) item is insertable ───────────────────
print("-- T9: timeline item with id is insertable")
clear_emits()
selection_hub.update_selection("project_browser",
    { { item_type = "timeline", id = "nested-seq-Q" } })
assert(effective_src.get() == "nested-seq-Q", string.format(
    "T9: timeline item id is effective source; got %s",
    tostring(effective_src.get())))

-- ── T10: master_seq_id_of predicate ─────────────────────────────────────
print("-- T10: master_seq_id_of predicate")
assert(effective_src.master_seq_id_of(
    { item_type = "master_clip", master_sequence_id = "m1" }) == "m1",
    "T10a: master_clip → master_sequence_id")
assert(effective_src.master_seq_id_of(
    { item_type = "timeline", id = "seq2" }) == "seq2",
    "T10b: timeline → id")
assert(effective_src.master_seq_id_of(
    { item_type = "bin", id = "binX" }) == nil,
    "T10c: bin → nil")
assert(effective_src.master_seq_id_of(
    { item_type = "master_clip", master_sequence_id = "" }) == nil,
    "T10d: empty master_sequence_id → nil")
assert(effective_src.master_seq_id_of("not a table") == nil,
    "T10e: non-table → nil")
assert(effective_src.master_seq_id_of(nil) == nil, "T10f: nil → nil")

-- ── T11: _reset_for_tests clears all state ──────────────────────────────
print("-- T11: _reset_for_tests clears all state")
effective_src._reset_for_tests()
assert(effective_src.get() == nil, "T11: get() nil after reset")

-- ── T12: pick_for_edit — missing_item ────────────────────────────────
print("-- T12: pick_for_edit — missing_item when no source")
-- Reset, no source viewer load, browser empty, browser active.
effective_src._reset_for_tests()
selection_hub.update_selection("project_browser", {})
selection_hub.set_active_panel("project_browser")
local seq, problem = effective_src.pick_for_edit("rec-1", "Overwrite")
assert(seq == nil, "T12: no source → nil")
assert(problem and problem.kind == "missing_item",
    "T12: problem.kind == missing_item")
assert(problem.cmd == "Overwrite",
    "T12: problem.cmd carries command name for popup")

-- ── T13: pick_for_edit — not_insertable ──────────────────────────────
print("-- T13: pick_for_edit — not_insertable")
selection_hub.update_selection("project_browser",
    { { item_type = "bin", id = "bin-1", display_name = "Trash Takes" } })
local seq13, problem13 = effective_src.pick_for_edit("rec-1", "Overwrite")
assert(seq13 == nil, "T13: bin selection → nil")
assert(problem13 and problem13.kind == "not_insertable",
    "T13: problem.kind == not_insertable")
assert(problem13.label == "Trash Takes",
    "T13: problem.label carries item display_name")

-- ── T14: pick_for_edit — cycle_self (source == destination) ──────────
print("-- T14: pick_for_edit — cycle_self short-circuit")
-- We pin Sequence.get_name and Cycle.would_create_cycle out of the
-- way: cycle_self returns BEFORE Cycle.would_create_cycle runs (so no
-- DB is required), but Sequence.get_name DOES run. Stub it black-box
-- via the package.loaded module table.
local sequence_mod = require("models.sequence")
local orig_get_name = sequence_mod.get_name
sequence_mod.get_name = function(id) return "Master Timeline" end
-- Browser active, selecting the very same id as the destination.
selection_hub.update_selection("project_browser",
    { { item_type = "timeline", id = "rec-1" } })
local seq14, problem14 = effective_src.pick_for_edit("rec-1", "Overwrite")
assert(seq14 == nil, "T14: source == rec → nil")
assert(problem14 and problem14.kind == "cycle_self",
    "T14: problem.kind == cycle_self")
assert(problem14.seq_name == "Master Timeline",
    "T14: problem.seq_name comes from Sequence.get_name")
sequence_mod.get_name = orig_get_name

-- ── T15: pick_for_edit — happy path ──────────────────────────────────
print("-- T15: pick_for_edit — happy path returns seq id, no problem")
-- Distinct source vs destination, browser active. Stub get_name so the
-- transitive-cycle branch (which calls Cycle.would_create_cycle requiring
-- a DB) doesn't fire; we set up a same-id check by-pass via a destination
-- different from the source AND stub Cycle.would_create_cycle to return
-- false (black-box: contract is "no cycle → return seq").
local cycle_mod = require("models.cycle")
local orig_would = cycle_mod.would_create_cycle
cycle_mod.would_create_cycle = function(_a, _b) return false end
sequence_mod.get_name = function(id) return "named-" .. id end
selection_hub.update_selection("project_browser",
    { { item_type = "master_clip", master_sequence_id = "src-1" } })
local seq15, problem15 = effective_src.pick_for_edit("rec-1", "Overwrite")
assert(seq15 == "src-1", string.format(
    "T15: happy path returns source id; got %s", tostring(seq15)))
assert(problem15 == nil, "T15: no problem on happy path")
cycle_mod.would_create_cycle = orig_would
sequence_mod.get_name = orig_get_name

-- ── T16: pick_for_edit input invariants (pcall-based) ────────────────
-- ENGINEERING.md 2.32: assert-based failure paths MUST be exercised via
-- pcall so the assert message is part of the regression contract.
print("-- T16: pick_for_edit input invariants")
do
    local ok, err

    ok, err = pcall(effective_src.pick_for_edit, nil, "Overwrite")
    assert(not ok, "T16a: nil rec_id must assert")
    assert(tostring(err):find("rec_id required"),
        "T16a: assert message must mention 'rec_id required'; got: " .. tostring(err))

    ok, err = pcall(effective_src.pick_for_edit, "", "Overwrite")
    assert(not ok, "T16b: empty rec_id must assert")
    assert(tostring(err):find("rec_id required"),
        "T16b: assert message must mention 'rec_id required'; got: " .. tostring(err))

    ok, err = pcall(effective_src.pick_for_edit, "rec-1", nil)
    assert(not ok, "T16c: nil cmd_name must assert")
    assert(tostring(err):find("cmd_name required"),
        "T16c: assert message must mention 'cmd_name required'; got: " .. tostring(err))

    ok, err = pcall(effective_src.pick_for_edit, "rec-1", "")
    assert(not ok, "T16d: empty cmd_name must assert")
    assert(tostring(err):find("cmd_name required"),
        "T16d: assert message must mention 'cmd_name required'; got: " .. tostring(err))
end

-- ── T17: pick_for_edit asserts on browser item missing display_name ──
print("-- T17: not_insertable path requires display_name from normalizer")
do
    -- Browser active, single non-insertable item with NO display_name
    -- (simulating a normalize_* contract violation).
    selection_hub.update_selection("project_browser",
        { { item_type = "bin", id = "bin-1" } })  -- display_name missing
    selection_hub.set_active_panel("project_browser")
    local ok, err = pcall(effective_src.pick_for_edit, "rec-1", "Overwrite")
    assert(not ok, "T17: missing display_name must assert (normalizer contract)")
    assert(tostring(err):find("display_name"),
        "T17: assert message must mention 'display_name'; got: " .. tostring(err))
end

Signals.disconnect(listener_token)

-- =============================================================================
-- 019: live-bound override channel (FR-016d)
-- =============================================================================
-- Per contracts/effective_source_pass_through.md. Three single-direction
-- entry points carry (seq_id, in, out) triple when live-bound; clear when
-- staged or unloaded. get() return shape grows from a single seq_id to an
-- optional triple. Browser-active still wins (015 precedence rule).

print("\n--- 019 override channel ---")

-- Reset only effective_src here; do NOT reset selection_hub because
-- effective_src registered as a listener at module load and
-- selection_hub._reset_for_tests() would silently drop that subscription
-- (selection_hub re-keys its listeners on `next_token`, which starts from
-- 0 on reset). After this section's test cases the existing T1–T17
-- assertions don't run again, so it's fine to inherit selection_hub state.
effective_src._reset_for_tests()
selection_hub.update_selection("project_browser", {})
selection_hub.set_active_panel("source_monitor")

-- T18: live-bound entry — get() returns the triple.
do
    effective_src._set_source_viewer_clip("source-seq-X", 100, 250)
    local got_seq, in_, out = effective_src.get()
    assert(got_seq == "source-seq-X", string.format(
        "T18: live-bound get() seq must equal _set arg; got %s", tostring(got_seq)))
    assert(in_ == 100, string.format(
        "T18: live-bound get() in must equal _set arg; got %s", tostring(in_)))
    assert(out == 250, string.format(
        "T18: live-bound get() out must equal _set arg; got %s", tostring(out)))
end

-- T19: staged entry — get() returns just the seq, in/out are nil.
do
    effective_src._set_source_viewer_sequence("staged-seq-Y")
    local got_seq, in_, out = effective_src.get()
    assert(got_seq == "staged-seq-Y", string.format(
        "T19: staged get() seq; got %s", tostring(got_seq)))
    assert(in_ == nil and out == nil, string.format(
        "T19: staged get() in/out must be nil; got (%s, %s)",
        tostring(in_), tostring(out)))
end

-- T20: clear — all three nil.
do
    effective_src._set_source_viewer_clip("source-seq-X", 100, 250)
    effective_src._clear_source_viewer()
    local got_seq, in_, out = effective_src.get()
    assert(got_seq == nil and in_ == nil and out == nil, string.format(
        "T20: after _clear_source_viewer, all three must be nil; got (%s, %s, %s)",
        tostring(got_seq), tostring(in_), tostring(out)))
end

-- T21: browser-active precedence still wins — even with a live-bound
-- override set, an insertable browser selection takes priority.
-- Note: only effective_src is reset; selection_hub keeps its registered
-- listeners (effective_src subscribes to selection_hub at module-load and
-- selection_hub._reset_for_tests() would silently drop that subscription).
do
    effective_src._reset_for_tests()
    effective_src._set_source_viewer_clip("source-seq-X", 100, 250)
    selection_hub.update_selection("project_browser", {
        {
            item_type           = "master_clip",
            clip_id             = "browser-clip",
            master_sequence_id  = "browser-master",
            display_name        = "Browser Master",
        },
    })
    selection_hub.set_active_panel("project_browser")

    local got_seq, in_, out = effective_src.get()
    assert(got_seq == "browser-master", string.format(
        "T21: browser-active must win over live-bound source viewer override; "
        .. "got seq=%s", tostring(got_seq)))
    -- Browser source has no override marks; in/out must be nil even when
    -- live-bound override was previously set on a different sequence.
    assert(in_ == nil and out == nil, string.format(
        "T21: browser-sourced get() must not leak the prior live-bound in/out "
        .. "overrides; got (%s, %s)", tostring(in_), tostring(out)))
end

print("  ✓ live-bound override channel: set/clear/precedence")

print("\n✅ test_effective_source.lua passed")
