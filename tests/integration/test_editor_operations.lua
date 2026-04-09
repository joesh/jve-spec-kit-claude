#!/usr/bin/env luajit

-- Integration test suite: exercises real editing operations on a copy of the
-- anamnesis project. Runs inside JVEEditor --test mode with full C++ bindings.
--
-- Architecture: single editor process, single script, real data.
-- Between every operation, the project validator runs to catch corruption.
-- Per-operation assertions verify correct behavior (not just valid state).

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")
local Clip = require("models.clip")
local Sequence = require("models.sequence")
local Command = require("command")
local validator = require("tests.helpers.project_validator")

-- =========================================================================
-- Setup: copy anamnesis project to /tmp
-- =========================================================================

local home = os.getenv("HOME")
local src_path = home .. "/Documents/JVE Projects/anamnesis joe edit.jvp"
local dst_path = "/tmp/jve/integ_editor_ops.jvp"

os.execute("mkdir -p /tmp/jve")
os.execute(string.format("cp %q %q", src_path, dst_path))
os.execute(string.format("rm -f %q", dst_path .. "-shm"))

-- Open project database
local project_open = require("core.project_open")
assert(project_open.open_project_database_or_prompt_cleanup(
    database, qt_constants, dst_path, nil),
    "Failed to open anamnesis project copy")

-- Pick the gold master sequence (largest, most complex)
local SEQUENCE_ID = "f29d6d6a-d173-436c-aba2-991a4078e049"
local sequence = Sequence.load(SEQUENCE_ID)
assert(sequence, "Failed to load gold master sequence")

local PROJECT_ID = sequence.project_id
assert(PROJECT_ID, "Sequence missing project_id")

-- Initialize command manager and timeline state
command_manager.init(SEQUENCE_ID, PROJECT_ID)
timeline_state.init(SEQUENCE_ID, PROJECT_ID)

local db = database.get_connection()

-- =========================================================================
-- Helpers
-- =========================================================================

local test_count = 0
local pass_count = 0
local fail_count = 0
local failures = {}

--- Validate JVP integrity + timeline state for the active sequence.
--- Skips undo stack validation — the anamnesis project has pre-existing
--- orphaned undo groups from prior editing sessions.
local function validate(context)
    -- JVP + timeline only (skip undo stack — project has pre-existing orphaned groups)
    local jvp_result = validator.validate_jvp_for_sequence(db, SEQUENCE_ID)
    local tl_result = validator.validate_timeline(timeline_state, db, SEQUENCE_ID)

    local errors = {}
    for _, e in ipairs(jvp_result.errors) do table.insert(errors, e) end
    for _, e in ipairs(tl_result.errors) do table.insert(errors, e) end

    if #errors > 0 then
        error(string.format("PROJECT VALIDATION FAILED%s:\n  %s",
            context and (" (" .. context .. ")") or "",
            table.concat(errors, "\n  ")), 2)
    end
end

local function run_test(name, fn)
    test_count = test_count + 1
    local ok, err = pcall(fn)
    if ok then
        pass_count = pass_count + 1
        print(string.format("  [PASS] %s", name))
    else
        fail_count = fail_count + 1
        table.insert(failures, {name = name, error = err})
        print(string.format("  [FAIL] %s: %s", name, tostring(err)))
    end
end

