#include "simple_lua_engine.h"
#include "qt_bindings.h"
#include "ui/timeline/scriptable_timeline.h"
#include "core/resource_paths.h"
#include <QDebug>
#include <QDir>
#include <QFileInfo>

SimpleLuaEngine::SimpleLuaEngine() : L(nullptr)
{
    qDebug() << "SimpleLuaEngine: Initializing LuaJIT engine";
    
    // Create new Lua state
    L = luaL_newstate();
    if (!L) {
        qCritical() << "Failed to create Lua state";
        return;
    }
    
    // Load standard libraries
    luaL_openlibs(L);

    // Install global error handler with stack traces
    const char* errorHandler = R"(
        -- Global error handler that prints detailed stack traces
        function __jve_error_handler(err)
            local trace = debug.traceback("ERROR: " .. tostring(err), 2)
            print(trace)
            return trace
        end

        -- Override default error() to always include stack trace
        local original_error = error
        function error(message, level)
            level = level or 1
            local trace = debug.traceback(tostring(message), level + 1)
            print("ERROR with stack trace:")
            print(trace)
            original_error(message, level + 1)
        end

        -- Install panic handler for pcall/xpcall
        debug.sethook(function()
            -- This doesn't get called for regular errors, but useful for debugging
        end, "", 0)
    )";

    int result = luaL_dostring(L, errorHandler);
    if (result != LUA_OK) {
        qCritical() << "Failed to install Lua error handler:" << lua_tostring(L, -1);
        lua_pop(L, 1);
    }

    // Setup Lua package paths for module loading
    JVE::ResourcePaths::setupLuaPackagePaths(L);

    // Setup Qt bindings
    setupBindings();
}

SimpleLuaEngine::~SimpleLuaEngine()
{
    qDebug() << "SimpleLuaEngine: Shutting down";
    if (L) {
        lua_close(L);
        L = nullptr;
    }
}

bool SimpleLuaEngine::executeFile(const QString& scriptPath)
{
    qDebug() << "SimpleLuaEngine: Executing script:" << scriptPath;
    
    if (!L) {
        m_lastError = "Lua state not initialized";
        return false;
    }
    
    QFileInfo fileInfo(scriptPath);
    if (!fileInfo.exists()) {
        m_lastError = QString("Script file does not exist: %1").arg(scriptPath);
        qWarning() << m_lastError;
        return false;
    }
    
    // Load and execute the Lua file
    int result = luaL_loadfile(L, scriptPath.toStdString().c_str());
    if (result != LUA_OK) {
        m_lastError = QString("Failed to load script: %1").arg(lua_tostring(L, -1));
        lua_pop(L, 1);
        return false;
    }
    
    // Push error handler onto stack
    lua_getglobal(L, "__jve_error_handler");
    int errHandlerIndex = lua_gettop(L) - 1;  // Error handler is below the function
    lua_insert(L, errHandlerIndex);  // Move error handler below function

    result = lua_pcall(L, 0, 0, errHandlerIndex);
    if (result != LUA_OK) {
        m_lastError = QString("Failed to execute script: %1").arg(lua_tostring(L, -1));
        lua_pop(L, 1);
        return false;
    }

    lua_pop(L, 1);  // Pop error handler
    
    qDebug() << "SimpleLuaEngine: Successfully executed script:" << scriptPath;
    return true;
}

bool SimpleLuaEngine::executeString(const QString& luaCode)
{
    qDebug() << "SimpleLuaEngine: Executing Lua code:" << luaCode.left(100) << "...";
    
    if (!L) {
        m_lastError = "Lua state not initialized";
        return false;
    }
    
    // Load and execute the Lua string
    int result = luaL_loadstring(L, luaCode.toStdString().c_str());
    if (result != LUA_OK) {
        m_lastError = QString("Failed to load Lua code: %1").arg(lua_tostring(L, -1));
        lua_pop(L, 1);
        return false;
    }
    
    // Push error handler onto stack
    lua_getglobal(L, "__jve_error_handler");
    int errHandlerIndex = lua_gettop(L) - 1;  // Error handler is below the function
    lua_insert(L, errHandlerIndex);  // Move error handler below function

    result = lua_pcall(L, 0, 0, errHandlerIndex);
    if (result != LUA_OK) {
        m_lastError = QString("Failed to execute Lua code: %1").arg(lua_tostring(L, -1));
        lua_pop(L, 1);
        return false;
    }

    lua_pop(L, 1);  // Pop error handler

    return true;
}

void SimpleLuaEngine::setMainWidget(QWidget* widget)
{
    m_mainWidget = widget;
    qDebug() << "SimpleLuaEngine: Main widget set:" << widget;
}

QString SimpleLuaEngine::getLastError() const
{
    return m_lastError;
}

QWidget* SimpleLuaEngine::s_lastCreatedMainWindow = nullptr;

QWidget* SimpleLuaEngine::getCreatedMainWindow() const
{
    return s_lastCreatedMainWindow;
}

void SimpleLuaEngine::setupBindings()
{
    qDebug() << "SimpleLuaEngine: Setting up Qt bindings with LuaJIT";

    if (!L) {
        qCritical() << "Cannot setup bindings: Lua state not initialized";
        return;
    }

    // Register Qt bindings
    registerQtBindings(L);

    // Register timeline bindings
    registerTimelineBindings(L);
}