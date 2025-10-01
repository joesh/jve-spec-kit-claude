#include "simple_lua_engine.h"
#include "qt_bindings.h"
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
    
    result = lua_pcall(L, 0, 0, 0);
    if (result != LUA_OK) {
        m_lastError = QString("Failed to execute script: %1").arg(lua_tostring(L, -1));
        lua_pop(L, 1);
        return false;
    }
    
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
    
    result = lua_pcall(L, 0, 0, 0);
    if (result != LUA_OK) {
        m_lastError = QString("Failed to execute Lua code: %1").arg(lua_tostring(L, -1));
        lua_pop(L, 1);
        return false;
    }
    
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
}