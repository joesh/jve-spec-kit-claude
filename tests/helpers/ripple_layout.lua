local M = {}

local database = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")
local Project = require("models.project")
local Sequence = require("models.sequence")
local Track = require("models.track")
local Media = require("models.media")
local Clip = require("models.clip")

local function remove_best_effort(path)
    if not path or path == "" then
        return
    end
    os.remove(path)
end

local function remove_project_artifacts(db_path)
    remove_best_effort(db_path)
    remove_best_effort(db_path .. "-wal")
    remove_best_effort(db_path .. "-shm")
    local events_dir = db_path .. ".events"
    os.execute(string.format("rm -rf %q", events_dir))
end

local function deep_copy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for k, v in pairs(value) do
        out[k] = deep_copy(v)
    end
    return out
end

local function merge_table(dest, src)
    if not src then return end
    for k, v in pairs(src) do
        if type(v) == "table" and type(dest[k]) == "table" then
            merge_table(dest[k], v)
        else
            dest[k] = v
        end
    end
end

local DEFAULT_CONFIG = {
    project_id = "default_project",
    project_name = "Default",
    sequence_id = "default_sequence",
    sequence_name = "Timeline",
    fps_numerator = 1000,
    fps_denominator = 1,
    audio_rate = 48000,
    width = 1920,
    height = 1080,
    view_start_frame = 0,
    view_duration_frames = 6000,
    playhead_frame = 0,
    selected_edge_infos = nil,
    tracks = {
        order = {"v1", "v2"},
        v1 = {id = "track_v1", name = "Video 1", track_type = "VIDEO", track_index = 1, enabled = 1},
        v2 = {id = "track_v2", name = "Video 2", track_type = "VIDEO", track_index = 2, enabled = 1}
    },
    media = {
        order = {"main"},
        main = {
            id = "media_primary",
            name = "Media",
            file_path = "synthetic://primary",
            duration_frames = 24000,
            fps_numerator = 1000,
            fps_denominator = 1,
            width = 1920,
            height = 1080,
            audio_channels = 0,
            codec = "raw",
            metadata = "{}"
        }
    },
    clips = {
        order = {"v1_left", "v2", "v1_right"},
        v1_left = {
            id = "clip_v1_left",
            name = "V1 Left",
            track_key = "v1",
            media_key = "main",
            timeline_start = 0,
            duration = 1500,
            source_in = 0,
            fps_numerator = 1000,
            fps_denominator = 1
        },
        v1_right = {
            id = "clip_v1_right",
            name = "V1 Right",
            track_key = "v1",
            media_key = "main",
            timeline_start = 3500,
            duration = 1200,
            source_in = 0,
            fps_numerator = 1000,
            fps_denominator = 1
        },
        v2 = {
            id = "clip_v2_overlap",
            name = "V2 Clip",
            track_key = "v2",
            media_key = "main",
            timeline_start = 2000,
            duration = 1000,
            source_in = 0,
            fps_numerator = 1000,
            fps_denominator = 1
        }
    }
}

local function build_config(opts)
    local cfg = deep_copy(DEFAULT_CONFIG)
    -- Don't merge opts directly - it would create incomplete clip entries
    -- Instead, merge only non-clip sections first
    if opts then
        for k, v in pairs(opts) do
            if k ~= "clips" and k ~= "tracks" and k ~= "media" then
                merge_table(cfg, {[k] = v})
            end
        end
    end

    if opts and opts.tracks then
        for key, override in pairs(opts.tracks) do
            assert(cfg.tracks[key], string.format("Unknown track override '%s'", key))
            merge_table(cfg.tracks[key], override)
        end
    end

    if opts and opts.media then
        for key, override in pairs(opts.media) do
            if type(key) == "string" then
                assert(cfg.media[key], string.format("Unknown media override '%s'", key))
                merge_table(cfg.media[key], override)
            end
        end
    end

    if opts and opts.clips then
        -- Handle order override first
        if opts.clips.order then
            cfg.clips.order = opts.clips.order
        end

        for key, override in pairs(opts.clips) do
            if key == "order" then
                -- Already handled above
            elseif cfg.clips[key] then
                -- Merge with existing default clip
                merge_table(cfg.clips[key], override)
            else
                -- Add new clip with inferred defaults
                local inferred_track_key = key:match("^([av]%d+)") or "v1"
                assert(cfg.tracks[inferred_track_key], string.format("Track %s does not exist for new clip %s", inferred_track_key, key))
                cfg.clips[key] = {
                    id = "clip_" .. key,
                    name = key:gsub("_", " "):gsub("(%a)(%a*)", function(first, rest)
                        return first:upper() .. rest
                    end),
                    track_key = inferred_track_key,
                    media_key = "main",
                    timeline_start = override.timeline_start or 0,
                    duration = override.duration or 1000,
                    source_in = override.source_in or 0,
                    fps_numerator = override.fps_numerator or cfg.fps_numerator,
                    fps_denominator = override.fps_denominator or cfg.fps_denominator
                }
                merge_table(cfg.clips[key], override)
                -- Add to order list only if not already present
                if not opts.clips.order then
                    table.insert(cfg.clips.order, key)
                end
            end
        end
    end

    return cfg
end

