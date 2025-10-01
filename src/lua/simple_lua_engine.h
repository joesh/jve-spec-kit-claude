#pragma once

#include <QString>
#include <QWidget>

extern "C" {
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
}

/**
 * LuaJIT engine for Qt widget management
 * Provides real Lua execution with Qt bindings
 */
class SimpleLuaEngine
{
public:
    SimpleLuaEngine();
    ~SimpleLuaEngine();
    
    // Execute a Lua script file
    bool executeFile(const QString& scriptPath);
    
    // Execute Lua code directly
    bool executeString(const QString& luaCode);
    
    // Set a global widget reference that Lua can access
    void setMainWidget(QWidget* widget);
    
    // Get the last error message
    QString getLastError() const;
    
    // Get Lua state for bindings
    lua_State* getLuaState() const { return L; }
    
    // Get last created main window from Lua
    QWidget* getCreatedMainWindow() const;
    
    // Public access to last created main window for Qt bindings
    static QWidget* s_lastCreatedMainWindow;
    
private:
    void setupBindings();
    lua_State* L;
    QString m_lastError;
    QWidget* m_mainWidget = nullptr;
};