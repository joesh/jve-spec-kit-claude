#include "jve/eventlog/Reducer.hpp"
#include "jve/eventlog/SqliteStore.hpp"

#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>

namespace fs = std::filesystem;

int main(int argc, char** argv) {
    std::string db_path;
    std::string schema_dir;
    std::string log_path;
    std::string expected_path;

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if (arg == "--db" && i + 1 < argc) {
            db_path = argv[++i];
        } else if (arg == "--schema-dir" && i + 1 < argc) {
            schema_dir = argv[++i];
        } else if (arg == "--log" && i + 1 < argc) {
            log_path = argv[++i];
        } else if (arg == "--expect" && i + 1 < argc) {
            expected_path = argv[++i];
        }
    }

    if (db_path.empty() || schema_dir.empty() || log_path.empty() || expected_path.empty()) {
        std::cerr << "Usage: test_golden_replay --db <path> --schema-dir <dir> --log <file> --expect <file>\n";
        return 2;
    }

    const fs::path dbPath(db_path);
    if (!dbPath.parent_path().empty()) {
        fs::create_directories(dbPath.parent_path());
    }
    if (fs::exists(dbPath)) {
        fs::remove(dbPath);
    }

    sqlite3* db = jve::eventlog::open_db(db_path);
    jve::eventlog::load_schema(db, schema_dir);
    jve::eventlog::foldLog(db, log_path);
    std::string checksum = jve::eventlog::computeReadModelChecksum(db);

    std::ifstream expected_stream(expected_path);
    std::string expected_checksum;
    std::getline(expected_stream, expected_checksum);

    if (checksum == expected_checksum) {
        std::cout << "OK " << checksum << "\n";
        return 0;
    }

    std::cerr << "Checksum mismatch\nExpected: " << expected_checksum << "\nActual:   " << checksum << "\n";
    return 1;
}
