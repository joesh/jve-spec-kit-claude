// EMP (Editor Media Platform) Lua bindings
// Provides frame-first video decoding for Source Viewer

#include <editor_media_platform/emp_media_file.h>
#include <editor_media_platform/emp_reader.h>
#include <editor_media_platform/emp_frame.h>
#include <editor_media_platform/emp_audio.h>
#include <editor_media_platform/emp_errors.h>
#include <editor_media_platform/emp_time.h>
#include <editor_media_platform/emp_timeline_media_buffer.h>

#include "gpu_video_surface.h"
#include "cpu_video_surface.h"
#include <QDebug>
#include <QImage>
#include <QPainter>
#include <QFont>
#include <QFontMetrics>
#include <QColor>
#include <QLinearGradient>
#include "binding_macros.h"

#include <lua.hpp>
#include <memory>
#include <unordered_map>
#include <cstdint>
#include <cstring>
#include <stdexcept>

// Forward declaration from binding_macros.h
extern const char* WIDGET_METATABLE;

namespace {

// Metatable names for EMP types
const char* EMP_MEDIA_FILE_METATABLE = "JVE.EMP.MediaFile";
const char* EMP_READER_METATABLE = "JVE.EMP.Reader";
const char* EMP_FRAME_METATABLE = "JVE.EMP.Frame";
const char* EMP_PCM_METATABLE = "JVE.EMP.PcmChunk";
const char* EMP_TMB_METATABLE = "JVE.EMP.TMB";

// Global registry for shared_ptr instances (prevent premature destruction)
// Key: Lua userdata address (unique per allocation), Value: shared_ptr
// IMPORTANT: Keys must be userdata addresses, NOT raw C++ pointers. The C++
// decoder cache can return the same shared_ptr<Frame> for repeated decodes of
// the same timestamp. If raw ptrs were used as keys, two Lua userdata objects
// would share one map entry, and GC of the first would invalidate the second.
static std::unordered_map<void*, std::shared_ptr<emp::MediaFile>> g_media_files;
static std::unordered_map<void*, std::shared_ptr<emp::Reader>> g_readers;
static std::unordered_map<void*, std::shared_ptr<emp::Frame>> g_frames;
static std::unordered_map<void*, std::shared_ptr<emp::PcmChunk>> g_pcm_chunks;
static std::unordered_map<void*, std::shared_ptr<emp::TimelineMediaBuffer>> g_tmb_instances;

// Helper: Push EMP error to Lua (nil, { code=string, msg=string })
void push_emp_error(lua_State* L, const emp::Error& err) {
    lua_pushnil(L);
    lua_newtable(L);
    lua_pushstring(L, emp::error_code_to_string(err.code));
    lua_setfield(L, -2, "code");
    lua_pushstring(L, err.message.c_str());
    lua_setfield(L, -2, "msg");
}

// Helper: Create userdata with metatable, return userdata address (map key)
template<typename T>
void* push_userdata(lua_State* L, std::shared_ptr<T> ptr, const char* metatable) {
    void** ud = static_cast<void**>(lua_newuserdata(L, sizeof(void*)));
    *ud = ptr.get();
    luaL_getmetatable(L, metatable);
    lua_setmetatable(L, -2);
    return static_cast<void*>(ud);
}

// Helper: Get Lua userdata address for map key lookup
// Returns the userdata allocation address (unique per Lua object), NOT the
// contained C++ pointer. This ensures each Lua handle has its own map entry.
void* get_map_key(lua_State* L, int idx, const char* metatable) {
    return static_cast<void*>(luaL_checkudata(L, idx, metatable));
}

// ============================================================================
// MediaFile bindings
// ============================================================================

// EMP.MEDIA_FILE_OPEN(path) -> media_file | nil, err
static int lua_emp_media_file_open(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);

    auto result = emp::MediaFile::Open(path);
    if (result.is_error()) {
        push_emp_error(L, result.error());
        return 2;
    }

    auto asset = result.value();
    void* key = push_userdata(L, asset, EMP_MEDIA_FILE_METATABLE);
    g_media_files[key] = asset;
    return 1;
}

// EMP.MEDIA_FILE_CLOSE(media_file)
static int lua_emp_media_file_close(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_MEDIA_FILE_METATABLE);
    g_media_files.erase(key);
    return 0;
}

// EMP.MEDIA_FILE_INFO(media_file) -> { path, has_video, width, height, fps_num, fps_den, duration_us, is_vfr, has_audio, audio_sample_rate, audio_channels }
static int lua_emp_media_file_info(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_MEDIA_FILE_METATABLE);
    auto it = g_media_files.find(key);
    if (it == g_media_files.end()) {
        return luaL_error(L, "EMP.MEDIA_FILE_INFO: invalid media file handle");
    }

    const auto& info = it->second->info();

    lua_newtable(L);
    lua_pushstring(L, info.path.c_str());
    lua_setfield(L, -2, "path");
    lua_pushboolean(L, info.has_video);
    lua_setfield(L, -2, "has_video");
    lua_pushinteger(L, info.video_width);
    lua_setfield(L, -2, "width");
    lua_pushinteger(L, info.video_height);
    lua_setfield(L, -2, "height");
    lua_pushinteger(L, info.video_fps_num);
    lua_setfield(L, -2, "fps_num");
    lua_pushinteger(L, info.video_fps_den);
    lua_setfield(L, -2, "fps_den");
    lua_pushinteger(L, static_cast<lua_Integer>(info.duration_us));
    lua_setfield(L, -2, "duration_us");
    lua_pushboolean(L, info.is_vfr);
    lua_setfield(L, -2, "is_vfr");

    // Start timecode in frames at media's native rate
    lua_pushinteger(L, static_cast<lua_Integer>(info.start_tc));
    lua_setfield(L, -2, "start_tc");

    // Rotation in degrees (0, 90, 180, 270) from display matrix
    lua_pushinteger(L, info.rotation);
    lua_setfield(L, -2, "rotation");

    // Audio fields
    lua_pushboolean(L, info.has_audio);
    lua_setfield(L, -2, "has_audio");
    lua_pushinteger(L, info.audio_sample_rate);
    lua_setfield(L, -2, "audio_sample_rate");
    lua_pushinteger(L, info.audio_channels);
    lua_setfield(L, -2, "audio_channels");

    return 1;
}

