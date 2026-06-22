-- 018 T026 / FR-023: frame-delta edit commands MUST preserve sub-frame
-- precision through their math. Slip and Roll only shift source_in_frame
-- and source_out_frame by a frame delta — the subframe residual that
-- carries inside one master frame is unrelated and must pass through
-- verbatim across execute, undo, and redo.
--
-- Sample-precise sub-frame splits are deferred (Phase 3.6 covers
-- preservation; subframe carry through a non-frame-aligned split point is
-- a separate future feature — SplitClip currently refuses non-zero
-- subframes, pinned by test_018_split_refuses_nonzero_subframe.lua).

require("test_env")
local database = require("core.database")
local command_manager = require("core.command_manager")
local Clip = require("models.clip")

local DB = "/tmp/jve/test_edit_command_subframe_preservation.db"

local SUB_IN, SUB_OUT = 2000, 4000   -- non-zero, < tpf=8000 at 192k/24fps

local function fresh_db()
    os.remove(DB)
    assert(database.init(DB))
    local db = database.get_connection()
    local now = os.time()
    assert(db:exec(string.format([[
        INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
        VALUES ('p', 'P', 'passthrough',
                '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}',
                %d, %d);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p', 'M', 'master',  24, 1, NULL,  1920, 1080, %d, %d),
               ('e', 'p', 'E', 'sequence',24, 1, 48000, 1920, 1080, %d, %d);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-a1', 'm', 'A1', 'AUDIO', 1),
               ('e-a1', 'e', 'A1', 'AUDIO', 1);
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels, audio_sample_rate,
            created_at, modified_at)
        VALUES ('med', 'p', 'a.wav', '/tmp/a.wav', 960000, 24, 1, 1, 48000, %d, %d);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames,
            audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr', 'p', 'm', 'm-a1', 'med', 0, 500, 0, 500,
                48000, 1, 1.0, 0, %d, %d);
    ]],
        now, now, now, now, now, now, now, now, now, now)))
    return db, now
end

local function seed_audio_clip(db, now, id, source_in, source_out, seq_start, dur)
    assert(db:exec(string.format([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id,
            name, sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            source_in_subframe, source_out_subframe,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('%s', 'p', 'e', 'e-a1', 'm', '%s',
                %d, %d, %d, %d, %d, %d,
                NULL, NULL, 'passthrough',
                1, 1.0, 0, %d, %d);
    ]], id, id, seq_start, dur, source_in, source_out, SUB_IN, SUB_OUT, now, now)))
end

local function read_subframes(clip_id)
    local c = Clip.load_row(clip_id)
    assert(c, "read_subframes: clip " .. clip_id .. " missing")
    return c.source_in_subframe, c.source_out_subframe,
           c.source_in_frame, c.source_out_frame
end

-- ───────────────────────────── Slip ─────────────────────────────────
print("-- Slip preserves subframes through execute/undo/redo --")
do
    local db, now = fresh_db()
    seed_audio_clip(db, now, "sc",  100, 200,   0,  100)
    command_manager.init('e', 'p')

    local before_in, before_out = read_subframes("sc")
    assert(before_in == SUB_IN and before_out == SUB_OUT,
        "test setup: subframes not seeded")

    local r = command_manager.execute("Slip", {
        project_id = "p", sequence_id = "e",
        clip_id = "sc", delta_source_frames = 25,
    })
    assert(r and r.success, "Slip execute: " .. tostring(r and r.error_message))
    local in_e, out_e, f_in_e, f_out_e = read_subframes("sc")
    assert(in_e == SUB_IN and out_e == SUB_OUT, string.format(
        "Slip execute MUST preserve subframes; got (in=%s, out=%s) expected (%d, %d)",
        tostring(in_e), tostring(out_e), SUB_IN, SUB_OUT))
    assert(f_in_e == 125 and f_out_e == 225, string.format(
        "Slip execute frame delta wrong: got [%d, %d), expected [125, 225)",
        f_in_e, f_out_e))

    assert(command_manager.undo(), "Slip undo failed")
    local in_u, out_u, f_in_u, f_out_u = read_subframes("sc")
    assert(in_u == SUB_IN and out_u == SUB_OUT, "Slip undo MUST preserve subframes")
    assert(f_in_u == 100 and f_out_u == 200, "Slip undo restores frame window")

    assert(command_manager.redo(), "Slip redo failed")
    local in_r, out_r, f_in_r, f_out_r = read_subframes("sc")
    assert(in_r == SUB_IN and out_r == SUB_OUT, "Slip redo MUST preserve subframes")
    assert(f_in_r == 125 and f_out_r == 225, "Slip redo re-applies frame window")
    print("  ok")
end

