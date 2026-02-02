// SSE (Scrub Stretch Engine) Lua bindings
// Provides WSOLA-based pitch-preserving time stretching

#include "scrub_stretch_engine/sse.h"
#include "binding_macros.h"

#include <lua.hpp>
#include <memory>
#include <unordered_map>
#include <vector>

namespace {

// Metatable name for SSE type
const char* SSE_METATABLE = "JVE.SSE.ScrubStretchEngine";

// Global registry for SSE instances
static std::unordered_map<void*, std::unique_ptr<sse::ScrubStretchEngine>> g_sse_instances;

// Helper: Create userdata with metatable
void* push_sse_userdata(lua_State* L, sse::ScrubStretchEngine* ptr) {
    void** ud = static_cast<void**>(lua_newuserdata(L, sizeof(void*)));
    *ud = ptr;
    luaL_getmetatable(L, SSE_METATABLE);
    lua_setmetatable(L, -2);
    return ptr;
}

// Helper: Get userdata pointer
sse::ScrubStretchEngine* get_sse_userdata(lua_State* L, int idx) {
    void** ud = static_cast<void**>(luaL_checkudata(L, idx, SSE_METATABLE));
    void* key = *ud;
    auto it = g_sse_instances.find(key);
    if (it == g_sse_instances.end()) {
        return nullptr;
    }
    return it->second.get();
}

// ============================================================================
// SSE bindings
// ============================================================================

// SSE.CREATE(config_table) -> sse | nil
// config_table: { sample_rate, channels, block_frames, lookahead_ms_q1, lookahead_ms_q2,
//                 min_speed_q1, min_speed_q2, max_speed, xfade_ms }
// All fields optional, defaults used if missing
static int lua_sse_create(lua_State* L) {
    sse::SseConfig config = sse::default_config();

    if (lua_istable(L, 1)) {
        lua_getfield(L, 1, "sample_rate");
        if (!lua_isnil(L, -1)) config.sample_rate = static_cast<int32_t>(lua_tointeger(L, -1));
        lua_pop(L, 1);

        lua_getfield(L, 1, "channels");
        if (!lua_isnil(L, -1)) config.channels = static_cast<int32_t>(lua_tointeger(L, -1));
        lua_pop(L, 1);

        lua_getfield(L, 1, "block_frames");
        if (!lua_isnil(L, -1)) config.block_frames = static_cast<int32_t>(lua_tointeger(L, -1));
        lua_pop(L, 1);

        lua_getfield(L, 1, "lookahead_ms_q1");
        if (!lua_isnil(L, -1)) config.lookahead_ms_q1 = static_cast<int32_t>(lua_tointeger(L, -1));
        lua_pop(L, 1);

        lua_getfield(L, 1, "lookahead_ms_q2");
        if (!lua_isnil(L, -1)) config.lookahead_ms_q2 = static_cast<int32_t>(lua_tointeger(L, -1));
        lua_pop(L, 1);

        lua_getfield(L, 1, "min_speed_q1");
        if (!lua_isnil(L, -1)) config.min_speed_q1 = static_cast<float>(lua_tonumber(L, -1));
        lua_pop(L, 1);

        lua_getfield(L, 1, "min_speed_q2");
        if (!lua_isnil(L, -1)) config.min_speed_q2 = static_cast<float>(lua_tonumber(L, -1));
        lua_pop(L, 1);

        lua_getfield(L, 1, "max_speed");
        if (!lua_isnil(L, -1)) config.max_speed = static_cast<float>(lua_tonumber(L, -1));
        lua_pop(L, 1);

        lua_getfield(L, 1, "xfade_ms");
        if (!lua_isnil(L, -1)) config.xfade_ms = static_cast<int32_t>(lua_tointeger(L, -1));
        lua_pop(L, 1);
    }

    auto engine = sse::ScrubStretchEngine::Create(config);
    if (!engine) {
        lua_pushnil(L);
        return 1;
    }

    void* key = push_sse_userdata(L, engine.get());
    g_sse_instances[key] = std::move(engine);
    return 1;
}

// SSE.CLOSE(sse)
static int lua_sse_close(lua_State* L) {
    void** ud = static_cast<void**>(luaL_checkudata(L, 1, SSE_METATABLE));
    void* key = *ud;
    g_sse_instances.erase(key);
    return 0;
}

// SSE.RESET(sse)
static int lua_sse_reset(lua_State* L) {
    sse::ScrubStretchEngine* engine = get_sse_userdata(L, 1);
    if (!engine) {
        return luaL_error(L, "SSE.RESET: invalid sse handle");
    }
    engine->Reset();
    return 0;
}

// SSE.SET_TARGET(sse, t_us, speed, quality_mode)
// quality_mode: 1 = Q1 (editor), 2 = Q2 (extreme slomo), 3 = Q3_DECIMATE (varispeed)
static int lua_sse_set_target(lua_State* L) {
    sse::ScrubStretchEngine* engine = get_sse_userdata(L, 1);
    if (!engine) {
        return luaL_error(L, "SSE.SET_TARGET: invalid sse handle");
    }

    int64_t t_us = static_cast<int64_t>(luaL_checkinteger(L, 2));
    float speed = static_cast<float>(luaL_checknumber(L, 3));
    int mode_int = static_cast<int>(luaL_optinteger(L, 4, 1));

    sse::QualityMode mode;
    if (mode_int == 3) {
        mode = sse::QualityMode::Q3_DECIMATE;
    } else if (mode_int == 2) {
        mode = sse::QualityMode::Q2;
    } else {
        mode = sse::QualityMode::Q1;
    }
    engine->SetTarget(t_us, speed, mode);
    return 0;
}

// SSE.PUSH_PCM(sse, pcm_data_ptr, frames, start_time_us [, skip_frames])
// Optional skip_frames: offset into buffer (in frames) to start from.
// When provided, pushes (frames - skip_frames) starting at data + skip_frames * channels,
// with start_time_us adjusted forward by skip_frames worth of time.
static int lua_sse_push_pcm(lua_State* L) {
    sse::ScrubStretchEngine* engine = get_sse_userdata(L, 1);
    if (!engine) {
        return luaL_error(L, "SSE.PUSH_PCM: invalid sse handle");
    }

    const float* data = nullptr;
    if (lua_islightuserdata(L, 2)) {
        data = static_cast<const float*>(lua_touserdata(L, 2));
    } else if (lua_type(L, 2) == 10) { // LUA_TCDATA (LuaJIT FFI cdata)
        data = static_cast<const float*>(lua_topointer(L, 2));
    } else {
        return luaL_error(L, "SSE.PUSH_PCM: expected lightuserdata or cdata for pcm_data_ptr");
    }
    if (!data) {
        return luaL_error(L, "SSE.PUSH_PCM: null pcm_data_ptr");
    }
    int64_t frames = static_cast<int64_t>(luaL_checkinteger(L, 3));
    int64_t start_time_us = static_cast<int64_t>(luaL_checkinteger(L, 4));

    // Optional: skip_frames offset into buffer (for windowed push)
    if (lua_gettop(L) >= 5 && !lua_isnil(L, 5)) {
        int64_t skip = static_cast<int64_t>(luaL_checkinteger(L, 5));
        int64_t max_frames = lua_gettop(L) >= 6
            ? static_cast<int64_t>(luaL_checkinteger(L, 6))
            : (frames - skip);
        constexpr int CHANNELS = 2;  // stereo interleaved
        data += skip * CHANNELS;
        frames = std::min(max_frames, frames - skip);
    }

    engine->PushSourcePcm(data, frames, start_time_us);
    return 0;
}

// SSE.RENDER(sse, out_buffer_ptr, out_frames) -> frames_produced
static int lua_sse_render(lua_State* L) {
    sse::ScrubStretchEngine* engine = get_sse_userdata(L, 1);
    if (!engine) {
        return luaL_error(L, "SSE.RENDER: invalid sse handle");
    }

    if (!lua_islightuserdata(L, 2)) {
        return luaL_error(L, "SSE.RENDER: expected lightuserdata for out_buffer_ptr");
    }

    float* out = static_cast<float*>(lua_touserdata(L, 2));
    int64_t out_frames = static_cast<int64_t>(luaL_checkinteger(L, 3));

    int64_t produced = engine->Render(out, out_frames);
    lua_pushinteger(L, static_cast<lua_Integer>(produced));
    return 1;
}

// SSE.STARVED(sse) -> bool
static int lua_sse_starved(lua_State* L) {
    sse::ScrubStretchEngine* engine = get_sse_userdata(L, 1);
    if (!engine) {
        return luaL_error(L, "SSE.STARVED: invalid sse handle");
    }
    lua_pushboolean(L, engine->Starved());
    return 1;
}

// SSE.CLEAR_STARVED(sse)
static int lua_sse_clear_starved(lua_State* L) {
    sse::ScrubStretchEngine* engine = get_sse_userdata(L, 1);
    if (!engine) {
        return luaL_error(L, "SSE.CLEAR_STARVED: invalid sse handle");
    }
    engine->ClearStarvedFlag();
    return 0;
}

// SSE.CURRENT_TIME_US(sse) -> t_us
static int lua_sse_current_time_us(lua_State* L) {
    sse::ScrubStretchEngine* engine = get_sse_userdata(L, 1);
    if (!engine) {
        return luaL_error(L, "SSE.CURRENT_TIME_US: invalid sse handle");
    }
    lua_pushinteger(L, static_cast<lua_Integer>(engine->CurrentTimeUS()));
    return 1;
}

// SSE __gc metamethod
static int lua_sse_gc(lua_State* L) {
    void** ud = static_cast<void**>(luaL_checkudata(L, 1, SSE_METATABLE));
    void* key = *ud;
    g_sse_instances.erase(key);
    return 0;
}

// Static render buffer for RENDER_ALLOC (avoids Lua allocation issues)
static std::vector<float> g_render_buffer;

// SSE.RENDER_ALLOC(sse, frames) -> lightuserdata, frames_produced
// Renders to internal buffer and returns pointer for use with AOP.WRITE_F32
// This avoids needing to allocate float arrays in Lua
static int lua_sse_render_alloc(lua_State* L) {
    sse::ScrubStretchEngine* engine = get_sse_userdata(L, 1);
    if (!engine) {
        return luaL_error(L, "SSE.RENDER_ALLOC: invalid sse handle");
    }

    int64_t frames = static_cast<int64_t>(luaL_checkinteger(L, 2));
    if (frames <= 0) {
        lua_pushlightuserdata(L, nullptr);
        lua_pushinteger(L, 0);
        return 2;
    }

    // Ensure buffer is large enough (stereo = 2 channels)
    size_t needed = static_cast<size_t>(frames * 2);
    if (g_render_buffer.size() < needed) {
        g_render_buffer.resize(needed);
    }

    int64_t produced = engine->Render(g_render_buffer.data(), frames);

    lua_pushlightuserdata(L, g_render_buffer.data());
    lua_pushinteger(L, static_cast<lua_Integer>(produced));
    return 2;
}

} // anonymous namespace

