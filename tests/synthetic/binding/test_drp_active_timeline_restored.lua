-- Regression: after importing a DRP, the resulting project must know which
-- timeline to open and which tabs to restore — even when the DRP was saved
-- without a SequenceTabsData binary blob (e.g. anamnesis-gold-timeline.drp).
--
-- Fast (the gold-timeline fixture is 4.6MB, ~4s) — the 41MB anamnesis
-- WITH-SequenceTabsData case lives in test_drp_anamnesis_full Phase 7.
--
-- Domain behavior under test:
--   1. The project's "active sequence" (last_open_sequence_id) MUST be set
--      and MUST point to a real sequence in the resulting .jvp.
--   2. The project's "open tabs" (open_sequence_ids) MUST be a non-empty list
--      of real sequence ids.
--   3. The active sequence MUST appear in the open-tabs list (you can't have
--      an active tab that isn't open).
--
-- Failure mode this catches: when FieldsBlob lacks SequenceTabsData, the
-- importer previously silently skipped writing these settings, so the editor
-- fell back to sequences[1] on open — wrong timeline, single tab.

require("test_env")

local open_project = require("core.commands.open_project")
local database = require("core.database")
local test_env = require("test_env")

local function assert_post_import_invariants(drp_fixture, jvp_path)
    os.remove(jvp_path)
    os.remove(jvp_path .. "-wal")
    os.remove(jvp_path .. "-shm")

    print(string.format("\n--- Convert %s ---", drp_fixture))
    local ok, err = open_project._convert_drp_to_jvp(drp_fixture, jvp_path)
    assert(ok, "convert failed: " .. tostring(err))

    local pid = database.get_current_project_id()
    assert(pid and pid ~= "", "no current project_id after convert")

    local sequences = database.load_sequences(pid)
    assert(sequences and #sequences > 0,
        "no sequences created by import — project is empty")
    local seq_ids = {}
    for _, s in ipairs(sequences) do seq_ids[s.id] = s end

    local active_id = database.get_project_setting(pid, "last_open_sequence_id")
    local open_ids  = database.get_project_setting(pid, "open_sequence_ids")

    -- Invariant 1: active is set and real
    assert(active_id and active_id ~= "",
        "last_open_sequence_id missing — editor will fall back to arbitrary sequence")
    assert(seq_ids[active_id],
        string.format("last_open_sequence_id=%s is not among the %d created sequences",
            active_id, #sequences))

    -- Invariant 2: open_ids is a real, non-empty list
    assert(type(open_ids) == "table",
        "open_sequence_ids missing or not a table — tab list can't be restored")
    assert(#open_ids > 0,
        "open_sequence_ids is empty — no tabs will be shown on open")
    for i, id in ipairs(open_ids) do
        assert(seq_ids[id],
            string.format("open_sequence_ids[%d]=%s is not a real sequence", i, id))
    end

    -- Invariant 3: active is in the open list
    local active_in_open = false
    for _, id in ipairs(open_ids) do
        if id == active_id then active_in_open = true; break end
    end
    assert(active_in_open,
        string.format("last_open_sequence_id=%s not found in open_sequence_ids %s",
            active_id, table.concat(open_ids, ",")))

    print(string.format("  OK: active=%s (%q), open_count=%d",
        active_id, seq_ids[active_id].name, #open_ids))
end

print("=== test_drp_active_timeline_restored.lua ===")

-- The fixture saved WITHOUT SequenceTabsData (the fallback path this test
-- exists for): project.xml has <TimelineVec/> empty, TimelineHandleVec
-- populated, CurrentTimelineIndex=0. The active timeline must still resolve.
-- The WITH-SequenceTabsData case (anamnesis joe edit.drp) is covered by
-- test_drp_anamnesis_full Phase 7, which parses that 41MB fixture once.
assert_post_import_invariants(
    test_env.require_fixture("tests/fixtures/resolve/anamnesis-gold-timeline.drp"),
    "/tmp/jve/test_drp_active_timeline_gold.jvp")

print("✅ test_drp_active_timeline_restored.lua passed")
