// EMP (Editor Media Platform) Lua bindings
// Provides frame-first video decoding for Source Viewer

#include <editor_media_platform/emp_media_file.h>
#include <editor_media_platform/emp_reader.h>
#include <editor_media_platform/emp_frame.h>
#include <editor_media_platform/emp_audio.h>
#include <editor_media_platform/emp_errors.h>
#include <editor_media_platform/emp_time.h>
#include <editor_media_platform/emp_timeline_media_buffer.h>
#include <editor_media_platform/emp_peak_file.h>
#include <editor_media_platform/emp_peak_generator.h>
#include <editor_media_platform/emp_cdl.h>

#include "../../editor_media_platform/src/impl/braw_decode.h"
#include "gpu_video_surface.h"
#include "cpu_video_surface.h"
#include "playback_controller.h"
#include "assert_handler.h"
#include "audio_output_platform/aop.h"
#include "scrub_stretch_engine/sse.h"
#include "jve_log.h"
#include <QImage>
#include <QPainter>
#include <QFont>
#include <QFontMetrics>
#include <QColor>
#include <QLinearGradient>
#include "binding_macros.h"

#include "codec_probe_worker.h"

#include <lua.hpp>
#include <memory>
#include <unordered_map>
#include <cstdint>
#include <cstring>
#include <stdexcept>

// Forward declaration from binding_macros.h
extern const char* WIDGET_METATABLE;

// External metatable names (defined in aop_bindings.cpp and sse_bindings.cpp)
extern const char* AOP_METATABLE;
extern const char* SSE_METATABLE;

// External lookup functions (defined in aop_bindings.cpp and sse_bindings.cpp)
extern aop::AudioOutput* get_aop_userdata(lua_State* L, int idx);
extern sse::ScrubStretchEngine* get_sse_userdata(lua_State* L, int idx);

namespace {

// Metatable names for EMP types
const char* EMP_MEDIA_FILE_METATABLE = "JVE.EMP.MediaFile";
const char* EMP_READER_METATABLE = "JVE.EMP.Reader";
const char* EMP_FRAME_METATABLE = "JVE.EMP.Frame";
const char* EMP_PCM_METATABLE = "JVE.EMP.PcmChunk";
const char* EMP_TMB_METATABLE = "JVE.EMP.TMB";
const char* PLAYBACK_CONTROLLER_METATABLE = "JVE.PlaybackController";

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
static std::unordered_map<void*, std::unique_ptr<PlaybackController>> g_playback_controllers;

// Lua callback refs held by C++ owners (PlaybackController, GPUVideoSurface).
// Each setter that previously did `luaL_ref(...)` straight into a captured
// lambda leaked the prior ref on replace/clear. These maps track the live
// ref so it can be unref'd when the callback is replaced, cleared, or the
// owning controller is destroyed (PLAYBACK.CLOSE / __gc).
//
// Keyed by raw owner pointer because each controller/surface owns exactly
// one slot per callback type. SURFACE_ON_READY (one-shot) does not need a
// map — its lambda unrefs itself on first fire.
static std::unordered_map<PlaybackController*, int> g_position_cb_refs;
static std::unordered_map<PlaybackController*, int> g_clip_provider_refs;
static std::unordered_map<PlaybackController*, int> g_clip_transition_refs;
static std::unordered_map<GPUVideoSurface*,    int> g_surface_error_refs;

template <typename Map, typename Key>
static void replace_cb_ref(lua_State* L, Map& map, Key key, int new_ref) {
    auto it = map.find(key);
    if (it != map.end()) {
        luaL_unref(L, LUA_REGISTRYINDEX, it->second);
        map.erase(it);
    }
    if (new_ref != LUA_NOREF) map.emplace(key, new_ref);
}

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

// Build the Lua info table from a MediaFileInfo. Shared by MEDIA_FILE_INFO
// (handle-based) and MEDIA_PROBE_BATCH (returns info directly without a
// MediaFile handle). Caller supplies an empty table slot; this function
// creates a new table on top of the Lua stack and populates it.
static void push_media_file_info_table(lua_State* L, const emp::MediaFileInfo& info) {
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
    lua_pushboolean(L, info.has_duration);
    lua_setfield(L, -2, "has_duration");
    // Authoritative counts when the demuxer exposes them directly.
    // -1 sentinel surfaces as nil so Lua callers can distinguish
    // "container reported N" from "container didn't report".
    if (info.video_frame_count >= 0) {
        lua_pushinteger(L, static_cast<lua_Integer>(info.video_frame_count));
        lua_setfield(L, -2, "video_frame_count");
    }
    if (info.audio_sample_count >= 0) {
        lua_pushinteger(L, static_cast<lua_Integer>(info.audio_sample_count));
        lua_setfield(L, -2, "audio_sample_count");
    }
    lua_pushboolean(L, info.is_vfr);
    lua_setfield(L, -2, "is_vfr");

    // TC origins. The has_*_tc_origin booleans distinguish authoritative
    // values (container metadata) from default-0 "unknown" values; callers
    // matching on TC should consult the presence bit, not the integer.
    lua_pushinteger(L, static_cast<lua_Integer>(info.first_frame_tc));
    lua_setfield(L, -2, "first_frame_tc");
    lua_pushboolean(L, info.has_video_tc_origin);
    lua_setfield(L, -2, "has_video_tc_origin");
    lua_pushinteger(L, static_cast<lua_Integer>(info.first_sample_tc));
    lua_setfield(L, -2, "first_sample_tc");
    lua_pushboolean(L, info.has_audio_tc_origin);
    lua_setfield(L, -2, "has_audio_tc_origin");
    // Legacy alias
    lua_pushinteger(L, static_cast<lua_Integer>(info.first_frame_tc));
    lua_setfield(L, -2, "start_tc");

    // Rotation in degrees (0, 90, 180, 270) from display matrix
    lua_pushinteger(L, info.rotation);
    lua_setfield(L, -2, "rotation");

    // Pixel aspect ratio
    lua_pushinteger(L, info.video_par_num);
    lua_setfield(L, -2, "par_num");
    lua_pushinteger(L, info.video_par_den);
    lua_setfield(L, -2, "par_den");

    // Audio fields
    lua_pushboolean(L, info.has_audio);
    lua_setfield(L, -2, "has_audio");
    lua_pushinteger(L, info.audio_sample_rate);
    lua_setfield(L, -2, "audio_sample_rate");
    lua_pushinteger(L, info.audio_channels);
    lua_setfield(L, -2, "audio_channels");
}

// EMP.MEDIA_FILE_INFO(media_file) -> info table (same shape as MEDIA_PROBE_BATCH entries)
static int lua_emp_media_file_info(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_MEDIA_FILE_METATABLE);
    auto it = g_media_files.find(key);
    if (it == g_media_files.end()) {
        return luaL_error(L, "EMP.MEDIA_FILE_INFO: invalid media file handle");
    }
    push_media_file_info_table(L, it->second->info());
    return 1;
}

// EMP.MEDIA_PROBE(path) -> info_table | nil, err
//
// Single-shot metadata probe via emp::MediaFile::ProbeMetadata. Returns
// the same info shape as MEDIA_FILE_OPEN+MEDIA_FILE_INFO but without
// retaining a MediaFile handle — cheaper for callers that only need
// the info table and never intend to decode frames. Use MEDIA_FILE_OPEN
// when you need to feed a Reader / decode path.
//
// For batches use MEDIA_PROBE_BATCH — it dispatches probes across a
// worker pool with hardware_concurrency parallelism.
static int lua_emp_media_probe(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    auto result = emp::MediaFile::ProbeMetadata(path);
    if (result.is_error()) {
        push_emp_error(L, result.error());
        return 2;
    }
    push_media_file_info_table(L, result.value());
    return 1;
}

// EMP.MEDIA_PROBE_BATCH({path, path, ...}, parallelism?) -> {info_or_nil, ...}
//
// Parallel metadata probe over many files using emp::MediaFile::ProbeMetadata.
// Dispatches across a worker pool — 8-way on typical hardware — so bulk
// probing of large media sets (relink scan, importer preflight) runs in
// wall-clock proportional to single_probe_ms × N / cores, rather than the
// serial baseline.
// Returns an array with one entry per input path, in the same order: either
// a populated info table (success) or nil (probe failed — input file missing,
// unsupported container, etc). A failure on one path does not abort the batch.
//
// parallelism: optional integer. Default = hardware_concurrency. Pass 1 to
// force serial execution (useful for debugging).
static int lua_emp_media_probe_batch(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    size_t parallelism = 0;
    if (lua_gettop(L) >= 2 && !lua_isnil(L, 2)) {
        lua_Integer p = luaL_checkinteger(L, 2);
        if (p < 0) {
            return luaL_error(L, "EMP.MEDIA_PROBE_BATCH: parallelism must be >= 0");
        }
        parallelism = static_cast<size_t>(p);
    }

    // Collect paths from Lua array.
    std::vector<std::string> paths;
    lua_Integer n = lua_objlen(L, 1);
    paths.reserve(static_cast<size_t>(n));
    for (lua_Integer i = 1; i <= n; ++i) {
        lua_rawgeti(L, 1, i);
        if (lua_type(L, -1) != LUA_TSTRING) {
            lua_pop(L, 1);
            return luaL_error(L,
                "EMP.MEDIA_PROBE_BATCH: paths[%d] must be a string", (int)i);
        }
        size_t len;
        const char* s = lua_tolstring(L, -1, &len);
        paths.emplace_back(s, len);
        lua_pop(L, 1);
    }

    // Run the parallel probe. This blocks the Lua thread until all workers join.
    auto results = emp::MediaFile::ProbeMetadataBatch(paths, parallelism);
    assert(results.size() == paths.size()
        && "ProbeMetadataBatch must return one result per input path");

    // Build Lua return array — one entry per path, either info table or nil.
    lua_createtable(L, static_cast<int>(results.size()), 0);
    for (size_t i = 0; i < results.size(); ++i) {
        if (results[i].is_ok()) {
            push_media_file_info_table(L, results[i].value());
        } else {
            lua_pushnil(L);
        }
        lua_rawseti(L, -2, static_cast<int>(i + 1));
    }
    return 1;
}

