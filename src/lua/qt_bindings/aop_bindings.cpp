// AOP (Audio Output Platform) Lua bindings
// Provides audio device output for playback

#include "audio_output_platform/aop.h"
#include "binding_macros.h"

#include <lua.hpp>
#include <memory>
#include <unordered_map>

namespace {

// Metatable name for AOP type
const char* AOP_METATABLE = "JVE.AOP.AudioOutput";

// Global registry for AudioOutput instances
static std::unordered_map<void*, std::unique_ptr<aop::AudioOutput>> g_audio_outputs;

// Helper: Push AOP error to Lua (nil, error_string)
void push_aop_error(lua_State* L, const char* msg) {
    lua_pushnil(L);
    lua_pushstring(L, msg);
}

// Helper: Create userdata with metatable
void* push_aop_userdata(lua_State* L, aop::AudioOutput* ptr) {
    void** ud = static_cast<void**>(lua_newuserdata(L, sizeof(void*)));
    *ud = ptr;
    luaL_getmetatable(L, AOP_METATABLE);
    lua_setmetatable(L, -2);
    return ptr;
}

// Helper: Get userdata pointer
aop::AudioOutput* get_aop_userdata(lua_State* L, int idx) {
    void** ud = static_cast<void**>(luaL_checkudata(L, idx, AOP_METATABLE));
    void* key = *ud;
    auto it = g_audio_outputs.find(key);
    if (it == g_audio_outputs.end()) {
        return nullptr;
    }
    return it->second.get();
}

// ============================================================================
// AOP bindings
// ============================================================================

// AOP.OPEN(sample_rate, channels, target_buffer_ms) -> aop | nil, err
static int lua_aop_open(lua_State* L) {
    int32_t sample_rate = static_cast<int32_t>(luaL_optinteger(L, 1, 48000));
    int32_t channels = static_cast<int32_t>(luaL_optinteger(L, 2, 2));
    int32_t buffer_ms = static_cast<int32_t>(luaL_optinteger(L, 3, 100));

    aop::AopConfig config;
    config.sample_rate = sample_rate;
    config.channels = channels;
    config.target_buffer_ms = buffer_ms;

    aop::AopOpenReport report;
    auto output = aop::AudioOutput::Open(config, &report);

    if (!output) {
        push_aop_error(L, report.device_name.c_str());
        return 2;
    }

    void* key = push_aop_userdata(L, output.get());
    g_audio_outputs[key] = std::move(output);
    return 1;
}

// AOP.CLOSE(aop)
static int lua_aop_close(lua_State* L) {
    void** ud = static_cast<void**>(luaL_checkudata(L, 1, AOP_METATABLE));
    void* key = *ud;
    g_audio_outputs.erase(key);
    return 0;
}

// AOP.START(aop)
static int lua_aop_start(lua_State* L) {
    aop::AudioOutput* output = get_aop_userdata(L, 1);
    if (!output) {
        return luaL_error(L, "AOP.START: invalid aop handle");
    }
    output->Start();
    return 0;
}

// AOP.STOP(aop)
static int lua_aop_stop(lua_State* L) {
    aop::AudioOutput* output = get_aop_userdata(L, 1);
    if (!output) {
        return luaL_error(L, "AOP.STOP: invalid aop handle");
    }
    output->Stop();
    return 0;
}

// AOP.IS_PLAYING(aop) -> bool
static int lua_aop_is_playing(lua_State* L) {
    aop::AudioOutput* output = get_aop_userdata(L, 1);
    if (!output) {
        return luaL_error(L, "AOP.IS_PLAYING: invalid aop handle");
    }
    lua_pushboolean(L, output->IsPlaying());
    return 1;
}

// AOP.FLUSH(aop)
static int lua_aop_flush(lua_State* L) {
    aop::AudioOutput* output = get_aop_userdata(L, 1);
    if (!output) {
        return luaL_error(L, "AOP.FLUSH: invalid aop handle");
    }
    output->Flush();
    return 0;
}

// AOP.BUFFERED_FRAMES(aop) -> frames
static int lua_aop_buffered_frames(lua_State* L) {
    aop::AudioOutput* output = get_aop_userdata(L, 1);
    if (!output) {
        return luaL_error(L, "AOP.BUFFERED_FRAMES: invalid aop handle");
    }
    lua_pushinteger(L, static_cast<lua_Integer>(output->BufferedFrames()));
    return 1;
}

// AOP.PLAYHEAD_US(aop) -> t_us
static int lua_aop_playhead_us(lua_State* L) {
    aop::AudioOutput* output = get_aop_userdata(L, 1);
    if (!output) {
        return luaL_error(L, "AOP.PLAYHEAD_US: invalid aop handle");
    }
    lua_pushinteger(L, static_cast<lua_Integer>(output->PlayheadTimeUS()));
    return 1;
}

// AOP.LATENCY_FRAMES(aop) -> frames
static int lua_aop_latency_frames(lua_State* L) {
    aop::AudioOutput* output = get_aop_userdata(L, 1);
    if (!output) {
        return luaL_error(L, "AOP.LATENCY_FRAMES: invalid aop handle");
    }
    lua_pushinteger(L, static_cast<lua_Integer>(output->LatencyFrames()));
    return 1;
}

// AOP.HAD_UNDERRUN(aop) -> bool
static int lua_aop_had_underrun(lua_State* L) {
    aop::AudioOutput* output = get_aop_userdata(L, 1);
    if (!output) {
        return luaL_error(L, "AOP.HAD_UNDERRUN: invalid aop handle");
    }
    lua_pushboolean(L, output->HadUnderrun());
    return 1;
}

// AOP.CLEAR_UNDERRUN(aop)
static int lua_aop_clear_underrun(lua_State* L) {
    aop::AudioOutput* output = get_aop_userdata(L, 1);
    if (!output) {
        return luaL_error(L, "AOP.CLEAR_UNDERRUN: invalid aop handle");
    }
    output->ClearUnderrunFlag();
    return 0;
}

// AOP.WRITE_F32(aop, pcm_data_ptr, frames) -> frames_written
// pcm_data_ptr is lightuserdata from EMP.PCM_DATA_PTR
static int lua_aop_write_f32(lua_State* L) {
    aop::AudioOutput* output = get_aop_userdata(L, 1);
    if (!output) {
        return luaL_error(L, "AOP.WRITE_F32: invalid aop handle");
    }

    if (!lua_islightuserdata(L, 2)) {
        return luaL_error(L, "AOP.WRITE_F32: expected lightuserdata for pcm_data_ptr");
    }

    const float* data = static_cast<const float*>(lua_touserdata(L, 2));
    int64_t frames = static_cast<int64_t>(luaL_checkinteger(L, 3));

    int64_t written = output->WriteF32(data, frames);
    lua_pushinteger(L, static_cast<lua_Integer>(written));
    return 1;
}

// AOP.WRITE_PCM(aop, pcm) -> frames_written
// Writes directly from PcmChunk without intermediate marshaling
// Requires emp_bindings to be included first for PcmChunk access
static int lua_aop_write_pcm(lua_State* L);  // Forward declaration, implemented below

// AOP __gc metamethod
static int lua_aop_gc(lua_State* L) {
    void** ud = static_cast<void**>(luaL_checkudata(L, 1, AOP_METATABLE));
    void* key = *ud;
    g_audio_outputs.erase(key);
    return 0;
}

} // anonymous namespace

