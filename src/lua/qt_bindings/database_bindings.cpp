#include "database_bindings.h"
#include "../../core/persistence/sql_executor.h"
#include "../simple_lua_engine.h" // For error handling and logging

#include <QSqlDatabase>
#include <QVariant>
#include <QDebug>

// Metatable name definition
const char* QSQLDATABASE_METATABLE = "JVE.QSqlDatabase";

// Helper to push QSqlDatabase to Lua
void lua_push_qsqldatabase(lua_State* L, const QSqlDatabase& database)
{
    // Store a reference to the database connection name, not the QSqlDatabase object itself.
    // QSqlDatabase objects are values, and copying them can cause issues with connection management.
    // We'll pass the connection name, and retrieve the database from QSqlDatabase::database() by name.
    QString* connectionName = static_cast<QString*>(lua_newuserdata(L, sizeof(QString)));
    new (connectionName) QString(database.connectionName()); // Placement new

    luaL_getmetatable(L, QSQLDATABASE_METATABLE);
    lua_setmetatable(L, -2);
}

// Helper to retrieve QSqlDatabase from Lua
// IMPORTANT: This function allocates a new QSqlDatabase object on the heap using the connection name.
// The caller is responsible for deleting this object after use to prevent memory leaks.
QSqlDatabase* lua_to_qsqldatabase(lua_State* L, int index)
{
    // Retrieve the connection name from userdata
    QString* connectionName = static_cast<QString*>(luaL_checkudata(L, index, QSQLDATABASE_METATABLE));
    if (!connectionName) {
        luaL_error(L, "Expected QSqlDatabase userdata at index %d, got nil", index);
        return nullptr;
    }

    // Get the QSqlDatabase instance by name
    QSqlDatabase* db = new QSqlDatabase(QSqlDatabase::database(*connectionName, false)); // false to not add it if it doesn't exist
    if (!db->isValid() || !db->isOpen()) {
        luaL_error(L, "Invalid or closed QSqlDatabase connection '%s' at index %d", qPrintable(*connectionName), index);
        delete db;
        return nullptr;
    }
    return db;
}


int lua_create_migration_connection(lua_State* L)
{
    const char* projectPath = luaL_checkstring(L, 1);

    QSqlDatabase db = SqlExecutor::createMigrationConnection(projectPath);

    if (db.isValid() && db.isOpen()) {
        lua_push_qsqldatabase(L, db);
    } else {
        lua_pushnil(L);
    }
    return 1;
}

int lua_apply_migration_version(lua_State* L)
{
    QSqlDatabase* db_ptr = lua_to_qsqldatabase(L, 1);
    if (!db_ptr) {
        return luaL_error(L, "Invalid database object provided to apply_migration_version");
    }
    QSqlDatabase& db = *db_ptr; // Use reference

    int version = luaL_checkinteger(L, 2);

    bool success = SqlExecutor::applyMigrationVersion(db, version);
    lua_pushboolean(L, success);
    
    delete db_ptr; // Delete the QSqlDatabase object created by lua_to_qsqldatabase
    return 1;
}

int lua_get_schema_version(lua_State* L)
{
    QSqlDatabase* db_ptr = lua_to_qsqldatabase(L, 1);
    if (!db_ptr) {
        return luaL_error(L, "Invalid database object provided to get_schema_version");
    }
    QSqlDatabase& db = *db_ptr; // Use reference

    int version = SqlExecutor::getSchemaVersion(db);
    lua_pushinteger(L, version);

    delete db_ptr; // Delete the QSqlDatabase object created by lua_to_qsqldatabase
    return 1;
}

int lua_execute_sql_script(lua_State* L)
{
    QSqlDatabase* db_ptr = lua_to_qsqldatabase(L, 1);
    if (!db_ptr) {
        return luaL_error(L, "Invalid database object provided to execute_sql_script");
    }
    QSqlDatabase& db = *db_ptr;

    const char* scriptPath = luaL_checkstring(L, 2);

    bool success = SqlExecutor::executeSqlScript(db, scriptPath);
    lua_pushboolean(L, success);

    delete db_ptr; // Delete the QSqlDatabase object created by lua_to_qsqldatabase
    return 1;
}

// Metatable __gc function for QSqlDatabase userdata
int qsqldatabase_gc(lua_State* L) {
    QString* connectionName = static_cast<QString*>(luaL_checkudata(L, 1, QSQLDATABASE_METATABLE));
    if (connectionName) {
        // Explicitly call destructor for QString
        connectionName->~QString();
        // Remove the database connection from QSqlDatabase's internal list
        // This is important to prevent resource leaks and ensure connections are closed.
        QSqlDatabase::removeDatabase(*connectionName);
        qDebug() << "QSqlDatabase connection removed:" << *connectionName;
    }
    return 0;
}

// Register the database functions and metatable
void register_database_bindings(lua_State* L)
{
    // Create metatable for QSqlDatabase objects
    luaL_newmetatable(L, QSQLDATABASE_METATABLE);
    lua_pushvalue(L, -1); // Duplicate the metatable to be the __index table
    lua_setfield(L, -2, "__index"); // metatable.__index = metatable
    lua_pushcfunction(L, qsqldatabase_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1); // Pop the metatable

    // Register functions in a 'database' sub-table of 'qt_constants'
    lua_newtable(L); // Create a table for database functions
    lua_pushcfunction(L, lua_create_migration_connection);
    lua_setfield(L, -2, "CREATE_MIGRATION_CONNECTION");
    lua_pushcfunction(L, lua_apply_migration_version);
    lua_setfield(L, -2, "APPLY_MIGRATION_VERSION");
    lua_pushcfunction(L, lua_get_schema_version);
    lua_setfield(L, -2, "GET_SCHEMA_VERSION");
    lua_pushcfunction(L, lua_execute_sql_script);
    lua_setfield(L, -2, "EXECUTE_SQL_SCRIPT");
    lua_setfield(L, -2, "DATABASE"); // Assign the table to qt_constants.DATABASE
}

