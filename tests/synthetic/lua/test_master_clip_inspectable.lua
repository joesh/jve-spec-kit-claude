#!/usr/bin/env luajit
-- MasterClipInspectable: the master-clip lens onto a sequences.kind='master'
-- row. Reads are aggregated from the sequence row + its media_refs + media
-- row. Writes for sequence-level fields delegate to SequenceInspectable's
-- existing command paths (name → SetSequenceMetadata, marks → SetMarkIn/Out,
-- playhead → SetPlayhead). Source In/Out are read-only in Phase 1
-- (write commands deferred — see spec 012 amendment).

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local inspectable_factory = require("inspectable")

_G.qt_create_single_shot_timer = function(_d, cb) cb(); return nil end

print("=== MasterClipInspectable: read-side contract ===\n")

local db_path = "/tmp/jve/test_master_clip_inspectable.db"
os.remove(db_path); os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'Test', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
]], now, now))

-- A master sequence: kind='master', audio_sample_rate NULL per FR-004
-- (018 — audio rate is per-media_ref, not per-master).
db:exec(string.format([[
    INSERT INTO sequences
        (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate,
         width, height, playhead_frame, view_start_frame, view_duration_frames,
         mark_in_frame, mark_out_frame, start_timecode_frame,
         video_scroll_offset, audio_scroll_offset, video_audio_split_ratio,
         created_at, modified_at)
    VALUES
        ('master_seq', 'proj', 'BoomMaster', 'master', 24, 1, NULL,
         1920, 1080, 88, 0, 1000,
         500, 1500, 86400,
         0, 0, 0.5,
         %d, %d);
]], now, now))

-- Media row that the master references.
db:exec(string.format([[
    INSERT INTO media
        (id, project_id, name, file_path, duration_frames,
         fps_numerator, fps_denominator, width, height, rotation,
         audio_sample_rate, audio_channels, codec, is_still,
         created_at, modified_at, metadata)
    VALUES
        ('media_boom', 'proj', 'boom.wav', '/captures/boom.wav', 4800,
         24, 1, 0, 0, 0,
         48000, 1, 'pcm_s24le', 0,
         %d, %d, '{}');
]], now, now))

-- A single master AUDIO track + its media_ref (one-channel boom file).
local ok_tr = db:exec(string.format([[
    INSERT INTO tracks
        (id, sequence_id, name, track_type, track_index, enabled, muted, soloed,
         locked, sync_mode, autoselect)
    VALUES
        ('mtrack_a1', 'master_seq', 'Boom', 'AUDIO', 1, 1, 0, 0, 0, 'off', 1);
]]))
assert(ok_tr, "tracks insert failed: " .. tostring(db:last_error()))
local ok_mref = db:exec(string.format([[
    INSERT INTO media_refs
        (id, project_id, owner_sequence_id, track_id, media_id,
         source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
         audio_sample_rate, source_channel,
         enabled, volume, mark_in_frame, mark_out_frame, playhead_frame,
         created_at, modified_at)
    VALUES
        ('mref_boom', 'proj', 'master_seq', 'mtrack_a1', 'media_boom',
         120, 4680, 0, 4560,
         48000, 0,
         1, 1.0, NULL, NULL, 0,
         %d, %d);
]], now, now))
assert(ok_mref, "media_refs insert failed: " .. tostring(db:last_error()))

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1; print(string.format("FAIL: %s — got %s, want %s", label, tostring(got), tostring(want))) end
end

-- factory.master_clip exists alongside .clip and .sequence
check("inspectable_factory.master_clip exists",
    type(inspectable_factory.master_clip) == "function", true)

local mc = inspectable_factory.master_clip({
    sequence_id = "master_seq",
    project_id  = "proj",
})

-- Schema discriminator drives Inspector mount.
check("schema_id == 'master_clip'", mc:get_schema_id(), "master_clip")

-- Sequence-row fields read through the wrapped sequence path.
check("get('name') == sequence.name",
    mc:get("name"), "BoomMaster")
check("get('mark_in') == sequence.mark_in_frame (frames)",
    mc:get("mark_in"), 500)
check("get('mark_out') == sequence.mark_out_frame",
    mc:get("mark_out"), 1500)
check("get('playhead_frame') == sequence.playhead_position",
    mc:get("playhead_frame"), 88)

