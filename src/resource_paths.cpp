#include "resource_paths.h"
#include <QApplication>
#include <QDir>
#include <QFileInfo>
#include <QLoggingCategory>
#include <filesystem>
#include <iostream>
#include <lua.hpp>

namespace JVE {

Q_LOGGING_CATEGORY(jveResources, "jve.resources")

std::string ResourcePaths::cached_app_directory_;
bool ResourcePaths::app_directory_cached_ = false;

std::string ResourcePaths::getApplicationDirectory() {
    if (app_directory_cached_) {
        return cached_app_directory_;
    }
    
    // Start with Qt's application directory path
    std::string app_dir_path = QApplication::applicationDirPath().toStdString();

    QString qt_dir = QString::fromStdString(app_dir_path);
    int bundle_idx = qt_dir.indexOf(".app/Contents/MacOS");

    // Deployed-bundle layout: src/lua + keymaps + resources are bundled
    // into jve.app/Contents/Resources/ at build time (see CMakeLists.txt
    // post-build rsync). When that bundle layout is present, the
    // .app is self-contained — no upward search required, no
    // dependency on the repo tree. This is the production path.
    if (bundle_idx >= 0) {
        std::string resources_dir =
            qt_dir.left(bundle_idx + 4).toStdString() + "/Contents/Resources";
        if (pathExists(resources_dir + "/src/lua")) {
            cached_app_directory_ = resources_dir;
            app_directory_cached_ = true;
            return cached_app_directory_;
        }
    }

    // Dev-build fallback: bare-binary layout (build/bin/jve → repo root)
    // or a not-yet-bundled .app sitting in the source tree. Walk up
    // looking for src/lua. Bundle-case starts from the .app's parent.
    QString search_dir = (bundle_idx >= 0)
        ? QFileInfo(qt_dir.left(bundle_idx + 4)).absolutePath()
        : qt_dir;
    QString cursor = search_dir;
    for (int i = 0; i <= 2; ++i) {
        std::string candidate_dir = cursor.toStdString();
        if (pathExists(candidate_dir + "/src/lua")) {
            cached_app_directory_ = candidate_dir;
            app_directory_cached_ = true;
            return cached_app_directory_;
        }
        cursor = QFileInfo(cursor).absolutePath();
    }
    // RULE 2.13: No fallbacks - src/lua directory is required for operation
    std::string error_msg = "CRITICAL ERROR: Cannot locate required src/lua "
        "directory near executable: " + app_dir_path
        + " (searched up to 2 levels from " + search_dir.toStdString()
        + ") - fix installation or build configuration";
    std::cerr << error_msg << std::endl;
    throw std::runtime_error(error_msg);
    app_directory_cached_ = true;
    return cached_app_directory_;
}

std::string ResourcePaths::getScriptsDirectory() {
    return getApplicationDirectory() + "/src/lua";
}

std::string ResourcePaths::getScriptPath(const std::string& relative_path) {
    return getScriptsDirectory() + "/" + relative_path;
}

void ResourcePaths::setupLuaPackagePaths(lua_State* lua_state) {
    std::string scripts_dir = getScriptsDirectory();
    std::string app_dir = getApplicationDirectory();

    lua_getglobal(lua_state, "package");

    // package.path — Lua sources. Prepend src/lua so vendored modules
    // (dkjson, tinytoml, uuid, etc.) and project modules resolve.
    lua_getfield(lua_state, -1, "path");
    std::string current_path = lua_isstring(lua_state, -1) ? lua_tostring(lua_state, -1) : "";
    lua_pop(lua_state, 1);
    std::string new_path = scripts_dir + "/?.lua;" + scripts_dir + "/?/init.lua;";
    if (!current_path.empty()) new_path += current_path;
    lua_pushstring(lua_state, new_path.c_str());
    lua_setfield(lua_state, -2, "path");

    // package.cpath — Lua C modules. Prepend lua_modules/ (bundled by
    // CMake POST_BUILD next to src/lua) so lxp.so and any future C
    // modules load without a host-side luarocks install. Only present
    // in bundled .app deployments; in dev raw-binary runs the dir
    // may not exist and require('lxp') falls through to the system
    // luarocks path (which dev machines have).
    std::string modules_dir = app_dir + "/lua_modules";
    lua_getfield(lua_state, -1, "cpath");
    std::string current_cpath = lua_isstring(lua_state, -1) ? lua_tostring(lua_state, -1) : "";
    lua_pop(lua_state, 1);
    std::string new_cpath = modules_dir + "/?.so;";
    if (!current_cpath.empty()) new_cpath += current_cpath;
    lua_pushstring(lua_state, new_cpath.c_str());
    lua_setfield(lua_state, -2, "cpath");

    lua_pop(lua_state, 1); // package table

    qCDebug(jveResources, "Lua package.path: %s", scripts_dir.c_str());
    qCDebug(jveResources, "Lua package.cpath: %s", modules_dir.c_str());
}

bool ResourcePaths::pathExists(const std::string& path) {
    return std::filesystem::exists(path) && std::filesystem::is_directory(path);
}

}
