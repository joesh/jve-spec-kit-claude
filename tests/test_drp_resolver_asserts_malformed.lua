#!/usr/bin/env luajit

-- Regression: the DRP importer's tab-resolution helper must fail loudly when
-- the DRP project.xml references a timeline that cannot be translated to a
-- real Sm2Sequence. Malformed metadata is almost always a corrupted DRP or a
-- parser regression; silently dropping into the blank state would hide the
-- problem. Feature spec 010, FR-007 + clarify session.
--
-- Case taxonomy (from contracts/drp_importer.md):
--   Case 1: tabs_data empty AND handle_vec empty                 → legitimate empty (no assert)
--   Case 2: handle_vec present, CurrentTimelineIndex out of range → assert
--   Case 3: handle_vec present, referenced id has no Sm2Sequence → assert
--   Case 4: handle_vec present but CurrentTimelineIndex missing   → assert
--
-- Each case is tested via pcall with a minimal in-memory project fixture.
-- Expected error-message substrings are chosen to survive phrasing changes
-- (we key on the CLASS of malformation, not the exact sentence).

require('test_env')

-- The resolver is a module-local function in drp_importer.lua today. Expose
-- it (or a thin re-export of it) as `M._resolve_project_tab_ids` on the
-- module so tests can drive it without parsing a full DRP archive. If the
-- implementation hasn't exposed it yet, this require path will surface
-- that gap as the red signal.
local drp = require('importers.drp_importer')
local resolve = assert(drp._resolve_project_tab_ids,
    "drp_importer must expose _resolve_project_tab_ids for black-box testing")

local function make_project(tabs_data, handle_ids, cti)
    return {
        sequence_tabs_data     = tabs_data,       -- {tab_ids, active_id} or nil
        timeline_handle_vec_ids = handle_ids or {},
        current_timeline_index  = cti,
        open_timeline_ids       = {},
        active_timeline_id      = nil,
    }
end

print("=== resolve_project_tab_ids malformation contract ===")

-- ── Case 1: no tab metadata at all → legitimate empty (no assert) ──────────
do
    local proj = make_project(nil, {}, nil)
    local id_map = {}
    local ok, err = pcall(resolve, proj, id_map)
    assert(ok,
        "Case 1 (no tab metadata at all) must NOT assert — it is a legitimate "
        .. "DRP format variant that should produce an empty open-tab list. "
        .. "Got error: " .. tostring(err))
    assert(#proj.open_timeline_ids == 0,
        "Case 1 must leave open_timeline_ids empty; got length "
        .. tostring(#proj.open_timeline_ids))
    assert(proj.active_timeline_id == nil,
        "Case 1 must leave active_timeline_id nil; got "
        .. tostring(proj.active_timeline_id))
    print("  OK: Case 1 — empty inputs produce empty tab state (no assert)")
end

-- ── Case 2: CurrentTimelineIndex out of range → assert ─────────────────────
do
    local proj = make_project(nil, {"tl-a", "tl-b"}, 5)
    local id_map = {
        ["tl-a"] = {name = "A", seq_id = "seq-a"},
        ["tl-b"] = {name = "B", seq_id = "seq-b"},
    }
    local ok, err = pcall(resolve, proj, id_map)
    assert(not ok,
        "Case 2 (CTI out of range) must assert — silent acceptance would hide "
        .. "DRP file corruption. Got successful return.")
    assert(tostring(err):lower():match("out of range"),
        "Case 2 assert message must name the malformation class ('out of range'); "
        .. "got: " .. tostring(err))
    print("  OK: Case 2 — CTI=5 with 2-element vec asserts with 'out of range'")
end

-- ── Case 3: handle_vec references a timeline with no Sm2Sequence ───────────
do
    local proj = make_project(nil, {"tl-stranded"}, 0)
    local id_map = {}  -- empty → tl-stranded has no mapping
    local ok, err = pcall(resolve, proj, id_map)
    assert(not ok,
        "Case 3 (handle id with no Sm2Sequence mapping) must assert — silently "
        .. "dropping would conceal a broken DRP or parser bug. Got successful return.")
    assert(tostring(err):lower():match("no corresponding sm2sequence")
           or tostring(err):lower():match("no sm2sequence mapping"),
        "Case 3 assert message must name the malformation class (no Sm2Sequence "
        .. "mapping); got: " .. tostring(err))
    print("  OK: Case 3 — unresolvable handle id asserts")
end

-- ── Case 4: handle_vec non-empty but CurrentTimelineIndex missing ──────────
do
    local proj = make_project(nil, {"tl-a"}, nil)
    local id_map = {["tl-a"] = {name = "A", seq_id = "seq-a"}}
    local ok, err = pcall(resolve, proj, id_map)
    assert(not ok,
        "Case 4 (handle_vec populated but CTI absent) must assert — an active "
        .. "tab list without an active pointer is internally inconsistent. "
        .. "Got successful return.")
    assert(tostring(err):lower():match("currenttimelineindex"),
        "Case 4 assert message must name the missing field <CurrentTimelineIndex>; "
        .. "got: " .. tostring(err))
    print("  OK: Case 4 — missing CTI with non-empty handle_vec asserts")
end

-- ── Happy path sanity: SequenceTabsData priority 1 still succeeds ──────────
do
    local proj = make_project({tab_ids = {"seq-a", "seq-b"}, active_id = "seq-b"}, {}, nil)
    local id_map = {}
    local ok, err = pcall(resolve, proj, id_map)
    assert(ok, "priority 1 SequenceTabsData path must succeed: " .. tostring(err))
    assert(#proj.open_timeline_ids == 2, "expected 2 open ids from SequenceTabsData")
    assert(proj.active_timeline_id == "seq-b", "expected active_id to be 'seq-b'")
    print("  OK: happy path — SequenceTabsData priority 1 resolves")
end

print("✅ test_drp_resolver_asserts_malformed.lua passed")