-- Synthetic / derived: frame rate string.
check("get('rate_display') == '24 fps'",
    mc:get("rate_display"), "24 fps")

-- Media-ref-side aggregate reads.
check("get('media_id') == media_ref.media_id",
    mc:get("media_id"), "media_boom")
check("get('source_in') == primary media_ref.source_in_frame",
    mc:get("source_in"), 120)
check("get('source_out') == primary media_ref.source_out_frame",
    mc:get("source_out"), 4680)

-- offline: media row exists (file_path set) and offline_note is NULL ⇒ false.
check("get('offline') == false (media row present, no offline_note)",
    mc:get("offline"), false)

-- display name reads the sequence name (matches what the inspector header uses).
check("get_display_name() == sequence.name",
    mc:get_display_name(), "BoomMaster")

-- supports_multi_edit: false (no domain meaning for multi-master inspect).
check("supports_multi_edit() == false",
    mc:supports_multi_edit(), false)

-- watcher keys: master_clip:<sequence_id> so signals from sequence model
-- trigger inspector refresh.
local keys = mc:get_watcher_keys()
check("watcher_keys is a table",   type(keys) == "table", true)
check("watcher_keys has 1 entry", #keys, 1)
check("watcher_keys[1] keys off master_clip:<id>",
    keys[1], "master_clip:master_seq")

-- ── Fail-fast: refusing the wrong lens ────────────────────────────────
-- A user can't end up with a MasterClipInspectable over a record sequence
-- (kind='sequence') — the dispatcher in source_viewer.publish_staged
-- routes by kind. If something upstream ever leaks the wrong row, the
-- adapter must refuse loudly rather than render the master-clip schema
-- over record-sequence data. Exercise that fail-fast via pcall so the
-- message is part of the regression contract (ENGINEERING.md 2.32).
local ok_rec = db:exec(string.format([[
    INSERT INTO sequences
        (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate,
         width, height, playhead_frame, view_start_frame, view_duration_frames,
         mark_in_frame, mark_out_frame, start_timecode_frame,
         video_scroll_offset, audio_scroll_offset, video_audio_split_ratio,
         created_at, modified_at)
    VALUES
        ('record_seq', 'proj', 'RecSeq', 'sequence', 24, 1, 48000,
         1920, 1080, 0, 0, 300,
         NULL, NULL, 0,
         0, 0, 0.5,
         %d, %d);
]], now, now))
assert(ok_rec, "fixture: failed to insert record sequence: " .. tostring(db:last_error()))

local ok, err = pcall(inspectable_factory.master_clip, {
    sequence_id = "record_seq",
    project_id  = "proj",
})
check("wrong-kind construction raises", ok, false)
-- Behavior-level: assert names the offending kind and the adapter.
-- Don't pin punctuation — that's format-string coupling.
check("wrong-kind assert names the offending kind",
    type(err) == "string" and err:find("sequence", 1, true) ~= nil
    and err:find("kind", 1, true) ~= nil, true)
check("wrong-kind assert names the adapter",
    type(err) == "string" and err:find("MasterClipInspectable", 1, true) ~= nil, true)

-- ── Lazy-fill: browser projection lacks mark_in/out/playhead ──────────
-- The project browser passes a flat master-clip entry as opts.sequence
-- (build_master_clip_entry — id + kind + name + frame_rate + source_in/out,
-- no marks/playhead). On first :get of one of those fields the adapter
-- must pull the full sequence row from DB and return the real value.
local browser_entry = {
    id           = "master_seq",
    kind         = "master",
    name         = "BoomMaster",
    frame_rate   = { fps_numerator = 24, fps_denominator = 1 },
    -- Notably absent: mark_in / mark_out / playhead_position.
}
local mc_partial = inspectable_factory.master_clip({
    sequence_id = "master_seq",
    project_id  = "proj",
    sequence    = browser_entry,
})
check("lazy-fill: mark_in pulled from DB (500)",
    mc_partial:get("mark_in"), 500)
check("lazy-fill: mark_out pulled from DB (1500)",
    mc_partial:get("mark_out"), 1500)
check("lazy-fill: playhead_frame pulled from DB (88)",
    mc_partial:get("playhead_frame"), 88)

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_master_clip_inspectable.lua passed")