--- Find two adjacent clips on a track where a small roll (delta frames) can succeed.
-- Checks that the left clip has media headroom to extend.
-- Returns clip_a (left), clip_b (right), or nil if none found.
local function find_adjacent_pair(track_id, min_headroom)
    min_headroom = min_headroom or 10
    local clips = timeline_state.get_clips()
    local track_clips = {}
    for _, c in ipairs(clips) do
        if c.track_id == track_id and c.clip_kind ~= "gap" then
            table.insert(track_clips, c)
        end
    end
    table.sort(track_clips, function(a, b) return a.timeline_start < b.timeline_start end)

    local Media = require("models.media")
    for i = 1, #track_clips - 1 do
        local a = track_clips[i]
        local b = track_clips[i + 1]
        if a.timeline_start + a.duration == b.timeline_start and a.media_id then
            -- Check media headroom: can clip_a extend its out edge?
            local media = Media.load(a.media_id)
            if media and media.duration then
                local tc_origin = media:get_start_tc() or 0
                local file_src_in = a.source_in - tc_origin
                if file_src_in < 0 then file_src_in = 0 end
                local available = media.duration - file_src_in - a.duration
                if available >= min_headroom and b.duration > min_headroom then
                    return a, b
                end
            end
        end
    end
    return nil, nil
end

--- Find two clips separated by a gap on a track.
local function find_gapped_pair(track_id)
    local clips = timeline_state.get_clips()
    local track_clips = {}
    for _, c in ipairs(clips) do
        if c.track_id == track_id and c.clip_kind ~= "gap" then
            table.insert(track_clips, c)
        end
    end
    table.sort(track_clips, function(a, b) return a.timeline_start < b.timeline_start end)

    for i = 1, #track_clips - 1 do
        local a = track_clips[i]
        local b = track_clips[i + 1]
        local gap_size = b.timeline_start - (a.timeline_start + a.duration)
        if gap_size > 10 then  -- meaningful gap
            return a, b, gap_size
        end
    end
    return nil, nil, nil
end

-- =========================================================================
-- Initial validation
-- =========================================================================

print("[integration] Validating initial state...")
validate("initial state")
print("[integration] Initial state valid. Running tests...")

-- =========================================================================
-- Test: Roll on V1 — downstream clips must NOT move
-- =========================================================================

run_test("roll_on_v1_doesnt_shift_downstream", function()
    -- Find first adjacent pair on V1
    local V1_TRACK = "ffb46a96-bcc3-4018-aba3-1145008f026e"
    local clip_a, clip_b = find_adjacent_pair(V1_TRACK)
    assert(clip_a and clip_b, "No adjacent clip pair found on V1")

    -- Find a downstream clip to verify it doesn't move
    local all_clips = timeline_state.get_clips()
    local downstream = nil
    for _, c in ipairs(all_clips) do
        if c.track_id == V1_TRACK and c.clip_kind ~= "gap"
            and c.timeline_start > clip_b.timeline_start + clip_b.duration then
            downstream = c
            break
        end
    end

    -- Capture before state
    local a_dur_before = clip_a.duration
    local b_start_before = clip_b.timeline_start
    local b_dur_before = clip_b.duration
    local downstream_start_before = downstream and downstream.timeline_start

    -- Execute roll: extend A out, trim B in, by 5 frames
    local delta = 5
    local cmd = Command.create("BatchRippleEdit", PROJECT_ID)
    cmd:set_parameter("sequence_id", SEQUENCE_ID)
    cmd:set_parameter("edge_infos", {
        {clip_id = clip_a.id, edge_type = "out", track_id = V1_TRACK, trim_type = "roll"},
        {clip_id = clip_b.id, edge_type = "in", track_id = V1_TRACK, trim_type = "roll"},
    })
    cmd:set_parameter("delta_frames", delta)
    local result = command_manager.execute(cmd)
    assert(result.success, "Roll failed: " .. tostring(result.error_message))

    validate("after V1 roll")

    -- Verify roll behavior
    local a_after = Clip.load(clip_a.id)
    local b_after = Clip.load(clip_b.id)
    assert(a_after.duration == a_dur_before + delta,
        string.format("A duration: expected %d, got %d", a_dur_before + delta, a_after.duration))
    assert(b_after.timeline_start == b_start_before + delta,
        string.format("B start: expected %d, got %d", b_start_before + delta, b_after.timeline_start))
    assert(b_after.duration == b_dur_before - delta,
        string.format("B duration: expected %d, got %d", b_dur_before - delta, b_after.duration))

    -- THE KEY ASSERTION: downstream clip must NOT move
    if downstream then
        local ds_after = Clip.load(downstream.id)
        assert(ds_after.timeline_start == downstream_start_before,
            string.format("DOWNSTREAM SHIFTED! Roll acted as ripple. Expected %d, got %d",
                downstream_start_before, ds_after.timeline_start))
    end

    -- Undo and verify restoration
    local undo_result = command_manager.undo()
    assert(undo_result.success, "Undo failed: " .. tostring(undo_result.error_message))

    validate("after V1 roll undo")

    local a_restored = Clip.load(clip_a.id)
    local b_restored = Clip.load(clip_b.id)
    assert(a_restored.duration == a_dur_before, "A duration not restored after undo")
    assert(b_restored.timeline_start == b_start_before, "B start not restored after undo")
end)

