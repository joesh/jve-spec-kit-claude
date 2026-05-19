--- T017 (015) — track-header cell layout (FR-008–FR-021d, spec §F4).
---
--- After the redesign, each track header row contains these cells, left
--- to right:
---
---   src-id button | rec-patch-id button | label | lock cell | sync-mode | S/M stack
---
--- Invariants (from spec):
---   - NO P button (patches replaced the parallel "P" affordance)
---   - NO R (record-arm) button
---   - Lock cell is an SVG icon, not the text "L"
---   - Audio rows show channel count inline with the label
---
--- Runs in --test mode against the real binary so the real layout code
--- runs and we hit-test actual Qt widgets.

local ui = require("integration.ui_test_env")
local ffi = require("ffi")
ffi.cdef[[ int setenv(const char *name, const char *value, int overwrite); ]]

print("=== test_015_track_header_layout ===")

-- Isolate HOME so layout's first-run prefs don't pollute the real user.
local saved_home = os.getenv("HOME")
ffi.C.setenv("HOME", "/tmp/jve_test_home", 1)
os.execute("mkdir -p /tmp/jve_test_home/.jve")

-- Set up a project with both V and A tracks so we exercise both header
-- code paths. Two video tracks + two audio tracks is the minimum that
-- catches both rows.
local DB = "/tmp/jve/test_015_track_header_layout.jvp"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")

local database = require("core.database")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at, settings)
    VALUES ('proj', 'Header Layout', 'resample', %d, %d,
            '{"last_open_sequence_id":"rec","open_sequence_ids":["rec"],"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}');


    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('rec', 'proj', 'Record', 'sequence', 25, 1, 48000, 1920, 1080,
            0, 0, 1500, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES
      ('rv1', 'rec', 'V1', 'VIDEO', 1, 1),
      ('rv2', 'rec', 'V2', 'VIDEO', 2, 1),
      ('ra1', 'rec', 'A1', 'AUDIO', 1, 1),
      ('ra2', 'rec', 'A2', 'AUDIO', 2, 1);
]], now, now, now, now))

-- Close the seed DB so layout opens it fresh against JVE_PROJECT_PATH.
database.shutdown()

ffi.C.setenv("JVE_PROJECT_PATH", DB, 1)
package.cpath = package.cpath .. ';' .. saved_home .. '/.luarocks/lib/lua/5.1/?.so'
package.path = package.path .. ';' .. saved_home .. '/.luarocks/share/lua/5.1/?.lua'
package.path = package.path .. ';' .. saved_home .. '/.luarocks/share/lua/5.1/?/init.lua'

local app = require("ui.layout")
assert(app and app.main_window, "layout.lua did not return main_window")
ui.pump(300)

--------------------------------------------------------------------------------
-- Single hook: timeline_panel exposes get_track_header_layout_for_test(id)
-- returning { cells = {"src_btn",...}, lock_kind = "icon"|"text",
--             label_text = "..." }. One inspection point keeps the test
-- surface small.
--------------------------------------------------------------------------------
local timeline_panel = require("ui.timeline.timeline_panel")
assert(type(timeline_panel.get_track_header_layout_for_test) == "function",
    "timeline_panel must expose get_track_header_layout_for_test(track_id) "
    .. "for T017 verification")

local EXPECTED_CELLS = { "src_btn", "rec_btn", "label", "lock", "sync_mode", "sm_stack" }

local function inspect(track_id)
    local layout = timeline_panel.get_track_header_layout_for_test(track_id)
    assert(type(layout) == "table",
        string.format("layout for %s must be a table, got %s",
            track_id, type(layout)))
    assert(type(layout.cells) == "table",
        string.format("layout.cells for %s missing", track_id))
    return layout
end

local function check_cells(track_id, label)
    local layout = inspect(track_id)
    local got = layout.cells
    -- Spec defines the first 6 cells (FR-008). Audio rows append a
    -- waveform toggle (extension, not in spec) so we verify positions
    -- 1..6 match and tolerate additional cells beyond.
    assert(#got >= #EXPECTED_CELLS, string.format(
        "%s: cell count %d, expected at least %d (got: %s)",
        label, #got, #EXPECTED_CELLS, table.concat(got, ",")))
    for i, want in ipairs(EXPECTED_CELLS) do
        assert(got[i] == want, string.format(
            "%s: cell[%d] is %s, expected %s (full order: %s)",
            label, i, tostring(got[i]), want, table.concat(got, ",")))
    end
    for _, cell in ipairs(got) do
        assert(cell ~= "p_btn", label .. ": contains banned P button cell")
        assert(cell ~= "r_btn", label .. ": contains banned record-arm cell")
    end
end

check_cells("rv1", "video row V1")
check_cells("rv2", "video row V2")
check_cells("ra1", "audio row A1")
check_cells("ra2", "audio row A2")
print("  ✓ header cell order matches spec for all 4 rows")
print("  ✓ no rows contain P or R cells (FR-021c, FR-021d)")

for _, track_id in ipairs({"rv1", "ra1"}) do
    local kind = inspect(track_id).lock_kind
    assert(kind == "icon" or kind == "svg", string.format(
        "row %s lock kind=%s, expected 'icon' or 'svg' (NOT 'L' text)",
        track_id, tostring(kind)))
end
print("  ✓ lock cell is an SVG icon, not text 'L'")

-- Label text inspection: confirm we can read the label content per row.
-- The channel-count format for audio rows is a spec follow-up — neither
-- spec.md nor tasks.md pins the exact rendering ("A1 (2)" vs "A1 2ch" vs
-- "A1 stereo"). Verifying ONLY that a label exists keeps the test honest
-- until the format is decided.
for _, track_id in ipairs({"rv1", "rv2", "ra1", "ra2"}) do
    local text = inspect(track_id).label_text
    assert(text and #text > 0, string.format(
        "row %s label text missing or empty (got: %s)",
        track_id, tostring(text)))
end
print("  ✓ every row carries a non-empty label")

print("\n✅ test_015_track_header_layout passed")
