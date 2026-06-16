#!/usr/bin/env luajit
--- Test: relink resolves media for a master virtual clip (id="mref:<ref>")
--
-- Domain scenario (TSO 2026-06-15): a master sequence is loaded in the Source
-- viewer. Its content renders as virtual clips synthesized from media_refs,
-- each carrying id="mref:<media_ref_id>" (they are NOT rows in `clips`). When
-- the user selects one and invokes Relink, ShowRelinkDialog must resolve the
-- media behind that media_ref — exactly as it does for a real clip. Previously
-- find_media_for_clips queried only the `clips` table and fail-fast asserted
-- "clip not found: mref:..." because no such row exists.
--
-- This test produces the selection id through the SAME code path the app uses
-- (database.load_master_virtual_clips), then asserts relink finds the media.
require("test_env")

_G.qt_create_single_shot_timer = function() end
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

print("=== test_relink_master_virtual_clip.lua ===")

local database = require("core.database")
local uuid = require("uuid")
local json = require("dkjson")
local Media = require("models.media")
local Sequence = require("models.sequence")
local media_relinker = require("core.media_relinker")

local TEST_DB = "/tmp/jve/test_relink_master_virtual_clip.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
local project_id = "proj-mref-relink"

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at, settings)
    VALUES ('%s', 'Mref Relink Project', 'resample', %d, %d, '{}');
]], project_id, now, now))

-- Offline media (file does not exist) — the thing the user wants to relink.
local offline_media = Media.create({
    id = uuid.generate(),
    project_id = project_id,
    file_path = "/nonexistent/path/A008_05211408_C011.mov",
    name = "A008_05211408_C011.mov",
    duration_frames = 1273177,
    fps_numerator = 25,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    audio_channels = 0,
    metadata = json.encode({start_tc_value = 1272357, start_tc_rate = 25}),
})
offline_media:save(db)

-- The master sequence holds this media as media_refs (no `clips` rows).
local master_id = Sequence.ensure_master(offline_media.id, project_id)

---------------------------------------------------------------------------------
-- Produce the selection id exactly as the app does: virtual clips synthesized
-- from the master's media_refs, each id="mref:<media_ref_id>".
---------------------------------------------------------------------------------
local virtual_clips = database.load_master_virtual_clips(master_id)
assert(#virtual_clips > 0,
    "expected master to synthesize >=1 virtual clip from its media_refs")

local mref_clip_id = virtual_clips[1].id
assert(mref_clip_id:match("^mref:"),
    string.format("expected virtual clip id to be 'mref:<ref>', got %s", mref_clip_id))

---------------------------------------------------------------------------------
-- The behavior under test: relink resolves the media behind the virtual clip.
---------------------------------------------------------------------------------
print("\n--- find_media_for_clips on a master virtual clip ---")
do
    local media_list = media_relinker.find_media_for_clips(db, {mref_clip_id})
    assert(#media_list == 1,
        string.format("expected 1 media for the virtual clip, got %d", #media_list))
    assert(media_list[1].id == offline_media.id,
        "virtual clip must resolve to the media behind its media_ref")
    print("  ✓ master virtual clip resolves to its underlying media")
end

---------------------------------------------------------------------------------
-- Mixed selection: a virtual clip + a real clip both resolve, deduped per media.
---------------------------------------------------------------------------------
print("\n--- mixed selection (virtual + real clip) ---")
do
    -- A second, online media with a real timeline clip referencing its master.
    local online_dir = "/tmp/jve/relink_mref_test"
    os.execute(string.format("mkdir -p %q", online_dir))
    local online_file = online_dir .. "/online.mov"
    local f = assert(io.open(online_file, "w"), "failed to create test file")
    f:write("dummy"); f:close()

    local online_media = Media.create({
        id = uuid.generate(),
        project_id = project_id,
        file_path = online_file,
        name = "online.mov",
        duration_frames = 500,
        fps_numerator = 25,
        fps_denominator = 1,
        width = 1920,
        height = 1080,
        audio_channels = 0,
        metadata = json.encode({start_tc_value = 0, start_tc_rate = 25}),
    })
    online_media:save(db)
    local online_master = Sequence.ensure_master(online_media.id, project_id)

    local seq_id = uuid.generate()
    local v1_track = uuid.generate()
    local real_clip_id = uuid.generate()
    db:exec(string.format([[
        INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
            audio_sample_rate, width, height, view_start_frame, view_duration_frames,
            playhead_frame, selected_clip_ids, selected_edge_infos, selected_gap_infos,
            current_sequence_number, created_at, modified_at)
        VALUES ('%s', '%s', 'Main', 'sequence', 25, 1, 48000, 1920, 1080, 0, 500, 0,
            '[]', '[]', '[]', 0, %d, %d);

        INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled,
            locked, muted, soloed, volume, pan)
        VALUES ('%s', '%s', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

        INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id,
            sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('%s', '%s', 'Online-Shot', '%s', '%s', '%s',
            0, 100, 100, 200, NULL, NULL, 'resample', 1, 1.0, 0, %d, %d);
    ]], seq_id, project_id, now, now, v1_track, seq_id,
        real_clip_id, project_id, v1_track, online_master, seq_id, now, now))

    local media_list = media_relinker.find_media_for_clips(db, {mref_clip_id, real_clip_id})
    assert(#media_list == 2,
        string.format("expected 2 unique media (virtual + real), got %d", #media_list))

    local ids = {}
    for _, m in ipairs(media_list) do ids[m.id] = true end
    assert(ids[offline_media.id], "offline media (from virtual clip) must be present")
    assert(ids[online_media.id], "online media (from real clip) must be present")
    print("  ✓ mixed virtual+real selection resolves both media")

    os.execute(string.format("rm -rf %q", online_dir))
end

---------------------------------------------------------------------------------
-- Failure path: a virtual clip id that names no media_ref must still fail-fast
-- (no silent drop). The relinker resolves nothing for it and asserts.
---------------------------------------------------------------------------------
print("\n--- unresolvable virtual clip id fails fast ---")
do
    local bogus_id = "mref:" .. uuid.generate()  -- well-formed prefix, no such ref
    local ok, err = pcall(media_relinker.find_media_for_clips, db, {bogus_id})
    assert(not ok, "expected unresolvable virtual clip id to assert, but it succeeded")
    assert(tostring(err):match("clip not found"),
        string.format("expected an actionable 'clip not found' error, got: %s", tostring(err)))
    assert(tostring(err):find(bogus_id, 1, true),
        "error must name the offending id so the failure is actionable")
    print("  ✓ unresolvable virtual clip id asserts with the offending id")
end

print("\n✅ test_relink_master_virtual_clip.lua passed")
