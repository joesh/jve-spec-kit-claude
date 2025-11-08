#include "command_manager.h"

#include <QDebug>
#include <QLoggingCategory>

#include "core/resource_paths.h"
#include "core/sqlite_env.h"

Q_LOGGING_CATEGORY(jveCommandManager, "jve.command.manager")

CommandManager::CommandManager(QSqlDatabase& database)
    : m_database(database), L(nullptr)
{
    qCDebug(jveCommandManager, "Initializing CommandManager (Lua wrapper)");
    qCDebug(jveCommandManager, "Using database connection '%s'", qPrintable(m_database.connectionName()));

    JVE::EnsureSqliteLibraryEnv();

    // Initialize Lua state
    L = luaL_newstate();
    luaL_openlibs(L);
    JVE::ResourcePaths::setupLuaPackagePaths(L);

    initializeLuaCommandManager();
}

CommandManager::~CommandManager()
{
    if (L) {
        lua_close(L);
    }
}

void CommandManager::initializeLuaCommandManager()
{
    // Load the Lua CommandManager module
    int result = luaL_dofile(L, "src/lua/core/command_manager.lua");
    if (result != LUA_OK) {
        const char* error = lua_tostring(L, -1);
        qCCritical(jveCommandManager, "Failed to load Lua CommandManager: %s", error);
        lua_pop(L, 1);
        return;
    }

    // Store the module in registry for later use
    lua_setfield(L, LUA_REGISTRYINDEX, "command_manager");

    // TODO: Initialize Lua CommandManager with database connection
    // This would require exposing QSqlDatabase to Lua through bindings

    qCDebug(jveCommandManager, "Lua CommandManager initialized");
}

ExecutionResult CommandManager::callLuaExecute(Command& command)
{
    Q_UNUSED(command);

    ExecutionResult result;
    result.success = false;

    // Get the command_manager module from registry
    lua_getfield(L, LUA_REGISTRYINDEX, "command_manager");
    if (!lua_istable(L, -1)) {
        qCWarning(jveCommandManager, "command_manager module not found in registry");
        result.errorMessage = "Lua CommandManager not initialized";
        lua_pop(L, 1);
        return result;
    }

    // Get the execute function
    lua_getfield(L, -1, "execute");
    if (!lua_isfunction(L, -1)) {
        qCWarning(jveCommandManager, "execute function not found in command_manager");
        result.errorMessage = "execute function not found";
        lua_pop(L, 2);
        return result;
    }

    // TODO: Push command as Lua table
    // For now, just call with nil
    lua_pushnil(L);

    // Call execute(command)
    if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
        const char* error = lua_tostring(L, -1);
        qCWarning(jveCommandManager, "Lua execute failed: %s", error);
        result.errorMessage = QString("Lua error: %1").arg(error);
        lua_pop(L, 1);
        return result;
    }

    // TODO: Parse result table from Lua
    // For now, assume success
    result.success = true;

    lua_pop(L, 1); // Pop result
    lua_pop(L, 1); // Pop module

    return result;
}

ExecutionResult CommandManager::execute(Command& command)
{
    qCDebug(jveCommandManager, "Executing command (delegating to Lua): %s", qPrintable(command.type()));

    // For now, stub implementation that always fails
    // This is intentional per TDD - tests should fail until Lua integration is complete
    ExecutionResult result;
    result.success = false;
    result.errorMessage = "CommandManager is now implemented in Lua. C++ tests need to be updated or removed.";

    qCWarning(jveCommandManager, "C++ CommandManager is deprecated. Use Lua implementation instead.");

    return result;
}

ExecutionResult CommandManager::executeUndo(const Command& originalCommand)
{
    Q_UNUSED(originalCommand);

    qCDebug(jveCommandManager, "Executing undo (delegating to Lua)");

    ExecutionResult result;
    result.success = false;
    result.errorMessage = "CommandManager is now implemented in Lua";
    return result;
}

QList<ExecutionResult> CommandManager::executeBatch(QList<Command>& commands)
{
    qCDebug(jveCommandManager, "Executing batch (delegating to Lua)");

    QList<ExecutionResult> results;
    for (auto& cmd : commands) {
        results.append(execute(cmd));
    }
    return results;
}

void CommandManager::revertToSequence(int sequenceNumber)
{
    qCInfo(jveCommandManager, "Reverting to sequence: %d", sequenceNumber);
    // Stub - Lua implementation needed
}

QString CommandManager::getProjectState(const QString& projectId) const
{
    Q_UNUSED(projectId);

    qCDebug(jveCommandManager, "Getting project state (stub)");
    return "";
}

Command CommandManager::getCurrentState() const
{
    return Command::create("StateSnapshot", "stub-project");
}

ReplayResult CommandManager::replayFromSequence(int startSequenceNumber)
{
    qCInfo(jveCommandManager, "Replaying from sequence: %d", startSequenceNumber);

    ReplayResult result;
    result.success = false;
    result.commandsReplayed = 0;
    result.errorMessage = "CommandManager is now implemented in Lua";
    return result;
}

ReplayResult CommandManager::replayAll()
{
    return replayFromSequence(1);
}

bool CommandManager::validateSequenceIntegrity() const
{
    qCDebug(jveCommandManager, "Validating sequence integrity (stub)");
    return true;
}

void CommandManager::repairSequenceNumbers()
{
    qCInfo(jveCommandManager, "Repairing sequence numbers (stub)");
}
