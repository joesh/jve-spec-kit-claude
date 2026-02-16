// EMP (Editor Media Platform) Lua bindings
// Provides frame-first video decoding for Source Viewer

#include <editor_media_platform/emp_asset.h>
#include <editor_media_platform/emp_reader.h>
#include <editor_media_platform/emp_frame.h>
#include <editor_media_platform/emp_audio.h>
#include <editor_media_platform/emp_errors.h>
#include <editor_media_platform/emp_time.h>

#include "gpu_video_surface.h"
#include "cpu_video_surface.h"
#include <QDebug>
#include "binding_macros.h"

#include <lua.hpp>
#include <memory>
#include <unordered_map>
#include <cstdint>
#include <cstring>

// Forward declaration from binding_macros.h
extern const char* WIDGET_METATABLE;

namespace {

// Metatable names for EMP types
const char* EMP_ASSET_METATABLE = "JVE.EMP.Asset";
const char* EMP_READER_METATABLE = "JVE.EMP.Reader";
const char* EMP_FRAME_METATABLE = "JVE.EMP.Frame";
const char* EMP_PCM_METATABLE = "JVE.EMP.PcmChunk";

// Global registry for shared_ptr instances (prevent premature destruction)
// Key: raw pointer, Value: shared_ptr (via unique_ptr to type-erase)
static std::unordered_map<void*, std::shared_ptr<emp::Asset>> g_assets;
static std::unordered_map<void*, std::shared_ptr<emp::Reader>> g_readers;
static std::unordered_map<void*, std::shared_ptr<emp::Frame>> g_frames;
static std::unordered_map<void*, std::shared_ptr<emp::PcmChunk>> g_pcm_chunks;

// Helper: Push EMP error to Lua (nil, { code=string, msg=string })
void push_emp_error(lua_State* L, const emp::Error& err) {
    lua_pushnil(L);
    lua_newtable(L);
    lua_pushstring(L, emp::error_code_to_string(err.code));
    lua_setfield(L, -2, "code");
    lua_pushstring(L, err.message.c_str());
    lua_setfield(L, -2, "msg");
}

// Helper: Create userdata with metatable
template<typename T>
void* push_userdata(lua_State* L, std::shared_ptr<T> ptr, const char* metatable) {
    void** ud = static_cast<void**>(lua_newuserdata(L, sizeof(void*)));
    *ud = ptr.get();
    luaL_getmetatable(L, metatable);
    lua_setmetatable(L, -2);
    return ptr.get();
}

// Helper: Get userdata pointer
template<typename T>
T* get_userdata(lua_State* L, int idx, const char* metatable) {
    void** ud = static_cast<void**>(luaL_checkudata(L, idx, metatable));
    return static_cast<T*>(*ud);
}

// ============================================================================
// Asset bindings
// ============================================================================

// EMP.ASSET_OPEN(path) -> asset | nil, err
static int lua_emp_asset_open(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);

    auto result = emp::Asset::Open(path);
    if (result.is_error()) {
        push_emp_error(L, result.error());
        return 2;
    }

    auto asset = result.value();
    void* key = push_userdata(L, asset, EMP_ASSET_METATABLE);
    g_assets[key] = asset;
    return 1;
}

// EMP.ASSET_CLOSE(asset)
static int lua_emp_asset_close(lua_State* L) {
    void* key = get_userdata<void>(L, 1, EMP_ASSET_METATABLE);
    g_assets.erase(key);
    return 0;
}

