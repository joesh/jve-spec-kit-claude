// csc_bindings.cpp — Lua binding for GPUVideoSurface::composeBt709Csc.
//
// Exposes one global, test-only:
//   qt_compose_bt709_csc(pixelFormat) → 12 floats
//     (row_r[0..3], row_g[0..3], row_b[0..3])
//
// pixelFormat is the integer CVPixelBuffer pixel format value (a 32-bit
// FourCC for the well-documented formats; the test composes them from
// 4-char ASCII the same way the OS does). Thin one-to-one wrapper —
// the matrix derivation lives in src/gpu_video_surface.mm so the
// production renderer and the binding test share one source of truth.
//
// Errors via luaL_checkinteger (no defaults) and via the underlying
// JVE_ASSERT in composeBt709Csc when the format is unrecognized.

#include <lua.hpp>

#include "gpu_video_surface.h"

static int lua_qt_compose_bt709_csc(lua_State* L) {
    uint32_t pf = static_cast<uint32_t>(luaL_checkinteger(L, 1));
    GPUVideoSurface::CscParams p = GPUVideoSurface::composeBt709Csc(pf);
    for (int i = 0; i < 4; ++i) lua_pushnumber(L, p.row_r[i]);
    for (int i = 0; i < 4; ++i) lua_pushnumber(L, p.row_g[i]);
    for (int i = 0; i < 4; ++i) lua_pushnumber(L, p.row_b[i]);
    return 12;
}

static void register_csc_bindings(lua_State* L) {
    lua_pushcfunction(L, lua_qt_compose_bt709_csc);
    lua_setglobal(L, "qt_compose_bt709_csc");
}
