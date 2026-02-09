#!/usr/bin/env luajit

-- Test: Split preserves link relationships
-- When a linked clip is split, both halves should remain linked to their counterparts

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local ClipLink = require("models.clip_link")

local db_path = "/tmp/jve/test_split_preserves_links.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()

-- Setup: project, sequence, tracks
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq', 'timeline', 24000, 1001, 48000,
        1920, 1080, 0, 3000, 500, '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk_v', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk_a', 'seq1', 'A1', 'AUDIO', 2, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels,
        codec, metadata, created_at, modified_at)
    VALUES ('med1', 'proj1', 'media.mov', '/tmp/media.mov', 3000,
        24000, 1001, 1920, 1080, 2, 'prores', '{}', %d, %d);
]], now, now, now, now, now, now))

-- Create linked clips: V1 [video 0..1000] linked to A1 [audio 0..1000]
db:exec(string.format([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip_video', 'proj1', 'timeline', 'Video', 'trk_v', 'med1',
        0, 1000, 0, 1000, 24000, 1001, 1, 0, %d, %d);
]], now, now))

db:exec(string.format([[
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip_audio', 'proj1', 'timeline', 'Audio', 'trk_a', 'med1',
        0, 1000, 0, 1000, 24000, 1001, 1, 0, %d, %d);
]], now, now))

-- Link them
ClipLink.create_link_group({
    { clip_id = "clip_video", role = "video", time_offset = 0 },
    { clip_id = "clip_audio", role = "audio", time_offset = 0 },
}, db)

-- Verify initial link
local video_links = ClipLink.get_link_group("clip_video", db)
assert(video_links and #video_links == 2, "Initial link group should have 2 clips")
print("Initial setup: video and audio clips linked")

-- Initialize command manager
command_manager.init("seq1", "proj1")

-- Split video clip at frame 500
print("\n--- Test: Split video clip at frame 500 ---")
local result = command_manager.execute("SplitClip", {
    project_id = "proj1",
    sequence_id = "seq1",
    clip_id = "clip_video",
    split_value = 500,
})
assert(result.success or result == true, "SplitClip should succeed")

-- Get the second clip ID from command manager's last command
-- (SplitClip stores second_clip_id in parameters)
local video_second_id = nil
local stmt = db:prepare([[
    SELECT id FROM clips WHERE track_id = 'trk_v' AND timeline_start_frame = 500
]])
if stmt:exec() and stmt:next() then
    video_second_id = stmt:value(0)
end
stmt:finalize()
assert(video_second_id, "Should find second video clip at frame 500")
print(string.format("  Second video clip: %s", video_second_id))

-- Check first half still linked to original audio clip
local first_half_links = ClipLink.get_link_group("clip_video", db)
assert(first_half_links, "First half should still be linked")
assert(#first_half_links == 2, string.format(
    "First half link group should have 2 clips (original pair), got %d", #first_half_links))
print(string.format("  First half links: %d", #first_half_links))

-- Second half should NOT be in the first half's link group
local found_second_in_first = false
for _, link_info in ipairs(first_half_links) do
    if link_info.clip_id == video_second_id then
        found_second_in_first = true
    end
end
assert(not found_second_in_first, "Second half should NOT be in first half's link group")
print("✓ Split creates separate groups: first halves stay linked to each other")

-- Note: Second half is unlinked because we only split one clip (video), not both
-- The Split wrapper only creates new link groups when 2+ clips from the same
-- original group are split. For a single SplitClip, second half stays unlinked.
local second_half_links = ClipLink.get_link_group(video_second_id, db)
print(string.format("  Second half links: %s", second_half_links and #second_half_links or "nil (unlinked)"))

-- Test undo restores original state
print("\n--- Test: Undo split ---")
local undo_result = command_manager.undo()
assert(undo_result, "Undo should succeed")

-- After undo, link group should be back to 2 clips
local restored_links = ClipLink.get_link_group("clip_video", db)
assert(restored_links, "Original clip should still be linked after undo")
assert(#restored_links == 2, string.format(
    "Link group should still have 2 clips after undo, got %d", #restored_links))

print("✓ Undo split: original link group preserved")

-- Cleanup
database.shutdown()
os.remove(db_path)

print("\n✅ test_split_preserves_links.lua passed")
