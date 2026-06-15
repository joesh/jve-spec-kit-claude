--- Shared SQLite DB scaffold for spec-023 LIVE source-range tests.
---
--- Three live tests (source-range clamp / field-diff / MTBA render) each
--- need the same fixture: one project with a master + editing sequence, a
--- single A005-at-23.976 media with a real embedded TC origin, and one
--- clip trimmed `in_offset` frames into that media (so its absolute
--- source_in = media_tc_origin + in_offset — the non-trivial case that
--- exercises the absolute-vs-media-relative coordinate seam). Lifted here
--- so the ~40-line scaffold lives once (rule: lift DRY at the third copy).
---
--- Pure model-layer construction (Project/Sequence/Track/Media/Clip), with
--- the one raw `media_refs` INSERT the model layer does not yet surface.

local database = require("core.database")
local Project  = require("models.project")
local Sequence = require("models.sequence")
local Track    = require("models.track")
local Media    = require("models.media")
local Clip     = require("models.clip")

local M = {}

-- Defaults are the A005-at-23.976 fixture every source-range test shares.
local DEFAULTS = {
    fps_num       = 24000,
    fps_den       = 1001,           -- 23.976
    media_frames  = 108,            -- A005 ffprobe nb_frames (video)
    in_offset     = 30,             -- trim this many frames into the media
    dur           = 24,             -- clip timeline duration
    seq_start     = 120,            -- record-start of the clip
    clip_id       = "0b50c0de-7007-4aaa-8aaa-000000000001",
}

--- Build the fixture DB and return its handles.
--- @param opts table { db_path (req), media_path (req), media_name?,
---   fps_num?, fps_den?, media_frames?, in_offset?, dur?, seq_start?,
---   clip_id? }
--- @return table { db, media, tc_origin, abs_source_in, clip_id,
---   fps_num, fps_den, media_frames, in_offset, dur, seq_start }
function M.build_a005_trimmed_db(opts)
    assert(type(opts) == "table", "build_a005_trimmed_db: opts table required")
    assert(type(opts.db_path) == "string" and opts.db_path ~= "",
        "build_a005_trimmed_db: opts.db_path required")
    assert(type(opts.media_path) == "string" and opts.media_path ~= "",
        "build_a005_trimmed_db: opts.media_path required")

    local cfg = {}
    for k, v in pairs(DEFAULTS) do cfg[k] = v end
    for k, v in pairs(opts) do cfg[k] = v end
    local media_name = cfg.media_name or "A005_C052_0925BL_001_tc01.mp4"

    os.remove(cfg.db_path)
    os.execute("mkdir -p /tmp/jve")
    assert(database.init(cfg.db_path), "schema init failed")
    local db = database.get_connection()
    db:exec(require("import_schema"))

    Project.create("p", {
        id = "p1", fps_mismatch_policy = "passthrough",
        settings = { master_clock_hz = 705600000,
                     default_fps = { num = cfg.fps_num, den = cfg.fps_den } },
    }):save()
    Sequence.create("m", "p1",
        { fps_numerator = cfg.fps_num, fps_denominator = cfg.fps_den },
        1920, 1080, { id = "m", kind = "master" }):save()
    Sequence.create("e", "p1",
        { fps_numerator = cfg.fps_num, fps_denominator = cfg.fps_den },
        1920, 1080, { id = "e1", kind = "sequence", audio_sample_rate = 48000 })
        :save()
    Track.create_video("V1", "e1", { id = "e1-v1", index = 1 }):save()
    Track.create_video("V1", "m", { id = "m-v1", index = 1 }):save()
    db:exec("UPDATE sequences SET default_video_layer_track_id = 'm-v1' "
        .. "WHERE id = 'm'")

    local media = Media.create({
        id = "med-tc01", project_id = "p1", name = media_name,
        file_path = cfg.media_path, duration_frames = cfg.media_frames,
        fps_numerator = cfg.fps_num, fps_denominator = cfg.fps_den,
        audio_channels = 0, metadata = "{}",
    })
    media:save()
    -- media_refs has no model-layer constructor yet; raw INSERT is the
    -- established pattern for these fixtures.
    db:exec(string.format([[
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames, audio_sample_rate,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr-tc01','p1','m','m-v1','med-tc01',0,%d,0,%d,NULL,1,1.0,0,0,0);
    ]], cfg.media_frames, cfg.media_frames))

    -- get_start_tc() extracts the file's embedded TC origin (EMP) since
    -- metadata is empty — the same origin the send path passes and Resolve
    -- reads. A zero origin would make the absolute/relative seam vacuous.
    local tc_origin = media:get_start_tc()
    assert(type(tc_origin) == "number" and tc_origin > 0, string.format(
        "build_a005_trimmed_db: embedded TC origin must extract non-zero "
        .. "from %s; got %s", cfg.media_path, tostring(tc_origin)))
    local abs_source_in = tc_origin + cfg.in_offset

    local sub_in, sub_out = Clip.subframe_defaults_for_track_type("VIDEO")
    assert(Clip.create({
        id = cfg.clip_id, project_id = "p1", owner_sequence_id = "e1",
        track_id = "e1-v1", sequence_id = "m", name = media_name,
        sequence_start_frame = cfg.seq_start, duration_frames = cfg.dur,
        source_in_frame = abs_source_in,
        source_out_frame = abs_source_in + cfg.dur,
        source_in_subframe = sub_in, source_out_subframe = sub_out,
        master_layer_track_id = nil, fps_mismatch_policy = "passthrough",
        enabled = true, volume = 1.0, playhead_frame = 0,
    }) == cfg.clip_id, "build_a005_trimmed_db: Clip.create failed")

    return {
        db = db, media = media, tc_origin = tc_origin,
        abs_source_in = abs_source_in, clip_id = cfg.clip_id,
        fps_num = cfg.fps_num, fps_den = cfg.fps_den,
        media_frames = cfg.media_frames, in_offset = cfg.in_offset,
        dur = cfg.dur, seq_start = cfg.seq_start,
    }
end

return M
