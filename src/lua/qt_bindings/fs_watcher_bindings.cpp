// QFileSystemWatcher Lua bindings
// Exposes file/directory change monitoring to Lua via qt_constants.FS subtable.
// Singleton QFileSystemWatcher; callbacks stored as luaL_ref in LUA_REGISTRYINDEX.

#include <QFileSystemWatcher>
#include <lua.hpp>
#include "assert_handler.h"

namespace {

static QFileSystemWatcher* s_watcher = nullptr;
static lua_State* s_L = nullptr;
static int s_file_changed_ref = LUA_NOREF;
static int s_dir_changed_ref = LUA_NOREF;

static void ensure_watcher() {
    if (!s_watcher) {
        s_watcher = new QFileSystemWatcher();

        QObject::connect(s_watcher, &QFileSystemWatcher::fileChanged,
            [](const QString& path) {
                if (s_L && s_file_changed_ref != LUA_NOREF) {
                    lua_rawgeti(s_L, LUA_REGISTRYINDEX, s_file_changed_ref);
                    lua_pushstring(s_L, path.toUtf8().constData());
                    if (lua_pcall(s_L, 1, 0, 0) != 0) {
                        const char* err = lua_tostring(s_L, -1);
                        std::string msg = std::string("FS file_changed callback error: ") + (err ? err : "(unknown)");
                        lua_pop(s_L, 1);
                        JVE_FAIL(msg.c_str());
                    }
                }
            });

        QObject::connect(s_watcher, &QFileSystemWatcher::directoryChanged,
            [](const QString& path) {
                if (s_L && s_dir_changed_ref != LUA_NOREF) {
                    lua_rawgeti(s_L, LUA_REGISTRYINDEX, s_dir_changed_ref);
                    lua_pushstring(s_L, path.toUtf8().constData());
                    if (lua_pcall(s_L, 1, 0, 0) != 0) {
                        const char* err = lua_tostring(s_L, -1);
                        std::string msg = std::string("FS dir_changed callback error: ") + (err ? err : "(unknown)");
                        lua_pop(s_L, 1);
                        JVE_FAIL(msg.c_str());
                    }
                }
            });
    }
}

// FS.WATCH_FILE(path) -> bool
static int lua_fs_watch_file(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    ensure_watcher();
    bool ok = s_watcher->addPath(QString::fromUtf8(path));
    lua_pushboolean(L, ok);
    return 1;
}

// FS.WATCH_DIR(path) -> bool
static int lua_fs_watch_dir(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    ensure_watcher();
    bool ok = s_watcher->addPath(QString::fromUtf8(path));
    lua_pushboolean(L, ok);
    return 1;
}

// FS.UNWATCH_FILE(path) -> bool
static int lua_fs_unwatch_file(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    if (!s_watcher) { lua_pushboolean(L, false); return 1; }
    bool ok = s_watcher->removePath(QString::fromUtf8(path));
    lua_pushboolean(L, ok);
    return 1;
}

// FS.UNWATCH_DIR(path) -> bool
static int lua_fs_unwatch_dir(lua_State* L) {
    const char* path = luaL_checkstring(L, 1);
    if (!s_watcher) { lua_pushboolean(L, false); return 1; }
    bool ok = s_watcher->removePath(QString::fromUtf8(path));
    lua_pushboolean(L, ok);
    return 1;
}

// FS.SET_FILE_CHANGED_CB(fn) — fn must be a function
static int lua_fs_set_file_changed_cb(lua_State* L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    ensure_watcher();
    s_L = L;
    if (s_file_changed_ref != LUA_NOREF) {
        luaL_unref(L, LUA_REGISTRYINDEX, s_file_changed_ref);
    }
    lua_pushvalue(L, 1);
    s_file_changed_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    return 0;
}

// FS.SET_DIR_CHANGED_CB(fn) — fn must be a function
static int lua_fs_set_dir_changed_cb(lua_State* L) {
    luaL_checktype(L, 1, LUA_TFUNCTION);
    ensure_watcher();
    s_L = L;
    if (s_dir_changed_ref != LUA_NOREF) {
        luaL_unref(L, LUA_REGISTRYINDEX, s_dir_changed_ref);
    }
    lua_pushvalue(L, 1);
    s_dir_changed_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    return 0;
}

// FS.CLEAR_ALL() — remove all watched paths but preserve callbacks.
// Callbacks persist across project changes; only overridden by SET_*_CB.
static int lua_fs_clear_all(lua_State* L) {
    (void)L;
    if (s_watcher) {
        auto files = s_watcher->files();
        if (!files.isEmpty()) s_watcher->removePaths(files);
        auto dirs = s_watcher->directories();
        if (!dirs.isEmpty()) s_watcher->removePaths(dirs);
    }
    return 0;
}

} // namespace

void register_fs_watcher_bindings(lua_State* L) {
    // L has qt_constants table on top of stack
    lua_newtable(L);
    lua_pushcfunction(L, lua_fs_watch_file);       lua_setfield(L, -2, "WATCH_FILE");
    lua_pushcfunction(L, lua_fs_watch_dir);         lua_setfield(L, -2, "WATCH_DIR");
    lua_pushcfunction(L, lua_fs_unwatch_file);      lua_setfield(L, -2, "UNWATCH_FILE");
    lua_pushcfunction(L, lua_fs_unwatch_dir);       lua_setfield(L, -2, "UNWATCH_DIR");
    lua_pushcfunction(L, lua_fs_set_file_changed_cb); lua_setfield(L, -2, "SET_FILE_CHANGED_CB");
    lua_pushcfunction(L, lua_fs_set_dir_changed_cb);  lua_setfield(L, -2, "SET_DIR_CHANGED_CB");
    lua_pushcfunction(L, lua_fs_clear_all);         lua_setfield(L, -2, "CLEAR_ALL");
    lua_setfield(L, -2, "FS");
}