// EMP.MEDIA_FILE_SET_TC_ORIGIN_OVERRIDE(media_file, first_frame_tc, first_sample_tc)
static int lua_emp_media_file_set_tc_origin_override(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_MEDIA_FILE_METATABLE);
    auto it = g_media_files.find(key);
    if (it == g_media_files.end()) {
        return luaL_error(L, "MEDIA_FILE_SET_TC_ORIGIN_OVERRIDE: invalid media file handle");
    }
    int64_t first_frame_tc = static_cast<int64_t>(luaL_checkinteger(L, 2));
    int64_t first_sample_tc = static_cast<int64_t>(luaL_checkinteger(L, 3));
    it->second->set_tc_origin_override(first_frame_tc, first_sample_tc);
    return 0;
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

// EMP.READER_CREATE_AUDIO_ONLY(media_file) -> reader | nil, err
// Skips video codec init even when the file has a video stream. Used
// by clients that decode audio only (peak generation), to avoid the
// VideoToolbox init mutex contention path.
static int lua_emp_reader_create_audio_only(lua_State* L) {
    void* mf_key = get_map_key(L, 1, EMP_MEDIA_FILE_METATABLE);
    auto mf_it = g_media_files.find(mf_key);
    if (mf_it == g_media_files.end()) {
        push_emp_error(L, emp::Error::invalid_arg("Invalid media file handle"));
        return 2;
    }

    auto result = emp::Reader::CreateAudioOnly(mf_it->second);
    if (result.is_error()) {
        push_emp_error(L, result.error());
        return 2;
    }

    auto reader = result.value();
    void* key = push_userdata(L, reader, EMP_READER_METATABLE);
    g_readers[key] = reader;
    return 1;
}

