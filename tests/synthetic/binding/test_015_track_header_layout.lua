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

require('test_env')
local ui = require("synthetic.integration.ui_test_env")

print("=== test_015_track_header_layout ===")

-- ui_test_env.launch handles HOME isolation, blank_project.open_fresh,
-- and the JVE_PROJECT_PATH → ui.layout boot — i.e. the exact user-visible
-- path through New Project + Open Project. The Film 24fps template
-- ships with V1-V3 + A1-A3, which covers the V/A header code paths.
local Track = require("models.track")

local DB = "/tmp/jve/test_015_track_header_layout.jvp"
local _, project_info = ui.launch({
    db_path      = DB,
    project_name = "Header Layout",
})
local sequence_id = project_info.sequences[1].id

local function track_id_at(track_type, idx)
    local id = Track.find_at(sequence_id, track_type, idx)
    assert(id, string.format(
        "template missing %s track at index %d", track_type, idx))
    return id
end

local TRACKS = {
    { id = track_id_at("VIDEO", 1), label = "video row V1" },
    { id = track_id_at("VIDEO", 2), label = "video row V2" },
    { id = track_id_at("AUDIO", 1), label = "audio row A1" },
    { id = track_id_at("AUDIO", 2), label = "audio row A2" },
}

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

for _, t in ipairs(TRACKS) do
    check_cells(t.id, t.label)
end
print("  ✓ header cell order matches spec for all 4 rows")
print("  ✓ no rows contain P or R cells (FR-021c, FR-021d)")

for _, t in ipairs({ TRACKS[1], TRACKS[3] }) do
    local kind = inspect(t.id).lock_kind
    assert(kind == "icon" or kind == "svg", string.format(
        "%s lock kind=%s, expected 'icon' or 'svg' (NOT 'L' text)",
        t.label, tostring(kind)))
end
print("  ✓ lock cell is an SVG icon, not text 'L'")

-- Label text inspection: confirm we can read the label content per row.
-- The channel-count format for audio rows is a spec follow-up — neither
-- spec.md nor tasks.md pins the exact rendering ("A1 (2)" vs "A1 2ch" vs
-- "A1 stereo"). Verifying ONLY that a label exists keeps the test honest
-- until the format is decided.
for _, t in ipairs(TRACKS) do
    local text = inspect(t.id).label_text
    assert(text and #text > 0, string.format(
        "%s label text missing or empty (got: %s)",
        t.label, tostring(text)))
end
print("  ✓ every row carries a non-empty label")

print("\n✅ test_015_track_header_layout passed")
