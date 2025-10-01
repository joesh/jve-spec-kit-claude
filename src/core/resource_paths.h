#pragma once

#include <string>

// Forward declarations
struct lua_State;

namespace JVE {

/**
 * Resource path management for cross-directory execution support
 * 
 * Automatically detects the application installation directory and provides
 * proper paths to scripts, assets, and configuration files regardless of 
 * the current working directory.
 */
class ResourcePaths {
public:
    /**
     * Get the application installation directory
     * 
     * This searches for the actual installation directory by:
     * 1. Checking QApplication::applicationDirPath()
     * 2. Looking for the scripts directory relative to the executable
     * 3. Falling back to compile-time paths if needed
     * 
     * @return Absolute path to the application installation directory
     */
    static std::string getApplicationDirectory();
    
    /**
     * Get the scripts directory path
     * 
     * @return Absolute path to the scripts directory
     */
    static std::string getScriptsDirectory();
    
    /**
     * Get path to a specific script file
     * 
     * @param relative_path Path relative to scripts directory (e.g., "core/ui_toolkit.lua")
     * @return Absolute path to the script file
     */
    static std::string getScriptPath(const std::string& relative_path);
    
    /**
     * Set up Lua package paths for module loading
     * 
     * Configures Lua's package.path to include the scripts directory
     * so that Lua modules can find each other using require().
     * 
     * @param lua_state The Lua state to configure
     */
    static void setupLuaPackagePaths(lua_State* lua_state);
    
    /**
     * Check if a path exists and is accessible
     * 
     * @param path Path to check
     * @return true if path exists and is readable
     */
    static bool pathExists(const std::string& path);

private:
    static std::string cached_app_directory_;
    static bool app_directory_cached_;
};

}