// EMP.READER_HAS_VIDEO_CODEC(reader) -> bool
static int lua_emp_reader_has_video_codec(lua_State* L) {
    void* key = get_map_key(L, 1, EMP_READER_METATABLE);
    auto it = g_readers.find(key);
    if (it == g_readers.end()) {
        return luaL_error(L, "EMP.READER_HAS_VIDEO_CODEC: invalid reader handle");
    }
    lua_pushboolean(L, it->second->HasVideoCodec() ? 1 : 0);
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
    int pool_threads = static_cast<int>(luaL_optinteger(L, 1, 3));
    if (pool_threads < 0 || (pool_threads != 0 && pool_threads < 3)) {
        return luaL_error(L, "TMB_CREATE: pool_threads must be 0 (sync) or >= 3 (1 prep + 1 video + 1 audio), got %d", pool_threads);
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

// Helper: parse track type string ("video" or "audio") from Lua arg
static emp::TrackType parse_track_type(lua_State* L, int idx) {
    const char* type_str = luaL_checkstring(L, idx);
    if (strcmp(type_str, "video") == 0) return emp::TrackType::Video;
    if (strcmp(type_str, "audio") == 0) return emp::TrackType::Audio;
    luaL_error(L, "invalid track type: '%s' (expected 'video' or 'audio')", type_str);
    return emp::TrackType::Video; // unreachable
}

// EMP.TMB_SET_TC_OVERRIDES(tmb, overrides_table)
// overrides_table = { [path_string] = { video = int64, audio = int64 | nil }, ... }
//
// `video` is required (the override applies to the file's video TC).
// `audio` is optional — absent for video-only media, where the audio side
// of the override is never consulted. When absent we store 0 as a no-op
// sentinel; if a file has audio AND needs an override, the Lua caller must
// supply a real audio sample count.
//
// Schema violations (non-string key, non-table value, missing/non-numeric
// `video`) are programming errors and fail loud per the fail-fast policy.
static int lua_emp_tmb_set_tc_overrides(lua_State* L) {
    auto tmb = get_tmb(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);

    std::unordered_map<std::string, emp::TcOverride> overrides;

    lua_pushnil(L);
    while (lua_next(L, 2)) {
        if (!lua_isstring(L, -2)) {
            return luaL_error(L,
                "TMB_SET_TC_OVERRIDES: override map key must be a string path");
        }
        if (!lua_istable(L, -1)) {
            return luaL_error(L,
                "TMB_SET_TC_OVERRIDES: override map value for '%s' must be a table",
                lua_tostring(L, -2));
        }
        std::string path = lua_tostring(L, -2);

        lua_getfield(L, -1, "video");
        if (!lua_isnumber(L, -1)) {
            return luaL_error(L,
                "TMB_SET_TC_OVERRIDES: '%s'.video must be an integer (got %s)",
                path.c_str(), luaL_typename(L, -1));
        }
        int64_t video_tc = static_cast<int64_t>(lua_tointeger(L, -1));
        lua_pop(L, 1);

        // audio is optional: absent → 0 sentinel (audio path won't be consulted
        // for video-only media). Present-but-non-numeric is a schema violation.
        lua_getfield(L, -1, "audio");
        int64_t audio_tc = 0;
        if (!lua_isnil(L, -1)) {
            if (!lua_isnumber(L, -1)) {
                return luaL_error(L,
                    "TMB_SET_TC_OVERRIDES: '%s'.audio must be an integer or nil (got %s)",
                    path.c_str(), luaL_typename(L, -1));
            }
            audio_tc = static_cast<int64_t>(lua_tointeger(L, -1));
        }
        lua_pop(L, 1);

        overrides[path] = emp::TcOverride{video_tc, audio_tc};
        lua_pop(L, 1);  // pop value, keep key for next iteration
    }

    tmb->SetTcOverrides(std::move(overrides));
    return 0;
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

// EMP.TMB_SET_SEQUENCE_RESOLUTION(tmb, width, height)
static int lua_emp_tmb_set_sequence_resolution(lua_State* L) {
    auto tmb = get_tmb(L, 1);
    int32_t w = static_cast<int32_t>(luaL_checkinteger(L, 2));
    int32_t h = static_cast<int32_t>(luaL_checkinteger(L, 3));
    if (w <= 0) return luaL_error(L, "TMB_SET_SEQUENCE_RESOLUTION: width must be > 0, got %d", w);
    if (h <= 0) return luaL_error(L, "TMB_SET_SEQUENCE_RESOLUTION: height must be > 0, got %d", h);
    tmb->SetSequenceResolution(w, h);
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

// EMP.TMB_SET_TRACK_CLIPS(tmb, type_string, track_index, clips_table)
// clips_table = array of { clip_id, media_path, sequence_start, duration, source_in, rate_num, rate_den, speed_ratio }
static int lua_emp_tmb_set_track_clips(lua_State* L) {
    auto tmb = get_tmb(L, 1);
    auto track_type = parse_track_type(L, 2);
    int track_index = static_cast<int>(luaL_checkinteger(L, 3));
    emp::TrackId track{track_type, track_index};
    luaL_checktype(L, 4, LUA_TTABLE);

    int n = static_cast<int>(lua_objlen(L, 4));
    std::vector<emp::ClipInfo> clips;
    clips.reserve(static_cast<size_t>(n));

    for (int i = 1; i <= n; ++i) {
        lua_rawgeti(L, 4, i);
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

        lua_getfield(L, -1, "sequence_start");
        if (!lua_isnumber(L, -1)) {
            return luaL_error(L, "TMB_SET_TRACK_CLIPS: element %d missing sequence_start", i);
        }
        ci.sequence_start = static_cast<int64_t>(lua_tointeger(L, -1));
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

        lua_getfield(L, -1, "offline");
        ci.offline = lua_isboolean(L, -1) ? lua_toboolean(L, -1) : false;
        lua_pop(L, 1);

        lua_getfield(L, -1, "volume");
        ci.volume = lua_isnumber(L, -1) ? static_cast<float>(lua_tonumber(L, -1)) : 1.0f;
        lua_pop(L, 1);

        lua_pop(L, 1); // pop clip table

        if (ci.rate_den <= 0) {
            return luaL_error(L, "TMB_SET_TRACK_CLIPS: element %d rate_den must be > 0, got %d", i, ci.rate_den);
        }
        if (ci.speed_ratio == 0.0f) {
            return luaL_error(L, "TMB_SET_TRACK_CLIPS: element %d speed_ratio must be non-zero", i);
        }

        clips.push_back(std::move(ci));
    }

    tmb->SetTrackClips(track, clips);
    return 0;
}

// EMP.TMB_ADD_CLIPS(tmb, type_string, track_index, clips_table)
// Same clip-table format as TMB_SET_TRACK_CLIPS; calls AddClips (dedup + sort).
static int lua_emp_tmb_add_clips(lua_State* L) {
    auto tmb = get_tmb(L, 1);
    auto track_type = parse_track_type(L, 2);
    int track_index = static_cast<int>(luaL_checkinteger(L, 3));
    emp::TrackId track{track_type, track_index};
    luaL_checktype(L, 4, LUA_TTABLE);

    int n = static_cast<int>(lua_objlen(L, 4));
    std::vector<emp::ClipInfo> clips;
    clips.reserve(static_cast<size_t>(n));

    for (int i = 1; i <= n; ++i) {
        lua_rawgeti(L, 4, i);
        if (!lua_istable(L, -1)) {
            return luaL_error(L, "TMB_ADD_CLIPS: element %d is not a table", i);
        }

        emp::ClipInfo ci{};

        lua_getfield(L, -1, "clip_id");
        if (!lua_isstring(L, -1)) {
            return luaL_error(L, "TMB_ADD_CLIPS: element %d missing clip_id", i);
        }
        ci.clip_id = lua_tostring(L, -1);
        lua_pop(L, 1);

        lua_getfield(L, -1, "media_path");
        if (!lua_isstring(L, -1)) {
            return luaL_error(L, "TMB_ADD_CLIPS: element %d missing media_path", i);
        }
        ci.media_path = lua_tostring(L, -1);
        lua_pop(L, 1);

        lua_getfield(L, -1, "sequence_start");
        if (!lua_isnumber(L, -1)) {
            return luaL_error(L, "TMB_ADD_CLIPS: element %d missing sequence_start", i);
        }
        ci.sequence_start = static_cast<int64_t>(lua_tointeger(L, -1));
        lua_pop(L, 1);

        lua_getfield(L, -1, "duration");
        if (!lua_isnumber(L, -1)) {
            return luaL_error(L, "TMB_ADD_CLIPS: element %d missing duration", i);
        }
        ci.duration = static_cast<int64_t>(lua_tointeger(L, -1));
        lua_pop(L, 1);

        lua_getfield(L, -1, "source_in");
        if (!lua_isnumber(L, -1)) {
            return luaL_error(L, "TMB_ADD_CLIPS: element %d missing source_in", i);
        }
        ci.source_in = static_cast<int64_t>(lua_tointeger(L, -1));
        lua_pop(L, 1);

        lua_getfield(L, -1, "rate_num");
        if (!lua_isnumber(L, -1)) {
            return luaL_error(L, "TMB_ADD_CLIPS: element %d missing rate_num", i);
        }
        ci.rate_num = static_cast<int32_t>(lua_tointeger(L, -1));
        lua_pop(L, 1);

        lua_getfield(L, -1, "rate_den");
        if (!lua_isnumber(L, -1)) {
            return luaL_error(L, "TMB_ADD_CLIPS: element %d missing rate_den", i);
        }
        ci.rate_den = static_cast<int32_t>(lua_tointeger(L, -1));
        lua_pop(L, 1);

        lua_getfield(L, -1, "speed_ratio");
        if (!lua_isnumber(L, -1)) {
            return luaL_error(L, "TMB_ADD_CLIPS: element %d missing speed_ratio", i);
        }
        ci.speed_ratio = static_cast<float>(lua_tonumber(L, -1));
        lua_pop(L, 1);

        lua_getfield(L, -1, "offline");
        ci.offline = lua_isboolean(L, -1) ? lua_toboolean(L, -1) : false;
        lua_pop(L, 1);

        lua_getfield(L, -1, "volume");
        ci.volume = lua_isnumber(L, -1) ? static_cast<float>(lua_tonumber(L, -1)) : 1.0f;
        lua_pop(L, 1);

        lua_pop(L, 1); // pop clip table

        if (ci.rate_den <= 0) {
            return luaL_error(L, "TMB_ADD_CLIPS: element %d rate_den must be > 0, got %d", i, ci.rate_den);
        }
        if (ci.speed_ratio == 0.0f) {
            return luaL_error(L, "TMB_ADD_CLIPS: element %d speed_ratio must be non-zero", i);
        }

        clips.push_back(std::move(ci));
    }

    tmb->AddClips(track, std::move(clips));
    return 0;
}

// EMP.TMB_CLEAR_ALL_CLIPS(tmb)
static int lua_emp_tmb_clear_all_clips(lua_State* L) {
    auto tmb = get_tmb(L, 1);
    tmb->ClearAllClips();
    return 0;
}

// EMP.TMB_CLEAR_OFFLINE(tmb, path)
static int lua_emp_tmb_clear_offline(lua_State* L) {
    auto tmb = get_tmb(L, 1);
    const char* path = luaL_checkstring(L, 2);
    tmb->ClearOffline(path);
    return 0;
}

// EMP.TMB_INVALIDATE_PATH(tmb, path) — drop cached readers and decoded
// frames/PCM for this path after an in-place content rewrite. Wired to
// the `media_content_changed` signal so FS watcher events flow through.
static int lua_emp_tmb_invalidate_path(lua_State* L) {
    auto tmb = get_tmb(L, 1);
    const char* path = luaL_checkstring(L, 2);
    tmb->InvalidatePath(path);
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

// EMP.TMB_GET_VIDEO_FRAME(tmb, track_index, timeline_frame [, cache_only]) -> frame|nil, info_table
// cache_only (optional, default false): if true, only return cached frames (playback mode).
static int lua_emp_tmb_get_video_frame(lua_State* L) {
    auto tmb = get_tmb(L, 1);
    int track_index = static_cast<int>(luaL_checkinteger(L, 2));
    int64_t timeline_frame = static_cast<int64_t>(luaL_checkinteger(L, 3));
    bool cache_only = lua_isboolean(L, 4) ? lua_toboolean(L, 4) : false;

    emp::TrackId track{emp::TrackType::Video, track_index};
    auto result = tmb->GetVideoFrame(track, timeline_frame, cache_only);

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
    lua_pushstring(L, result.media_path.c_str());
    lua_setfield(L, -2, "media_path");
    lua_pushinteger(L, result.rotation);
    lua_setfield(L, -2, "rotation");
    lua_pushinteger(L, result.par_num);
    lua_setfield(L, -2, "par_num");
    lua_pushinteger(L, result.par_den);
    lua_setfield(L, -2, "par_den");
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
    lua_pushboolean(L, result.obscured);
    lua_setfield(L, -2, "obscured");
    if (!result.error_msg.empty()) {
        lua_pushstring(L, result.error_msg.c_str());
        lua_setfield(L, -2, "error_msg");
    }
    if (!result.error_code.empty()) {
        lua_pushstring(L, result.error_code.c_str());
        lua_setfield(L, -2, "error_code");
    }

    return 2;
}

// EMP.TMB_GET_TRACK_AUDIO(tmb, track_index, t0_us, t1_us, sample_rate, channels) -> pcm|nil
// Type is implied: always Audio
static int lua_emp_tmb_get_track_audio(lua_State* L) {
    auto tmb = get_tmb(L, 1);
    int track_index = static_cast<int>(luaL_checkinteger(L, 2));
    int64_t t0 = static_cast<int64_t>(luaL_checkinteger(L, 3));
    int64_t t1 = static_cast<int64_t>(luaL_checkinteger(L, 4));
    int32_t sample_rate = static_cast<int32_t>(luaL_checkinteger(L, 5));
    int32_t channels = static_cast<int32_t>(luaL_checkinteger(L, 6));
    if (t1 <= t0) return luaL_error(L, "TMB_GET_TRACK_AUDIO: t1 (%lld) must be > t0 (%lld)", (long long)t1, (long long)t0);
    if (sample_rate <= 0) return luaL_error(L, "TMB_GET_TRACK_AUDIO: sample_rate must be > 0, got %d", sample_rate);
    if (channels <= 0) return luaL_error(L, "TMB_GET_TRACK_AUDIO: channels must be > 0, got %d", channels);

    emp::TrackId track{emp::TrackType::Audio, track_index};
    emp::AudioFormat fmt{emp::SampleFormat::F32, sample_rate, channels};
    auto pcm = tmb->GetTrackAudio(track, t0, t1, fmt);

    if (!pcm) {
        lua_pushnil(L);
        return 1;
    }

    void* pcm_key = push_userdata(L, pcm, EMP_PCM_METATABLE);
    g_pcm_chunks[pcm_key] = pcm;
    return 1;
}

// EMP.TMB_SET_AUDIO_MIX_PARAMS(tmb, params_table, sample_rate, channels)
// params_table = array of { track_index=N, volume=V }
static int lua_emp_tmb_set_audio_mix_params(lua_State* L) {
    auto tmb = get_tmb(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);
    int32_t sample_rate = static_cast<int32_t>(luaL_checkinteger(L, 3));
    int32_t channels = static_cast<int32_t>(luaL_checkinteger(L, 4));
    if (sample_rate <= 0) return luaL_error(L, "TMB_SET_AUDIO_MIX_PARAMS: sample_rate must be > 0, got %d", sample_rate);
    if (channels <= 0) return luaL_error(L, "TMB_SET_AUDIO_MIX_PARAMS: channels must be > 0, got %d", channels);

    int n = static_cast<int>(lua_objlen(L, 2));
    std::vector<emp::MixTrackParam> params;
    params.reserve(static_cast<size_t>(n));

    for (int i = 1; i <= n; ++i) {
        lua_rawgeti(L, 2, i);
        if (!lua_istable(L, -1)) {
            return luaL_error(L, "TMB_SET_AUDIO_MIX_PARAMS: element %d is not a table", i);
        }

        emp::MixTrackParam p{};
        lua_getfield(L, -1, "track_index");
        if (!lua_isnumber(L, -1)) {
            return luaL_error(L, "TMB_SET_AUDIO_MIX_PARAMS: element %d missing track_index", i);
        }
        p.track_index = static_cast<int>(lua_tointeger(L, -1));
        lua_pop(L, 1);

        lua_getfield(L, -1, "volume");
        if (!lua_isnumber(L, -1)) {
            return luaL_error(L, "TMB_SET_AUDIO_MIX_PARAMS: element %d missing volume", i);
        }
        p.volume = static_cast<float>(lua_tonumber(L, -1));
        lua_pop(L, 1);

        lua_pop(L, 1); // pop element table
        params.push_back(p);
    }

    emp::AudioFormat fmt{emp::SampleFormat::F32, sample_rate, channels};
    tmb->SetAudioMixParams(params, fmt);
    return 0;
}

// EMP.TMB_GET_MIXED_AUDIO(tmb, t0_us, t1_us) -> pcm | nil
static int lua_emp_tmb_get_mixed_audio(lua_State* L) {
    auto tmb = get_tmb(L, 1);
    int64_t t0 = static_cast<int64_t>(luaL_checkinteger(L, 2));
    int64_t t1 = static_cast<int64_t>(luaL_checkinteger(L, 3));
    if (t1 <= t0) return luaL_error(L, "TMB_GET_MIXED_AUDIO: t1 (%lld) must be > t0 (%lld)", (long long)t1, (long long)t0);

    auto pcm = tmb->GetMixedAudio(t0, t1);
    if (!pcm) {
        lua_pushnil(L);
        return 1;
    }

    void* pcm_key = push_userdata(L, pcm, EMP_PCM_METATABLE);
    g_pcm_chunks[pcm_key] = pcm;
    return 1;
}

// EMP.TMB_PARK_READERS(tmb)
// Stop all background decode work (REFILL workers + pre-buffer jobs).
static int lua_emp_tmb_park_readers(lua_State* L) {
    auto tmb = get_tmb(L, 1);
    tmb->ParkReaders();
    return 0;
}

// EMP.TMB_RELEASE_TRACK(tmb, type_string, track_index)
static int lua_emp_tmb_release_track(lua_State* L) {
    auto tmb = get_tmb(L, 1);
    auto track_type = parse_track_type(L, 2);
    int track_index = static_cast<int>(luaL_checkinteger(L, 3));
    tmb->ReleaseTrack(emp::TrackId{track_type, track_index});
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
    // TC origins
    lua_pushinteger(L, static_cast<lua_Integer>(info.first_frame_tc));
    lua_setfield(L, -2, "first_frame_tc");
    lua_pushinteger(L, static_cast<lua_Integer>(info.first_sample_tc));
    lua_setfield(L, -2, "first_sample_tc");
    // Legacy alias (read by existing Lua code until fully migrated)
    lua_pushinteger(L, static_cast<lua_Integer>(info.first_frame_tc));
    lua_setfield(L, -2, "start_tc");

    lua_pushinteger(L, info.rotation);
    lua_setfield(L, -2, "rotation");
    lua_pushinteger(L, info.video_par_num);
    lua_setfield(L, -2, "par_num");
    lua_pushinteger(L, info.video_par_den);
    lua_setfield(L, -2, "par_den");
    lua_pushboolean(L, info.has_audio);
    lua_setfield(L, -2, "has_audio");
    lua_pushinteger(L, info.audio_sample_rate);
    lua_setfield(L, -2, "audio_sample_rate");
    lua_pushinteger(L, info.audio_channels);
    lua_setfield(L, -2, "audio_channels");

    // BWF time_reference: -1 = not present, else samples since midnight
    lua_pushinteger(L, static_cast<lua_Integer>(info.bwf_time_reference));
    lua_setfield(L, -2, "bwf_time_reference");

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

    JVE_LOG_EVENT(Video, "Creating GPUVideoSurface (hw-accelerated)");
    GPUVideoSurface* widget = new GPUVideoSurface();

    // Goes through lua_push_widget so the surface is registered in
    // g_widgetRegistry — required for the staleness check in lua_to_widget()
    // that EMP.SURFACE_* bindings rely on after Qt destroys the QObject.
    lua_push_widget(L, widget);

    return 1;
}

// qt_constants.WIDGET.CREATE_CPU_VIDEO_SURFACE() -> widget
// Creates CPUVideoSurface for software rendering
static int lua_create_cpu_video_surface(lua_State* L) {
    CPUVideoSurface* widget = new CPUVideoSurface();

    // Goes through lua_push_widget so the surface is registered in
    // g_widgetRegistry — required for the staleness check in lua_to_widget()
    // that EMP.SURFACE_* bindings rely on after Qt destroys the QObject.
    lua_push_widget(L, widget);

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

// EMP.SURFACE_SET_ROTATION(surface_widget, degrees)
// Set rotation for video surface (0, 90, 180, 270)
// Currently only CPUVideoSurface supports rotation
static int lua_emp_surface_set_rotation(lua_State* L) {
    QWidget* qwidget = static_cast<QWidget*>(lua_to_widget(L, 1));
    if (!qwidget) return luaL_error(L, "SURFACE_SET_ROTATION: widget is null or destroyed");
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

// EMP.SURFACE_SET_PAR(surface_widget, num, den)
// Set pixel aspect ratio for video surface (1:1 = square, 4:3 = anamorphic HD)
static int lua_emp_surface_set_par(lua_State* L) {
    QWidget* qwidget = static_cast<QWidget*>(lua_to_widget(L, 1));
    if (!qwidget) return luaL_error(L, "SURFACE_SET_PAR: widget is null or destroyed");
    int num = static_cast<int>(luaL_checkinteger(L, 2));
    int den = static_cast<int>(luaL_checkinteger(L, 3));

    GPUVideoSurface* gpu_surface = qobject_cast<GPUVideoSurface*>(qwidget);
    if (gpu_surface) {
        gpu_surface->setPixelAspectRatio(num, den);
        return 0;
    }

    // CPUVideoSurface does not support PAR (no letterboxing)
    return 0;
}

// EMP.SURFACE_FRAME_COUNT(surface_widget) -> int
// Returns the number of times setFrame was called on a GPUVideoSurface.
// Used by integration tests to verify frame delivery without mocks.
static int lua_emp_surface_frame_count(lua_State* L) {
    QWidget* qwidget = static_cast<QWidget*>(lua_to_widget(L, 1));
    if (!qwidget) return luaL_error(L, "SURFACE_FRAME_COUNT: widget is null or destroyed");

    GPUVideoSurface* gpu_surface = qobject_cast<GPUVideoSurface*>(qwidget);
    if (!gpu_surface) {
        return luaL_error(L, "SURFACE_FRAME_COUNT: widget is not a GPUVideoSurface");
    }

    lua_pushinteger(L, gpu_surface->frameCount());
    return 1;
}

// EMP.SURFACE_UNIQUE_FRAME_COUNT(surface_widget) -> int
// Returns the number of frames with distinct source PTS displayed on a GPUVideoSurface.
// Stride-duplicated frames (same decoded content reused for multiple timeline positions)
// share the same PTS and don't increment this counter.
static int lua_emp_surface_unique_frame_count(lua_State* L) {
    QWidget* qwidget = static_cast<QWidget*>(lua_to_widget(L, 1));
    if (!qwidget) return luaL_error(L, "SURFACE_UNIQUE_FRAME_COUNT: widget is null or destroyed");

    GPUVideoSurface* gpu_surface = qobject_cast<GPUVideoSurface*>(qwidget);
    if (!gpu_surface) {
        return luaL_error(L, "SURFACE_UNIQUE_FRAME_COUNT: widget is not a GPUVideoSurface");
    }

    lua_pushinteger(L, gpu_surface->uniqueFrameCount());
    return 1;
}

// EMP.SURFACE_FRAME_SIZE(surface_widget) -> width, height
// Returns current frame dimensions. 0,0 after clearFrame (gap), non-zero after setFrame.
// Used by integration tests to verify gap rendering.
static int lua_emp_surface_frame_size(lua_State* L) {
    QWidget* qwidget = static_cast<QWidget*>(lua_to_widget(L, 1));
    if (!qwidget) return luaL_error(L, "SURFACE_FRAME_SIZE: widget is null or destroyed");

    GPUVideoSurface* gpu_surface = qobject_cast<GPUVideoSurface*>(qwidget);
    if (!gpu_surface) {
        return luaL_error(L, "SURFACE_FRAME_SIZE: widget is not a GPUVideoSurface");
    }

    lua_pushinteger(L, gpu_surface->frameWidth());
    lua_pushinteger(L, gpu_surface->frameHeight());
    return 2;
}

// EMP.SURFACE_ON_READY(surface_widget, callback_fn)
// Registers a callback that fires once when the GPUVideoSurface's Metal backend
// becomes render-ready. If already ready, fires immediately.
static int lua_emp_surface_on_ready(lua_State* L) {
    QWidget* qwidget = static_cast<QWidget*>(lua_to_widget(L, 1));
    if (!qwidget) return luaL_error(L, "EMP.SURFACE_ON_READY: widget is null or destroyed");

    GPUVideoSurface* gpu_surface = qobject_cast<GPUVideoSurface*>(qwidget);
    if (!gpu_surface) {
        return luaL_error(L, "EMP.SURFACE_ON_READY: widget is not a GPUVideoSurface");
    }

    luaL_checktype(L, 2, LUA_TFUNCTION);

    lua_pushvalue(L, 2);
    int ref = luaL_ref(L, LUA_REGISTRYINDEX);
    lua_State* main_L = L;

    // One-shot: unref after firing so the registry entry doesn't leak for
    // the lifetime of the surface. (If the surface is destroyed before it
    // becomes ready, the ref is unreachable — bounded one-per-call leak.)
    gpu_surface->setReadyCallback([main_L, ref]() {
        lua_rawgeti(main_L, LUA_REGISTRYINDEX, ref);
        if (lua_isfunction(main_L, -1)) {
            JveLuaStateGuard guard(main_L);
            if (lua_pcall(main_L, 0, 0, 0) != 0) {
                jve_handle_lua_callback_error(main_L, "emp.surface_on_ready");
            }
        } else {
            jve_discard_non_function_handler(main_L, "<registry ref>", "emp.surface_on_ready");
        }
        luaL_unref(main_L, LUA_REGISTRYINDEX, ref);
    });

    return 0;
}

// EMP.SURFACE_ON_ERROR(surface_widget, callback_fn)
// Registers a callback that fires when GPUVideoSurface can't render a frame
// (unsupported pixel format, texture creation failure, etc.).
// Callback receives one string argument: the error description.
static int lua_emp_surface_on_error(lua_State* L) {
    QWidget* qwidget = static_cast<QWidget*>(lua_to_widget(L, 1));
    if (!qwidget) return luaL_error(L, "EMP.SURFACE_ON_ERROR: widget is null or destroyed");

    GPUVideoSurface* gpu_surface = qobject_cast<GPUVideoSurface*>(qwidget);
    if (!gpu_surface) {
        return luaL_error(L, "EMP.SURFACE_ON_ERROR: widget is not a GPUVideoSurface");
    }

    luaL_checktype(L, 2, LUA_TFUNCTION);

    lua_pushvalue(L, 2);
    int ref = luaL_ref(L, LUA_REGISTRYINDEX);
    replace_cb_ref(L, g_surface_error_refs, gpu_surface, ref);
    lua_State* main_L = L;

    gpu_surface->setErrorCallback([main_L, ref](const std::string& error) {
        lua_rawgeti(main_L, LUA_REGISTRYINDEX, ref);
        if (lua_isfunction(main_L, -1)) {
            lua_pushstring(main_L, error.c_str());
            JveLuaStateGuard guard(main_L);
            if (lua_pcall(main_L, 1, 0, 0) != 0) {
                jve_handle_lua_callback_error(main_L, "emp.surface_on_error");
            }
        } else {
            jve_discard_non_function_handler(main_L, "<registry ref>", "emp.surface_on_error");
        }
    });

    return 0;
}

// EMP.SURFACE_SET_GRADE(surface_widget, grade_table|nil)
// Push the View-pulled CDL params to the surface's color stage (spec
// 023 T032 / FR-016). grade_table is `{slope_r, slope_g, slope_b,
// offset_r, offset_g, offset_b, power_r, power_g, power_b, saturation}`
// matching the `clip_grade.cdl` shape. nil clears (surface displays
// ungraded). Validation: every field is luaL_checknumber. Works with
// both GPUVideoSurface and CPUVideoSurface.
static int lua_emp_surface_set_grade(lua_State* L) {
    QWidget* qwidget = static_cast<QWidget*>(lua_to_widget(L, 1));
    if (!qwidget) return luaL_error(L,
        "EMP.SURFACE_SET_GRADE: widget is null or destroyed");

    GPUVideoSurface* gpu_surface = qobject_cast<GPUVideoSurface*>(qwidget);
    CPUVideoSurface* cpu_surface = qobject_cast<CPUVideoSurface*>(qwidget);
    if (!gpu_surface && !cpu_surface) {
        return luaL_error(L,
            "EMP.SURFACE_SET_GRADE: widget is not a video surface (GPU or CPU)");
    }

    // nil ⇒ clear (passthrough display)
    if (lua_isnil(L, 2)) {
        if (gpu_surface) gpu_surface->clearGrade();
        if (cpu_surface) cpu_surface->clearGrade();
        return 0;
    }

    luaL_checktype(L, 2, LUA_TTABLE);
    emp::CdlParams cdl{};
    auto get_num = [&](const char* key) -> float {
        lua_getfield(L, 2, key);
        if (!lua_isnumber(L, -1)) {
            lua_pop(L, 1);
            luaL_error(L, "EMP.SURFACE_SET_GRADE: cdl.%s must be number", key);
        }
        float v = static_cast<float>(lua_tonumber(L, -1));
        lua_pop(L, 1);
        return v;
    };
    cdl.slope[0]  = get_num("slope_r");
    cdl.slope[1]  = get_num("slope_g");
    cdl.slope[2]  = get_num("slope_b");
    cdl.offset[0] = get_num("offset_r");
    cdl.offset[1] = get_num("offset_g");
    cdl.offset[2] = get_num("offset_b");
    cdl.power[0]  = get_num("power_r");
    cdl.power[1]  = get_num("power_g");
    cdl.power[2]  = get_num("power_b");
    cdl.saturation = get_num("saturation");
    cdl.enabled = 1;

    if (gpu_surface) gpu_surface->setGrade(cdl);
    if (cpu_surface) cpu_surface->setGrade(cdl);
    return 0;
}

// EMP.SURFACE_SET_FRAME(surface_widget, frame|nil)
// Works with both GPUVideoSurface and CPUVideoSurface
static int lua_emp_surface_set_frame(lua_State* L) {
    QWidget* qwidget = static_cast<QWidget*>(lua_to_widget(L, 1));
    if (!qwidget) return luaL_error(L, "EMP.SURFACE_SET_FRAME: widget is null or destroyed");

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

// ============================================================================
// PlaybackController bindings
// ============================================================================

// Helper: get PlaybackController from Lua arg or error
static PlaybackController* get_playback_controller(lua_State* L, int idx) {
    void* key = get_map_key(L, idx, PLAYBACK_CONTROLLER_METATABLE);
    auto it = g_playback_controllers.find(key);
    if (it == g_playback_controllers.end()) {
        luaL_error(L, "PLAYBACK: invalid controller handle");
        return nullptr;
    }
    return it->second.get();
}

// PLAYBACK.CREATE() -> controller
static int lua_playback_create(lua_State* L) {
    auto controller = PlaybackController::Create();
    if (!controller) {
        return luaL_error(L, "PLAYBACK.CREATE: PlaybackController not available on this platform");
    }

    void** ud = static_cast<void**>(lua_newuserdata(L, sizeof(void*)));
    *ud = controller.get();
    luaL_getmetatable(L, PLAYBACK_CONTROLLER_METATABLE);
    lua_setmetatable(L, -2);

    void* key = static_cast<void*>(ud);
    g_playback_controllers[key] = std::move(controller);
    return 1;
}

// Unref every Lua callback ref this controller is holding, then drop the
// controller from the owning map. Called from both PLAYBACK.CLOSE (explicit
// teardown) and __gc (Lua-side userdata collected). Idempotent: the controller
// may already be gone if CLOSE ran before __gc.
static void release_playback_controller(lua_State* L, void* key) {
    auto it = g_playback_controllers.find(key);
    if (it == g_playback_controllers.end()) return;
    PlaybackController* pc = it->second.get();
    replace_cb_ref(L, g_position_cb_refs,    pc, LUA_NOREF);
    replace_cb_ref(L, g_clip_provider_refs,  pc, LUA_NOREF);
    replace_cb_ref(L, g_clip_transition_refs, pc, LUA_NOREF);
    g_playback_controllers.erase(it);
}

// PLAYBACK.CLOSE(controller)
static int lua_playback_close(lua_State* L) {
    void* key = get_map_key(L, 1, PLAYBACK_CONTROLLER_METATABLE);
    release_playback_controller(L, key);
    return 0;
}

// PLAYBACK __gc metamethod
static int lua_playback_gc(lua_State* L) {
    void* key = get_map_key(L, 1, PLAYBACK_CONTROLLER_METATABLE);
    release_playback_controller(L, key);
    return 0;
}

// PLAYBACK.SET_SURFACE(controller, surface_widget)
static int lua_playback_set_surface(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);

    QWidget* qwidget = static_cast<QWidget*>(lua_to_widget(L, 2));
    if (!qwidget) return luaL_error(L, "PLAYBACK.SET_SURFACE: widget is null or destroyed");
    GPUVideoSurface* surface = qobject_cast<GPUVideoSurface*>(qwidget);
    if (!surface) {
        return luaL_error(L, "PLAYBACK.SET_SURFACE: widget is not a GPUVideoSurface");
    }

    controller->SetSurface(surface);
    return 0;
}

// PLAYBACK.SET_MIRROR_SURFACE(controller, surface_widget)
static int lua_playback_set_mirror_surface(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);

    QWidget* qwidget = static_cast<QWidget*>(lua_to_widget(L, 2));
    if (!qwidget) return luaL_error(L, "PLAYBACK.SET_MIRROR_SURFACE: widget is null or destroyed");
    GPUVideoSurface* surface = qobject_cast<GPUVideoSurface*>(qwidget);
    if (!surface) {
        return luaL_error(L, "PLAYBACK.SET_MIRROR_SURFACE: widget is not a GPUVideoSurface");
    }

    controller->SetMirrorSurface(surface);
    return 0;
}

// PLAYBACK.CLEAR_MIRROR_SURFACE(controller)
static int lua_playback_clear_mirror_surface(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);
    controller->ClearMirrorSurface();
    return 0;
}

// PLAYBACK.SET_TMB(controller, tmb)
static int lua_playback_set_tmb(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);
    auto tmb = get_tmb(L, 2);
    controller->SetTMB(tmb.get());
    return 0;
}

// PLAYBACK.SET_BOUNDS(controller, start_frame, end_frame, fps_num, fps_den)
static int lua_playback_set_bounds(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);
    int64_t start_frame = static_cast<int64_t>(luaL_checkinteger(L, 2));
    int64_t end_frame = static_cast<int64_t>(luaL_checkinteger(L, 3));
    int32_t fps_num = static_cast<int32_t>(luaL_checkinteger(L, 4));
    int32_t fps_den = static_cast<int32_t>(luaL_checkinteger(L, 5));
    controller->SetBounds(start_frame, end_frame, fps_num, fps_den);
    return 0;
}

// PLAYBACK.PLAY(controller, direction, speed)
static int lua_playback_play(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);
    int direction = static_cast<int>(luaL_checkinteger(L, 2));
    float speed = static_cast<float>(luaL_checknumber(L, 3));
    controller->Play(direction, speed);
    return 0;
}

// PLAYBACK.STOP(controller)
static int lua_playback_stop(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);
    controller->Stop();
    return 0;
}

// PLAYBACK.PARK(controller, frame) — position + TMB prime only, no display
static int lua_playback_park(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);
    int64_t frame = static_cast<int64_t>(luaL_checkinteger(L, 2));
    controller->Park(frame);
    return 0;
}