-- =========================================================================
-- Test: Roll on A3 (audio) — the reported bug scenario
-- =========================================================================

run_test("roll_on_audio_doesnt_shift_downstream", function()
    local A3_TRACK = "a6d9ed8a-9c62-4922-9734-75399023ca2b"
    local clip_a, clip_b = find_adjacent_pair(A3_TRACK)
    assert(clip_a and clip_b, "No adjacent clip pair found on A3")

    -- Find downstream
    local all_clips = timeline_state.get_clips()
    local downstream = nil
    for _, c in ipairs(all_clips) do
        if c.track_id == A3_TRACK and c.clip_kind ~= "gap"
            and c.timeline_start > clip_b.timeline_start + clip_b.duration then
            downstream = c
            break
        end
    end

    local downstream_start = downstream and downstream.timeline_start
    local b_start_before = clip_b.timeline_start
    local b_dur_before = clip_b.duration

    -- Roll by 5 frames (small delta to stay within bounds)
    local delta = 5
    local cmd = Command.create("BatchRippleEdit", PROJECT_ID)
    cmd:set_parameter("sequence_id", SEQUENCE_ID)
    cmd:set_parameter("edge_infos", {
        {clip_id = clip_a.id, edge_type = "out", track_id = A3_TRACK, trim_type = "roll"},
        {clip_id = clip_b.id, edge_type = "in", track_id = A3_TRACK, trim_type = "roll"},
    })
    cmd:set_parameter("delta_frames", delta)
    local result = command_manager.execute(cmd)
    assert(result.success, "Audio roll failed: " .. tostring(result.error_message))

    validate("after A3 roll")

    -- Key assertion: downstream doesn't shift
    if downstream then
        local ds = Clip.load(downstream.id)
        assert(ds.timeline_start == downstream_start,
            string.format("AUDIO DOWNSTREAM SHIFTED! Roll acted as ripple. Expected %d, got %d",
                downstream_start, ds.timeline_start))
    end

    local b_after = Clip.load(clip_b.id)
    assert(b_after.timeline_start == b_start_before + delta,
        string.format("B start after roll: expected %d, got %d",
            b_start_before + delta, b_after.timeline_start))
    assert(b_after.duration == b_dur_before - delta,
        string.format("B duration after roll: expected %d, got %d",
            b_dur_before - delta, b_after.duration))

    -- Undo
    local undo_result = command_manager.undo()
    assert(undo_result.success, "Undo failed")
    validate("after A3 roll undo")
end)

-- =========================================================================
-- Test: Ripple on V1 — downstream MUST shift (opposite of roll)
-- =========================================================================

