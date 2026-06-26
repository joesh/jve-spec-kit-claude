// GPU introspection via Metal for the bug-reporter pipeline
// (feature 027 T031). macOS-only.
//
// qt_get_gpu_info_metal() ->
//   { vendor, model, memory_mb, api = "Metal", unified_memory }
//
// MTLCreateSystemDefaultDevice gives us the primary GPU; on Apple
// Silicon that's the only GPU. recommendedMaxWorkingSetSize is the
// budget Metal tells apps to stay under — it's the user-visible
// memory headline for a unified-memory device.

#include <lua.hpp>
#import <Metal/Metal.h>
#include <string>

namespace {

static const char* vendor_from_name(const std::string& name)
{
    if (name.rfind("Apple", 0) == 0) return "Apple";
    if (name.find("AMD") != std::string::npos) return "AMD";
    if (name.find("Intel") != std::string::npos) return "Intel";
    if (name.find("NVIDIA") != std::string::npos) return "NVIDIA";
    return "Unknown";
}

int lua_qt_get_gpu_info_metal(lua_State* L)
{
    lua_newtable(L);
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            lua_pushstring(L, "Unknown"); lua_setfield(L, -2, "vendor");
            lua_pushnil(L); lua_setfield(L, -2, "model");
            lua_pushnil(L); lua_setfield(L, -2, "memory_mb");
            lua_pushstring(L, "Metal"); lua_setfield(L, -2, "api");
            lua_pushboolean(L, 0); lua_setfield(L, -2, "unified_memory");
            return 1;
        }
        std::string name([[device name] UTF8String] ?: "");
        lua_pushstring(L, vendor_from_name(name)); lua_setfield(L, -2, "vendor");
        lua_pushstring(L, name.c_str()); lua_setfield(L, -2, "model");

        uint64_t budget = [device recommendedMaxWorkingSetSize];
        lua_pushinteger(L, static_cast<lua_Integer>(budget / (1024 * 1024)));
        lua_setfield(L, -2, "memory_mb");

        lua_pushstring(L, "Metal"); lua_setfield(L, -2, "api");

        BOOL unified = [device hasUnifiedMemory];
        lua_pushboolean(L, unified ? 1 : 0); lua_setfield(L, -2, "unified_memory");
    }
    return 1;
}

} // namespace

extern "C" void register_bug_reporter_hardware_gpu_bindings(lua_State* L)
{
    lua_pushcfunction(L, lua_qt_get_gpu_info_metal);
    lua_setglobal(L, "qt_get_gpu_info_metal");
}
