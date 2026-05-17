-- T059a (013): FR-017 default-derivation for sequences.video_start_tc_frame
-- and audio_start_tc_samples on master sequences created from media.
--
-- Per FR-017:
--   "Every sequence MUST have user-modifiable 'video start timecode' and
--    'audio start timecode' properties, defaulting from the first video
--    media ref / first audio media ref (for masters) or the first video
--    clip / first audio clip (for non-masters)."
--
-- This test pins the master path: Sequence.ensure_master(media_id, ...)
-- creates a kind='master' sequence whose video_start_tc_frame matches
-- the media's video TC origin and whose audio_start_tc_samples matches
-- the media's audio TC origin (samples).
--
-- The non-master derivation (from first clip) is tested separately by
-- the import flow tests; sequences explicitly created via Sequence.create
-- accept opts.video_start_tc_frame / audio_start_tc_samples directly,
-- so they don't auto-derive.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_sequence_start_tc_defaults.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

local function insert_project(db)
    assert(db:exec(
        "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
        .. "VALUES ('p1', 'p', 'resample', 0, 0)"))
end

-- Build a media row with embedded TC metadata. Post-normalization
-- (2026-05-16) V and A TC live in separate fields; audio_start_tc_samples
-- is derived from start_tc_frames * sr / fps_num so the per-medium pair
-- expresses the same TC moment in its native unit.
local function insert_media(db, opts)
    local meta = {}
    local function add(k, v)
        meta[#meta + 1] = string.format('"%s":%s', k, tostring(v))
    end
    if opts.width and opts.width > 0 then
        add("start_tc_value", opts.start_tc_frames)
        add("start_tc_rate", opts.fps_num)
    end
    if opts.audio_channels and opts.audio_channels > 0 then
        local samp = math.floor(
            opts.start_tc_frames * opts.audio_sample_rate / opts.fps_num + 0.5)
        add("start_tc_audio_samples", samp)
        add("start_tc_audio_rate", opts.audio_sample_rate)
    end
    local meta_json = "{" .. table.concat(meta, ",") .. "}"
    local sql = string.format([[
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_sample_rate, audio_channels,
            width, height, metadata, created_at, modified_at)
        VALUES ('%s', 'p1', '%s', '%s', %d, %d, %d, %d, %d, %d, %d, '%s', 0, 0)
    ]], opts.id, opts.name, opts.path, opts.duration_frames,
        opts.fps_num, opts.fps_den, opts.audio_sample_rate, opts.audio_channels,
        opts.width, opts.height, meta_json)
    assert(db:exec(sql))
end

local function load_master_tcs(db, seq_id)
    local stmt = db:prepare(
        "SELECT video_start_tc_frame, audio_start_tc_samples FROM sequences WHERE id = ?")
    stmt:bind_value(1, seq_id)
    assert(stmt:exec() and stmt:next())
    local v = stmt:value(0)
    local a = stmt:value(1)
    stmt:finalize()
    return v, a
end

local Sequence = require("models.sequence")

print("-- video+audio master derives both TC defaults from media --")
do
    local db = fresh_db()
    insert_project(db)
    -- 24fps media, 100 frame duration, audio at 48000Hz, 2 channels.
    -- start_tc_frames = 86400 = 1 hour at 24fps.
    insert_media(db, {
        id = "med", name = "AV", path = "/tmp/av.mov",
        duration_frames = 100, fps_num = 24, fps_den = 1,
        audio_sample_rate = 48000, audio_channels = 2,
        width = 1920, height = 1080,
        start_tc_frames = 86400,
    })
    require("test_env").touch_media_fixtures()

    local seq_id = Sequence.ensure_master("med", "p1", {
        sample_rate = 48000,
    })
    local v_tc, a_tc = load_master_tcs(db, seq_id)
    assert(v_tc == 86400, string.format(
        "video_start_tc_frame must derive from media's start_tc_value; "
        .. "expected 86400, got %s", tostring(v_tc)))
    -- audio TC samples = video frames * sample_rate / fps
    --                  = 86400 * 48000 / 24 = 172800000.
    assert(a_tc == 172800000, string.format(
        "audio_start_tc_samples must derive from media's TC at sample rate; "
        .. "expected 172800000, got %s", tostring(a_tc)))
    print("  ok")
end

print("-- video-only master leaves audio_start_tc_samples NULL --")
do
    local db = fresh_db()
    insert_project(db)
    insert_media(db, {
        id = "med", name = "VOnly", path = "/tmp/v.mov",
        duration_frames = 100, fps_num = 24, fps_den = 1,
        audio_sample_rate = 0, audio_channels = 0,
        width = 1920, height = 1080,
        start_tc_frames = 86400,
    })
    require("test_env").touch_media_fixtures()

    -- For video-only the master has no audio media_refs; ensure_master
    -- should not derive an audio TC.
    local seq_id = Sequence.ensure_master("med", "p1", {})
    local v_tc, a_tc = load_master_tcs(db, seq_id)
    assert(v_tc == 86400, "video TC derived")
    assert(a_tc == nil,
        "audio_start_tc_samples must remain NULL for video-only master; got "
        .. tostring(a_tc))
    print("  ok")
end

print("-- start_tc_value=0 is a valid TC (00:00:00:00), not a missing value --")
do
    local db = fresh_db()
    insert_project(db)
    insert_media(db, {
        id = "med", name = "Zero", path = "/tmp/z.mov",
        duration_frames = 100, fps_num = 24, fps_den = 1,
        audio_sample_rate = 48000, audio_channels = 1,
        width = 1920, height = 1080,
        start_tc_frames = 0,
    })
    require("test_env").touch_media_fixtures()

    local seq_id = Sequence.ensure_master("med", "p1", { sample_rate = 48000 })
    local v_tc, a_tc = load_master_tcs(db, seq_id)
    assert(v_tc == 0, "TC 00:00:00:00 is a real value (frame 0)")
    assert(a_tc == 0, "audio TC at sample 0 derives")
    print("  ok")
end

print("✅ test_sequence_start_tc_defaults.lua passed")
