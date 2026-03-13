--- Test: reverse clip playback (source_in > source_out encodes direction)
--
-- WHITE-BOX: Tests private methods (_compute_video_speed_ratio, _build_tmb_clip,
-- _provide_clips) directly because speed ratio computation is internal to
-- the playback engine. Expected values derived from NLE domain knowledge:
--   speed = (source_out - source_in) / duration
-- No schema change — direction encoded in source coordinate ordering.

require("test_env")

--------------------------------------------------------------------------------
-- Mock Infrastructure
--------------------------------------------------------------------------------

local timer_callbacks = {}
_G.qt_create_single_shot_timer = function(interval, callback)
    timer_callbacks[#timer_callbacks + 1] = callback
end

-- TMB clip tracking: captures what gets sent to C++
local tmb_clips = {}

-- PLAYBACK mock
local playback_calls = {}

local function reset_playback()
    playback_calls = {}
end

local function track_pb(name, ...)
    playback_calls[#playback_calls + 1] = { name = name, args = {...} }
end

package.loaded["core.qt_constants"] = {
    EMP = {
        SET_DECODE_MODE = function() end,
        MEDIA_FILE_OPEN = function() return nil end,
        MEDIA_FILE_INFO = function() return nil end,
        MEDIA_FILE_CLOSE = function() end,
        READER_CREATE = function() return nil end,
        READER_CLOSE = function() end,
        READER_DECODE_FRAME = function() return nil end,
        FRAME_RELEASE = function() end,
        PCM_RELEASE = function() end,
        TMB_CREATE = function() return "mock_tmb" end,
        TMB_CLOSE = function() end,
        TMB_PARK_READERS = function() end,
        TMB_SET_SEQUENCE_RATE = function() end,
        TMB_SET_AUDIO_FORMAT = function() end,
        TMB_SET_TRACK_CLIPS = function() end,
        TMB_ADD_CLIPS = function(tmb, track_type, track_idx, clips)
            for _, c in ipairs(clips) do
                tmb_clips[#tmb_clips + 1] = {
                    track_type = track_type,
                    track_idx = track_idx,
                    clip = c,
                }
            end
        end,
        TMB_SET_PLAYHEAD = function() end,
        TMB_GET_VIDEO_FRAME = function() return nil, { offline = false } end,
    },
    PLAYBACK = {
        CREATE = function() return "mock_controller" end,
        PLAY = function(pc, dir, speed) track_pb("PLAY", dir, speed) end,
        STOP = function() track_pb("STOP") end,
        PARK = function(pc, frame) track_pb("PARK", frame) end,
        SEEK = function(pc, frame) track_pb("SEEK", frame) end,
        SET_TMB = function() end,
        SET_BOUNDS = function() end,
        SET_SURFACE = function() end,
        SET_CLIP_PROVIDER = function() end,
        RELOAD_ALL_CLIPS = function() end,
        SET_SHUTTLE_MODE = function() end,
        SET_POSITION_CALLBACK = function() end,
        SET_CLIP_TRANSITION_CALLBACK = function() end,
        CLOSE = function() end,
        HAS_AUDIO = function() return false end,
        ACTIVATE_AUDIO = function() end,
        DEACTIVATE_AUDIO = function() end,
        PLAY_BURST = function() end,
    },
}

package.loaded["core.media.media_cache"] = {
    ensure_audio_pooled = function()
        return { has_audio = true, audio_sample_rate = 48000 }
    end,
    get_audio_pcm_for_path = function() return nil, 0, 0 end,
    pre_buffer = function() end,
}

package.loaded["core.logger"] = {
    for_area = function()
        return {
            event = function() end,
            detail = function() end,
            warn = function() end,
            error = function() end,
        }
    end,
}

package.loaded["core.renderer"] = {
    get_sequence_info = function()
        return {
            fps_num = 25, fps_den = 1,
            kind = "timeline", name = "Test Seq",
            audio_sample_rate = 48000,
        }
    end,
    get_video_frame = function(tmb, track_indices, frame)
        if frame >= 0 and frame < 100 then
            return "frame_handle_" .. frame, {
                clip_id = "clip1",
                media_path = "/test.mov",
                source_frame = frame,
                rotation = 0,
                par_num = 1, par_den = 1,
                offline = false,
            }
        end
        return nil, nil
    end,
}

package.loaded["core.signals"] = {
    connect = function() return "conn_id" end,
    disconnect = function() end,
    emit = function() end,
}

package.loaded["models.track"] = {
    find_by_sequence = function() return {} end,
}

--------------------------------------------------------------------------------
-- Mock Sequence: supports reverse clips (source_in > source_out)
--------------------------------------------------------------------------------

local mock_clips = {}

local mock_sequence = {
    id = "seq1",
    compute_content_end = function() return 100 end,
    get_video_at = function() return {} end,
    get_next_video = function() return {} end,
    get_prev_video = function() return {} end,
    get_audio_at = function() return {} end,
    get_next_audio = function() return {} end,
    get_prev_audio = function() return {} end,
    get_video_in_range = function()
        return mock_clips
    end,
    get_audio_in_range = function() return {} end,
    get_track_indices = function() return { 0 } end,
}

package.loaded["models.sequence"] = {
    load = function() return mock_sequence end,
}

--------------------------------------------------------------------------------
-- Load PlaybackEngine
--------------------------------------------------------------------------------

local PlaybackEngine = require("core.playback.playback_engine")

local function make_engine()
    reset_playback()
    tmb_clips = {}

    local engine = PlaybackEngine.new({
        on_show_frame = function() end,
        on_show_gap = function() end,
        on_set_rotation = function() end,
        on_set_par = function() end,
        on_position_changed = function() end,
    })

    return engine
end

--------------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------------

print("=== test_reverse_clip_playback.lua ===")

-- ─── Test 1: _compute_video_speed_ratio returns negative for reverse ───
print("\n--- _compute_video_speed_ratio: reverse clip →  negative ratio ---")
do
    local engine = make_engine()
    engine:load_sequence("seq1", 100)

    -- Domain: 50 source frames forward over 50 timeline frames = real-time (1.0x)
    local entry_fwd = {
        clip = {
            id = "fwd1",
            source_in = 0,
            source_out = 50,
            duration = 50,
            rate = { fps_numerator = 25, fps_denominator = 1 },
        },
        media_path = "/test.mov",
        track = { track_index = 0 },
    }
    local ratio_fwd = engine:_compute_video_speed_ratio(entry_fwd)
    assert(ratio_fwd == 1.0, string.format("forward clip: expected 1.0, got %.4f", ratio_fwd))
    print("  forward clip: ratio = " .. ratio_fwd .. " ok")

    -- Domain: playing source backwards (50→0) over 50 timeline frames = -1.0x
    local entry_rev = {
        clip = {
            id = "rev1",
            source_in = 50,
            source_out = 0,
            duration = 50,
            rate = { fps_numerator = 25, fps_denominator = 1 },
        },
        media_path = "/test.mov",
        track = { track_index = 0 },
    }
    local ratio_rev = engine:_compute_video_speed_ratio(entry_rev)
    assert(ratio_rev == -1.0, string.format("reverse clip: expected -1.0, got %.4f", ratio_rev))
    print("  reverse clip: ratio = " .. ratio_rev .. " ok")

    -- Domain: 50 source frames backwards over 100 timeline frames = -0.5x (half-speed reverse)
    local entry_rev_slow = {
        clip = {
            id = "rev_slow1",
            source_in = 50,
            source_out = 0,
            duration = 100,
            rate = { fps_numerator = 25, fps_denominator = 1 },
        },
        media_path = "/test.mov",
        track = { track_index = 0 },
    }
    local ratio_rev_slow = engine:_compute_video_speed_ratio(entry_rev_slow)
    assert(ratio_rev_slow == -0.5, string.format("reverse slow-mo: expected -0.5, got %.4f", ratio_rev_slow))
    print("  reverse slow-mo: ratio = " .. ratio_rev_slow .. " ok")
end

-- ─── Test 2: _build_tmb_clip accepts negative speed_ratio ───
print("\n--- _build_tmb_clip: accepts negative speed_ratio ---")
do
    local engine = make_engine()
    engine:load_sequence("seq1", 100)

    local entry = {
        clip = {
            id = "rev1",
            timeline_start = 0,
            duration = 50,
            source_in = 50,
            source_out = 0,
            rate = { fps_numerator = 25, fps_denominator = 1 },
        },
        media_path = "/test.mov",
        track = { track_index = 0 },
    }
    local ok, err = pcall(engine._build_tmb_clip, engine, entry, -1.0)
    assert(ok, "negative speed_ratio should be accepted: " .. tostring(err))
    print("  negative speed_ratio accepted ok")

    -- Zero must still be rejected
    ok = pcall(engine._build_tmb_clip, engine, entry, 0)
    assert(not ok, "zero speed_ratio should be rejected")
    print("  zero speed_ratio rejected ok")
end

-- ─── Test 3: _provide_clips sends negative speed for reverse clip ───
print("\n--- _provide_clips: reverse clip gets negative speed ---")
do
    local engine = make_engine()
    tmb_clips = {}

    -- Set up mock clips: one reverse video clip
    mock_clips = {
        {
            clip = {
                id = "rev1",
                timeline_start = 0,
                duration = 50,
                source_in = 50,
                source_out = 0,
                rate = { fps_numerator = 25, fps_denominator = 1 },
            },
            media_path = "/test.mov",
            track = { track_index = 0 },
            media_fps_num = 25,
            media_fps_den = 1,
        },
    }

    engine:load_sequence("seq1", 100)
    engine:_provide_clips(0, 100, "video")

    assert(#tmb_clips == 1, "expected 1 TMB clip, got " .. #tmb_clips)
    assert(tmb_clips[1].clip.speed_ratio == -1.0,
        string.format("expected speed_ratio=-1.0, got %.4f", tmb_clips[1].clip.speed_ratio))
    print("  reverse clip sent to TMB with speed_ratio=-1.0 ok")

    mock_clips = {}
end

-- ─── Test 4: audio speed incorporates retime direction ───
print("\n--- audio speed: retime sign applied ---")
do
    local engine = make_engine()
    tmb_clips = {}

    -- Reverse audio clip: source_in > source_out
    -- 25fps media in 25fps sequence → conform ratio = 1.0
    -- But clip is reversed → final speed should be -1.0
    mock_clips = {
        {
            clip = {
                id = "rev_audio1",
                timeline_start = 0,
                duration = 50,
                source_in = 2400000,   -- 50s * 48000
                source_out = 0,
                rate = { fps_numerator = 48000, fps_denominator = 1 },
            },
            media_path = "/test.wav",
            track = { track_index = 0 },
            media_fps_num = 25,
            media_fps_den = 1,
        },
    }

    mock_sequence.get_audio_in_range = function() return mock_clips end

    engine:load_sequence("seq1", 100)
    engine:_provide_clips(0, 100, "audio")

    assert(#tmb_clips == 1, "expected 1 TMB clip, got " .. #tmb_clips)
    local sr = tmb_clips[1].clip.speed_ratio
    assert(sr < 0, string.format("expected negative speed_ratio for reverse audio, got %.4f", sr))
    print("  reverse audio clip: speed_ratio=" .. sr .. " ok")

    mock_sequence.get_audio_in_range = function() return {} end
    mock_clips = {}
end

print("\n✅ test_reverse_clip_playback.lua passed")