// MediaFile __gc metamethod
static int lua_emp_media_file_gc(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_MEDIA_FILE_METATABLE);
    g_media_files.erase(key);
    return 0;
}

// ============================================================================
// Reader bindings
// ============================================================================

// EMP.READER_CREATE(media_file) -> reader | nil, err
static int lua_emp_reader_create(lua_State* L) {
    void* mf_key = get_map_key(L, 1, EMP_MEDIA_FILE_METATABLE);
    auto mf_it = g_media_files.find(mf_key);
    if (mf_it == g_media_files.end()) {
        push_emp_error(L, emp::Error::invalid_arg("Invalid media file handle"));
        return 2;
    }

    auto result = emp::Reader::Create(mf_it->second);
    if (result.is_error()) {
        push_emp_error(L, result.error());
        return 2;
    }

    auto reader = result.value();
    void* key = push_userdata(L, reader, EMP_READER_METATABLE);
    g_readers[key] = reader;
    return 1;
}

// EMP.READER_CLOSE(reader)
static int lua_emp_reader_close(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_READER_METATABLE);
    g_readers.erase(key);
    return 0;
}

// EMP.READER_SEEK_FRAME(reader, frame_idx, rate_num, rate_den) -> true | nil, err
static int lua_emp_reader_seek_frame(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_READER_METATABLE);
    auto it = g_readers.find(key);
    if (it == g_readers.end()) {
        push_emp_error(L, emp::Error::invalid_arg("Invalid reader handle"));
        return 2;
    }

    int64_t frame_idx = static_cast<int64_t>(luaL_checkinteger(L, 2));
    int32_t rate_num = static_cast<int32_t>(luaL_checkinteger(L, 3));
    int32_t rate_den = static_cast<int32_t>(luaL_checkinteger(L, 4));

    emp::FrameTime ft = emp::FrameTime::from_frame(frame_idx, {rate_num, rate_den});
    auto result = it->second->Seek(ft);

    if (result.is_error()) {
        push_emp_error(L, result.error());
        return 2;
    }

    lua_pushboolean(L, 1);
    return 1;
}

// EMP.READER_DECODE_FRAME(reader, frame_idx, rate_num, rate_den) -> frame | nil, err
static int lua_emp_reader_decode_frame(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_READER_METATABLE);
    auto it = g_readers.find(key);
    if (it == g_readers.end()) {
        push_emp_error(L, emp::Error::invalid_arg("Invalid reader handle"));
        return 2;
    }

    int64_t frame_idx = static_cast<int64_t>(luaL_checkinteger(L, 2));
    int32_t rate_num = static_cast<int32_t>(luaL_checkinteger(L, 3));
    int32_t rate_den = static_cast<int32_t>(luaL_checkinteger(L, 4));

    emp::FrameTime ft = emp::FrameTime::from_frame(frame_idx, {rate_num, rate_den});
    auto result = it->second->DecodeAt(ft);

    if (result.is_error()) {
        push_emp_error(L, result.error());
        return 2;
    }

    auto frame = result.value();
    void* frame_key = push_userdata(L, frame, EMP_FRAME_METATABLE);
    g_frames[frame_key] = frame;
    return 1;
}

// EMP.READER_START_PREFETCH(reader, direction)
// direction: 1=forward, -1=reverse, 0=stop
static int lua_emp_reader_start_prefetch(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_READER_METATABLE);
    auto it = g_readers.find(key);
    if (it == g_readers.end()) {
        return luaL_error(L, "READER_START_PREFETCH: invalid reader handle");
    }

    int direction = static_cast<int>(luaL_checkinteger(L, 2));
    if (direction < -1 || direction > 1) {
        return luaL_error(L, "READER_START_PREFETCH: direction must be -1, 0, or 1");
    }

    it->second->StartPrefetch(direction);
    return 0;
}

// EMP.READER_STOP_PREFETCH(reader)
static int lua_emp_reader_stop_prefetch(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_READER_METATABLE);
    auto it = g_readers.find(key);
    if (it == g_readers.end()) {
        return luaL_error(L, "READER_STOP_PREFETCH: invalid reader handle");
    }

    it->second->StopPrefetch();
    return 0;
}

// EMP.READER_UPDATE_PREFETCH_TARGET(reader, frame_idx, rate_num, rate_den)
static int lua_emp_reader_update_prefetch_target(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_READER_METATABLE);
    auto it = g_readers.find(key);
    if (it == g_readers.end()) {
        return luaL_error(L, "READER_UPDATE_PREFETCH_TARGET: invalid reader handle");
    }

    int64_t frame_idx = static_cast<int64_t>(luaL_checkinteger(L, 2));
    int32_t rate_num = static_cast<int32_t>(luaL_checkinteger(L, 3));
    int32_t rate_den = static_cast<int32_t>(luaL_checkinteger(L, 4));

    emp::FrameTime ft = emp::FrameTime::from_frame(frame_idx, {rate_num, rate_den});
    it->second->UpdatePrefetchTarget(ft.to_us());
    return 0;
}

// EMP.READER_GET_CACHED_FRAME(reader, frame_idx, rate_num, rate_den) -> frame | nil
static int lua_emp_reader_get_cached_frame(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_READER_METATABLE);
    auto it = g_readers.find(key);
    if (it == g_readers.end()) {
        return luaL_error(L, "READER_GET_CACHED_FRAME: invalid reader handle");
    }

    int64_t frame_idx = static_cast<int64_t>(luaL_checkinteger(L, 2));
    int32_t rate_num = static_cast<int32_t>(luaL_checkinteger(L, 3));
    int32_t rate_den = static_cast<int32_t>(luaL_checkinteger(L, 4));

    emp::FrameTime ft = emp::FrameTime::from_frame(frame_idx, {rate_num, rate_den});
    auto frame = it->second->GetCachedFrame(ft.to_us());

    if (!frame) {
        lua_pushnil(L);
        return 1;
    }

    void* frame_key = push_userdata(L, frame, EMP_FRAME_METATABLE);
    g_frames[frame_key] = frame;
    return 1;
}

