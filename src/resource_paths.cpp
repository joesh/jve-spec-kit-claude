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

    // .app-bundle awareness (macOS dev builds): when the executable
    // lives inside `JVEEditor.app/Contents/MacOS/`, Qt reports app_dir
    // as that nested path. Walk back up to the bundle's parent
    // directory before doing the upward `src/lua` search — otherwise
    // the bundle's 3 extra path components push the repo root past the
    // existing 2-level ceiling. Detect by literal substring; the
    // ".app/Contents/MacOS" suffix is the macOS bundle convention.
    QString qt_dir = QString::fromStdString(app_dir_path);
    int bundle_idx = qt_dir.indexOf(".app/Contents/MacOS");
    QString search_dir = (bundle_idx >= 0)
        ? QFileInfo(qt_dir.left(bundle_idx + 4)).absolutePath()  // parent of .app
        : qt_dir;

    // Check up to N levels up from search_dir. 2 was enough for the
    // bare-binary layout (build/bin/JVEEditor → repo root); kept at 2
    // for the bundle case too since we already jumped past .app.
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
    
    // Get current package.path
    lua_getglobal(lua_state, "package");
    lua_getfield(lua_state, -1, "path");
    std::string current_path;
    if (lua_isstring(lua_state, -1)) {
        current_path = lua_tostring(lua_state, -1);
    }
    lua_pop(lua_state, 1); // Remove path value
    
    // Add src/lua directory to package.path 
    // The Lua modules use dotted notation like 'ui.inspector.view'
    // So we need to add the src/lua directory to the path
    std::string new_path = scripts_dir + "/?.lua;" + 
                          scripts_dir + "/?/init.lua;";
    if (!current_path.empty()) {
        new_path += current_path;
    }
    
    // Set the new package.path
    lua_pushstring(lua_state, new_path.c_str());
    lua_setfield(lua_state, -2, "path");
    lua_pop(lua_state, 1); // Remove package table
    
    qCDebug(jveResources, "Lua package path configured: %s", scripts_dir.c_str());
}

bool ResourcePaths::pathExists(const std::string& path) {
    return std::filesystem::exists(path) && std::filesystem::is_directory(path);
}

}
