#pragma once

#include "command.h"
#include <QSqlDatabase>
#include <QString>
#include <QList>

extern "C" {
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>
}

/**
 * CommandManager: C++ wrapper for Lua CommandManager
 *
 * This is a thin wrapper that delegates all command execution
 * to the Lua implementation at src/lua/core/command_manager.lua
 *
 * The actual command logic is implemented in Lua as per architecture.
 */
class CommandManager
{
public:
    explicit CommandManager(QSqlDatabase& database);
    ~CommandManager();

    // Command execution
    ExecutionResult execute(Command& command);
    ExecutionResult executeUndo(const Command& originalCommand);

    // Batch operations
    QList<ExecutionResult> executeBatch(QList<Command>& commands);

    // State management
    void revertToSequence(int sequenceNumber);
    QString getProjectState(const QString& projectId) const;
    Command getCurrentState() const;

    // Replay functionality
    ReplayResult replayFromSequence(int startSequenceNumber);
    ReplayResult replayAll();

    // Sequence integrity
    bool validateSequenceIntegrity() const;
    void repairSequenceNumbers();

private:
    QSqlDatabase& m_database;
    lua_State* L;

    void initializeLuaCommandManager();
    ExecutionResult callLuaExecute(Command& command);
};