// PLAYBACK.SEEK(controller, frame) — Park + deliverFrame (C++ push)
static int lua_playback_seek(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);
    int64_t frame = static_cast<int64_t>(luaL_checkinteger(L, 2));
    controller->Seek(frame);
    return 0;
}

// PLAYBACK.TICK(controller) — manual display link tick for integration tests.
// Call when CVDisplayLink is unavailable (headless/CLI). Follow with
// CONTROL.PROCESS_EVENTS() to drain GCD main queue for frame delivery.
static int lua_playback_tick(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);
    controller->Tick();
    return 0;
}

// PLAYBACK.SET_SHUTTLE_MODE(controller, enabled)
static int lua_playback_set_shuttle_mode(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);
    bool enabled = lua_toboolean(L, 2) != 0;
    controller->SetShuttleMode(enabled);
    return 0;
}

// PLAYBACK.HIT_BOUNDARY(controller) -> boolean
static int lua_playback_hit_boundary(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);
    lua_pushboolean(L, controller->HitBoundary() ? 1 : 0);
    return 1;
}

// PLAYBACK.CURRENT_FRAME(controller) -> integer
static int lua_playback_current_frame(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);
    lua_pushinteger(L, static_cast<lua_Integer>(controller->CurrentFrame()));
    return 1;
}

