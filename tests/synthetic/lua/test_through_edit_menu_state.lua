-- Unit: FR-001 edit-point context-menu enablement logic (spec 025).
--
-- DOMAIN RULES:
--  * "Join Through Edit" is offered only at an edit point, and is enabled
--    ONLY when the pair is a real through-edit on an UNLOCKED track; otherwise
--    it is grayed with a reason ("Track is locked" / "Not a through-edit").
--  * "Join All Through Edits" is enabled iff the sequence has at least one
--    joinable through-edit (on an unlocked track).
-- Pure decision logic — no Qt, no DB.

require("test_env")

local input = require("ui.timeline.view.timeline_view_input")

print("=== test_through_edit_menu_state.lua ===")

-- `source` is the master sequence (clip.sequence_id) the clip was drawn from
-- — the source identity. Master layer ids stay NULL (ordinary default layer).
local function vclip(start, dur, src_in, src_out, source, is_gap)
    return {
        sequence_id = source,
        sequence_start = start, duration = dur,
        source_in = src_in, source_out = src_out,
        master_layer_track_id = nil, master_audio_track_id = nil,
        is_gap = is_gap,
    }
end

-- A contiguous same-source pair (through-edit) and a non-contiguous one.
local te_left  = vclip(0,   100, 0,   100, "m")
local te_right = vclip(100, 100, 100, 200, "m")
local gap_left  = vclip(0,   100, 0,   100, "m")
local gap_right = vclip(100, 100, 150, 250, "m")   -- source gap (150 != 100)

-- join_one_state -----------------------------------------------------------
do
    local en, tip = input.join_one_state(te_left, te_right, "video", false)
    assert(en == true and tip == nil, "through-edit on unlocked track → enabled")

    en, tip = input.join_one_state(te_left, te_right, "video", true)
    assert(en == false and tip == "Track is locked", "locked track → grayed with lock tooltip")

    en, tip = input.join_one_state(gap_left, gap_right, "video", false)
    assert(en == false and tip == "Not a through-edit", "non-contiguous → grayed 'Not a through-edit'")
    print("  PASS: join_one_state covers enabled / locked / not-a-through-edit")
end

-- any_through_edit_joinable -------------------------------------------------
do
    -- Unlocked track holding a through-edit → joinable.
    assert(input.any_through_edit_joinable({
        { locked = false, kind = "video", clips = { te_left, te_right } },
    }) == true, "unlocked through-edit present → joinable")

    -- Same through-edit but the track is locked → NOT joinable.
    assert(input.any_through_edit_joinable({
        { locked = true, kind = "video", clips = { te_left, te_right } },
    }) == false, "through-edit only on a locked track → not joinable")

    -- No through-edits anywhere → not joinable.
    assert(input.any_through_edit_joinable({
        { locked = false, kind = "video", clips = { gap_left, gap_right } },
    }) == false, "no through-edit present → not joinable")

    -- Mixed: a locked track with one + an unlocked track with one → joinable.
    assert(input.any_through_edit_joinable({
        { locked = true,  kind = "video", clips = { te_left, te_right } },
        { locked = false, kind = "video", clips = { te_left, te_right } },
    }) == true, "any unlocked through-edit makes the sequence joinable")
    print("  PASS: any_through_edit_joinable honors lock + presence")
end

print("✅ test_through_edit_menu_state.lua passed")
