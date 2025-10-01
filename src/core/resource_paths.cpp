#include "resource_paths.h"
#include <QApplication>
#include <QDir>
#include <QFileInfo>
#include <filesystem>
#include <iostream>
#include <lua.hpp>

namespace JVE {

std::string ResourcePaths::cached_app_directory_;
bool ResourcePaths::app_directory_cached_ = false;

std::string ResourcePaths::getApplicationDirectory() {
    if (app_directory_cached_) {
        return cached_app_directory_;
    }
    
    // Start with Qt's application directory path
    std::string app_dir_path = QApplication::applicationDirPath().toStdString();
    
    // Check if src/lua directory exists relative to the executable  
    std::string scripts_path = app_dir_path + "/src/lua";
    if (pathExists(scripts_path)) {
        cached_app_directory_ = app_dir_path;
        app_directory_cached_ = true;
        return cached_app_directory_;
    }
    
    // Check one level up (for executables in build directories)
    std::string parent_dir = QDir(QString::fromStdString(app_dir_path)).absolutePath().toStdString();
    parent_dir = QFileInfo(QString::fromStdString(parent_dir)).absolutePath().toStdString();
    scripts_path = parent_dir + "/src/lua";
    if (pathExists(scripts_path)) {
        cached_app_directory_ = parent_dir;
        app_directory_cached_ = true;
        return cached_app_directory_;
    }
    
    // Check two levels up (for deeply nested build directories)
    std::string grandparent_dir = QFileInfo(QString::fromStdString(parent_dir)).absolutePath().toStdString();
    scripts_path = grandparent_dir + "/src/lua";
    if (pathExists(scripts_path)) {
        cached_app_directory_ = grandparent_dir;
        app_directory_cached_ = true;
        return cached_app_directory_;
    }
    
    // RULE 2.13: No fallbacks - src/lua directory is required for operation
    std::string error_msg = "CRITICAL ERROR: Cannot locate required src/lua directory relative to executable: " + app_dir_path + " - fix installation or build configuration";
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
    
    std::cout << "📁 Lua package path configured: " << scripts_dir << std::endl;
}

bool ResourcePaths::pathExists(const std::string& path) {
    return std::filesystem::exists(path) && std::filesystem::is_directory(path);
}

}