// PLAYBACK.IS_PLAYING(controller) -> boolean
static int lua_playback_is_playing(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);
    lua_pushboolean(L, controller->IsPlaying() ? 1 : 0);
    return 1;
}

// PLAYBACK.SET_POSITION_CALLBACK(controller, callback_function)
// The callback receives (frame, stopped_boolean)
static int lua_playback_set_position_callback(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);

    if (lua_isnil(L, 2)) {
        replace_cb_ref(L, g_position_cb_refs, controller, LUA_NOREF);
        controller->SetPositionCallback(nullptr);
        return 0;
    }

    luaL_checktype(L, 2, LUA_TFUNCTION);

    lua_pushvalue(L, 2);
    int ref = luaL_ref(L, LUA_REGISTRYINDEX);
    replace_cb_ref(L, g_position_cb_refs, controller, ref);
    lua_State* main_L = L;

    controller->SetPositionCallback([main_L, ref](int64_t frame, bool stopped) {
        // This callback is called from the main thread (via dispatch_async)
        lua_rawgeti(main_L, LUA_REGISTRYINDEX, ref);
        if (lua_isfunction(main_L, -1)) {
            lua_pushinteger(main_L, static_cast<lua_Integer>(frame));
            lua_pushboolean(main_L, stopped ? 1 : 0);
            JveLuaStateGuard guard(main_L);
            if (lua_pcall(main_L, 2, 0, 0) != 0) {
                jve_handle_lua_callback_error(main_L, "emp.position_callback");
            }
        } else {
            jve_discard_non_function_handler(main_L, "<registry ref>", "emp.position_callback");
        }
    });

    return 0;
}

