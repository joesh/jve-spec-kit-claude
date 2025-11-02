#pragma once

#include "jve/eventlog/Event.hpp"
#include "jve/eventlog/SqliteStore.hpp"

#include <sqlite3.h>

#include <string>

namespace jve::eventlog {

class TimelineReducer {
public:
    void apply(sqlite3* db, const Event& event);

private:
    void insertClip(sqlite3* db, const Event& event);
    void removeClip(sqlite3* db, const Event& event);
    void trimClip(sqlite3* db, const Event& event);
    void moveClip(sqlite3* db, const Event& event);
    void addMarker(sqlite3* db, const Event& event);
};

class MediaReducer {
public:
    void apply(sqlite3* db, const Event& event);
};

class UiReducer {
public:
    void apply(sqlite3* db, const Event& event);
};

class BrowserReducer {
public:
    void apply(sqlite3* db, const Event& event);
};

// Replay an event log file into the supplied read-model database.
void foldLog(sqlite3* db, const std::string& logPath);

// Compute a deterministic checksum of the read-model tables.
std::string computeReadModelChecksum(sqlite3* db);

}  // namespace jve::eventlog