// Reader __gc metamethod
static int lua_emp_reader_gc(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_READER_METATABLE);
    g_readers.erase(key);
    return 0;
}

// ============================================================================
// Frame bindings
// ============================================================================

// EMP.FRAME_INFO(frame) -> { width, height, stride, source_pts_us }
static int lua_emp_frame_info(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_FRAME_METATABLE);
    auto it = g_frames.find(key);
    if (it == g_frames.end()) {
        return luaL_error(L, "EMP.FRAME_INFO: invalid frame handle");
    }

    auto frame = it->second;

    lua_newtable(L);
    lua_pushinteger(L, frame->width());
    lua_setfield(L, -2, "width");
    lua_pushinteger(L, frame->height());
    lua_setfield(L, -2, "height");
    lua_pushinteger(L, frame->stride_bytes());
    lua_setfield(L, -2, "stride");
    lua_pushinteger(L, static_cast<lua_Integer>(frame->source_pts_us()));
    lua_setfield(L, -2, "source_pts_us");

    return 1;
}

// EMP.FRAME_RELEASE(frame)
static int lua_emp_frame_release(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_FRAME_METATABLE);
    g_frames.erase(key);
    return 0;
}

// EMP.FRAME_DATA_PTR(frame) -> lightuserdata (for FFI or surface widget)
static int lua_emp_frame_data_ptr(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_FRAME_METATABLE);
    auto it = g_frames.find(key);
    if (it == g_frames.end()) {
        return luaL_error(L, "EMP.FRAME_DATA_PTR: invalid frame handle");
    }

    lua_pushlightuserdata(L, const_cast<uint8_t*>(it->second->data()));
    return 1;
}

// Frame __gc metamethod
static int lua_emp_frame_gc(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_FRAME_METATABLE);
    g_frames.erase(key);
    return 0;
}

// ============================================================================
// Audio/PCM bindings
// ============================================================================

// EMP.READER_DECODE_AUDIO_RANGE(reader, frame0, frame1, rate_num, rate_den, out_sample_rate, out_channels) -> pcm | nil, err
static int lua_emp_reader_decode_audio_range(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_READER_METATABLE);
    auto it = g_readers.find(key);
    if (it == g_readers.end()) {
        push_emp_error(L, emp::Error::invalid_arg("Invalid reader handle"));
        return 2;
    }

    int64_t frame0 = static_cast<int64_t>(luaL_checkinteger(L, 2));
    int64_t frame1 = static_cast<int64_t>(luaL_checkinteger(L, 3));
    int32_t rate_num = static_cast<int32_t>(luaL_checkinteger(L, 4));
    int32_t rate_den = static_cast<int32_t>(luaL_checkinteger(L, 5));
    int32_t out_sample_rate = static_cast<int32_t>(luaL_checkinteger(L, 6));
    int32_t out_channels = static_cast<int32_t>(luaL_checkinteger(L, 7));

    emp::FrameTime t0 = emp::FrameTime::from_frame(frame0, {rate_num, rate_den});
    emp::FrameTime t1 = emp::FrameTime::from_frame(frame1, {rate_num, rate_den});

    emp::AudioFormat out_fmt;
    out_fmt.fmt = emp::SampleFormat::F32;
    out_fmt.sample_rate = out_sample_rate;
    out_fmt.channels = out_channels;

    auto result = it->second->DecodeAudioRange(t0, t1, out_fmt);
    if (result.is_error()) {
        push_emp_error(L, result.error());
        return 2;
    }

    auto pcm = result.value();
    void* pcm_key = push_userdata(L, pcm, EMP_PCM_METATABLE);
    g_pcm_chunks[pcm_key] = pcm;
    return 1;
}

// EMP.PCM_INFO(pcm) -> { sample_rate, channels, frames, start_time_us }
static int lua_emp_pcm_info(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_PCM_METATABLE);
    auto it = g_pcm_chunks.find(key);
    if (it == g_pcm_chunks.end()) {
        return luaL_error(L, "EMP.PCM_INFO: invalid pcm handle");
    }

    auto pcm = it->second;

    lua_newtable(L);
    lua_pushinteger(L, pcm->sample_rate());
    lua_setfield(L, -2, "sample_rate");
    lua_pushinteger(L, pcm->channels());
    lua_setfield(L, -2, "channels");
    lua_pushinteger(L, static_cast<lua_Integer>(pcm->frames()));
    lua_setfield(L, -2, "frames");
    lua_pushinteger(L, static_cast<lua_Integer>(pcm->start_time_us()));
    lua_setfield(L, -2, "start_time_us");

    return 1;
}

// EMP.PCM_DATA_PTR(pcm) -> lightuserdata (for direct buffer access)
static int lua_emp_pcm_data_ptr(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_PCM_METATABLE);
    auto it = g_pcm_chunks.find(key);
    if (it == g_pcm_chunks.end()) {
        return luaL_error(L, "EMP.PCM_DATA_PTR: invalid pcm handle");
    }

    lua_pushlightuserdata(L, const_cast<float*>(it->second->data_f32()));
    return 1;
}

// EMP.PCM_RELEASE(pcm)
static int lua_emp_pcm_release(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_PCM_METATABLE);
    g_pcm_chunks.erase(key);
    return 0;
}

// PCM __gc metamethod
static int lua_emp_pcm_gc(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_PCM_METATABLE);
    g_pcm_chunks.erase(key);
    return 0;
}

// ============================================================================
// TimelineMediaBuffer (TMB) bindings
// ============================================================================

// EMP.TMB_CREATE(pool_threads) -> tmb | nil, err
static int lua_emp_tmb_create(lua_State* L) {
    int pool_threads = static_cast<int>(luaL_optinteger(L, 1, 2));
    if (pool_threads < 0) {
        return luaL_error(L, "TMB_CREATE: pool_threads must be >= 0, got %d", pool_threads);
    }

    auto tmb = emp::TimelineMediaBuffer::Create(pool_threads);
    // Convert unique_ptr to shared_ptr for the global registry
    std::shared_ptr<emp::TimelineMediaBuffer> shared_tmb(std::move(tmb));

    void* key = push_userdata(L, shared_tmb, EMP_TMB_METATABLE);
    g_tmb_instances[key] = shared_tmb;
    return 1;
}

