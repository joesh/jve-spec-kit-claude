#pragma once

#include <lua.hpp>
#include <QSqlDatabase>

// Forward declarations for Lua C functions
int lua_create_migration_connection(lua_State* L);
int lua_apply_migration_version(lua_State* L);
int lua_get_schema_version(lua_State* L);
int lua_execute_sql_script(lua_State* L);

// Metatable name for QSqlDatabase objects in Lua
extern const char* QSQLDATABASE_METATABLE;

// Helper to push QSqlDatabase to Lua
void lua_push_qsqldatabase(lua_State* L, const QSqlDatabase& database);
// Helper to retrieve QSqlDatabase from Lua. Note: This returns a pointer to a NEW QSqlDatabase object.
// The caller is responsible for deleting it.
QSqlDatabase* lua_to_qsqldatabase(lua_State* L, int index);

// Registration function for database bindings
void register_database_bindings(lua_State* L);
