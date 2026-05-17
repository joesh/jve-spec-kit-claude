-- T052 (013): FR-020 per-override undo granularity.
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
-- Note: command_manager-level persistence grouping (the `commands`
-- table rows) is the responsibility of command_manager itself; that
-- end-to-end check is blocked on database.load_clips being migrated
-- from V8-shape (clip_kind / media_id / master_clip_id / offline) to
-- V13 — an unrelated cleanup task. The command-layer mechanism this
-- test pins is what command_manager builds atop.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_override_undo_granularity.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

local function build_fixture()
    local db = fresh_db()
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('p1', 'p', 'passthrough', 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p1', 'master', 'master', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('e', 'p1', 'edit', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-a1', 'm', 'A1', 'AUDIO', 1),
               ('e-a1', 'e', 'A1', 'AUDIO', 1);
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels,
            created_at, modified_at)
        VALUES ('a-med', 'p1', 'a.wav', '/tmp/a.wav', 200000, 48000, 1, 5, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('mr-a', 'p1', 'm', 'm-a1', 'a-med', 0, 200000, 0, 200000,
                1, 1.0, 0, 0, 0);
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('ca', 'p1', 'e', 'e-a1', 'm', 'ca',
                0, 100, 0, 200000, NULL, NULL, 'passthrough',
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

local function override_for(db, clip_id, channel_index)
    local stmt = db:prepare(
        "SELECT enabled, gain_db FROM clip_channel_override "
        .. "WHERE clip_id = ? AND channel_index = ?")
    stmt:bind_value(1, clip_id)
    stmt:bind_value(2, channel_index)
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

    -- Five toggles, one per channel.
    local captures = {}
    for ch = 0, 4 do
        captures[ch + 1] = ToggleClipChannel.execute({
            sequence_id   = "e",
            clip_id       = "ca",
            channel_index = ch,
        })
        assert(override_count(db, "ca") == ch + 1, string.format(
            "after toggle %d, expected %d override rows", ch, ch + 1))
    end

    -- Each capture is distinct (different channel_index, different
    -- prior_existed/prior_enabled state). Sanity:
    for i = 1, 5 do
        assert(captures[i] ~= captures[(i % 5) + 1],
            "captures are distinct objects (no shared identity)")
        assert(captures[i].channel_index == i - 1,
            "capture i targets channel i-1")
        assert(captures[i].prior_existed == false,
            "first toggle on each channel records prior_existed=false")
    end

    -- All 5 override rows materialized, each enabled=false (the master's
    -- channels were enabled by default; toggle flipped them).
    for ch = 0, 4 do
        local row = override_for(db, "ca", ch)
        assert(row, "ch=" .. ch .. " override exists")
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

print("-- 5 toggles on the SAME channel produce 5 distinct captures --")
do
    -- This case pins the "no coalescing" guarantee from FR-020 even
    -- when the user toggles the same channel rapidly. Each call must
    -- be independent — capture #2's undo restores capture #1's state,
    -- not the original.
    local db = build_fixture()

    local captures = {}
    for i = 1, 5 do
        captures[i] = ToggleClipChannel.execute({
            sequence_id   = "e",
            clip_id       = "ca",
            channel_index = 0,
        })
    end

    -- After 5 toggles on ch=0:
    --   #1: no row → INSERT (enabled=false). prior_existed=false.
    --   #2: row exists (enabled=false) → UPDATE to enabled=true.
    --   #3: row exists (enabled=true) → UPDATE to enabled=false.
    --   #4: enabled=false → enabled=true.
    --   #5: enabled=true → enabled=false.
    -- Final state: enabled=false. One row.
    local row = override_for(db, "ca", 0)
    assert(row and row.enabled == false,
        "after 5 toggles on ch=0, final enabled=false")
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
        local r = override_for(db, "ca", 0)
        assert(r, "row still exists during undo (down to capture 2)")
    end
    -- Undo capture 1: should DELETE the row (prior_existed was false).
    ToggleClipChannel.undo(captures[1])
    assert(override_for(db, "ca", 0) == nil,
        "undo of first toggle deletes the row")
    print("  ok")
end

print("✅ test_override_undo_granularity.lua passed")