// EMP.TMB_CLOSE(tmb)
static int lua_emp_tmb_close(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_TMB_METATABLE);
    g_tmb_instances.erase(key);
    return 0;
}

// TMB __gc metamethod
static int lua_emp_tmb_gc(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_TMB_METATABLE);
    g_tmb_instances.erase(key);
    return 0;
}

// Helper: get TMB from Lua arg or error
static std::shared_ptr<emp::TimelineMediaBuffer> get_tmb(lua_State* L, int idx) {
    void* key = get_map_key(L, idx, EMP_TMB_METATABLE);
    auto it = g_tmb_instances.find(key);
    if (it == g_tmb_instances.end()) {
        luaL_error(L, "TMB: invalid handle");
        return nullptr;
    }
    return it->second;
}

// EMP.TMB_SET_MAX_READERS(tmb, max)
static int lua_emp_tmb_set_max_readers(lua_State* L) {
    auto tmb = get_tmb(L, 1);
    int max = static_cast<int>(luaL_checkinteger(L, 2));
    if (max < 1) {
        return luaL_error(L, "TMB_SET_MAX_READERS: max must be >= 1, got %d", max);
    }
    tmb->SetMaxReaders(max);
    return 0;
}

// EMP.TMB_SET_SEQUENCE_RATE(tmb, num, den)
static int lua_emp_tmb_set_sequence_rate(lua_State* L) {
    auto tmb = get_tmb(L, 1);
    int32_t num = static_cast<int32_t>(luaL_checkinteger(L, 2));
    int32_t den = static_cast<int32_t>(luaL_checkinteger(L, 3));
    if (num <= 0) return luaL_error(L, "TMB_SET_SEQUENCE_RATE: num must be > 0, got %d", num);
    if (den <= 0) return luaL_error(L, "TMB_SET_SEQUENCE_RATE: den must be > 0, got %d", den);
    tmb->SetSequenceRate(num, den);
    return 0;
}

// EMP.TMB_SET_AUDIO_FORMAT(tmb, sample_rate, channels)
static int lua_emp_tmb_set_audio_format(lua_State* L) {
    auto tmb = get_tmb(L, 1);
    int32_t sample_rate = static_cast<int32_t>(luaL_checkinteger(L, 2));
    int32_t channels = static_cast<int32_t>(luaL_checkinteger(L, 3));
    if (sample_rate <= 0) return luaL_error(L, "TMB_SET_AUDIO_FORMAT: sample_rate must be > 0, got %d", sample_rate);
    if (channels <= 0) return luaL_error(L, "TMB_SET_AUDIO_FORMAT: channels must be > 0, got %d", channels);
    emp::AudioFormat fmt{emp::SampleFormat::F32, sample_rate, channels};
    tmb->SetAudioFormat(fmt);
    return 0;
}

// EMP.TMB_SET_TRACK_CLIPS(tmb, track_id, clips_table)
// clips_table = array of { clip_id, media_path, timeline_start, duration, source_in, rate_num, rate_den, speed_ratio }
static int lua_emp_tmb_set_track_clips(lua_State* L) {
    auto tmb = get_tmb(L, 1);
    int track_id = static_cast<int>(luaL_checkinteger(L, 2));
    luaL_checktype(L, 3, LUA_TTABLE);

    int n = static_cast<int>(lua_objlen(L, 3));
    std::vector<emp::ClipInfo> clips;
    clips.reserve(static_cast<size_t>(n));

    for (int i = 1; i <= n; ++i) {
        lua_rawgeti(L, 3, i);
        if (!lua_istable(L, -1)) {
            return luaL_error(L, "TMB_SET_TRACK_CLIPS: element %d is not a table", i);
        }

        emp::ClipInfo ci{};

        lua_getfield(L, -1, "clip_id");
        if (!lua_isstring(L, -1)) {
            return luaL_error(L, "TMB_SET_TRACK_CLIPS: element %d missing clip_id", i);
        }
        ci.clip_id = lua_tostring(L, -1);
        lua_pop(L, 1);

        lua_getfield(L, -1, "media_path");
        if (!lua_isstring(L, -1)) {
            return luaL_error(L, "TMB_SET_TRACK_CLIPS: element %d missing media_path", i);
        }
        ci.media_path = lua_tostring(L, -1);
        lua_pop(L, 1);

        lua_getfield(L, -1, "timeline_start");
        if (!lua_isnumber(L, -1)) {
            return luaL_error(L, "TMB_SET_TRACK_CLIPS: element %d missing timeline_start", i);
        }
        ci.timeline_start = static_cast<int64_t>(lua_tointeger(L, -1));
        lua_pop(L, 1);

        lua_getfield(L, -1, "duration");
        if (!lua_isnumber(L, -1)) {
            return luaL_error(L, "TMB_SET_TRACK_CLIPS: element %d missing duration", i);
        }
        ci.duration = static_cast<int64_t>(lua_tointeger(L, -1));
        lua_pop(L, 1);

        lua_getfield(L, -1, "source_in");
        if (!lua_isnumber(L, -1)) {
            return luaL_error(L, "TMB_SET_TRACK_CLIPS: element %d missing source_in", i);
        }
        ci.source_in = static_cast<int64_t>(lua_tointeger(L, -1));
        lua_pop(L, 1);

        lua_getfield(L, -1, "rate_num");
        if (!lua_isnumber(L, -1)) {
            return luaL_error(L, "TMB_SET_TRACK_CLIPS: element %d missing rate_num", i);
        }
        ci.rate_num = static_cast<int32_t>(lua_tointeger(L, -1));
        lua_pop(L, 1);

        lua_getfield(L, -1, "rate_den");
        if (!lua_isnumber(L, -1)) {
            return luaL_error(L, "TMB_SET_TRACK_CLIPS: element %d missing rate_den", i);
        }
        ci.rate_den = static_cast<int32_t>(lua_tointeger(L, -1));
        lua_pop(L, 1);

        lua_getfield(L, -1, "speed_ratio");
        if (!lua_isnumber(L, -1)) {
            return luaL_error(L, "TMB_SET_TRACK_CLIPS: element %d missing speed_ratio", i);
        }
        ci.speed_ratio = static_cast<float>(lua_tonumber(L, -1));
        lua_pop(L, 1);

        lua_pop(L, 1); // pop clip table

        if (ci.rate_den <= 0) {
            return luaL_error(L, "TMB_SET_TRACK_CLIPS: element %d rate_den must be > 0, got %d", i, ci.rate_den);
        }
        if (ci.speed_ratio <= 0.0f) {
            return luaL_error(L, "TMB_SET_TRACK_CLIPS: element %d speed_ratio must be > 0", i);
        }

        clips.push_back(std::move(ci));
    }

    tmb->SetTrackClips(track_id, clips);
    return 0;
}