// ============================================================================
// Registration
// ============================================================================

void register_aop_bindings(lua_State* L) {
    // Create metatable with __gc
    luaL_newmetatable(L, AOP_METATABLE);
    lua_pushcfunction(L, lua_aop_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);

    // Create AOP subtable in qt_constants
    // Assumes qt_constants is on stack at index -1
    lua_newtable(L);

    lua_pushcfunction(L, lua_aop_open);
    lua_setfield(L, -2, "OPEN");
    lua_pushcfunction(L, lua_aop_close);
    lua_setfield(L, -2, "CLOSE");
    lua_pushcfunction(L, lua_aop_start);
    lua_setfield(L, -2, "START");
    lua_pushcfunction(L, lua_aop_stop);
    lua_setfield(L, -2, "STOP");
    lua_pushcfunction(L, lua_aop_is_playing);
    lua_setfield(L, -2, "IS_PLAYING");
    lua_pushcfunction(L, lua_aop_flush);
    lua_setfield(L, -2, "FLUSH");
    lua_pushcfunction(L, lua_aop_buffered_frames);
    lua_setfield(L, -2, "BUFFERED_FRAMES");
    lua_pushcfunction(L, lua_aop_playhead_us);
    lua_setfield(L, -2, "PLAYHEAD_US");
    lua_pushcfunction(L, lua_aop_latency_frames);
    lua_setfield(L, -2, "LATENCY_FRAMES");
    lua_pushcfunction(L, lua_aop_had_underrun);
    lua_setfield(L, -2, "HAD_UNDERRUN");
    lua_pushcfunction(L, lua_aop_clear_underrun);
    lua_setfield(L, -2, "CLEAR_UNDERRUN");
    lua_pushcfunction(L, lua_aop_write_f32);
    lua_setfield(L, -2, "WRITE_F32");

    lua_setfield(L, -2, "AOP");
}
