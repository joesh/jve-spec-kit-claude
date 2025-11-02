#include "jve/eventlog/SqliteStore.hpp"

#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <vector>

namespace fs = std::filesystem;

namespace jve::eventlog {

sqlite3* open_db(const std::string& path) {
    sqlite3* db = nullptr;
    if (sqlite3_open(path.c_str(), &db) != SQLITE_OK) {
        throw std::runtime_error("Failed to open SQLite database at " + path);
    }

    exec_sql(db, "PRAGMA journal_mode=WAL;");
    exec_sql(db, "PRAGMA synchronous=NORMAL;");
    exec_sql(db, "PRAGMA foreign_keys=ON;");
    return db;
}

void exec_sql(sqlite3* db, const std::string& sql) {
    char* errmsg = nullptr;
    if (sqlite3_exec(db, sql.c_str(), nullptr, nullptr, &errmsg) != SQLITE_OK) {
        std::string message = errmsg ? errmsg : "unknown error";
        sqlite3_free(errmsg);
        throw std::runtime_error("SQLite exec failed: " + message);
    }
}

void load_schema(sqlite3* db, const std::string& schema_dir) {
    std::vector<fs::path> files;
    for (const auto& entry : fs::directory_iterator(schema_dir)) {
        if (entry.path().extension() == ".sql") {
            files.push_back(entry.path());
        }
    }
    std::sort(files.begin(), files.end());
    for (const auto& file : files) {
        std::ifstream in(file);
        if (!in) {
            throw std::runtime_error("Failed to open schema file: " + file.string());
        }
        std::string sql((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
        exec_sql(db, sql);
    }
}

}  // namespace jve::eventlog
