#pragma once

#include <sqlite3.h>

#include <string>

namespace jve::eventlog {

sqlite3* open_db(const std::string& path);

void exec_sql(sqlite3* db, const std::string& sql);

void load_schema(sqlite3* db, const std::string& schema_dir);

}  // namespace jve::eventlog