// EMP.ASSET_INFO(asset) -> { path, has_video, width, height, fps_num, fps_den, duration_us, is_vfr, has_audio, audio_sample_rate, audio_channels }
static int lua_emp_asset_info(lua_State* L) {
    void* key = get_userdata<void>(L, 1, EMP_ASSET_METATABLE);
    auto it = g_assets.find(key);
    if (it == g_assets.end()) {
        return luaL_error(L, "EMP.ASSET_INFO: invalid asset handle");
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

// Asset __gc metamethod
static int lua_emp_asset_gc(lua_State* L) {
    void* key = get_userdata<void>(L, 1, EMP_ASSET_METATABLE);
    g_assets.erase(key);
    return 0;
}

// ============================================================================
// Reader bindings
// ============================================================================

// EMP.READER_CREATE(asset) -> reader | nil, err
static int lua_emp_reader_create(lua_State* L) {
    void* asset_key = get_userdata<void>(L, 1, EMP_ASSET_METATABLE);
    auto asset_it = g_assets.find(asset_key);
    if (asset_it == g_assets.end()) {
        push_emp_error(L, emp::Error::invalid_arg("Invalid asset handle"));
        return 2;
    }

    auto result = emp::Reader::Create(asset_it->second);
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
    void* key = get_userdata<void>(L, 1, EMP_READER_METATABLE);
    g_readers.erase(key);
    return 0;
}

// EMP.READER_SEEK_FRAME(reader, frame_idx, rate_num, rate_den) -> true | nil, err
static int lua_emp_reader_seek_frame(lua_State* L) {
    void* key = get_userdata<void>(L, 1, EMP_READER_METATABLE);
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
    void* key = get_userdata<void>(L, 1, EMP_READER_METATABLE);
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
    void* key = get_userdata<void>(L, 1, EMP_READER_METATABLE);
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
    void* key = get_userdata<void>(L, 1, EMP_READER_METATABLE);
    auto it = g_readers.find(key);
    if (it == g_readers.end()) {
        return luaL_error(L, "READER_STOP_PREFETCH: invalid reader handle");
    }

    it->second->StopPrefetch();
    return 0;
}

// EMP.READER_UPDATE_PREFETCH_TARGET(reader, frame_idx, rate_num, rate_den)
static int lua_emp_reader_update_prefetch_target(lua_State* L) {
    void* key = get_userdata<void>(L, 1, EMP_READER_METATABLE);
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
    void* key = get_userdata<void>(L, 1, EMP_READER_METATABLE);
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
    void* key = get_userdata<void>(L, 1, EMP_READER_METATABLE);
    g_readers.erase(key);
    return 0;
}

// ============================================================================
// Frame bindings
// ============================================================================

// EMP.FRAME_INFO(frame) -> { width, height, stride, source_pts_us }
static int lua_emp_frame_info(lua_State* L) {
    void* key = get_userdata<void>(L, 1, EMP_FRAME_METATABLE);
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
    void* key = get_userdata<void>(L, 1, EMP_FRAME_METATABLE);
    g_frames.erase(key);
    return 0;
}

// EMP.FRAME_DATA_PTR(frame) -> lightuserdata (for FFI or surface widget)
static int lua_emp_frame_data_ptr(lua_State* L) {
    void* key = get_userdata<void>(L, 1, EMP_FRAME_METATABLE);
    auto it = g_frames.find(key);
    if (it == g_frames.end()) {
        return luaL_error(L, "EMP.FRAME_DATA_PTR: invalid frame handle");
    }

    lua_pushlightuserdata(L, const_cast<uint8_t*>(it->second->data()));
    return 1;
}

// Frame __gc metamethod
static int lua_emp_frame_gc(lua_State* L) {
    void* key = get_userdata<void>(L, 1, EMP_FRAME_METATABLE);
    g_frames.erase(key);
    return 0;
}

// ============================================================================
// Audio/PCM bindings
// ============================================================================

// EMP.READER_DECODE_AUDIO_RANGE(reader, frame0, frame1, rate_num, rate_den, out_sample_rate, out_channels) -> pcm | nil, err
static int lua_emp_reader_decode_audio_range(lua_State* L) {
    void* key = get_userdata<void>(L, 1, EMP_READER_METATABLE);
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
    void* key = get_userdata<void>(L, 1, EMP_PCM_METATABLE);
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
    void* key = get_userdata<void>(L, 1, EMP_PCM_METATABLE);
    auto it = g_pcm_chunks.find(key);
    if (it == g_pcm_chunks.end()) {
        return luaL_error(L, "EMP.PCM_DATA_PTR: invalid pcm handle");
    }

    lua_pushlightuserdata(L, const_cast<float*>(it->second->data_f32()));
    return 1;
}

// EMP.PCM_RELEASE(pcm)
static int lua_emp_pcm_release(lua_State* L) {
    void* key = get_userdata<void>(L, 1, EMP_PCM_METATABLE);
    g_pcm_chunks.erase(key);
    return 0;
}

// PCM __gc metamethod
static int lua_emp_pcm_gc(lua_State* L) {
    void* key = get_userdata<void>(L, 1, EMP_PCM_METATABLE);
    g_pcm_chunks.erase(key);
    return 0;
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
    void* key = get_userdata<void>(L, 1, EMP_READER_METATABLE);
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
    void* frame_key = get_userdata<void>(L, 2, EMP_FRAME_METATABLE);
    auto it = g_frames.find(frame_key);
    if (it == g_frames.end()) {
        return luaL_error(L, "EMP.SURFACE_SET_FRAME: invalid frame handle");
    }
    auto frame = it->second;

    // Dispatch to appropriate surface
    if (gpu_surface) {
        gpu_surface->setFrame(frame);  // Will assert if frame has no hw buffer
    } else {
        cpu_surface->setFrame(frame);  // Calls frame->data() for CPU pixels
    }

    return 0;
}

} // anonymous namespace

// ============================================================================
// Registration
// ============================================================================

void register_emp_bindings(lua_State* L) {
    // Create metatables with __gc
    luaL_newmetatable(L, EMP_ASSET_METATABLE);
    lua_pushcfunction(L, lua_emp_asset_gc);
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

    // Create EMP subtable in qt_constants
    // Assumes qt_constants is on stack at index -1
    lua_newtable(L);

    // Asset functions
    lua_pushcfunction(L, lua_emp_asset_open);
    lua_setfield(L, -2, "ASSET_OPEN");
    lua_pushcfunction(L, lua_emp_asset_close);
    lua_setfield(L, -2, "ASSET_CLOSE");
    lua_pushcfunction(L, lua_emp_asset_info);
    lua_setfield(L, -2, "ASSET_INFO");

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
