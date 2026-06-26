-- 018 INV-3 inline subframe migration applied (count=1)
-- T052 (013): FR-020 per-override undo granularity — Phase 4a (master_track_id identity).
--
-- "Each clip-level override change ... MUST be a single undoable
--  command with a descriptive human-readable label. Override changes
--  MUST NOT be coalesced into grouped undo entries; five channel
--  toggles in rapid succession produce five undo steps."
--
-- Tests the command-layer mechanic that FR-020 mandates:
--   * Five rapid ToggleClipChannel.execute calls produce five DISTINCT
--     undo captures.
--   * Each capture independently reverses exactly one toggle (no
--     coalescing, no shared mutable state across captures).
--   * Five undos in reverse order restore the clip to its pre-toggle
--     state.
--
-- Under Phase 4a: command arg is master_track_id (track UUID), not
-- channel_index. Fixture provides 5 master AUDIO tracks so each toggle
-- targets a distinct track identity.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_override_undo_granularity.db"

-- Stable track UUIDs for the 5 master AUDIO tracks.
local MASTER_TRACKS = { "m-a1", "m-a2", "m-a3", "m-a4", "m-a5" }

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

local function build_fixture()
    local db = fresh_db()
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
        VALUES ('p1', 'p', 'passthrough', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p1', 'master', 'master', 24, 1, NULL, 1920, 1080, 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('e', 'p1', 'edit', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-a1', 'm', 'A1', 'AUDIO', 1),
               ('m-a2', 'm', 'A2', 'AUDIO', 2),
               ('m-a3', 'm', 'A3', 'AUDIO', 3),
               ('m-a4', 'm', 'A4', 'AUDIO', 4),
               ('m-a5', 'm', 'A5', 'AUDIO', 5),
               ('e-a1', 'e', 'A1', 'AUDIO', 1);
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels,
            created_at, modified_at)
        VALUES ('a-med', 'p1', 'a.wav', '/tmp/a.wav', 200000, 48000, 1, 5, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames, audio_sample_rate, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('mr-a', 'p1', 'm', 'm-a1', 'a-med', 0, 200000, 0, 200000, 48000,
                1, 1.0, 0, 0, 0);
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            source_in_subframe, source_out_subframe,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('ca', 'p1', 'e', 'e-a1', 'm', 'ca',
                0, 100, 0, 200000, 0, 0, NULL, NULL, 'passthrough',
                1, 1.0, 0, 0, 0);
    ]]))
    require("test_env").touch_media_fixtures()
    return db
end

local function override_count(db, clip_id)
    local stmt = db:prepare(
        "SELECT COUNT(*) FROM clip_channel_override WHERE clip_id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec() and stmt:next())
    local n = stmt:value(0)
    stmt:finalize()
    return n
end

local function override_for(db, clip_id, master_track_id)
    local stmt = db:prepare(
        "SELECT enabled, gain_db FROM clip_channel_override "
        .. "WHERE clip_id = ? AND master_track_id = ?")
    stmt:bind_value(1, clip_id)
    stmt:bind_value(2, master_track_id)
    assert(stmt:exec())
    local row
    if stmt:next() then
        row = { enabled = stmt:value(0) == 1, gain_db = stmt:value(1) }
    end
    stmt:finalize()
    return row
end

local ToggleClipChannel = require("core.commands.toggle_clip_channel")

print("-- 5 rapid toggles produce 5 distinct undo captures, each independent --")
do
    local db = build_fixture()

    -- Five toggles, one per master AUDIO track.
    local captures = {}
    for i, mt in ipairs(MASTER_TRACKS) do
        captures[i] = ToggleClipChannel.execute({
            sequence_id    = "e",
            clip_id        = "ca",
            master_track_id = mt,
        })
        assert(override_count(db, "ca") == i, string.format(
            "after toggle %d, expected %d override rows", i, i))
    end

    -- Each capture is distinct (different master_track_id, different
    -- prior_existed/prior_enabled state). Sanity:
    for i = 1, 5 do
        assert(captures[i] ~= captures[(i % 5) + 1],
            "captures are distinct objects (no shared identity)")
        assert(captures[i].master_track_id == MASTER_TRACKS[i],
            "capture i targets MASTER_TRACKS[i]")
        assert(captures[i].prior_existed == false,
            "first toggle on each track records prior_existed=false")
    end

    -- All 5 override rows materialized, each enabled=false (the master's
    -- channels were enabled by default; toggle flipped them).
    for _, mt in ipairs(MASTER_TRACKS) do
        local row = override_for(db, "ca", mt)
        assert(row, mt .. " override exists")
        assert(row.enabled == false,
            "toggle from enabled=true (inherited default) → enabled=false")
    end

    -- Undo in reverse order. Each undo reverses exactly ONE toggle:
    -- the clip_channel_override row count drops by 1 per undo.
    for i = 5, 1, -1 do
        local pre = override_count(db, "ca")
        ToggleClipChannel.undo(captures[i])
        local post = override_count(db, "ca")
        assert(post == pre - 1, string.format(
            "undo %d should remove exactly 1 override row; rows %d → %d",
            i, pre, post))
    end

    assert(override_count(db, "ca") == 0,
        "after 5 undos in reverse, all overrides cleared")
    print("  ok")
end

print("-- 5 toggles on the SAME master track produce 5 distinct captures --")
do
    -- This case pins the "no coalescing" guarantee from FR-020 even
    -- when the user toggles the same track rapidly. Each call must
    -- be independent — capture #2's undo restores capture #1's state,
    -- not the original.
    local db = build_fixture()
    local mt = "m-a1"  -- single master track, toggled 5 times

    local captures = {}
    for i = 1, 5 do
        captures[i] = ToggleClipChannel.execute({
            sequence_id    = "e",
            clip_id        = "ca",
            master_track_id = mt,
        })
    end

    -- After 5 toggles on m-a1:
    --   #1: no row → INSERT (enabled=false). prior_existed=false.
    --   #2: row exists (enabled=false) → UPDATE to enabled=true.
    --   #3: row exists (enabled=true) → UPDATE to enabled=false.
    --   #4: enabled=false → enabled=true.
    --   #5: enabled=true → enabled=false.
    -- Final state: enabled=false. One row.
    local row = override_for(db, "ca", mt)
    assert(row and row.enabled == false,
        "after 5 toggles on m-a1, final enabled=false")
    assert(captures[1].prior_existed == false,
        "first toggle: no prior row")
    for i = 2, 5 do
        assert(captures[i].prior_existed == true,
            "toggle " .. i .. ": prior row exists")
    end
    -- Each capture's prior_enabled alternates: capture[2].prior_enabled=false,
    -- capture[3].prior_enabled=true, etc.
    assert(captures[2].prior_enabled == false)
    assert(captures[3].prior_enabled == true)
    assert(captures[4].prior_enabled == false)
    assert(captures[5].prior_enabled == true)

    -- Undo in reverse — each undo restores the previous state.
    for i = 5, 2, -1 do
        ToggleClipChannel.undo(captures[i])
        local r = override_for(db, "ca", mt)
        assert(r, "row still exists during undo (down to capture 2)")
    end
    -- Undo capture 1: should DELETE the row (prior_existed was false).
    ToggleClipChannel.undo(captures[1])
    assert(override_for(db, "ca", mt) == nil,
        "undo of first toggle deletes the row")
    print("  ok")
end

print("✅ test_override_undo_granularity.lua passed")
