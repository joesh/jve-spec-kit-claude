--- Regression: closing the last remaining sequence tab must leave the editor
--- in the no-active-sequence state rather than refusing to close (the old
--- TODO hack at timeline_panel.lua:486–491) or silently reopening the
--- just-closed tab. Feature spec 010, AS-1 + FR-001..FR-003.
---
--- Domain behavior under test (no code-tracing):
---   * After the close, the timeline panel must have zero open tabs.
---   * timeline_state.get_sequence_id() must be nil (view will pull blank).
---   * The project settings that drive re-open must persist the blank state:
---       last_open_sequence_id == "" (or absent)
---       open_sequence_ids == []  (empty array, not nil)
---     so a crash immediately after close does not resurrect a phantom tab
---     on next launch.
---   * The project itself stays open — the editor is blank, not closed.
---
--- Runs inside ./build/bin/JVEEditor --test with full Qt + panels.

local ui = require("integration.ui_test_env")

print("=== test_close_last_tab_enters_blank ===")

-- 1-sequence project — the tab we're about to close IS the last tab.
local _, info = ui.launch({
    project_name = "Close Last Tab",
    num_sequences = 1,
    sequence_names = { "Alpha" },
    active_sequence = 1,
})

local database = require("core.database")
local timeline_panel = require("ui.timeline.timeline_panel")
local timeline_state = require("ui.timeline.timeline_state")

local project_id = info.project.id
local seq_id = info.sequences[1].id

-- Pre-conditions: exactly one open tab, it is the active sequence.
local open_before = timeline_panel.get_open_tab_ids()
assert(#open_before == 1 and open_before[1] == seq_id,
    "pre-condition: expected single tab for seq " .. seq_id
    .. "; got " .. table.concat(open_before, ","))
assert(timeline_state.get_sequence_id() == seq_id,
    "pre-condition: active sequence should be " .. seq_id
    .. "; got " .. tostring(timeline_state.get_sequence_id()))

-- Close the only tab.
timeline_panel.close_tab(seq_id)

-- Post-condition 1: no tabs are open.
local open_after = timeline_panel.get_open_tab_ids()
assert(#open_after == 0,
    "after closing the last tab, no tabs should remain open; got "
    .. #open_after .. " (" .. table.concat(open_after, ",") .. ")")

-- Post-condition 2: active-sequence state is blank.
assert(timeline_state.get_sequence_id() == nil,
    "after closing the last tab, get_sequence_id() must be nil so the "
    .. "timeline view renders blank; got "
    .. tostring(timeline_state.get_sequence_id()))

-- Post-condition 3: persisted tab state reflects the blank state.
local persisted_active = database.get_project_setting(project_id, "last_open_sequence_id")
assert(persisted_active == nil or persisted_active == "",
    "after closing the last tab, last_open_sequence_id must be empty or absent; "
    .. "got " .. tostring(persisted_active))

local persisted_open = database.get_project_setting(project_id, "open_sequence_ids")
-- Accept nil or empty table — both mean "no tabs were open at save time".
-- Reject anything that contains the just-closed seq_id.
if persisted_open ~= nil then
    assert(type(persisted_open) == "table",
        "open_sequence_ids must be a JSON array (table); got " .. type(persisted_open))
    assert(#persisted_open == 0,
        "after closing the last tab, open_sequence_ids must be empty; got "
        .. #persisted_open .. " (" .. table.concat(persisted_open, ",") .. ")")
end

-- Post-condition 4: the project itself is still open (its row still reachable).
local Project = require("models.project")
local project = Project.load(project_id)
assert(project and project.id == project_id,
    "project must still be open after close-last-tab; got "
    .. tostring(project and project.id))

print("✅ test_close_last_tab_enters_blank.lua passed")
