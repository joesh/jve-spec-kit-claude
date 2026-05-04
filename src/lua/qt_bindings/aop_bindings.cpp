// AOP (Audio Output Platform) Lua bindings
// Provides audio device output for playback

#include "audio_output_platform/aop.h"
#include "binding_macros.h"

#include <lua.hpp>
#include <memory>
#include <unordered_map>

// Metatable name for AOP type (extern for cross-file access)
const char* AOP_METATABLE = "JVE.AOP.AudioOutput";

// Global registry for AudioOutput instances
static std::unordered_map<void*, std::unique_ptr<aop::AudioOutput>> g_audio_outputs;

// Helper: Get userdata pointer (extern for cross-file access).
// The map key is the Lua userdata allocation address (stable for the
// userdata's lifetime), NOT the contained AudioOutput* (which can be reused
// by the allocator after CLOSE — see push_aop_userdata for the rationale).
aop::AudioOutput* get_aop_userdata(lua_State* L, int idx) {
    void* key = static_cast<void*>(luaL_checkudata(L, idx, AOP_METATABLE));
    auto it = g_audio_outputs.find(key);
    if (it == g_audio_outputs.end()) {
        return nullptr;
    }
    return it->second.get();
}

namespace {

// Helper: Push AOP error to Lua (nil, error_string)
void push_aop_error(lua_State* L, const char* msg) {
    lua_pushnil(L);
    lua_pushstring(L, msg);
}

// Helper: Create userdata with metatable.
// Returns the userdata's allocation address — Lua guarantees this stays
// stable for the userdata's lifetime, so it's a safe registry key. Using
// the contained AudioOutput* would be unsafe: after CLOSE the underlying
// allocation is freed and the same address can be handed back by the
// allocator on the next OPEN, silently aliasing two distinct Lua handles.
void* push_aop_userdata(lua_State* L, aop::AudioOutput* ptr) {
    void** ud = static_cast<void**>(lua_newuserdata(L, sizeof(void*)));
    *ud = ptr;
    luaL_getmetatable(L, AOP_METATABLE);
    lua_setmetatable(L, -2);
    return static_cast<void*>(ud);
}

// ============================================================================
// AOP bindings
// ============================================================================

// AOP.OPEN(sample_rate, channels, target_buffer_ms) -> aop | nil, err
//
// All three arguments are required. Silent defaults (rule 2.13) would
// substitute 48000/2/100 for missing values, masking caller bugs. Use
// luaL_checkinteger so a missing argument raises a Lua error with the
// argument index, not a silent default.
static int lua_aop_open(lua_State* L) {
    int32_t sample_rate = static_cast<int32_t>(luaL_checkinteger(L, 1));
    int32_t channels = static_cast<int32_t>(luaL_checkinteger(L, 2));
    int32_t buffer_ms = static_cast<int32_t>(luaL_checkinteger(L, 3));

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
    void* key = static_cast<void*>(luaL_checkudata(L, 1, AOP_METATABLE));
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
// Buffer-fill position. Use as internal clock anchor (cancels in deltas).
// For UI / A/V sync against video display, prefer AOP.AUDIBLE_US.
static int lua_aop_playhead_us(lua_State* L) {
    aop::AudioOutput* output = get_aop_userdata(L, 1);
    if (!output) {
        return luaL_error(L, "AOP.PLAYHEAD_US: invalid aop handle");
    }
    lua_pushinteger(L, static_cast<lua_Integer>(output->PlayheadTimeUS()));
    return 1;
}

// AOP.AUDIBLE_US(aop) -> t_us
// Position currently audible at the speaker (PLAYHEAD_US minus QAudioSink
// internal buffer). Use for video-sync drift measurement and any user-visible
// "where am I" reporting.
static int lua_aop_audible_us(lua_State* L) {
    aop::AudioOutput* output = get_aop_userdata(L, 1);
    if (!output) {
        return luaL_error(L, "AOP.AUDIBLE_US: invalid aop handle");
    }
    lua_pushinteger(L, static_cast<lua_Integer>(output->AudibleTimeUS()));
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

// AOP._TEST_WRITE_F32(aop, pcm_data_ptr, frames) -> frames_written
// pcm_data_ptr is lightuserdata from EMP.PCM_DATA_PTR.
//
// TEST INFRASTRUCTURE ONLY. Production audio does not pump through Lua —
// the hot path is playback_controller.mm → AudioPump::pumpLoop() →
// m_aop->WriteF32() entirely in C++ for low-latency, lock-free operation.
// This binding exists so Lua integration tests can drive PCM through AOP
// without spinning up the full playback pipeline. The `_TEST_` prefix is
// load-bearing — do not rename or remove it without first migrating callers
// off this binding.
static int lua_aop_write_f32(lua_State* L) {
    aop::AudioOutput* output = get_aop_userdata(L, 1);
    if (!output) {
        return luaL_error(L, "AOP._TEST_WRITE_F32: invalid aop handle");
    }

    if (!lua_islightuserdata(L, 2)) {
        return luaL_error(L, "AOP._TEST_WRITE_F32: expected lightuserdata for pcm_data_ptr");
    }

    const float* data = static_cast<const float*>(lua_touserdata(L, 2));
    int64_t frames = static_cast<int64_t>(luaL_checkinteger(L, 3));

    int64_t written = output->WriteF32(data, frames);
    lua_pushinteger(L, static_cast<lua_Integer>(written));
    return 1;
}

// AOP.WRITE_PCM(aop, pcm) -> frames_written
// AOP.SAMPLE_RATE(aop) -> int
// Returns actual sample rate (may differ from requested if device doesn't support it)
static int lua_aop_sample_rate(lua_State* L) {
    aop::AudioOutput* output = get_aop_userdata(L, 1);
    if (!output) {
        return luaL_error(L, "AOP.SAMPLE_RATE: invalid aop handle");
    }
    lua_pushinteger(L, output->SampleRate());
    return 1;
}

// AOP.CHANNELS(aop) -> int
// Returns actual channel count
static int lua_aop_channels(lua_State* L) {
    aop::AudioOutput* output = get_aop_userdata(L, 1);
    if (!output) {
        return luaL_error(L, "AOP.CHANNELS: invalid aop handle");
    }
    lua_pushinteger(L, output->Channels());
    return 1;
}

// AOP.TARGET_BUFFER_MS(aop) -> int
// Returns the target buffer duration AOP was opened with. AOP is the canonical
// source — anything pumping into it must derive its own target from this so
// the 3× ring headroom is preserved (see AudioOutput::Open in aop.cpp).
static int lua_aop_target_buffer_ms(lua_State* L) {
    aop::AudioOutput* output = get_aop_userdata(L, 1);
    if (!output) {
        return luaL_error(L, "AOP.TARGET_BUFFER_MS: invalid aop handle");
    }
    lua_pushinteger(L, output->TargetBufferMs());
    return 1;
}

// AOP.SET_VOLUME(aop, volume) — volume 0.0 (mute) to 1.0 (full)
static int lua_aop_set_volume(lua_State* L) {
    aop::AudioOutput* output = get_aop_userdata(L, 1);
    if (!output) {
        return luaL_error(L, "AOP.SET_VOLUME: invalid aop handle");
    }
    float volume = static_cast<float>(luaL_checknumber(L, 2));
    output->SetVolume(volume);
    return 0;
}

// AOP.VOLUME(aop) -> float
static int lua_aop_volume(lua_State* L) {
    aop::AudioOutput* output = get_aop_userdata(L, 1);
    if (!output) {
        return luaL_error(L, "AOP.VOLUME: invalid aop handle");
    }
    lua_pushnumber(L, static_cast<double>(output->Volume()));
    return 1;
}

// AOP __gc metamethod
static int lua_aop_gc(lua_State* L) {
    void* key = static_cast<void*>(luaL_checkudata(L, 1, AOP_METATABLE));
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
    lua_pushcfunction(L, lua_aop_audible_us);
    lua_setfield(L, -2, "AUDIBLE_US");
    lua_pushcfunction(L, lua_aop_latency_frames);
    lua_setfield(L, -2, "LATENCY_FRAMES");
    lua_pushcfunction(L, lua_aop_had_underrun);
    lua_setfield(L, -2, "HAD_UNDERRUN");
    lua_pushcfunction(L, lua_aop_clear_underrun);
    lua_setfield(L, -2, "CLEAR_UNDERRUN");
    lua_pushcfunction(L, lua_aop_write_f32);
    lua_setfield(L, -2, "_TEST_WRITE_F32");
    lua_pushcfunction(L, lua_aop_sample_rate);
    lua_setfield(L, -2, "SAMPLE_RATE");
    lua_pushcfunction(L, lua_aop_channels);
    lua_setfield(L, -2, "CHANNELS");
    lua_pushcfunction(L, lua_aop_target_buffer_ms);
    lua_setfield(L, -2, "TARGET_BUFFER_MS");
    lua_pushcfunction(L, lua_aop_set_volume);
    lua_setfield(L, -2, "SET_VOLUME");
    lua_pushcfunction(L, lua_aop_volume);
    lua_setfield(L, -2, "VOLUME");

    lua_setfield(L, -2, "AOP");
}
