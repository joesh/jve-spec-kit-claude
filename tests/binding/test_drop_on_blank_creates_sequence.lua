--- Regression: dropping clips onto a blank timeline creates a new sequence
--- named after the first clip, with that clip's fps/resolution, and places
--- every dropped clip serially. Feature 010, FR-011.
---
--- Domain behavior under test:
---   * With no active sequence, dropping N clips creates ONE new sequence.
---   * New sequence name = <first-clip> if N==1, or "<first-clip> (+N-1 more)".
---   * Clips lay sequentially on V1 in drop order (no gaps between them).
---   * After the drop, the new sequence is the active tab.
---   * Dropping an existing sequence (no clips) opens it as a tab without
---     creating a new sequence.

local ui = require("integration.ui_test_env")

print("=== test_drop_on_blank_creates_sequence ===")

local _, info = ui.launch({
    project_name = "Drop Blank",
    num_sequences = 1,
    sequence_names = { "Existing" },
    active_sequence = 1,
})

local database = require("core.database")
local Media = require("models.media")
local Sequence = require("models.sequence")
local Track = require("models.track")
local test_env = require("test_env")
local timeline_panel = require("ui.timeline.timeline_panel")
local timeline_state = require("ui.timeline.timeline_state")

local project_id = info.project.id
local seed_seq_id = info.sequences[1].id

-- Seed three media items + masterclip sequences so the drop payload has
-- real backing objects for Overwrite.
local function seed_clip(media_id, name, dur_frames)
    local m = Media.create({
        id = media_id, project_id = project_id,
        file_path = "/tmp/jve/" .. media_id .. ".mov",
        name = name, duration_frames = dur_frames,
        fps_numerator = 25, fps_denominator = 1,
    })
    m:save(database.get_connection())
    local mc_seq_id = test_env.create_test_masterclip_sequence(
        project_id, name .. " MC", 25, 1, dur_frames, media_id)
    local mc_seq = Sequence.load(mc_seq_id)
    mc_seq:set_in(0)
    mc_seq:set_out(dur_frames)
    mc_seq:save()
    return {
        nested_sequence_id = mc_seq_id,
        name = name,
        duration = dur_frames,
        fps_numerator = 25,
        fps_denominator = 1,
        width = 1920,
        height = 1080,
    }
end

local clip1 = seed_clip("mA", "first_shot.mov", 120)
local clip2 = seed_clip("mB", "second_shot.mov", 90)
local clip3 = seed_clip("mC", "third_shot.mov", 60)

-- Enter the no-active-sequence state by closing the only tab.
timeline_panel.close_tab(seed_seq_id)
assert(timeline_state.get_sequence_id() == nil,
    "pre: close_tab must leave state in no-active-sequence; got "
        .. tostring(timeline_state.get_sequence_id()))

-- ── Case A: drop 3 clips → one new sequence with the compound name ────
timeline_panel.handle_drop_on_blank_timeline({ clips = { clip1, clip2, clip3 } })

local active_seq_id = timeline_state.get_sequence_id()
assert(active_seq_id and active_seq_id ~= "",
    "post-drop: a new sequence must be active; got "
        .. tostring(active_seq_id))
local new_seq = Sequence.load(active_seq_id)
assert(new_seq.name == "first_shot.mov (+2 more)",
    "new sequence name must follow the first-clip-plus-suffix rule; got "
        .. tostring(new_seq.name))
assert(new_seq.frame_rate.fps_numerator == 25
    and new_seq.frame_rate.fps_denominator == 1,
    "new sequence fps must come from the first clip (25/1)")
assert(new_seq.width == 1920 and new_seq.height == 1080,
    "new sequence resolution must come from the first clip (1920x1080)")

-- Clip layout: sequential on V1, starts at 0, durations [120, 90, 60].
local tracks = Track.find_by_sequence(active_seq_id, "VIDEO")
assert(tracks and tracks[1], "new sequence must have a VIDEO track")
local v1_clips = database.load_clips(active_seq_id) or {}
local v1_media_clips = {}
for _, c in ipairs(v1_clips) do
    if c.clip_kind ~= "gap" and c.track_id == tracks[1].id then
        v1_media_clips[#v1_media_clips + 1] = c
    end
end
table.sort(v1_media_clips, function(a, b) return a.timeline_start < b.timeline_start end)
assert(#v1_media_clips == 3,
    "3 dropped clips must produce 3 clips on V1; got " .. #v1_media_clips)
assert(v1_media_clips[1].timeline_start == 0
    and v1_media_clips[2].timeline_start == 120
    and v1_media_clips[3].timeline_start == 210,
    string.format("clips must lay serially (0, 120, 210); got (%d, %d, %d)",
        v1_media_clips[1].timeline_start,
        v1_media_clips[2].timeline_start,
        v1_media_clips[3].timeline_start))

-- ── Case B: drop ONE existing sequence → opens as tab, no new sequence ──
-- Return to the blank state.
timeline_panel.close_tab(active_seq_id)
assert(timeline_state.get_sequence_id() == nil, "pre-case-B: must be blank again")

local function count_timeline_sequences()
    local stmt = assert(database.get_connection():prepare(
        "SELECT COUNT(*) FROM sequences WHERE project_id=? "
            .. "AND (kind IS NULL OR kind != 'masterclip')"))
    stmt:bind_value(1, project_id)
    assert(stmt:exec() and stmt:next())
    local n = stmt:value(0)
    stmt:finalize()
    return n
end

local sequence_count_before = count_timeline_sequences()

timeline_panel.handle_drop_on_blank_timeline({
    sequences = { { id = seed_seq_id } },
})

assert(timeline_state.get_sequence_id() == seed_seq_id,
    "post-case-B: dropped sequence must be active; got "
        .. tostring(timeline_state.get_sequence_id()))

local sequence_count_after = count_timeline_sequences()
assert(sequence_count_after == sequence_count_before,
    "dropping an existing sequence must NOT create a new one; "
        .. "before=" .. sequence_count_before .. " after=" .. sequence_count_after)

print("✅ test_drop_on_blank_creates_sequence.lua passed")
