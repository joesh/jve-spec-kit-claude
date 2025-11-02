#pragma once

#include <sqlite3.h>

#include <cstdint>
#include <string>
#include <vector>

namespace jve::eventlog {

struct Event {
    std::string id;
    std::string type;
    std::string scope;
    std::int64_t timestampMs{0};
    std::string author;
    std::vector<std::string> parents;
    int schemaVersion{1};
    int payloadVersion{1};
    std::string payloadJson;
};

// Parse a single JSONL line into an Event. Throws std::exception on failure.
Event parseEventJsonLine(const std::string& line);

// Convenience SHA-256 helper used by checksum folding.
std::string sha256Hex(const std::string& input);

}  // namespace jve::eventlog