run_test("ripple_on_v1_shifts_downstream", function()
    local V1_TRACK = "ffb46a96-bcc3-4018-aba3-1145008f026e"
    local clip_a, clip_b = find_adjacent_pair(V1_TRACK)
    assert(clip_a and clip_b, "No adjacent clip pair on V1")

    local all_clips = timeline_state.get_clips()
    local downstream = nil
    for _, c in ipairs(all_clips) do
        if c.track_id == V1_TRACK and c.clip_kind ~= "gap"
            and c.timeline_start > clip_b.timeline_start + clip_b.duration then
            downstream = c
            break
        end
    end

    local downstream_start = downstream and downstream.timeline_start

    -- Ripple A out by 5 frames
    local delta = 5
    local cmd = Command.create("BatchRippleEdit", PROJECT_ID)
    cmd:set_parameter("sequence_id", SEQUENCE_ID)
    cmd:set_parameter("edge_infos", {
        {clip_id = clip_a.id, edge_type = "out", track_id = V1_TRACK, trim_type = "ripple"},
    })
    cmd:set_parameter("delta_frames", delta)
    local result = command_manager.execute(cmd)
    assert(result.success, "Ripple failed: " .. tostring(result.error_message))

    validate("after V1 ripple")

    -- Downstream MUST shift (opposite of roll)
    if downstream then
        local ds = Clip.load(downstream.id)
        assert(ds.timeline_start == downstream_start + delta,
            string.format("Downstream should shift by %d. Expected %d, got %d",
                delta, downstream_start + delta, ds.timeline_start))
    end

    -- Undo
    local undo_result = command_manager.undo()
    assert(undo_result.success, "Undo failed")
    validate("after V1 ripple undo")

    -- Verify restoration
    if downstream then
        local ds_restored = Clip.load(downstream.id)
        assert(ds_restored.timeline_start == downstream_start,
            "Downstream not restored after ripple undo")
    end
end)

-- =========================================================================
-- Test: Roll then ripple — verify they produce different results
-- =========================================================================

run_test("roll_vs_ripple_produce_different_results", function()
    local V1_TRACK = "ffb46a96-bcc3-4018-aba3-1145008f026e"
    local clip_a, clip_b = find_adjacent_pair(V1_TRACK)
    assert(clip_a and clip_b, "No adjacent pair on V1")

    local all_clips = timeline_state.get_clips()
    local downstream = nil
    for _, c in ipairs(all_clips) do
        if c.track_id == V1_TRACK and c.clip_kind ~= "gap"
            and c.timeline_start > clip_b.timeline_start + clip_b.duration then
            downstream = c
            break
        end
    end
    assert(downstream, "No downstream clip found — can't compare roll vs ripple")

    local ds_start_orig = downstream.timeline_start
    local delta = 3

    -- Roll
    local roll_cmd = Command.create("BatchRippleEdit", PROJECT_ID)
    roll_cmd:set_parameter("sequence_id", SEQUENCE_ID)
    roll_cmd:set_parameter("edge_infos", {
        {clip_id = clip_a.id, edge_type = "out", track_id = V1_TRACK, trim_type = "roll"},
        {clip_id = clip_b.id, edge_type = "in", track_id = V1_TRACK, trim_type = "roll"},
    })
    roll_cmd:set_parameter("delta_frames", delta)
    local r1 = command_manager.execute(roll_cmd)
    assert(r1.success, "Roll failed")

    local ds_after_roll = Clip.load(downstream.id).timeline_start
    command_manager.undo()

    -- Ripple
    local rip_cmd = Command.create("BatchRippleEdit", PROJECT_ID)
    rip_cmd:set_parameter("sequence_id", SEQUENCE_ID)
    rip_cmd:set_parameter("edge_infos", {
        {clip_id = clip_a.id, edge_type = "out", track_id = V1_TRACK, trim_type = "ripple"},
    })
    rip_cmd:set_parameter("delta_frames", delta)
    local r2 = command_manager.execute(rip_cmd)
    assert(r2.success, "Ripple failed")

    local ds_after_ripple = Clip.load(downstream.id).timeline_start
    command_manager.undo()

    validate("after roll vs ripple comparison")

    -- Roll: downstream should NOT move. Ripple: downstream SHOULD move.
    assert(ds_after_roll == ds_start_orig,
        string.format("Roll shifted downstream! %d → %d", ds_start_orig, ds_after_roll))
    assert(ds_after_ripple == ds_start_orig + delta,
        string.format("Ripple didn't shift downstream! Expected %d, got %d",
            ds_start_orig + delta, ds_after_ripple))
    assert(ds_after_roll ~= ds_after_ripple,
        "Roll and ripple produced same downstream position — one of them is broken")
end)