// EMP.TMB_SET_PLAYHEAD(tmb, frame, direction, speed)
static int lua_emp_tmb_set_playhead(lua_State* L) {
    auto tmb = get_tmb(L, 1);
    int64_t frame = static_cast<int64_t>(luaL_checkinteger(L, 2));
    int direction = static_cast<int>(luaL_checkinteger(L, 3));
    float speed = static_cast<float>(luaL_checknumber(L, 4));
    tmb->SetPlayhead(frame, direction, speed);
    return 0;
}

// EMP.TMB_GET_VIDEO_FRAME(tmb, track_id, timeline_frame) -> frame|nil, info_table
static int lua_emp_tmb_get_video_frame(lua_State* L) {
    auto tmb = get_tmb(L, 1);
    int track_id = static_cast<int>(luaL_checkinteger(L, 2));
    int64_t timeline_frame = static_cast<int64_t>(luaL_checkinteger(L, 3));

    auto result = tmb->GetVideoFrame(track_id, timeline_frame);

    // Push frame handle (or nil for gap/offline)
    if (result.frame) {
        void* frame_key = push_userdata(L, result.frame, EMP_FRAME_METATABLE);
        g_frames[frame_key] = result.frame;
    } else {
        lua_pushnil(L);
    }

    // Push metadata table (always returned)
    lua_newtable(L);
    lua_pushstring(L, result.clip_id.c_str());
    lua_setfield(L, -2, "clip_id");
    lua_pushinteger(L, result.rotation);
    lua_setfield(L, -2, "rotation");
    lua_pushinteger(L, static_cast<lua_Integer>(result.source_frame));
    lua_setfield(L, -2, "source_frame");
    lua_pushinteger(L, result.clip_fps_num);
    lua_setfield(L, -2, "clip_fps_num");
    lua_pushinteger(L, result.clip_fps_den);
    lua_setfield(L, -2, "clip_fps_den");
    lua_pushinteger(L, static_cast<lua_Integer>(result.clip_start_frame));
    lua_setfield(L, -2, "clip_start_frame");
    lua_pushinteger(L, static_cast<lua_Integer>(result.clip_end_frame));
    lua_setfield(L, -2, "clip_end_frame");
    lua_pushboolean(L, result.offline);
    lua_setfield(L, -2, "offline");

    return 2;
}

// EMP.TMB_GET_TRACK_AUDIO(tmb, track_id, t0_us, t1_us, sample_rate, channels) -> pcm|nil
static int lua_emp_tmb_get_track_audio(lua_State* L) {
    auto tmb = get_tmb(L, 1);
    int track_id = static_cast<int>(luaL_checkinteger(L, 2));
    int64_t t0 = static_cast<int64_t>(luaL_checkinteger(L, 3));
    int64_t t1 = static_cast<int64_t>(luaL_checkinteger(L, 4));
    int32_t sample_rate = static_cast<int32_t>(luaL_checkinteger(L, 5));
    int32_t channels = static_cast<int32_t>(luaL_checkinteger(L, 6));
    if (t1 <= t0) return luaL_error(L, "TMB_GET_TRACK_AUDIO: t1 (%lld) must be > t0 (%lld)", (long long)t1, (long long)t0);
    if (sample_rate <= 0) return luaL_error(L, "TMB_GET_TRACK_AUDIO: sample_rate must be > 0, got %d", sample_rate);
    if (channels <= 0) return luaL_error(L, "TMB_GET_TRACK_AUDIO: channels must be > 0, got %d", channels);

    emp::AudioFormat fmt{emp::SampleFormat::F32, sample_rate, channels};
    auto pcm = tmb->GetTrackAudio(track_id, t0, t1, fmt);

    if (!pcm) {
        lua_pushnil(L);
        return 1;
    }

    void* pcm_key = push_userdata(L, pcm, EMP_PCM_METATABLE);
    g_pcm_chunks[pcm_key] = pcm;
    return 1;
}

// EMP.TMB_RELEASE_TRACK(tmb, track_id)
static int lua_emp_tmb_release_track(lua_State* L) {
    auto tmb = get_tmb(L, 1);
    int track_id = static_cast<int>(luaL_checkinteger(L, 2));
    tmb->ReleaseTrack(track_id);
    return 0;
}

// EMP.TMB_RELEASE_ALL(tmb)
static int lua_emp_tmb_release_all(lua_State* L) {
    auto tmb = get_tmb(L, 1);
    tmb->ReleaseAll();
    return 0;
}