// PLAYBACK.SET_CLIP_PROVIDER(controller, callback_function)
// The callback receives (from_frame, to_frame, track_type_string)
static int lua_playback_set_clip_provider(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);

    if (lua_isnil(L, 2)) {
        replace_cb_ref(L, g_clip_provider_refs, controller, LUA_NOREF);
        controller->SetClipProvider(nullptr);
        return 0;
    }

    luaL_checktype(L, 2, LUA_TFUNCTION);

    lua_pushvalue(L, 2);
    int ref = luaL_ref(L, LUA_REGISTRYINDEX);
    replace_cb_ref(L, g_clip_provider_refs, controller, ref);
    lua_State* main_L = L;

    controller->SetClipProvider([main_L, ref](int64_t from, int64_t to, emp::TrackType type) {
        lua_rawgeti(main_L, LUA_REGISTRYINDEX, ref);
        if (lua_isfunction(main_L, -1)) {
            lua_pushinteger(main_L, static_cast<lua_Integer>(from));
            lua_pushinteger(main_L, static_cast<lua_Integer>(to));
            lua_pushstring(main_L, type == emp::TrackType::Video ? "video" : "audio");
            JveLuaStateGuard guard(main_L);
            if (lua_pcall(main_L, 3, 0, 0) != 0) {
                jve_handle_lua_callback_error(main_L, "emp.clip_provider");
            }
        } else {
            jve_discard_non_function_handler(main_L, "<registry ref>", "emp.clip_provider");
        }
    });

    return 0;
}

// PLAYBACK.RELOAD_ALL_CLIPS(controller)
static int lua_playback_reload_all_clips(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);
    controller->reloadAllClips();
    return 0;
}

// PLAYBACK.ACTIVATE_AUDIO(controller, aop, sse, sample_rate, channels)
static int lua_playback_activate_audio(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);
    aop::AudioOutput* aop = get_aop_userdata(L, 2);
    if (!aop) {
        return luaL_error(L, "PLAYBACK.ACTIVATE_AUDIO: invalid aop handle");
    }
    sse::ScrubStretchEngine* sse = get_sse_userdata(L, 3);
    if (!sse) {
        return luaL_error(L, "PLAYBACK.ACTIVATE_AUDIO: invalid sse handle");
    }
    int32_t sample_rate = static_cast<int32_t>(luaL_checkinteger(L, 4));
    int32_t channels = static_cast<int32_t>(luaL_checkinteger(L, 5));

    controller->ActivateAudio(aop, sse, sample_rate, channels);
    return 0;
}

// PLAYBACK.DEACTIVATE_AUDIO(controller)
static int lua_playback_deactivate_audio(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);
    controller->DeactivateAudio();
    return 0;
}

// 017 / FR-022: PLAYBACK.SET_LOG_TAG(controller, tag)
// Pure FFI wrapper — parameter validation only. The C++ controller stores
// the string and prefixes every JVE_LOG_*(Ticks, ...) line it emits, so
// log streams from source-engine and record-engine are disambiguable.
static int lua_playback_set_log_tag(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);
    if (!lua_isstring(L, 2)) {
        return luaL_error(L, "PLAYBACK.SET_LOG_TAG: tag must be a string");
    }
    size_t len = 0;
    const char* tag = lua_tolstring(L, 2, &len);
    controller->SetLogTag(std::string(tag, len));
    return 0;
}

// PLAYBACK.SET_SPEED(controller, signed_speed)
static int lua_playback_set_speed(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);
    float speed = static_cast<float>(luaL_checknumber(L, 2));
    controller->SetSpeed(speed);
    return 0;
}

// PLAYBACK.PLAY_BURST(controller, frame, direction, duration_ms)
static int lua_playback_play_burst(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);
    int64_t frame = static_cast<int64_t>(luaL_checkinteger(L, 2));
    int direction = static_cast<int>(luaL_checkinteger(L, 3));
    int duration_ms = static_cast<int>(luaL_checkinteger(L, 4));
    controller->PlayBurst(frame, direction, duration_ms);
    return 0;
}

// PLAYBACK.HAS_AUDIO(controller) -> boolean
static int lua_playback_has_audio(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);
    lua_pushboolean(L, controller->HasAudio() ? 1 : 0);
    return 1;
}

// PLAYBACK.SET_CLIP_TRANSITION_CALLBACK(controller, callback_function)
// The callback receives (clip_id, rotation, par_num, par_den, is_offline, media_path, frame)
static int lua_playback_set_clip_transition_callback(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);

    if (lua_isnil(L, 2)) {
        replace_cb_ref(L, g_clip_transition_refs, controller, LUA_NOREF);
        controller->SetClipTransitionCallback(nullptr);
        return 0;
    }

    luaL_checktype(L, 2, LUA_TFUNCTION);

    lua_pushvalue(L, 2);
    int ref = luaL_ref(L, LUA_REGISTRYINDEX);
    replace_cb_ref(L, g_clip_transition_refs, controller, ref);
    lua_State* main_L = L;

    controller->SetClipTransitionCallback([main_L, ref](
        const std::string& clip_id, int rotation, int par_num, int par_den,
        bool offline, const std::string& media_path, int64_t frame) {
        lua_rawgeti(main_L, LUA_REGISTRYINDEX, ref);
        if (lua_isfunction(main_L, -1)) {
            lua_pushstring(main_L, clip_id.c_str());
            lua_pushinteger(main_L, rotation);
            lua_pushinteger(main_L, par_num);
            lua_pushinteger(main_L, par_den);
            lua_pushboolean(main_L, offline ? 1 : 0);
            lua_pushstring(main_L, media_path.c_str());
            lua_pushinteger(main_L, static_cast<lua_Integer>(frame));
            JveLuaStateGuard guard(main_L);
            if (lua_pcall(main_L, 7, 0, 0) != 0) {
                jve_handle_lua_callback_error(main_L, "emp.clip_transition");
            }
        } else {
            jve_discard_non_function_handler(main_L, "<registry ref>", "emp.clip_transition");
        }
    });

    return 0;
}

// PLAYBACK.GET_DIAG_SUMMARY(controller) -> table
// Returns diagnostic ring buffer summary after Stop(). Rings survive until next Play().
static int lua_playback_get_diag_summary(lua_State* L) {
    auto* controller = get_playback_controller(L, 1);
    auto s = controller->GetDiagSummary();

    lua_createtable(L, 0, 14);

    lua_pushinteger(L, static_cast<lua_Integer>(s.tick_count));
    lua_setfield(L, -2, "tick_count");

    lua_pushnumber(L, s.cadence_p50_ms);
    lua_setfield(L, -2, "cadence_p50_ms");
    lua_pushnumber(L, s.cadence_p95_ms);
    lua_setfield(L, -2, "cadence_p95_ms");
    lua_pushnumber(L, s.cadence_p99_ms);
    lua_setfield(L, -2, "cadence_p99_ms");

    lua_pushnumber(L, s.drift_p50_s);
    lua_setfield(L, -2, "drift_p50_s");
    lua_pushnumber(L, s.drift_p95_s);
    lua_setfield(L, -2, "drift_p95_s");
    lua_pushnumber(L, s.drift_p99_s);
    lua_setfield(L, -2, "drift_p99_s");

    lua_pushinteger(L, static_cast<lua_Integer>(s.skip_count));
    lua_setfield(L, -2, "skip_count");
    lua_pushinteger(L, static_cast<lua_Integer>(s.hold_count));
    lua_setfield(L, -2, "hold_count");
    lua_pushinteger(L, static_cast<lua_Integer>(s.repeat_count));
    lua_setfield(L, -2, "repeat_count");
    lua_pushinteger(L, static_cast<lua_Integer>(s.gap_count));
    lua_setfield(L, -2, "gap_count");
    lua_pushinteger(L, static_cast<lua_Integer>(s.dropped_count));
    lua_setfield(L, -2, "dropped_count");
    lua_pushinteger(L, static_cast<lua_Integer>(s.backward_jumps));
    lua_setfield(L, -2, "backward_jumps");

    lua_pushboolean(L, s.audio_master_engaged ? 1 : 0);
    lua_setfield(L, -2, "audio_master_engaged");

    return 1;
}

// ============================================================================
// Background codec probe worker
// ============================================================================

} // end anonymous namespace (temporarily) for g_codec_probe_worker linkage

CodecProbeWorker g_codec_probe_worker;

namespace { // resume anonymous namespace

// EMP.CODEC_PROBE_START(paths_table, callback)
// paths_table: array of file path strings
// callback: function(results_table, is_final)
//   results_table: { [path] = { offline=bool, error_code=string|nil } }
//   is_final: true when all paths have been probed
static int lua_emp_codec_probe_start(lua_State* L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    luaL_checktype(L, 2, LUA_TFUNCTION);

    // Read paths from table
    std::vector<std::string> paths;
    int n = lua_objlen(L, 1);
    paths.reserve(n);
    for (int i = 1; i <= n; ++i) {
        lua_rawgeti(L, 1, i);
        if (lua_isstring(L, -1)) {
            paths.emplace_back(lua_tostring(L, -1));
        }
        lua_pop(L, 1);
    }

    if (paths.empty()) return 0;

    // Store callback ref
    lua_pushvalue(L, 2);
    int callback_ref = luaL_ref(L, LUA_REGISTRYINDEX);

    g_codec_probe_worker.start(std::move(paths),
        [L, callback_ref](const std::vector<CodecProbeResult>& batch, bool is_final) {
            // This runs on main thread (via QTimer::singleShot)
            lua_rawgeti(L, LUA_REGISTRYINDEX, callback_ref);

            // Build results table: { [path] = { offline=bool, error_code=string|nil } }
            lua_newtable(L);
            for (const auto& r : batch) {
                lua_newtable(L);
                lua_pushboolean(L, r.offline);
                lua_setfield(L, -2, "offline");
                if (!r.error_code.empty()) {
                    lua_pushstring(L, r.error_code.c_str());
                } else {
                    lua_pushnil(L);
                }
                lua_setfield(L, -2, "error_code");
                lua_setfield(L, -2, r.path.c_str());
            }

            lua_pushboolean(L, is_final);

            if (lua_pcall(L, 2, 0, 0) != LUA_OK) {
                jve_handle_lua_callback_error(L, "emp.codec_probe_batch");
            }
            // Drain does not unwind — release the ref on both success and
            // error paths when this is the final batch.
            if (is_final) {
                luaL_unref(L, LUA_REGISTRYINDEX, callback_ref);
            }
        });

    return 0;
}

// EMP.CODEC_PROBE_CANCEL()
static int lua_emp_codec_probe_cancel(lua_State*) {
    g_codec_probe_worker.cancel();
    return 0;
}

} // anonymous namespace

// ============================================================================
// Peak Generator + Peak File bindings
// ============================================================================

static emp::PeakGenerator* s_peak_generator = nullptr;

static emp::PeakGenerator* get_peak_generator() {
    if (!s_peak_generator) {
        s_peak_generator = new emp::PeakGenerator();
    }
    return s_peak_generator;
}

