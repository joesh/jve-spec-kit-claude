#!/usr/bin/env luajit
-- Regression: opening a second project while the first is displayed must
-- not crash the timeline.
--
-- Domain behavior: when the active project is about to change, the
-- timeline stops showing the outgoing project's sequence. A large import
-- (e.g. a big DRP) pumps Qt events mid-swap to drive the progress bar,
-- which reentrantly repaints the timeline. If the strip's displayed tab
-- still points at the OUTGOING project's sequence, that repaint asks the
-- INCOMING database for a sequence it does not contain and the editor
-- crashes. After the swap the timeline must render blank (no marks, no
-- displayed tab) until the new project loads its own sequence.
--
-- Observed in the field on the "anamnesis joe edit" DRP:
--   timeline_tab.lua:49 TimelineTab:get_marks: sequence_id=... not found

require("test_env")
print("=== test_project_swap_detaches_timeline.lua ===")

local setup = require("synthetic.helpers.test_017_setup")
setup.install_qt_stub()

-- Project A: 'p' with record sequence 'rec', displayed in the timeline.
local h = setup.fresh_project_db("test_project_swap_detaches_timeline_A.db")

local timeline_state = require("ui.timeline.timeline_state")
timeline_state.switch_to_record_tab("rec")

-- Precondition: a tab is displayed and its marks resolve cleanly.
assert(timeline_state.get_tab_strip():get_displayed() ~= nil,
    "precondition: a record tab must be displayed before the swap")
do
    local ok, err = pcall(timeline_state.get_display_mark_in)
    assert(ok, "precondition: display marks must resolve while project A is live: "
        .. tostring(err))
end

-- Swap to project B, which does NOT contain sequence 'rec'. database.init
-- emits project_will_change before closing the outgoing connection — the
-- exact moment the timeline must detach. Apply the schema so the INCOMING
-- DB has a (rowless) sequences table, mirroring a freshly-created project:
-- Sequence.load('rec') then resolves to "absent", not "no such table".
local DB_B = "/tmp/jve/test_project_swap_detaches_timeline_B.db"
os.remove(DB_B)
h.database.init(DB_B)
h.database.get_connection():exec(require("import_schema"))

-- A reentrant repaint after the swap goes through get_display_mark_in.
-- This must NOT raise: the displayed tab should have been detached by the
-- project_will_change handler, so the accessor returns nil (blank timeline).
local ok, err = pcall(timeline_state.get_display_mark_in)
assert(ok, "get_display_mark_in must not throw after a project swap — the "
    .. "timeline must detach its displayed tab on project_will_change: "
    .. tostring(err))

assert(timeline_state.get_display_mark_in() == nil,
    "no display marks should resolve once the outgoing project is gone")
assert(timeline_state.get_display_mark_out() == nil,
    "no display marks should resolve once the outgoing project is gone")
assert(timeline_state.get_tab_strip():get_displayed() == nil,
    "the displayed tab must be detached when the active project changes")

print("✅ test_project_swap_detaches_timeline.lua passed")
