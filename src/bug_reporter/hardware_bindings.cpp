// Hardware introspection for the bug-reporter pipeline (feature 027 T031).
//
// Exposes:
//   qt_get_cpu_info()        -> { model, cores_physical, cores_logical,
//                                 perf_cores, eff_cores }
//   qt_get_system_memory_mb()-> integer
//   qt_get_uname()           -> { platform, os_version, arch }
//
// Mac uses sysctlbyname (cheap, no shellouts). perf_cores / eff_cores
// query Apple Silicon perflevel knobs which are only present on AS;
// pre-AS hardware returns nil for those columns. Linux/Windows return
// nil for unsupported fields rather than crashing — the spec documents
// these platforms as out-of-scope for v1.

#include <lua.hpp>
#include <sys/utsname.h>

#if defined(__APPLE__)
#include <sys/types.h>
#include <sys/sysctl.h>
#endif

namespace {

#if defined(__APPLE__)
static bool sysctl_int(const char* name, int64_t* out)
{
    int64_t v = 0;
    size_t len = sizeof(v);
    if (sysctlbyname(name, &v, &len, nullptr, 0) != 0) return false;
    *out = v;
    return true;
}
static bool sysctl_str(const char* name, char* buf, size_t cap, size_t* out_len)
{
    *out_len = cap;
    if (sysctlbyname(name, buf, out_len, nullptr, 0) != 0) return false;
    return true;
}
#endif

int lua_qt_get_cpu_info(lua_State* L)
{
    lua_newtable(L);
#if defined(__APPLE__)
    char model[256] = {0};
    size_t model_len = 0;
    if (sysctl_str("machdep.cpu.brand_string", model, sizeof(model), &model_len)) {
        // sysctl_str returns a NUL-terminated cstring with len including
        // the NUL; lua_pushlstring will copy len-1 bytes for the value.
        lua_pushlstring(L, model, model_len > 0 ? model_len - 1 : 0);
    } else {
        lua_pushnil(L);
    }
    lua_setfield(L, -2, "model");

    int64_t cores_phys = 0, cores_log = 0, perf = 0, eff = 0;
    if (sysctl_int("hw.physicalcpu", &cores_phys)) {
        lua_pushinteger(L, static_cast<lua_Integer>(cores_phys));
    } else {
        lua_pushnil(L);
    }
    lua_setfield(L, -2, "cores_physical");

    if (sysctl_int("hw.logicalcpu", &cores_log)) {
        lua_pushinteger(L, static_cast<lua_Integer>(cores_log));
    } else {
        lua_pushnil(L);
    }
    lua_setfield(L, -2, "cores_logical");

    if (sysctl_int("hw.perflevel0.physicalcpu", &perf)) {
        lua_pushinteger(L, static_cast<lua_Integer>(perf));
    } else {
        lua_pushnil(L);
    }
    lua_setfield(L, -2, "perf_cores");

    if (sysctl_int("hw.perflevel1.physicalcpu", &eff)) {
        lua_pushinteger(L, static_cast<lua_Integer>(eff));
    } else {
        lua_pushnil(L);
    }
    lua_setfield(L, -2, "eff_cores");
#else
    lua_pushnil(L); lua_setfield(L, -2, "model");
    lua_pushnil(L); lua_setfield(L, -2, "cores_physical");
    lua_pushnil(L); lua_setfield(L, -2, "cores_logical");
    lua_pushnil(L); lua_setfield(L, -2, "perf_cores");
    lua_pushnil(L); lua_setfield(L, -2, "eff_cores");
#endif
    return 1;
}

int lua_qt_get_system_memory_mb(lua_State* L)
{
#if defined(__APPLE__)
    int64_t bytes = 0;
    if (sysctl_int("hw.memsize", &bytes)) {
        lua_pushinteger(L, static_cast<lua_Integer>(bytes / (1024 * 1024)));
        return 1;
    }
#endif
    lua_pushnil(L);
    return 1;
}

int lua_qt_get_uname(lua_State* L)
{
    struct utsname u{};
    if (uname(&u) != 0) {
        return luaL_error(L, "qt_get_uname: uname syscall failed");
    }
    lua_newtable(L);
    lua_pushstring(L, u.sysname); lua_setfield(L, -2, "platform");
    lua_pushstring(L, u.release); lua_setfield(L, -2, "os_version");
    lua_pushstring(L, u.machine); lua_setfield(L, -2, "arch");
    return 1;
}

} // namespace

extern "C" void register_bug_reporter_hardware_cpu_bindings(lua_State* L)
{
    lua_pushcfunction(L, lua_qt_get_cpu_info); lua_setglobal(L, "qt_get_cpu_info");
    lua_pushcfunction(L, lua_qt_get_system_memory_mb); lua_setglobal(L, "qt_get_system_memory_mb");
    lua_pushcfunction(L, lua_qt_get_uname); lua_setglobal(L, "qt_get_uname");
}