-- =========================================================================
-- Test: Roll at clip-gap boundary on V1
-- =========================================================================

run_test("roll_at_gap_boundary", function()
    local V1_TRACK = "ffb46a96-bcc3-4018-aba3-1145008f026e"
    local clip_a, clip_b = find_gapped_pair(V1_TRACK)
    assert(clip_a and clip_b, "No gapped pair found on V1")

    local clip_a_end = clip_a.timeline_start + clip_a.duration
    local gap_id = string.format("gap_%s_%d", V1_TRACK, clip_a_end)
    local b_start_before = clip_b.timeline_start

    -- Roll clip_a:out + gap:in by 3 frames (extend A into gap)
    local delta = 3
    local cmd = Command.create("BatchRippleEdit", PROJECT_ID)
    cmd:set_parameter("sequence_id", SEQUENCE_ID)
    cmd:set_parameter("edge_infos", {
        {clip_id = clip_a.id, edge_type = "out", track_id = V1_TRACK, trim_type = "roll"},
        {clip_id = gap_id, edge_type = "in", track_id = V1_TRACK, trim_type = "roll"},
    })
    cmd:set_parameter("delta_frames", delta)
    local result = command_manager.execute(cmd)
    assert(result.success, "Gap roll failed: " .. tostring(result.error_message))

    validate("after gap roll")

    -- clip_b should NOT move (roll into gap)
    local b_after = Clip.load(clip_b.id)
    assert(b_after.timeline_start == b_start_before,
        string.format("B moved after gap roll! Expected %d, got %d",
            b_start_before, b_after.timeline_start))

    -- Undo
    command_manager.undo()
    validate("after gap roll undo")
end)

-- =========================================================================
-- Test: Multiple undo/redo cycles
-- =========================================================================

run_test("undo_redo_cycle_preserves_state", function()
    local A3_TRACK = "a6d9ed8a-9c62-4922-9734-75399023ca2b"
    -- Use A3 (audio) — fewer undo stack interactions from prior tests
    local clip_a, clip_b = find_adjacent_pair(A3_TRACK)
    assert(clip_a and clip_b, "No adjacent pair on A3 for undo/redo test")

    local a_dur_orig = clip_a.duration
    local b_start_orig = clip_b.timeline_start
    local delta = 2

    -- Execute
    local cmd = Command.create("BatchRippleEdit", PROJECT_ID)
    cmd:set_parameter("sequence_id", SEQUENCE_ID)
    cmd:set_parameter("edge_infos", {
        {clip_id = clip_a.id, edge_type = "out", track_id = A3_TRACK, trim_type = "roll"},
        {clip_id = clip_b.id, edge_type = "in", track_id = A3_TRACK, trim_type = "roll"},
    })
    cmd:set_parameter("delta_frames", delta)
    local result = command_manager.execute(cmd)
    assert(result.success, "Execute failed: " .. tostring(result.error_message))
    validate("after execute")

    assert(Clip.load(clip_a.id).duration == a_dur_orig + delta,
        "Roll didn't extend A")

    -- Undo
    command_manager.undo()
    validate("after undo")
    assert(Clip.load(clip_a.id).duration == a_dur_orig, "Undo didn't restore A duration")
    assert(Clip.load(clip_b.id).timeline_start == b_start_orig, "Undo didn't restore B start")

    -- Note: redo not tested here — pre-existing undo history in the anamnesis
    -- project interferes with redo target resolution. Redo is tested in the
    -- unit test suite with fresh DBs (test_batch_ripple_roll.lua etc).
end)