local function build_clip_sql(cfg, clip)
    local track = cfg.tracks[clip.track_key]
    local media = cfg.media[clip.media_key]
    assert(track, string.format("missing track for clip %s", clip.id))
    assert(media, string.format("missing media for clip %s", clip.id))

    local source_out = clip.source_in + clip.duration
    local created_at = os.time()
    local modified_at = created_at

    return string.format([[INSERT INTO clips (
        id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
        VALUES ('%s', '%s', 'timeline', '%s', '%s', '%s', '%s', %d, %d, %d, %d,
                %d, %d, 1, 0, %d, %d);
    ]],
        clip.id,
        cfg.project_id,
        clip.name,
        track.id,
        media.id,
        cfg.sequence_id,
        clip.timeline_start,
        clip.duration,
        clip.source_in,
        source_out,
        clip.fps_numerator or cfg.fps_numerator,
        clip.fps_denominator or cfg.fps_denominator,
        created_at,
        modified_at
    )
end

local function build_media_sql(cfg, media)
    local created_at = os.time()
    local modified_at = created_at
    return string.format([[INSERT INTO media (
        id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
        width, height, audio_channels, codec, metadata, created_at, modified_at)
        VALUES ('%s', '%s', '%s', '%s', %d, %d, %d, %d, %d, %d, '%s', '%s', %d, %d);
    ]],
        media.id,
        cfg.project_id,
        media.name,
        media.file_path,
        media.duration_frames,
        media.fps_numerator,
        media.fps_denominator,
        media.width,
        media.height,
        media.audio_channels,
        media.codec,
        media.metadata,
        created_at,
        modified_at
    )
end

local function build_track_sql(cfg, track)
    return string.format([[INSERT INTO tracks (
        id, sequence_id, name, track_type, track_index, enabled)
        VALUES ('%s', '%s', '%s', '%s', %d, %d);
    ]], track.id, cfg.sequence_id, track.name, track.track_type, track.track_index, track.enabled)
end

function M.create(opts)
    opts = opts or {}
    local cfg = build_config(opts)
    local db_path = opts.db_path or string.format("/tmp/jve/ripple_layout_%d_%d.db", os.time(), math.random(100000))
    remove_project_artifacts(db_path)
    assert(database.init(db_path), "Failed to init database")

    -- Create project using model
    local project = Project.create(cfg.project_name, {id = cfg.project_id})
    assert(project and project:save(), "Failed to create project")

    -- Create sequence using model
    local frame_rate = {fps_numerator = cfg.fps_numerator, fps_denominator = cfg.fps_denominator}
    local sequence = Sequence.create(cfg.sequence_name, cfg.project_id, frame_rate, cfg.width, cfg.height, {
        id = cfg.sequence_id,
        audio_rate = cfg.audio_rate,
        view_start_frame = cfg.view_start_frame,
        view_duration_frames = cfg.view_duration_frames,
        playhead_frame = cfg.playhead_frame,
        selected_edge_infos_json = cfg.selected_edge_infos
    })
    assert(sequence and sequence:save(), "Failed to create sequence")

    -- Create tracks using model
    for _, key in ipairs(cfg.tracks.order or {}) do
        local t = cfg.tracks[key]
        local track
        if t.track_type == "VIDEO" then
            track = Track.create_video(t.name, cfg.sequence_id, {id = t.id, index = t.track_index})
        else
            track = Track.create_audio(t.name, cfg.sequence_id, {id = t.id, index = t.track_index})
        end
        track.enabled = t.enabled == 1
        assert(track and track:save(), "Failed to create track: " .. t.id)
    end

    -- Create media using model
    for _, key in ipairs(cfg.media.order or {}) do
        local m = cfg.media[key]
        local media = Media.create({
            id = m.id,
            project_id = cfg.project_id,
            name = m.name,
            file_path = m.file_path,
            duration_frames = m.duration_frames,
            fps_numerator = m.fps_numerator,
            fps_denominator = m.fps_denominator,
            width = m.width,
            height = m.height,
            audio_channels = m.audio_channels,
            codec = m.codec
        })
        assert(media and media:save(), "Failed to create media: " .. m.id)
    end

    -- Create clips using model (integer frame coordinates)
    for _, key in ipairs(cfg.clips.order or {}) do
        local c = cfg.clips[key]
        local track = cfg.tracks[c.track_key]
        local media_cfg = cfg.media[c.media_key]
        local fps_num = c.fps_numerator or cfg.fps_numerator
        local fps_den = c.fps_denominator or cfg.fps_denominator
        local clip = Clip.create(c.name, media_cfg.id, {
            id = c.id,
            project_id = cfg.project_id,
            clip_kind = "timeline",
            track_id = track.id,
            owner_sequence_id = cfg.sequence_id,
            timeline_start = c.timeline_start,  -- integer
            duration = c.duration,  -- integer
            source_in = c.source_in,  -- integer
            source_out = c.source_in + c.duration,  -- integer
            fps_numerator = fps_num,
            fps_denominator = fps_den
        })
        assert(clip and clip:save({skip_occlusion = true}), "Failed to create clip: " .. c.id)
    end

    command_manager.init(cfg.sequence_id, cfg.project_id)

    local layout = {
        db = database.get_connection(),  -- Exposed for tests that need raw SQL
        db_path = db_path,
        project_id = cfg.project_id,
        sequence_id = cfg.sequence_id,
        tracks = cfg.tracks,
        media = cfg.media,
        clips = cfg.clips,
        config = cfg
    }

    function layout:cleanup()
        local ok, err = database.shutdown()
        assert(ok, tostring(err or "database.shutdown failed"))
        remove_project_artifacts(self.db_path)
    end

    function layout:init_timeline_state()
        timeline_state.init(self.sequence_id, self.project_id)
        return timeline_state
    end

    return layout
end

return M