// EMP.MEDIA_FILE_PROBE(path) -> info_table | nil, err
static int lua_emp_media_file_probe(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);

    auto result = emp::TimelineMediaBuffer::ProbeFile(path);
    if (result.is_error()) {
        push_emp_error(L, result.error());
        return 2;
    }

    const auto& info = result.value();
    lua_newtable(L);
    lua_pushstring(L, info.path.c_str());
    lua_setfield(L, -2, "path");
    lua_pushboolean(L, info.has_video);
    lua_setfield(L, -2, "has_video");
    lua_pushinteger(L, info.video_width);
    lua_setfield(L, -2, "width");
    lua_pushinteger(L, info.video_height);
    lua_setfield(L, -2, "height");
    lua_pushinteger(L, info.video_fps_num);
    lua_setfield(L, -2, "fps_num");
    lua_pushinteger(L, info.video_fps_den);
    lua_setfield(L, -2, "fps_den");
    lua_pushinteger(L, static_cast<lua_Integer>(info.duration_us));
    lua_setfield(L, -2, "duration_us");
    lua_pushboolean(L, info.is_vfr);
    lua_setfield(L, -2, "is_vfr");
    lua_pushinteger(L, static_cast<lua_Integer>(info.start_tc));
    lua_setfield(L, -2, "start_tc");
    lua_pushinteger(L, info.rotation);
    lua_setfield(L, -2, "rotation");
    lua_pushboolean(L, info.has_audio);
    lua_setfield(L, -2, "has_audio");
    lua_pushinteger(L, info.audio_sample_rate);
    lua_setfield(L, -2, "audio_sample_rate");
    lua_pushinteger(L, info.audio_channels);
    lua_setfield(L, -2, "audio_channels");

    return 1;
}

// ============================================================================
// Offline Frame Compositor
// ============================================================================

// EMP.COMPOSE_OFFLINE_FRAME(png_path, lines_table) -> frame_handle
// lines_table = array of { text=string, size=number, color=string, bold=bool }
// Loads PNG, composites text band in bottom third, returns frame handle.
static int lua_emp_compose_offline_frame(lua_State* L) {
    const char* png_path = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);

    // Load PNG for dimensions, then paint gradient background over it
    QImage img(png_path);
    if (img.isNull()) {
        return luaL_error(L, "COMPOSE_OFFLINE_FRAME: failed to load PNG: %s", png_path);
    }
    img = img.convertToFormat(QImage::Format_ARGB32);

    int w = img.width();
    int h = img.height();

    // Vertical gradient: bright red top → dark red bottom (Premiere-style)
    {
        QPainter bgPainter(&img);
        QLinearGradient grad(0, 0, 0, h);
        grad.setColorAt(0.0, QColor(0xc0, 0x28, 0x28));
        grad.setColorAt(1.0, QColor(0x30, 0x08, 0x08));
        bgPainter.fillRect(0, 0, w, h, grad);
        bgPainter.end();
    }

    // Line spacing as percentage of frame height
    int line_spacing = std::max(4, h / 80);

    // First pass: parse lines, create fonts, measure text heights
    struct LineInfo {
        QString text;
        QFont font;
        QColor color;
        int height;
        int gap_after;  // extra space after this line (pixels)
    };

    int line_count = static_cast<int>(lua_objlen(L, 2));
    std::vector<LineInfo> lines;
    int total_height = 0;

    for (int i = 1; i <= line_count; ++i) {
        lua_rawgeti(L, 2, i);
        if (!lua_istable(L, -1)) {
            lua_pop(L, 1);
            continue;
        }

        lua_getfield(L, -1, "text");
        const char* text = lua_isstring(L, -1) ? lua_tostring(L, -1) : "";
        lua_pop(L, 1);

        lua_getfield(L, -1, "height_pct");
        double height_pct = lua_isnumber(L, -1) ? lua_tonumber(L, -1) : 3.0;
        lua_pop(L, 1);

        lua_getfield(L, -1, "color");
        const char* color_str = lua_isstring(L, -1) ? lua_tostring(L, -1) : "#ffffff";
        lua_pop(L, 1);

        lua_getfield(L, -1, "bold");
        bool bold = lua_isboolean(L, -1) ? lua_toboolean(L, -1) : false;
        lua_pop(L, 1);

        lua_getfield(L, -1, "gap_after_pct");
        double gap_after_pct = lua_isnumber(L, -1) ? lua_tonumber(L, -1) : 0.0;
        lua_pop(L, 1);

        int pixel_size = std::max(10, static_cast<int>(height_pct / 100.0 * h));
        QFont font("Helvetica Neue");
        font.setPixelSize(pixel_size);
        font.setBold(bold);

        QFontMetrics fm(font);
        int line_h = fm.height();
        int gap = static_cast<int>(gap_after_pct / 100.0 * h);

        if (!lines.empty()) total_height += line_spacing;
        total_height += line_h + gap;

        lines.push_back({QString::fromUtf8(text), font, QColor(color_str), line_h, gap});
        lua_pop(L, 1); // pop line table
    }

    // Second pass: draw text block centered vertically in frame
    QPainter painter(&img);
    painter.setRenderHint(QPainter::TextAntialiasing, true);

    int y_cursor = (h - total_height) / 2;
    for (size_t i = 0; i < lines.size(); ++i) {
        const auto& line = lines[i];
        painter.setFont(line.font);
        painter.setPen(line.color);
        QRect text_rect(0, y_cursor, w, line.height);
        painter.drawText(text_rect, Qt::AlignHCenter | Qt::AlignVCenter, line.text);
        y_cursor += line.height + line.gap_after + line_spacing;
    }
    painter.end();

    // Copy QImage scanlines to vector<uint8_t>
    // QImage Format_ARGB32 on little-endian = BGRA in memory — matches EMP convention
    int stride = static_cast<int>(img.bytesPerLine());
    std::vector<uint8_t> pixels(static_cast<size_t>(stride) * h);
    for (int y = 0; y < h; ++y) {
        std::memcpy(pixels.data() + y * stride,
                    img.constScanLine(y),
                    static_cast<size_t>(stride));
    }

    // Create Frame via public factory
    auto frame = emp::Frame::CreateCPU(w, h, stride, 0, std::move(pixels));

    // Register in g_frames and return handle
    void* frame_key = push_userdata(L, frame, EMP_FRAME_METATABLE);
    g_frames[frame_key] = frame;
    return 1;
}

// ============================================================================
// Video Surface bindings
// ============================================================================