-- =========================================================================
-- Test: Split clip on V1 — creates two clips, preserves total coverage
-- =========================================================================

run_test("split_clip_preserves_coverage", function()
    local V1_TRACK = "ffb46a96-bcc3-4018-aba3-1145008f026e"
    -- Find a clip long enough to split
    local all_clips = timeline_state.get_clips()
    local target = nil
    for _, c in ipairs(all_clips) do
        if c.track_id == V1_TRACK and c.clip_kind ~= "gap" and c.duration > 10 then
            target = c
            break
        end
    end
    assert(target, "No clip long enough to split on V1")

    local orig_start = target.timeline_start
    local orig_dur = target.duration
    local split_point = orig_start + math.floor(orig_dur / 2)

    local cmd = Command.create("SplitClip", PROJECT_ID)
    cmd:set_parameter("sequence_id", SEQUENCE_ID)
    cmd:set_parameter("clip_id", target.id)
    cmd:set_parameter("split_value", split_point)

    local result = command_manager.execute(cmd)
    assert(result.success, "SplitClip failed: " .. tostring(result.error_message))

    validate("after split")

    -- First part should end at split_point
    local first = Clip.load(target.id)
    assert(first.timeline_start == orig_start, "First part start changed")
    assert(first.timeline_start + first.duration == split_point,
        string.format("First part should end at %d, ends at %d",
            split_point, first.timeline_start + first.duration))

    -- Undo and verify restoration
    command_manager.undo()
    validate("after split undo")

    local restored = Clip.load(target.id)
    assert(restored.duration == orig_dur,
        string.format("Split undo didn't restore duration: expected %d, got %d",
            orig_dur, restored.duration))
end)

-- =========================================================================
-- Test: ToggleClipEnabled on V1 — disables/enables a clip
-- =========================================================================

run_test("toggle_clip_enabled", function()
    local V1_TRACK = "ffb46a96-bcc3-4018-aba3-1145008f026e"
    local all_clips = timeline_state.get_clips()
    local target = nil
    for _, c in ipairs(all_clips) do
        if c.track_id == V1_TRACK and c.clip_kind ~= "gap" then
            target = c
            break
        end
    end
    assert(target, "No clip on V1")

    local was_enabled = target.enabled

    local cmd = Command.create("ToggleClipEnabled", PROJECT_ID)
    cmd:set_parameter("sequence_id", SEQUENCE_ID)
    cmd:set_parameter("clip_ids", {target.id})

    local result = command_manager.execute(cmd)
    assert(result.success, "ToggleClipEnabled failed: " .. tostring(result.error_message))

    validate("after toggle enabled")

    local toggled = Clip.load(target.id)
    assert(toggled.enabled ~= was_enabled,
        "Clip enabled state should have toggled")

    -- Undo
    command_manager.undo()
    validate("after toggle undo")

    local restored = Clip.load(target.id)
    assert(restored.enabled == was_enabled, "Undo didn't restore enabled state")
end)

-- =========================================================================
-- Test: Nudge clip position on V1
-- =========================================================================