// EMP.PEAK_REQUEST(media_id, media_path, output_path) -> nil
static int lua_emp_peak_request(lua_State* L) {
    const char* media_id = luaL_checkstring(L, 1);
    const char* media_path = luaL_checkstring(L, 2);
    const char* output_path = luaL_checkstring(L, 3);
    get_peak_generator()->RequestPeaks(media_id, media_path, output_path);
    return 0;
}

// EMP.PEAK_CANCEL(media_id) -> nil
static int lua_emp_peak_cancel(lua_State* L) {
    const char* media_id = luaL_checkstring(L, 1);
    get_peak_generator()->CancelPeaks(media_id);
    return 0;
}

// EMP.PEAK_CANCEL_ALL() -> nil
static int lua_emp_peak_cancel_all(lua_State* L) {
    (void)L;
    if (s_peak_generator) {
        s_peak_generator->CancelAll();
    }
    return 0;
}

// EMP.PEAK_RUNNING_COUNT() -> int — jobs currently holding media resources.
static int lua_emp_peak_running_count(lua_State* L) {
    int n = s_peak_generator ? s_peak_generator->GetRunningCount() : 0;
    lua_pushinteger(L, n);
    return 1;
}

// EMP.PEAK_MAX_RUNNING() -> int — admission cap (constant).
static int lua_emp_peak_max_running(lua_State* L) {
    lua_pushinteger(L, emp::PeakGenerator::MAX_RUNNING_JOBS);
    return 1;
}

// EMP.PEAK_STATUS(media_id) -> {state, progress_samples, total_samples} | nil
static int lua_emp_peak_status(lua_State* L) {
    const char* media_id = luaL_checkstring(L, 1);
    if (!s_peak_generator) {
        lua_pushnil(L);
        return 1;
    }
    auto status = s_peak_generator->GetStatus(media_id);
    if (status.state == emp::PeakGenerator::JobStatus::None) {
        lua_pushnil(L);
        return 1;
    }
    lua_newtable(L);
    const char* state_str = "none";
    switch (status.state) {
        case emp::PeakGenerator::JobStatus::Queued:   state_str = "queued"; break;
        case emp::PeakGenerator::JobStatus::Running:  state_str = "generating"; break;
        case emp::PeakGenerator::JobStatus::Complete: state_str = "complete"; break;
        case emp::PeakGenerator::JobStatus::Failed:   state_str = "failed"; break;
        default: break;
    }
    lua_pushstring(L, state_str);
    lua_setfield(L, -2, "state");
    lua_pushinteger(L, static_cast<lua_Integer>(status.progress_samples));
    lua_setfield(L, -2, "progress_samples");
    lua_pushinteger(L, static_cast<lua_Integer>(status.total_samples));
    lua_setfield(L, -2, "total_samples");
    return 1;
}

// Peak file reader handles
static const char* EMP_PEAK_METATABLE = "emp_peak";
static std::unordered_map<void*, std::unique_ptr<emp::PeakFileReader>> g_peak_readers;

// EMP.PEAK_LOAD(file_path) -> peak_handle | nil, err
static int lua_emp_peak_load(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    auto reader = emp::PeakFileReader::Open(path);
    if (!reader) {
        lua_pushnil(L);
        lua_pushstring(L, "failed to open peak file");
        return 2;
    }

    void* ud = lua_newuserdata(L, sizeof(void*));
    luaL_getmetatable(L, EMP_PEAK_METATABLE);
    lua_setmetatable(L, -2);

    g_peak_readers[ud] = std::move(reader);
    return 1;
}

// EMP.PEAK_QUERY(peak_handle, start_sample, end_sample, pixel_width)
//   -> peaks_ptr, count, actual_start_sample, actual_end_sample
//   or nil, 0, 0, 0 on failure
static int lua_emp_peak_query(lua_State* L) {
    void* key = luaL_checkudata(L, 1, EMP_PEAK_METATABLE);
    auto it = g_peak_readers.find(key);
    if (it == g_peak_readers.end()) {
        return luaL_error(L, "EMP.PEAK_QUERY: invalid peak handle");
    }

    int64_t start = static_cast<int64_t>(luaL_checkinteger(L, 2));
    int64_t end = static_cast<int64_t>(luaL_checkinteger(L, 3));
    int pixel_width = static_cast<int>(luaL_checkinteger(L, 4));

    auto result = it->second->Query(start, end, pixel_width);

    if (!result.peaks || result.count <= 0) {
        lua_pushnil(L);
        lua_pushinteger(L, 0);
        lua_pushinteger(L, 0);
        lua_pushinteger(L, 0);
        return 4;
    }

    lua_pushlightuserdata(L, const_cast<float*>(result.peaks));
    lua_pushinteger(L, result.count);
    lua_pushinteger(L, static_cast<lua_Integer>(result.actual_start));
    lua_pushinteger(L, static_cast<lua_Integer>(result.actual_end));
    return 4;
}

// EMP.PEAK_QUERY_PROGRESS(media_id, start_sample, end_sample, pixel_width)
//   -> lightuserdata(float*), count, actual_start_sample, actual_end_sample
//   or nil, 0, 0, 0 if no in-progress data
//
// Queries partially-generated peak data for progressive waveform display.
// The returned pointer is valid until the next call to PEAK_QUERY_PROGRESS.
static emp::PeakGenerator::ProgressQueryResult s_progress_result;

static int lua_emp_peak_query_progress(lua_State* L) {
    const char* media_id = luaL_checkstring(L, 1);
    int64_t start = static_cast<int64_t>(luaL_checkinteger(L, 2));
    int64_t end_sample = static_cast<int64_t>(luaL_checkinteger(L, 3));
    int pixel_width = static_cast<int>(luaL_checkinteger(L, 4));

    if (!s_peak_generator) {
        lua_pushnil(L);
        lua_pushinteger(L, 0);
        lua_pushinteger(L, 0);
        lua_pushinteger(L, 0);
        return 4;
    }

    s_progress_result = s_peak_generator->QueryInProgress(
        media_id, start, end_sample, pixel_width);

    if (s_progress_result.count <= 0 || s_progress_result.peaks.empty()) {
        lua_pushnil(L);
        lua_pushinteger(L, 0);
        lua_pushinteger(L, 0);
        lua_pushinteger(L, 0);
        return 4;
    }

    lua_pushlightuserdata(L, s_progress_result.peaks.data());
    lua_pushinteger(L, s_progress_result.count);
    lua_pushinteger(L, static_cast<lua_Integer>(s_progress_result.actual_start));
    lua_pushinteger(L, static_cast<lua_Integer>(s_progress_result.actual_end));
    return 4;
}

// EMP.PEAK_HEADER(peak_handle) -> table
static int lua_emp_peak_header(lua_State* L) {
    void* key = luaL_checkudata(L, 1, EMP_PEAK_METATABLE);
    auto it = g_peak_readers.find(key);
    if (it == g_peak_readers.end()) {
        return luaL_error(L, "EMP.PEAK_HEADER: invalid peak handle");
    }

    const auto& hdr = it->second->header();
    lua_newtable(L);
    lua_pushinteger(L, hdr.version);
    lua_setfield(L, -2, "version");
    lua_pushinteger(L, static_cast<lua_Integer>(hdr.source_mtime));
    lua_setfield(L, -2, "source_mtime");
    lua_pushinteger(L, hdr.sample_rate);
    lua_setfield(L, -2, "sample_rate");
    lua_pushinteger(L, hdr.channels);
    lua_setfield(L, -2, "channels");
    lua_pushinteger(L, hdr.base_spp);
    lua_setfield(L, -2, "base_spp");
    lua_pushinteger(L, hdr.num_levels);
    lua_setfield(L, -2, "num_levels");

    lua_newtable(L);
    for (int i = 0; i < emp::MIPMAP_LEVELS; ++i) {
        lua_pushinteger(L, static_cast<lua_Integer>(hdr.bins_per_level[i]));
        lua_rawseti(L, -2, i + 1);
    }
    lua_setfield(L, -2, "bins_per_level");

    return 1;
}

// EMP.PEAK_RELEASE(peak_handle) -> nil
static int lua_emp_peak_release(lua_State* L) {
    void* key = luaL_checkudata(L, 1, EMP_PEAK_METATABLE);
    g_peak_readers.erase(key);
    return 0;
}

