-- Zombie-tab cleanup: when a sequence is deleted, any open timeline tab
-- pointing at it must close. Reproduces the cascade tail of Joe's
-- 2026-05-14 TSO bug: a DeleteSequence (legitimately on the user's
-- current branch) left an open tab pointing at the deleted sequence_id,
-- the timeline panel then fell back to loading a master sequence as the
-- "active record," violating FR-005, and the playback bounds + emp.clip_provider
-- crashed against the now-deleted sequence_id.
--
-- Fix shape (architectural): tab strip listens to `sequence_list_changed`
-- and prunes any tab whose sequence_id no longer exists. The strip's own
-- close_record_tab / close_source_tab repair pointers (displayed,
-- active_record) automatically, so this is purely "walk + close."

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")
local Signals = require("core.signals")
local Command = require("command")

local pass_count = 0
local fail_count = 0
local function check(label, cond)
    if cond then pass_count = pass_count + 1
    else fail_count = fail_count + 1; print("FAIL: " .. label) end
end

print("\n=== Tab Strip Prune Deleted Tests ===")

local db_path = "/tmp/jve/test_tab_strip_prune.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()

local project_id = "proj_prune_001"
local seq_a = "seq_prune_a"
local seq_b = "seq_prune_b"
local now = os.time()
db:exec(string.format(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('%s', 'T', 'resample', %d, %d)", project_id, now, now))
local function insert_seq(id)
    db:exec(string.format(
        "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
        .. "audio_sample_rate, width, height, created_at, modified_at) "
        .. "VALUES ('%s', '%s', '%s', 'sequence', 30, 1, 48000, 1920, 1080, %d, %d)",
        id, project_id, id, now, now))
end
insert_seq(seq_a)
insert_seq(seq_b)

command_manager.init(seq_a, project_id)

-- Open record tabs for both sequences.
local strip = timeline_state.get_tab_strip()
strip:open_record_tab(seq_a)
strip:open_record_tab(seq_b)

-- Sanity: both tabs present.
check("strip has 2 tabs before delete", #strip.tabs == 2)

-- Make seq_b the active/displayed so we can verify that deleting seq_a
-- leaves the active intact AND that deleting the active falls back.
local tab_b
for _, t in ipairs(strip.tabs) do if t.sequence_id == seq_b then tab_b = t end end
strip:switch_displayed(tab_b)
strip.active_record_tab = tab_b
check("active is seq_b", strip.active_record_tab.sequence_id == seq_b)

-- ============================================================
-- Delete a NON-active tab's sequence → its tab is closed; active intact
-- ============================================================
print("\n--- delete non-active sequence prunes its tab ---")
do
    local del = Command.create("DeleteSequence", project_id)
    del:set_parameter("sequence_id", seq_a)
    local r = command_manager.execute(del)
    check("DeleteSequence executes", r.success)

    -- The post-commit signal_list_changed fires; the prune handler should
    -- have walked the strip and closed seq_a's tab.
    local found_a = false
    for _, t in ipairs(strip.tabs) do
        if t.sequence_id == seq_a then found_a = true end
    end
    check("seq_a tab closed after delete", not found_a)
    check("strip has 1 tab remaining", #strip.tabs == 1)
    check("active tab still seq_b", strip.active_record_tab
        and strip.active_record_tab.sequence_id == seq_b)
    check("displayed still seq_b", strip.displayed_tab
        and strip.displayed_tab.sequence_id == seq_b)
end

-- ============================================================
-- Delete the ACTIVE tab's sequence → tab closes, pointers fall back
-- ============================================================
print("\n--- delete active sequence falls pointers back ---")
do
    -- Add a third sequence + open its tab so there's a fallback after
    -- deleting the active one.
    local seq_c = "seq_prune_c"
    insert_seq(seq_c)
    -- Manual sequence_list_changed since we INSERTed bypassing commands;
    -- the create path real users hit (CreateSequence command) fires it
    -- normally, but here we want to test the delete-of-active path
    -- without entangling create flow.
    Signals.emit("sequence_list_changed", project_id)
    strip:open_record_tab(seq_c)
    check("strip has 2 tabs (b + c)", #strip.tabs == 2)

    -- seq_b is still active. Delete it.
    local del = Command.create("DeleteSequence", project_id)
    del:set_parameter("sequence_id", seq_b)
    local r = command_manager.execute(del)
    check("DeleteSequence(seq_b) executes", r.success)

    local found_b = false
    for _, t in ipairs(strip.tabs) do
        if t.sequence_id == seq_b then found_b = true end
    end
    check("seq_b tab closed after delete", not found_b)
    check("active tab fell back to a remaining record", strip.active_record_tab
        and strip.active_record_tab.sequence_id == seq_c)
    check("displayed fell back to a remaining record", strip.displayed_tab
        and strip.displayed_tab.sequence_id == seq_c)
end

print("")
print(string.format("PASS: %d / FAIL: %d", pass_count, pass_count + fail_count))
if fail_count > 0 then os.exit(1) end
print("✅ test_tab_strip_prune_deleted.lua passed")