// ============================================================================
// Registration
// ============================================================================

void register_sse_bindings(lua_State* L) {
    // Create metatable with __gc
    luaL_newmetatable(L, SSE_METATABLE);
    lua_pushcfunction(L, lua_sse_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);

    // Create SSE subtable in qt_constants
    // Assumes qt_constants is on stack at index -1
    lua_newtable(L);

    lua_pushcfunction(L, lua_sse_create);
    lua_setfield(L, -2, "CREATE");
    lua_pushcfunction(L, lua_sse_close);
    lua_setfield(L, -2, "CLOSE");
    lua_pushcfunction(L, lua_sse_reset);
    lua_setfield(L, -2, "RESET");
    lua_pushcfunction(L, lua_sse_set_target);
    lua_setfield(L, -2, "SET_TARGET");
    lua_pushcfunction(L, lua_sse_push_pcm);
    lua_setfield(L, -2, "PUSH_PCM");
    lua_pushcfunction(L, lua_sse_render);
    lua_setfield(L, -2, "RENDER");
    lua_pushcfunction(L, lua_sse_render_alloc);
    lua_setfield(L, -2, "RENDER_ALLOC");
    lua_pushcfunction(L, lua_sse_starved);
    lua_setfield(L, -2, "STARVED");
    lua_pushcfunction(L, lua_sse_clear_starved);
    lua_setfield(L, -2, "CLEAR_STARVED");
    lua_pushcfunction(L, lua_sse_current_time_us);
    lua_setfield(L, -2, "CURRENT_TIME_US");

    // Quality mode constants
    lua_pushinteger(L, 1);
    lua_setfield(L, -2, "Q1");
    lua_pushinteger(L, 2);
    lua_setfield(L, -2, "Q2");
    lua_pushinteger(L, 3);
    lua_setfield(L, -2, "Q3_DECIMATE");

    lua_setfield(L, -2, "SSE");
}
