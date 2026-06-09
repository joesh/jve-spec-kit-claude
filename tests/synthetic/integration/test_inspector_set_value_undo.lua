--- Editing a field on a single selected clip must keep that clip
--- selected on the timeline — the user is editing it, not deselecting
--- it. After undo the inspector must show the clip's pre-edit value
--- (the model was reverted) and the clip must still be selected so
--- the user can re-edit, redo, or carry on.
---
--- Runs inside ./build/bin/jve --test with full Qt + panels.

local ui = require("synthetic.integration.ui_test_env")

print("=== test_inspector_set_value_undo ===")

local _, info = ui.launch({
    project_name = "Inspector Set Value Undo",
    num_sequences = 1,
    sequence_names = { "S1" },
    active_sequence = 1,
})

local Clip            = require("models.clip")
local Track           = require("models.track")
local Media           = require("models.media")
local timeline_state  = require("ui.timeline.timeline_state")
local command_manager = require("core.command_manager")
local inspector       = require("ui.inspector")
local inspectable     = require("inspectable")
local test_env        = require("test_env")

local project_id = info.project.id
local seq_id     = info.sequences[1].id
local ORIGINAL   = "OriginalName"
local EDITED     = "EditedName"

-- Build a clip on the existing video track.
local tracks = Track.find_by_sequence(seq_id, "VIDEO")
assert(tracks and #tracks >= 1, "expected at least one video track")
local v_track = tracks[1]

local med = Media.create({
    project_id      = project_id,
    name            = "test_media.mp4",
    file_path       = "/tmp/jve/inspector_undo_fixture.mp4",
    duration_frames = 240,
    frame_rate      = 24,
    width           = 1920,
    height          = 1080,
})
assert(med:save(), "media save failed")

local mc_seq_id = test_env.create_test_masterclip_sequence(
    project_id, "test mc", 24, 1, 240, med.id)

local clip_id = Clip.create({
        name = ORIGINAL,
        project_id = project_id,
        owner_sequence_id = seq_id,
        track_id = v_track.id,
        sequence_start_frame = 24,
        duration_frames = 60,
        source_in_frame = 0,
        source_out_frame = 60,
        enabled = true,
        sequence_id = mc_seq_id,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
    })
assert(clip_id ~= nil and clip_id ~= "", "clip create failed")

-- Force a clip reload; load_sequence early-returns because ui.launch
-- already made this the active sequence.
timeline_state.reload_clips(seq_id)
ui.pump(50)

local loaded = assert(timeline_state.get_tab_strip():clip_by_id(clip_id),
    "clip not loaded into timeline_state")
assert(loaded.name == ORIGINAL, "clip name setup mismatch")

timeline_state.set_selection({ loaded })
ui.pump(50)

local function assert_selected(label)
    local sel = timeline_state.get_selected_clips()
    assert(#sel == 1 and sel[1].id == clip_id, string.format(
        "%s: expected 1 clip selected; got %d", label, #sel))
end

local function inspectable_for(clip_obj)
    return inspectable.clip({
        clip_id     = clip_id,
        project_id  = project_id,
        sequence_id = seq_id,
        clip        = clip_obj,
    })
end

assert_selected("after set_selection")

-- Hand our inspectable to the inspector so we observe its view directly.
local clip_insp = inspectable_for(loaded)
inspector.update_selection({
    {
        item_type   = "timeline_clip",
        clip_id     = clip_id,
        project_id  = project_id,
        sequence_id = seq_id,
        clip        = loaded,
        inspectable = clip_insp,
    },
}, "timeline")
ui.pump(50)

--------------------------------------------------------------------------------
-- Editing a field must NOT clear the timeline selection.
--------------------------------------------------------------------------------

local ok, err = clip_insp:set("name", { value = EDITED, property_type = "STRING" })
assert(ok, "ClipInspectable:set failed: " .. tostring(err))
ui.pump(50)

assert(timeline_state.get_tab_strip():clip_by_id(clip_id).name == EDITED,
    "model must reflect the edit")
assert_selected("after ClipInspectable:set")

--------------------------------------------------------------------------------
-- Undo must restore the selection and revert the field in the inspector's view.
--------------------------------------------------------------------------------

local undo_result = command_manager.undo()
assert(undo_result.success,
    "undo failed: " .. tostring(undo_result.error_message))
ui.pump(50)

assert(timeline_state.get_tab_strip():clip_by_id(clip_id).name == ORIGINAL,
    "model must revert on undo")
assert_selected("after undo")

-- In production the undo's selection-restore broadcast rebuilds the
-- inspector's inspectables from the current clip refs. Mirror that here.
assert(inspectable_for(timeline_state.get_tab_strip():clip_by_id(clip_id)):get("name") == ORIGINAL,
    "fresh inspectable must report the reverted value")

-- An inspectable held across content_changed (not rebuilt) must drop
-- metadata_overrides on refresh() so the model wins on subsequent reads.
local stale = inspectable_for(timeline_state.get_tab_strip():clip_by_id(clip_id))
stale.metadata_overrides["name"] = "ShadowValue"
assert(stale:get("name") == "ShadowValue",
    "pre-condition: override should shadow before refresh")
stale:refresh()
assert(stale:get("name") == ORIGINAL,
    "refresh() must clear the override so the model wins")

print("✅ test_inspector_set_value_undo passed")