-- ───────────────────────────── Roll ─────────────────────────────────
print("-- Roll preserves subframes on both edges through execute/undo/redo --")
do
    local db, now = fresh_db()
    -- Two adjacent audio clips A=[0,100), B=[100,200). Roll the boundary.
    seed_audio_clip(db, now, "ra",   0, 100,   0, 100)
    seed_audio_clip(db, now, "rb", 100, 200, 100, 100)
    command_manager.init('e', 'p')

    local r = command_manager.execute("Roll", {
        project_id = "p", sequence_id = "e",
        outgoing_clip_id = "ra", incoming_clip_id = "rb",
        delta_timeline_frames = 10,
    })
    assert(r and r.success, "Roll execute: " .. tostring(r and r.error_message))

    -- Outgoing (A): source_out shifted; subframes preserved.
    local a_in, a_out, a_f_in, a_f_out = read_subframes("ra")
    assert(a_in == SUB_IN and a_out == SUB_OUT, string.format(
        "Roll outgoing MUST preserve subframes; got (in=%s, out=%s)",
        tostring(a_in), tostring(a_out)))
    assert(a_f_in == 0 and a_f_out == 110,
        string.format("Roll outgoing frames: got [%d, %d), expected [0, 110)",
            a_f_in, a_f_out))

    -- Incoming (B): source_in shifted; subframes preserved.
    local b_in, b_out, b_f_in, b_f_out = read_subframes("rb")
    assert(b_in == SUB_IN and b_out == SUB_OUT,
        "Roll incoming MUST preserve subframes")
    assert(b_f_in == 110 and b_f_out == 200,
        string.format("Roll incoming frames: got [%d, %d), expected [110, 200)",
            b_f_in, b_f_out))

    assert(command_manager.undo(), "Roll undo failed")
    local au_in, au_out = read_subframes("ra")
    local bu_in, bu_out = read_subframes("rb")
    assert(au_in == SUB_IN and au_out == SUB_OUT, "Roll undo preserves A subframes")
    assert(bu_in == SUB_IN and bu_out == SUB_OUT, "Roll undo preserves B subframes")

    assert(command_manager.redo(), "Roll redo failed")
    local ar_in, ar_out = read_subframes("ra")
    local br_in, br_out = read_subframes("rb")
    assert(ar_in == SUB_IN and ar_out == SUB_OUT, "Roll redo preserves A subframes")
    assert(br_in == SUB_IN and br_out == SUB_OUT, "Roll redo preserves B subframes")
    print("  ok")
end

-- ───────────────────────────── TrimTail ────────────────────────────
-- TrimTail shrinks a clip's source_out_frame to land at the playhead.
-- The subframe residual on either end MUST pass through.
print("-- TrimTail preserves subframes through execute/undo/redo --")
do
    local db, now = fresh_db()
    seed_audio_clip(db, now, "tc", 0, 100, 0, 100)
    command_manager.init('e', 'p')

    local r = command_manager.execute("TrimTail", {
        project_id = "p", sequence_id = "e",
        clip_ids = { "tc" }, trim_frame = 60,
    })
    assert(r and r.success, "TrimTail execute: " .. tostring(r and r.error_message))

    local t_in, t_out, t_f_in, t_f_out = read_subframes("tc")
    assert(t_in == SUB_IN and t_out == SUB_OUT, string.format(
        "TrimTail MUST preserve subframes; got (in=%s, out=%s)",
        tostring(t_in), tostring(t_out)))
    -- TrimTail trimmed source_out to frame=60 in OWNER frames. At
    -- passthrough policy + same fps the master-frame source_out is also 60.
    assert(t_f_in == 0 and t_f_out == 60, string.format(
        "TrimTail frames: got [%d, %d), expected [0, 60)", t_f_in, t_f_out))

    assert(command_manager.undo(), "TrimTail undo failed")
    local u_in, u_out, u_f_in, u_f_out = read_subframes("tc")
    assert(u_in == SUB_IN and u_out == SUB_OUT, "TrimTail undo preserves subframes")
    assert(u_f_in == 0 and u_f_out == 100, "TrimTail undo restores frame window")
    print("  ok")
end

-- ───────────────────────────── BatchRippleEdit ──────────────────────
-- BRE shifts clips' timeline positions; it doesn't normally touch
-- source_*_frame, but the column-preservation invariant should still hold.
print("-- BatchRippleEdit preserves subframes when shifting timeline --")
do
    local db, now = fresh_db()
    -- Two clips so BRE has something to ripple.
    seed_audio_clip(db, now, "bra",   0, 100,   0, 100)
    seed_audio_clip(db, now, "brb", 100, 200, 100, 100)
    command_manager.init('e', 'p')

    local r = command_manager.execute("BatchRippleEdit", {
        project_id = "p", sequence_id = "e",
        edge_infos = {
            { clip_id = "bra", edge_type = "out", track_id = "e-a1",
              trim_type = "ripple" },
        },
        delta_frames = 10,
    })
    assert(r and r.success, "BRE execute: " .. tostring(r and r.error_message))

    local a_in, a_out = read_subframes("bra")
    local b_in, b_out = read_subframes("brb")
    assert(a_in == SUB_IN and a_out == SUB_OUT, "BRE preserves outgoing subframes")
    assert(b_in == SUB_IN and b_out == SUB_OUT, "BRE preserves downstream subframes")
    print("  ok")
end

-- ───────────────────────────── Split refusal pin ──────────────────────
-- Re-affirm that SplitClip refuses non-zero subframes (cross-ref with
-- test_018_split_refuses_nonzero_subframe.lua). This guarantees Phase 3.6
-- doesn't accidentally regress the refusal once preservation lands for
-- the other commands.
print("-- Split refuses non-zero subframe (regression cross-ref) --")
do
    local db, now = fresh_db()
    seed_audio_clip(db, now, "spc", 0, 100, 0, 100)
    command_manager.init('e', 'p')

    local result
    local ok = pcall(function()
        result = command_manager.execute("SplitClip", {
            project_id  = "p", sequence_id = "e",
            clip_id     = "spc", split_frame = 50,
        })
    end)
    local refused = (not ok) or (type(result) == "table" and result.success == false)
    assert(refused, "SplitClip must REFUSE non-zero subframe input")
    print("  ok")
end

print("✅ test_edit_command_subframe_preservation.lua passed")