// qt_constants.WIDGET.CREATE_GPU_VIDEO_SURFACE() -> widget
// Creates GPUVideoSurface for hw-accelerated display (macOS Metal)
// Asserts if GPU not available
static int lua_create_gpu_video_surface(lua_State* L) {
    if (!GPUVideoSurface::isAvailable()) {
        return luaL_error(L, "CREATE_GPU_VIDEO_SURFACE: GPU video surface not available on this platform");
    }

    qWarning() << "Creating GPUVideoSurface (hw-accelerated)";
    GPUVideoSurface* widget = new GPUVideoSurface();

    void** widget_ptr = static_cast<void**>(lua_newuserdata(L, sizeof(void*)));
    *widget_ptr = widget;
    luaL_getmetatable(L, WIDGET_METATABLE);
    lua_setmetatable(L, -2);

    return 1;
}

// qt_constants.WIDGET.CREATE_CPU_VIDEO_SURFACE() -> widget
// Creates CPUVideoSurface for software rendering
static int lua_create_cpu_video_surface(lua_State* L) {
    CPUVideoSurface* widget = new CPUVideoSurface();

    void** widget_ptr = static_cast<void**>(lua_newuserdata(L, sizeof(void*)));
    *widget_ptr = widget;
    luaL_getmetatable(L, WIDGET_METATABLE);
    lua_setmetatable(L, -2);

    return 1;
}

// EMP.SET_DECODE_MODE(mode_string)
// mode_string: "play", "scrub", or "park"
static int lua_emp_set_decode_mode(lua_State* L) {
    const char* mode_str = luaL_checkstring(L, 1);

    if (strcmp(mode_str, "play") == 0) {
        emp::SetDecodeMode(emp::DecodeMode::Play);
    } else if (strcmp(mode_str, "scrub") == 0) {
        emp::SetDecodeMode(emp::DecodeMode::Scrub);
    } else if (strcmp(mode_str, "park") == 0) {
        emp::SetDecodeMode(emp::DecodeMode::Park);
    } else {
        return luaL_error(L, "SET_DECODE_MODE: invalid mode '%s' (expected play/scrub/park)", mode_str);
    }

    return 0;
}

// EMP.READER_SET_MAX_CACHE(reader, max_frames)
static int lua_emp_reader_set_max_cache(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_READER_METATABLE);
    auto it = g_readers.find(key);
    if (it == g_readers.end()) {
        return luaL_error(L, "READER_SET_MAX_CACHE: invalid reader handle");
    }

    int max_frames = static_cast<int>(luaL_checkinteger(L, 2));
    if (max_frames < 0) {
        return luaL_error(L, "READER_SET_MAX_CACHE: max_frames must be >= 0, got %d", max_frames);
    }

    it->second->SetMaxCacheFrames(static_cast<size_t>(max_frames));
    return 0;
}

// EMP.SURFACE_SET_ROTATION(surface_widget, degrees)
// Set rotation for video surface (0, 90, 180, 270)
// Currently only CPUVideoSurface supports rotation
static int lua_emp_surface_set_rotation(lua_State* L) {
    void** widget_ptr = static_cast<void**>(luaL_checkudata(L, 1, WIDGET_METATABLE));
    QWidget* qwidget = static_cast<QWidget*>(*widget_ptr);
    int degrees = static_cast<int>(luaL_checkinteger(L, 2));

    GPUVideoSurface* gpu_surface = qobject_cast<GPUVideoSurface*>(qwidget);
    if (gpu_surface) {
        gpu_surface->setRotation(degrees);
        return 0;
    }

    CPUVideoSurface* cpu_surface = qobject_cast<CPUVideoSurface*>(qwidget);
    if (cpu_surface) {
        cpu_surface->setRotation(degrees);
        return 0;
    }

    return luaL_error(L, "SURFACE_SET_ROTATION: widget is neither GPU nor CPU video surface");
    return 0;
}

// EMP.SURFACE_SET_FRAME(surface_widget, frame|nil)
// Works with both GPUVideoSurface and CPUVideoSurface
static int lua_emp_surface_set_frame(lua_State* L) {
    void** widget_ptr = static_cast<void**>(luaL_checkudata(L, 1, WIDGET_METATABLE));
    QWidget* qwidget = static_cast<QWidget*>(*widget_ptr);

    // Try GPU surface first
    GPUVideoSurface* gpu_surface = qobject_cast<GPUVideoSurface*>(qwidget);
    CPUVideoSurface* cpu_surface = qobject_cast<CPUVideoSurface*>(qwidget);

    if (!gpu_surface && !cpu_surface) {
        return luaL_error(L, "EMP.SURFACE_SET_FRAME: widget is not a video surface (GPU or CPU)");
    }

    // Handle nil (clear)
    if (lua_isnil(L, 2)) {
        if (gpu_surface) gpu_surface->clearFrame();
        if (cpu_surface) cpu_surface->clearFrame();
        return 0;
    }

    // Get frame
    void* frame_key = get_map_key(L, 2, EMP_FRAME_METATABLE);
    auto it = g_frames.find(frame_key);
    if (it == g_frames.end()) {
        return luaL_error(L, "EMP.SURFACE_SET_FRAME: invalid frame handle");
    }
    auto frame = it->second;

    // Dispatch to appropriate surface, catching any C++ exceptions
    try {
        if (gpu_surface) {
            gpu_surface->setFrame(frame);
        } else {
            cpu_surface->setFrame(frame);
        }
    } catch (const std::exception& e) {
        return luaL_error(L, "EMP.SURFACE_SET_FRAME: C++ exception: %s", e.what());
    }

    return 0;
}

} // anonymous namespace

// ============================================================================
// Registration
// ============================================================================