run_test("nudge_clip_position", function()
    local V1_TRACK = "ffb46a96-bcc3-4018-aba3-1145008f026e"
    local all_clips = timeline_state.get_clips()
    -- Find a clip that's NOT at position 0 (so we can nudge left)
    local target = nil
    for _, c in ipairs(all_clips) do
        if c.track_id == V1_TRACK and c.clip_kind ~= "gap" and c.timeline_start > 10 then
            target = c
            break
        end
    end
    assert(target, "No nudgeable clip on V1")

    local orig_start = target.timeline_start
    local nudge_amount = 3

    local cmd = Command.create("Nudge", PROJECT_ID)
    cmd:set_parameter("sequence_id", SEQUENCE_ID)
    cmd:set_parameter("nudge_amount", nudge_amount)
    cmd:set_parameter("selected_clip_ids", {target.id})

    local result = command_manager.execute(cmd)
    assert(result.success, "Nudge failed: " .. tostring(result.error_message))

    validate("after nudge")

    local nudged = Clip.load(target.id)
    assert(nudged.timeline_start == orig_start + nudge_amount,
        string.format("Nudge: expected start=%d, got %d",
            orig_start + nudge_amount, nudged.timeline_start))

    -- Duration and source coordinates should NOT change for clip nudge
    assert(nudged.duration == target.duration, "Nudge shouldn't change duration")
    assert(nudged.source_in == target.source_in, "Nudge shouldn't change source_in")
    assert(nudged.source_out == target.source_out, "Nudge shouldn't change source_out")

    -- Undo
    command_manager.undo()
    validate("after nudge undo")

    local restored = Clip.load(target.id)
    assert(restored.timeline_start == orig_start, "Nudge undo didn't restore position")
end)

-- =========================================================================
-- Test: Roll on A3 (audio, 1223 clips) — stress test with real audio data
-- =========================================================================

run_test("roll_on_large_audio_track", function()
    local A3_TRACK = "a6d9ed8a-9c62-4922-9734-75399023ca2b"
    local clip_a, clip_b = find_adjacent_pair(A3_TRACK)
    assert(clip_a and clip_b, "No adjacent pair on A3")

    local b_source_in_before = clip_b.source_in
    local b_source_out_before = clip_b.source_out
    local delta = 3

    local cmd = Command.create("BatchRippleEdit", PROJECT_ID)
    cmd:set_parameter("sequence_id", SEQUENCE_ID)
    cmd:set_parameter("edge_infos", {
        {clip_id = clip_a.id, edge_type = "out", track_id = A3_TRACK, trim_type = "roll"},
        {clip_id = clip_b.id, edge_type = "in", track_id = A3_TRACK, trim_type = "roll"},
    })
    cmd:set_parameter("delta_frames", delta)
    local result = command_manager.execute(cmd)
    assert(result.success, "A3 roll failed: " .. tostring(result.error_message))

    validate("after A3 large roll")

    -- B's source_in should change in SAMPLES (A3 has audio clips at 48000)
    local b_after = Clip.load(clip_b.id)
    local source_delta = b_after.source_in - b_source_in_before
    -- For audio: expected = delta * 48000 / 25 = delta * 1920
    -- For video: expected = delta * 25 / 25 = delta
    -- We don't know the clip rate here, but we can verify it's not == delta
    -- (which would indicate the unit mismatch bug)
    if b_after.fps_numerator and b_after.fps_numerator > 1000 then
        -- Audio clip: source_delta should be >> delta
        assert(source_delta > delta * 100,
            string.format("Audio source_in only changed by %d for %d-frame roll — unit mismatch?",
                source_delta, delta))
    end

    -- B's source_out should NOT change (in-edge trim)
    assert(b_after.source_out == b_source_out_before,
        string.format("B source_out should not change on in-edge roll: before=%d after=%d",
            b_source_out_before, b_after.source_out))

    -- Undo
    command_manager.undo()
    validate("after A3 large roll undo")
end)

-- =========================================================================
-- Results
-- =========================================================================

print(string.format("\n[integration] %d/%d tests passed, %d failed",
    pass_count, test_count, fail_count))

if fail_count > 0 then
    print("\nFailed tests:")
    for _, f in ipairs(failures) do
        print(string.format("  %s: %s", f.name, f.error))
    end
end

-- Cleanup
database.shutdown()
os.remove(dst_path)
os.remove(dst_path .. "-wal")
os.remove(dst_path .. "-shm")

assert(fail_count == 0, string.format("%d integration test(s) failed", fail_count))
print("✅ test_editor_operations.lua passed")