// Peak handle __gc
static int lua_emp_peak_gc(lua_State* L) {
    void* key = luaL_checkudata(L, 1, EMP_PEAK_METATABLE);
    g_peak_readers.erase(key);
    return 0;
}

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

    luaL_newmetatable(L, PLAYBACK_CONTROLLER_METATABLE);
    lua_pushcfunction(L, lua_playback_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);

    luaL_newmetatable(L, EMP_PEAK_METATABLE);
    lua_pushcfunction(L, lua_emp_peak_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);

    // Create EMP subtable in qt_constants
    // Assumes qt_constants is on stack at index -1
    lua_newtable(L);

    // BRAW SDK availability
    lua_pushcfunction(L, [](lua_State* L) -> int {
        lua_pushboolean(L, emp::impl::braw_sdk_available());
        return 1;
    });
    lua_setfield(L, -2, "BRAW_SUPPORTED");

    // MediaFile functions
    lua_pushcfunction(L, lua_emp_media_file_open);
    lua_setfield(L, -2, "MEDIA_FILE_OPEN");
    lua_pushcfunction(L, lua_emp_media_file_close);
    lua_setfield(L, -2, "MEDIA_FILE_CLOSE");
    lua_pushcfunction(L, lua_emp_media_file_info);
    lua_setfield(L, -2, "MEDIA_FILE_INFO");
    lua_pushcfunction(L, lua_emp_media_file_set_tc_origin_override);
    lua_setfield(L, -2, "MEDIA_FILE_SET_TC_ORIGIN_OVERRIDE");
    lua_pushcfunction(L, lua_emp_media_probe);
    lua_setfield(L, -2, "MEDIA_PROBE");
    lua_pushcfunction(L, lua_emp_media_probe_batch);
    lua_setfield(L, -2, "MEDIA_PROBE_BATCH");

    // Reader functions
    lua_pushcfunction(L, lua_emp_reader_create);
    lua_setfield(L, -2, "READER_CREATE");
    lua_pushcfunction(L, lua_emp_reader_create_audio_only);
    lua_setfield(L, -2, "READER_CREATE_AUDIO_ONLY");
    lua_pushcfunction(L, lua_emp_reader_has_video_codec);
    lua_setfield(L, -2, "READER_HAS_VIDEO_CODEC");
    lua_pushcfunction(L, lua_emp_reader_close);
    lua_setfield(L, -2, "READER_CLOSE");
    lua_pushcfunction(L, lua_emp_reader_seek_frame);
    lua_setfield(L, -2, "READER_SEEK_FRAME");
    lua_pushcfunction(L, lua_emp_reader_decode_frame);
    lua_setfield(L, -2, "READER_DECODE_FRAME");

    // Decode mode
    lua_pushcfunction(L, lua_emp_set_decode_mode);
    lua_setfield(L, -2, "SET_DECODE_MODE");

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
    lua_pushcfunction(L, lua_emp_tmb_set_tc_overrides);
    lua_setfield(L, -2, "TMB_SET_TC_OVERRIDES");
    lua_pushcfunction(L, lua_emp_tmb_set_sequence_rate);
    lua_setfield(L, -2, "TMB_SET_SEQUENCE_RATE");
    lua_pushcfunction(L, lua_emp_tmb_set_sequence_resolution);
    lua_setfield(L, -2, "TMB_SET_SEQUENCE_RESOLUTION");
    lua_pushcfunction(L, lua_emp_tmb_set_audio_format);
    lua_setfield(L, -2, "TMB_SET_AUDIO_FORMAT");
    lua_pushcfunction(L, lua_emp_tmb_set_track_clips);
    lua_setfield(L, -2, "TMB_SET_TRACK_CLIPS");
    lua_pushcfunction(L, lua_emp_tmb_add_clips);
    lua_setfield(L, -2, "TMB_ADD_CLIPS");
    lua_pushcfunction(L, lua_emp_tmb_clear_all_clips);
    lua_setfield(L, -2, "TMB_CLEAR_ALL_CLIPS");
    lua_pushcfunction(L, lua_emp_tmb_clear_offline);
    lua_setfield(L, -2, "TMB_CLEAR_OFFLINE");
    lua_pushcfunction(L, lua_emp_tmb_invalidate_path);
    lua_setfield(L, -2, "TMB_INVALIDATE_PATH");
    lua_pushcfunction(L, lua_emp_tmb_set_playhead);
    lua_setfield(L, -2, "TMB_SET_PLAYHEAD");
    lua_pushcfunction(L, lua_emp_tmb_get_video_frame);
    lua_setfield(L, -2, "TMB_GET_VIDEO_FRAME");
    lua_pushcfunction(L, lua_emp_tmb_get_track_audio);
    lua_setfield(L, -2, "TMB_GET_TRACK_AUDIO");
    lua_pushcfunction(L, lua_emp_tmb_set_audio_mix_params);
    lua_setfield(L, -2, "TMB_SET_AUDIO_MIX_PARAMS");
    lua_pushcfunction(L, lua_emp_tmb_get_mixed_audio);
    lua_setfield(L, -2, "TMB_GET_MIXED_AUDIO");
    lua_pushcfunction(L, lua_emp_tmb_park_readers);
    lua_setfield(L, -2, "TMB_PARK_READERS");
    lua_pushcfunction(L, lua_emp_tmb_release_track);
    lua_setfield(L, -2, "TMB_RELEASE_TRACK");
    lua_pushcfunction(L, lua_emp_tmb_release_all);
    lua_setfield(L, -2, "TMB_RELEASE_ALL");
    lua_pushcfunction(L, lua_emp_media_file_probe);
    lua_setfield(L, -2, "MEDIA_FILE_PROBE");

    // Surface functions
    lua_pushcfunction(L, lua_emp_surface_set_frame);
    lua_setfield(L, -2, "SURFACE_SET_FRAME");
    lua_pushcfunction(L, lua_emp_surface_set_grade);
    lua_setfield(L, -2, "SURFACE_SET_GRADE");
    lua_pushcfunction(L, lua_emp_surface_set_rotation);
    lua_setfield(L, -2, "SURFACE_SET_ROTATION");
    lua_pushcfunction(L, lua_emp_surface_set_par);
    lua_setfield(L, -2, "SURFACE_SET_PAR");
    lua_pushcfunction(L, lua_emp_surface_frame_count);
    lua_setfield(L, -2, "SURFACE_FRAME_COUNT");
    lua_pushcfunction(L, lua_emp_surface_unique_frame_count);
    lua_setfield(L, -2, "SURFACE_UNIQUE_FRAME_COUNT");
    lua_pushcfunction(L, lua_emp_surface_frame_size);
    lua_setfield(L, -2, "SURFACE_FRAME_SIZE");
    lua_pushcfunction(L, lua_emp_surface_on_ready);
    lua_setfield(L, -2, "SURFACE_ON_READY");
    lua_pushcfunction(L, lua_emp_surface_on_error);
    lua_setfield(L, -2, "SURFACE_ON_ERROR");

    // Codec probe worker
    lua_pushcfunction(L, lua_emp_codec_probe_start);
    lua_setfield(L, -2, "CODEC_PROBE_START");
    lua_pushcfunction(L, lua_emp_codec_probe_cancel);
    lua_setfield(L, -2, "CODEC_PROBE_CANCEL");

    // Peak generator functions
    lua_pushcfunction(L, lua_emp_peak_request);
    lua_setfield(L, -2, "PEAK_REQUEST");
    lua_pushcfunction(L, lua_emp_peak_cancel);
    lua_setfield(L, -2, "PEAK_CANCEL");
    lua_pushcfunction(L, lua_emp_peak_cancel_all);
    lua_setfield(L, -2, "PEAK_CANCEL_ALL");
    lua_pushcfunction(L, lua_emp_peak_status);
    lua_setfield(L, -2, "PEAK_STATUS");
    lua_pushcfunction(L, lua_emp_peak_running_count);
    lua_setfield(L, -2, "PEAK_RUNNING_COUNT");
    lua_pushcfunction(L, lua_emp_peak_max_running);
    lua_setfield(L, -2, "PEAK_MAX_RUNNING");
    lua_pushcfunction(L, lua_emp_peak_query_progress);
    lua_setfield(L, -2, "PEAK_QUERY_PROGRESS");

    // Peak file reader functions
    lua_pushcfunction(L, lua_emp_peak_load);
    lua_setfield(L, -2, "PEAK_LOAD");
    lua_pushcfunction(L, lua_emp_peak_query);
    lua_setfield(L, -2, "PEAK_QUERY");
    lua_pushcfunction(L, lua_emp_peak_header);
    lua_setfield(L, -2, "PEAK_HEADER");
    lua_pushcfunction(L, lua_emp_peak_release);
    lua_setfield(L, -2, "PEAK_RELEASE");

    lua_setfield(L, -2, "EMP");

    // Create PLAYBACK subtable in qt_constants
    lua_newtable(L);
    lua_pushcfunction(L, lua_playback_create);
    lua_setfield(L, -2, "CREATE");
    lua_pushcfunction(L, lua_playback_close);
    lua_setfield(L, -2, "CLOSE");
    lua_pushcfunction(L, lua_playback_set_surface);
    lua_setfield(L, -2, "SET_SURFACE");
    lua_pushcfunction(L, lua_playback_set_mirror_surface);
    lua_setfield(L, -2, "SET_MIRROR_SURFACE");
    lua_pushcfunction(L, lua_playback_clear_mirror_surface);
    lua_setfield(L, -2, "CLEAR_MIRROR_SURFACE");
    lua_pushcfunction(L, lua_playback_set_tmb);
    lua_setfield(L, -2, "SET_TMB");
    lua_pushcfunction(L, lua_playback_set_bounds);
    lua_setfield(L, -2, "SET_BOUNDS");
    lua_pushcfunction(L, lua_playback_play);
    lua_setfield(L, -2, "PLAY");
    lua_pushcfunction(L, lua_playback_stop);
    lua_setfield(L, -2, "STOP");
    lua_pushcfunction(L, lua_playback_park);
    lua_setfield(L, -2, "PARK");
    lua_pushcfunction(L, lua_playback_seek);
    lua_setfield(L, -2, "SEEK");
    lua_pushcfunction(L, lua_playback_tick);
    lua_setfield(L, -2, "TICK");
    lua_pushcfunction(L, lua_playback_set_shuttle_mode);
    lua_setfield(L, -2, "SET_SHUTTLE_MODE");
    lua_pushcfunction(L, lua_playback_hit_boundary);
    lua_setfield(L, -2, "HIT_BOUNDARY");
    lua_pushcfunction(L, lua_playback_current_frame);
    lua_setfield(L, -2, "CURRENT_FRAME");
    lua_pushcfunction(L, lua_playback_is_playing);
    lua_setfield(L, -2, "IS_PLAYING");
    lua_pushcfunction(L, lua_playback_set_position_callback);
    lua_setfield(L, -2, "SET_POSITION_CALLBACK");
    lua_pushcfunction(L, lua_playback_set_clip_provider);
    lua_setfield(L, -2, "SET_CLIP_PROVIDER");
    lua_pushcfunction(L, lua_playback_reload_all_clips);
    lua_setfield(L, -2, "RELOAD_ALL_CLIPS");
    lua_pushcfunction(L, lua_playback_set_clip_transition_callback);
    lua_setfield(L, -2, "SET_CLIP_TRANSITION_CALLBACK");
    lua_pushcfunction(L, lua_playback_activate_audio);
    lua_setfield(L, -2, "ACTIVATE_AUDIO");
    lua_pushcfunction(L, lua_playback_deactivate_audio);
    lua_setfield(L, -2, "DEACTIVATE_AUDIO");
    // 017 / FR-022: per-engine log tag plumbing for [ticks] disambiguation.
    lua_pushcfunction(L, lua_playback_set_log_tag);
    lua_setfield(L, -2, "SET_LOG_TAG");
    lua_pushcfunction(L, lua_playback_set_speed);
    lua_setfield(L, -2, "SET_SPEED");
    lua_pushcfunction(L, lua_playback_play_burst);
    lua_setfield(L, -2, "PLAY_BURST");
    lua_pushcfunction(L, lua_playback_has_audio);
    lua_setfield(L, -2, "HAS_AUDIO");
    lua_pushcfunction(L, lua_playback_get_diag_summary);
    lua_setfield(L, -2, "GET_DIAG_SUMMARY");
    lua_setfield(L, -2, "PLAYBACK");

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
