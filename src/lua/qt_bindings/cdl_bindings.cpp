// cdl_bindings.cpp — Lua binding for the ASC CDL math (T032).
//
// Exposes one global:
//   qt_cdl_apply_pixel(r, g, b,
//                      slope_r, slope_g, slope_b,
//                      offset_r, offset_g, offset_b,
//                      power_r, power_g, power_b,
//                      saturation)
//     → r', g', b'
//
// Thin one-to-one wrapper over emp::apply_cdl_rgb. Exists so the
// binding test (tests/binding/test_cdl_apply_pixel.lua) can pin the
// math against ASC-derived domain values without shipping a parallel
// Lua reimplementation of the formula (which would silently drift
// from the C++/MSL source of truth).
//
// Errors via luaL_checknumber on every arg — no defaults, no fallbacks.

#include <lua.hpp>

#include <editor_media_platform/emp_cdl.h>

// qt_cdl_apply_pixel(r,g,b, slope_r,slope_g,slope_b, offset_r,offset_g,offset_b,
//                    power_r,power_g,power_b, saturation) → (r', g', b')
static int lua_qt_cdl_apply_pixel(lua_State* L) {
    float r = static_cast<float>(luaL_checknumber(L, 1));
    float g = static_cast<float>(luaL_checknumber(L, 2));
    float b = static_cast<float>(luaL_checknumber(L, 3));

    emp::CdlParams cdl{};
    cdl.slope[0]  = static_cast<float>(luaL_checknumber(L, 4));
    cdl.slope[1]  = static_cast<float>(luaL_checknumber(L, 5));
    cdl.slope[2]  = static_cast<float>(luaL_checknumber(L, 6));
    cdl.offset[0] = static_cast<float>(luaL_checknumber(L, 7));
    cdl.offset[1] = static_cast<float>(luaL_checknumber(L, 8));
    cdl.offset[2] = static_cast<float>(luaL_checknumber(L, 9));
    cdl.power[0]  = static_cast<float>(luaL_checknumber(L, 10));
    cdl.power[1]  = static_cast<float>(luaL_checknumber(L, 11));
    cdl.power[2]  = static_cast<float>(luaL_checknumber(L, 12));
    cdl.saturation = static_cast<float>(luaL_checknumber(L, 13));
    cdl.enabled = 1;

    emp::apply_cdl_rgb(r, g, b, cdl);

    lua_pushnumber(L, r);
    lua_pushnumber(L, g);
    lua_pushnumber(L, b);
    return 3;
}

static void register_cdl_bindings(lua_State* L) {
    lua_pushcfunction(L, lua_qt_cdl_apply_pixel);
    lua_setglobal(L, "qt_cdl_apply_pixel");
}
