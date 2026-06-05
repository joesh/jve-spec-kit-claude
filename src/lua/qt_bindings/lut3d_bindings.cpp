// lut3d_bindings.cpp — Lua binding for the .cube parser + trilinear
// apply (Piece 3 of spec 023).
//
// Exposes two globals — both are thin one-to-one wrappers over the
// editor-general EMP primitives so the binding test can pin the math
// against Adobe-spec reference vectors WITHOUT shipping a parallel Lua
// reimplementation (which would silently drift from the C++/MSL
// source of truth).
//
//   qt_lut3d_parse_string(content) → handle_id  -- or nil, err
//   qt_lut3d_apply_pixel(handle_id, r, g, b)    → r', g', b'
//   qt_lut3d_free(handle_id)                     -- explicit; tests own lifetime
//
// Handle-id model: parsed LUTs live in a process-static map keyed by
// integer handle. Test code holds the handle, applies pixels through
// it, then frees it explicitly. No GC magic — the binding is a
// regression vector for the math, not a long-lived production resource
// (production resource path is EMP.SURFACE_SET_LUT3D, T-3.4).
//
// Errors via luaL_checknumber / luaL_checkstring on every arg — no
// defaults, no silent fallbacks. Parse failures surface the parser's
// `err` string verbatim (rule 2.32).

#include <lua.hpp>

#include <editor_media_platform/emp_lut3d.h>

#include <cstring>
#include <string>
#include <unordered_map>

namespace {

std::unordered_map<int, emp::Lut3d>& handle_table() {
    static std::unordered_map<int, emp::Lut3d> table;
    return table;
}

int next_handle = 1;

}  // namespace

// qt_lut3d_parse_string(content) → handle_id  | nil, err_msg
static int lua_qt_lut3d_parse_string(lua_State* L) {
    size_t len = 0;
    const char* p = luaL_checklstring(L, 1, &len);
    std::string content(p, len);

    emp::Lut3d lut;
    std::string err;
    if (!emp::parse_cube(content, lut, err)) {
        lua_pushnil(L);
        lua_pushstring(L, err.c_str());
        return 2;
    }
    const int handle = next_handle++;
    handle_table().emplace(handle, std::move(lut));
    lua_pushinteger(L, handle);
    return 1;
}

// qt_lut3d_apply_pixel(handle_id, r, g, b) → r', g', b'
static int lua_qt_lut3d_apply_pixel(lua_State* L) {
    const int handle = static_cast<int>(luaL_checkinteger(L, 1));
    float r = static_cast<float>(luaL_checknumber(L, 2));
    float g = static_cast<float>(luaL_checknumber(L, 3));
    float b = static_cast<float>(luaL_checknumber(L, 4));

    auto& tbl = handle_table();
    auto it = tbl.find(handle);
    if (it == tbl.end()) {
        return luaL_error(L,
            "qt_lut3d_apply_pixel: unknown handle %d (was it freed?)",
            handle);
    }
    emp::apply_lut3d_rgb(r, g, b, it->second);

    lua_pushnumber(L, r);
    lua_pushnumber(L, g);
    lua_pushnumber(L, b);
    return 3;
}

// qt_lut3d_free(handle_id)
static int lua_qt_lut3d_free(lua_State* L) {
    const int handle = static_cast<int>(luaL_checkinteger(L, 1));
    auto& tbl = handle_table();
    auto it = tbl.find(handle);
    if (it == tbl.end()) {
        return luaL_error(L,
            "qt_lut3d_free: unknown handle %d (double-free?)", handle);
    }
    tbl.erase(it);
    return 0;
}

static void register_lut3d_bindings(lua_State* L) {
    lua_pushcfunction(L, lua_qt_lut3d_parse_string);
    lua_setglobal(L, "qt_lut3d_parse_string");
    lua_pushcfunction(L, lua_qt_lut3d_apply_pixel);
    lua_setglobal(L, "qt_lut3d_apply_pixel");
    lua_pushcfunction(L, lua_qt_lut3d_free);
    lua_setglobal(L, "qt_lut3d_free");
}
