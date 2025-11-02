#include "jve/eventlog/Reducer.hpp"

#include <nlohmann/json.hpp>

#include <fstream>
#include <iostream>
#include <stdexcept>

namespace jve::eventlog {

namespace {

using json = nlohmann::json;

void beginTransaction(sqlite3* db) {
    exec_sql(db, "BEGIN IMMEDIATE;");
}

void commitTransaction(sqlite3* db) {
    exec_sql(db, "COMMIT;");
}

void finalizeOrThrow(sqlite3_stmt* stmt, const std::string& error_message) {
    if (sqlite3_step(stmt) != SQLITE_DONE) {
        sqlite3_finalize(stmt);
        throw std::runtime_error(error_message);
    }
    sqlite3_finalize(stmt);
}

}  // namespace

void TimelineReducer::apply(sqlite3* db, const Event& event) {
    if (event.type == "InsertClip") {
        insertClip(db, event);
    } else if (event.type == "RemoveClip") {
        removeClip(db, event);
    } else if (event.type == "TrimClip") {
        trimClip(db, event);
    } else if (event.type == "MoveClip") {
        moveClip(db, event);
    } else if (event.type == "AddMarker") {
        addMarker(db, event);
    }
}

void TimelineReducer::insertClip(sqlite3* db, const Event& event) {
    json payload = json::parse(event.payloadJson);
    const std::string sql =
        "INSERT INTO tl_clips(seq_id,clip_id,media_id,track,t_in,t_out,src_in,src_out,enable,attrs_json)"
        " VALUES(?,?,?,?,?,?,?,?,?,json('{}'));";
    sqlite3_stmt* stmt = nullptr;
    if (sqlite3_prepare_v2(db, sql.c_str(), -1, &stmt, nullptr) != SQLITE_OK) {
        throw std::runtime_error("TimelineReducer::insertClip prepare failed");
    }

    sqlite3_bind_text(stmt, 1, payload.at("seq_id").get<std::string>().c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, payload.at("clip_id").get<std::string>().c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, payload.at("media_id").get<std::string>().c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_int(stmt, 4, payload.at("track").get<int>());
    const auto dst_time = payload.at("dst_time").get<long long>();
    const auto src_in = payload.at("src_in").get<long long>();
    const auto src_out = payload.at("src_out").get<long long>();
    sqlite3_bind_int64(stmt, 5, dst_time);
    sqlite3_bind_int64(stmt, 6, dst_time + (src_out - src_in));
    sqlite3_bind_int64(stmt, 7, src_in);
    sqlite3_bind_int64(stmt, 8, src_out);
    sqlite3_bind_int(stmt, 9, payload.value("enable", true) ? 1 : 0);
    finalizeOrThrow(stmt, "TimelineReducer::insertClip step failed");
}

void TimelineReducer::removeClip(sqlite3* db, const Event& event) {
    json payload = json::parse(event.payloadJson);
    const std::string sql = "DELETE FROM tl_clips WHERE clip_id=?;";
    sqlite3_stmt* stmt = nullptr;
    if (sqlite3_prepare_v2(db, sql.c_str(), -1, &stmt, nullptr) != SQLITE_OK) {
        throw std::runtime_error("TimelineReducer::removeClip prepare failed");
    }
    sqlite3_bind_text(stmt, 1, payload.at("clip_id").get<std::string>().c_str(), -1, SQLITE_TRANSIENT);
    finalizeOrThrow(stmt, "TimelineReducer::removeClip step failed");
}

void TimelineReducer::trimClip(sqlite3* db, const Event& event) {
    json payload = json::parse(event.payloadJson);
    const std::string edge = payload.at("edge").get<std::string>();
    const long long delta = payload.at("delta_ticks").get<long long>();
    const std::string clip_id = payload.at("clip_id").get<std::string>();

    if (edge == "head") {
        const std::string sql = "UPDATE tl_clips SET t_in=t_in+?, src_in=src_in+? WHERE clip_id=?;";
        sqlite3_stmt* stmt = nullptr;
        sqlite3_prepare_v2(db, sql.c_str(), -1, &stmt, nullptr);
        sqlite3_bind_int64(stmt, 1, delta);
        sqlite3_bind_int64(stmt, 2, delta);
        sqlite3_bind_text(stmt, 3, clip_id.c_str(), -1, SQLITE_TRANSIENT);
        finalizeOrThrow(stmt, "TimelineReducer::trimClip head step failed");
    } else {
        const std::string sql = "UPDATE tl_clips SET t_out=t_out+?, src_out=src_out+? WHERE clip_id=?;";
        sqlite3_stmt* stmt = nullptr;
        sqlite3_prepare_v2(db, sql.c_str(), -1, &stmt, nullptr);
        sqlite3_bind_int64(stmt, 1, delta);
        sqlite3_bind_int64(stmt, 2, delta);
        sqlite3_bind_text(stmt, 3, clip_id.c_str(), -1, SQLITE_TRANSIENT);
        finalizeOrThrow(stmt, "TimelineReducer::trimClip tail step failed");
    }
}

void TimelineReducer::moveClip(sqlite3* db, const Event& event) {
    json payload = json::parse(event.payloadJson);
    const std::string sql = "UPDATE tl_clips SET track=?, t_in=?, t_out=?+(?-src_in) WHERE clip_id=?;";
    sqlite3_stmt* stmt = nullptr;
    if (sqlite3_prepare_v2(db, sql.c_str(), -1, &stmt, nullptr) != SQLITE_OK) {
        throw std::runtime_error("TimelineReducer::moveClip prepare failed");
    }
    const long long new_time = payload.at("new_time").get<long long>();
    sqlite3_bind_int(stmt, 1, payload.at("new_track").get<int>());
    sqlite3_bind_int64(stmt, 2, new_time);
    sqlite3_bind_int64(stmt, 3, new_time);
    sqlite3_bind_int64(stmt, 4, 0);  // Placeholder to keep stub parity with v0 reference implementation.
    sqlite3_bind_text(stmt, 5, payload.at("clip_id").get<std::string>().c_str(), -1, SQLITE_TRANSIENT);
    finalizeOrThrow(stmt, "TimelineReducer::moveClip step failed");
}

void TimelineReducer::addMarker(sqlite3* db, const Event& event) {
    json payload = json::parse(event.payloadJson);
    const std::string sql = "INSERT INTO tl_markers(seq_id,marker_id,t,color,name) VALUES(?,?,?,?,?);";
    sqlite3_stmt* stmt = nullptr;
    if (sqlite3_prepare_v2(db, sql.c_str(), -1, &stmt, nullptr) != SQLITE_OK) {
        throw std::runtime_error("TimelineReducer::addMarker prepare failed");
    }
    sqlite3_bind_text(stmt, 1, payload.at("seq_id").get<std::string>().c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, payload.at("marker_id").get<std::string>().c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 3, payload.at("time").get<long long>());
    sqlite3_bind_text(stmt, 4, payload.value("color", "yellow").c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 5, payload.value("name", "marker").c_str(), -1, SQLITE_TRANSIENT);
    finalizeOrThrow(stmt, "TimelineReducer::addMarker step failed");
}

void MediaReducer::apply(sqlite3* db, const Event& event) {
    if (event.type != "ImportMedia") {
        return;
    }
    json payload = json::parse(event.payloadJson);
    const std::string sql =
        "INSERT OR REPLACE INTO media(media_id,uri,sha3,duration,time_base,audio_layout,tags_json)"
        " VALUES(?,?,?,?,?,?,json(?));";
    sqlite3_stmt* stmt = nullptr;
    if (sqlite3_prepare_v2(db, sql.c_str(), -1, &stmt, nullptr) != SQLITE_OK) {
        throw std::runtime_error("MediaReducer::apply prepare failed");
    }
    sqlite3_bind_text(stmt, 1, payload.at("media_id").get<std::string>().c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 2, payload.at("uri").get<std::string>().c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(stmt, 3, payload.at("sha3").get<std::string>().c_str(), -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(stmt, 4, payload.at("duration_ticks").get<long long>());
    sqlite3_bind_int(stmt, 5, payload.at("time_base").get<int>());
    sqlite3_bind_text(stmt, 6, payload.value("audio_layout", "stereo").c_str(), -1, SQLITE_TRANSIENT);
    std::string tags_json = json(payload.value("tags", std::vector<std::string>{})).dump();
    sqlite3_bind_text(stmt, 7, tags_json.c_str(), -1, SQLITE_TRANSIENT);
    finalizeOrThrow(stmt, "MediaReducer::apply ImportMedia step failed");
}

void UiReducer::apply(sqlite3* db, const Event& event) {
    if (event.type == "SetPlayhead") {
        json payload = json::parse(event.payloadJson);
        const std::string sql =
            "INSERT INTO ui_state(id,active_seq,playhead_time,last_panel)"
            " VALUES(1,COALESCE((SELECT active_seq FROM ui_state WHERE id=1),''),?,"
            " COALESCE((SELECT last_panel FROM ui_state WHERE id=1),'timeline'))"
            " ON CONFLICT(id) DO UPDATE SET playhead_time=excluded.playhead_time;";
        sqlite3_stmt* stmt = nullptr;
        sqlite3_prepare_v2(db, sql.c_str(), -1, &stmt, nullptr);
        sqlite3_bind_int64(stmt, 1, payload.at("time").get<long long>());
        finalizeOrThrow(stmt, "UiReducer::apply SetPlayhead step failed");
    } else if (event.type == "SetActiveSequence") {
        json payload = json::parse(event.payloadJson);
        const std::string sql =
            "INSERT INTO ui_state(id,active_seq,playhead_time,last_panel)"
            " VALUES(1,?,0,'timeline')"
            " ON CONFLICT(id) DO UPDATE SET active_seq=excluded.active_seq;";
        sqlite3_stmt* stmt = nullptr;
        sqlite3_prepare_v2(db, sql.c_str(), -1, &stmt, nullptr);
        sqlite3_bind_text(stmt, 1, payload.at("seq_id").get<std::string>().c_str(), -1, SQLITE_TRANSIENT);
        finalizeOrThrow(stmt, "UiReducer::apply SetActiveSequence step failed");
    }
}

void BrowserReducer::apply(sqlite3* db, const Event& event) {
    (void)db;
    (void)event;
    // v0 browser reducer is a placeholder.
}

void foldLog(sqlite3* db, const std::string& logPath) {
    TimelineReducer timeline;
    MediaReducer media;
    UiReducer ui;
    BrowserReducer browser;
    std::ifstream input(logPath);
    if (!input) {
        throw std::runtime_error("Failed to open log file: " + logPath);
    }
    beginTransaction(db);
    std::string line;
    while (std::getline(input, line)) {
        if (line.empty()) {
            continue;
        }
        Event event = parseEventJsonLine(line);
        media.apply(db, event);
        timeline.apply(db, event);
        ui.apply(db, event);
        browser.apply(db, event);
    }
    commitTransaction(db);
}

std::string computeReadModelChecksum(sqlite3* db) {
    auto checksum_for_query = [&](const char* sql) -> std::string {
        sqlite3_stmt* stmt = nullptr;
        if (sqlite3_prepare_v2(db, sql, -1, &stmt, nullptr) != SQLITE_OK) {
            return {};
        }
        std::string accumulator;
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            int cols = sqlite3_column_count(stmt);
            for (int i = 0; i < cols; ++i) {
                const unsigned char* text = sqlite3_column_text(stmt, i);
                if (text) {
                    accumulator.append(reinterpret_cast<const char*>(text));
                }
                accumulator.push_back('|');
            }
            accumulator.push_back('\n');
        }
        sqlite3_finalize(stmt);
        return sha256Hex(accumulator);
    };

    std::string timeline_sum = checksum_for_query(
        "SELECT seq_id,clip_id,track,t_in,t_out,media_id FROM tl_clips ORDER BY seq_id,track,t_in,clip_id;");
    std::string marker_sum =
        checksum_for_query("SELECT seq_id,marker_id,t FROM tl_markers ORDER BY seq_id,t,marker_id;");
    std::string media_sum = checksum_for_query("SELECT media_id,sha3 FROM media ORDER BY media_id;");
    std::string ui_sum = checksum_for_query("SELECT active_seq,playhead_time FROM ui_state WHERE id=1;");

    return sha256Hex(timeline_sum + marker_sum + media_sum + ui_sum);
}

}  // namespace jve::eventlog