void register_emp_bindings(lua_State* L) {
    // Create metatables with __gc
    luaL_newmetatable(L, EMP_MEDIA_FILE_METATABLE);
    lua_pushcfunction(L, lua_emp_media_file_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);

    luaL_newmetatable(L, EMP_READER_METATABLE);
    lua_pushcfunction(L, lua_emp_reader_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);

    luaL_newmetatable(L, EMP_FRAME_METATABLE);
    lua_pushcfunction(L, lua_emp_frame_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);

    luaL_newmetatable(L, EMP_PCM_METATABLE);
    lua_pushcfunction(L, lua_emp_pcm_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);

    luaL_newmetatable(L, EMP_TMB_METATABLE);
    lua_pushcfunction(L, lua_emp_tmb_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);

    // Create EMP subtable in qt_constants
    // Assumes qt_constants is on stack at index -1
    lua_newtable(L);

    // MediaFile functions
    lua_pushcfunction(L, lua_emp_media_file_open);
    lua_setfield(L, -2, "MEDIA_FILE_OPEN");
    lua_pushcfunction(L, lua_emp_media_file_close);
    lua_setfield(L, -2, "MEDIA_FILE_CLOSE");
    lua_pushcfunction(L, lua_emp_media_file_info);
    lua_setfield(L, -2, "MEDIA_FILE_INFO");

    // Reader functions
    lua_pushcfunction(L, lua_emp_reader_create);
    lua_setfield(L, -2, "READER_CREATE");
    lua_pushcfunction(L, lua_emp_reader_close);
    lua_setfield(L, -2, "READER_CLOSE");
    lua_pushcfunction(L, lua_emp_reader_seek_frame);
    lua_setfield(L, -2, "READER_SEEK_FRAME");
    lua_pushcfunction(L, lua_emp_reader_decode_frame);
    lua_setfield(L, -2, "READER_DECODE_FRAME");

    // Prefetch functions (background decode thread)
    lua_pushcfunction(L, lua_emp_reader_start_prefetch);
    lua_setfield(L, -2, "READER_START_PREFETCH");
    lua_pushcfunction(L, lua_emp_reader_stop_prefetch);
    lua_setfield(L, -2, "READER_STOP_PREFETCH");
    lua_pushcfunction(L, lua_emp_reader_update_prefetch_target);
    lua_setfield(L, -2, "READER_UPDATE_PREFETCH_TARGET");
    lua_pushcfunction(L, lua_emp_reader_get_cached_frame);
    lua_setfield(L, -2, "READER_GET_CACHED_FRAME");

    // Decode mode and cache control
    lua_pushcfunction(L, lua_emp_set_decode_mode);
    lua_setfield(L, -2, "SET_DECODE_MODE");
    lua_pushcfunction(L, lua_emp_reader_set_max_cache);
    lua_setfield(L, -2, "READER_SET_MAX_CACHE");

    // Frame functions
    lua_pushcfunction(L, lua_emp_frame_info);
    lua_setfield(L, -2, "FRAME_INFO");
    lua_pushcfunction(L, lua_emp_frame_release);
    lua_setfield(L, -2, "FRAME_RELEASE");
    lua_pushcfunction(L, lua_emp_frame_data_ptr);
    lua_setfield(L, -2, "FRAME_DATA_PTR");

    // Audio functions
    lua_pushcfunction(L, lua_emp_reader_decode_audio_range);
    lua_setfield(L, -2, "READER_DECODE_AUDIO_RANGE");
    lua_pushcfunction(L, lua_emp_pcm_info);
    lua_setfield(L, -2, "PCM_INFO");
    lua_pushcfunction(L, lua_emp_pcm_data_ptr);
    lua_setfield(L, -2, "PCM_DATA_PTR");
    lua_pushcfunction(L, lua_emp_pcm_release);
    lua_setfield(L, -2, "PCM_RELEASE");

    // Offline frame compositor
    lua_pushcfunction(L, lua_emp_compose_offline_frame);
    lua_setfield(L, -2, "COMPOSE_OFFLINE_FRAME");

    // TimelineMediaBuffer (TMB) functions
    lua_pushcfunction(L, lua_emp_tmb_create);
    lua_setfield(L, -2, "TMB_CREATE");
    lua_pushcfunction(L, lua_emp_tmb_close);
    lua_setfield(L, -2, "TMB_CLOSE");
    lua_pushcfunction(L, lua_emp_tmb_set_max_readers);
    lua_setfield(L, -2, "TMB_SET_MAX_READERS");
    lua_pushcfunction(L, lua_emp_tmb_set_sequence_rate);
    lua_setfield(L, -2, "TMB_SET_SEQUENCE_RATE");
    lua_pushcfunction(L, lua_emp_tmb_set_audio_format);
    lua_setfield(L, -2, "TMB_SET_AUDIO_FORMAT");
    lua_pushcfunction(L, lua_emp_tmb_set_track_clips);
    lua_setfield(L, -2, "TMB_SET_TRACK_CLIPS");
    lua_pushcfunction(L, lua_emp_tmb_set_playhead);
    lua_setfield(L, -2, "TMB_SET_PLAYHEAD");
    lua_pushcfunction(L, lua_emp_tmb_get_video_frame);
    lua_setfield(L, -2, "TMB_GET_VIDEO_FRAME");
    lua_pushcfunction(L, lua_emp_tmb_get_track_audio);
    lua_setfield(L, -2, "TMB_GET_TRACK_AUDIO");
    lua_pushcfunction(L, lua_emp_tmb_release_track);
    lua_setfield(L, -2, "TMB_RELEASE_TRACK");
    lua_pushcfunction(L, lua_emp_tmb_release_all);
    lua_setfield(L, -2, "TMB_RELEASE_ALL");
    lua_pushcfunction(L, lua_emp_media_file_probe);
    lua_setfield(L, -2, "MEDIA_FILE_PROBE");

    // Surface functions
    lua_pushcfunction(L, lua_emp_surface_set_frame);
    lua_setfield(L, -2, "SURFACE_SET_FRAME");
    lua_pushcfunction(L, lua_emp_surface_set_rotation);
    lua_setfield(L, -2, "SURFACE_SET_ROTATION");

    lua_setfield(L, -2, "EMP");

    // Add video surface creators to qt_constants.WIDGET
    lua_getfield(L, -1, "WIDGET");
    if (lua_istable(L, -1)) {
        lua_pushcfunction(L, lua_create_gpu_video_surface);
        lua_setfield(L, -2, "CREATE_GPU_VIDEO_SURFACE");

        lua_pushcfunction(L, lua_create_cpu_video_surface);
        lua_setfield(L, -2, "CREATE_CPU_VIDEO_SURFACE");
    }
    lua_pop(L, 1);  // Pop WIDGET table
}
