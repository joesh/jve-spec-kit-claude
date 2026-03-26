// jve_log.cpp — Unified logging implementation
//
// Parses JVE_LOG env var, writes formatted output to stderr.
// Both C++ macros and Lua FFI call into this single implementation.

#include "jve_log.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <unordered_map>

// ---- Global level array (default: WARN for all areas) ----
JveLevel g_jve_area_levels[static_cast<int>(JveArea::COUNT)];

// ---- Extended area levels for hierarchical names (e.g. "ui.find") ----
static std::unordered_map<std::string, JveLevel> g_extended_levels;

// ---- Area name table ----
static const char* const AREA_NAMES[] = {
    "ticks", "audio", "video", "timeline",
    "commands", "database", "ui", "media"
};
static_assert(sizeof(AREA_NAMES) / sizeof(AREA_NAMES[0]) == static_cast<int>(JveArea::COUNT),
              "AREA_NAMES must match JveArea::COUNT");

// ---- Level name table ----
static const char* const LEVEL_NAMES[] = {
    "DETAIL", "EVENT", "WARN", "ERROR", "NONE"
};

// ---- Parser helpers ----

static JveLevel parse_level(const char* s, int len) {
    // Case-insensitive comparison
    if (len == 6 && strncasecmp(s, "detail", 6) == 0) return JveLevel::Detail;
    if (len == 5 && strncasecmp(s, "event", 5) == 0)  return JveLevel::Event;
    if (len == 4 && strncasecmp(s, "warn", 4) == 0)   return JveLevel::Warn;
    if (len == 5 && strncasecmp(s, "error", 5) == 0)  return JveLevel::Error;
    if (len == 4 && strncasecmp(s, "none", 4) == 0)   return JveLevel::None;
    return JveLevel::Warn;  // unknown → default
}

static int parse_area(const char* s, int len) {
    // Returns area index or -1 for meta-categories
    for (int i = 0; i < static_cast<int>(JveArea::COUNT); ++i) {
        if (static_cast<int>(strlen(AREA_NAMES[i])) == len &&
            strncasecmp(s, AREA_NAMES[i], len) == 0) {
            return i;
        }
    }
    return -1;  // not a direct area
}

static void set_area_level(int area_idx, JveLevel level) {
    if (area_idx >= 0 && area_idx < static_cast<int>(JveArea::COUNT)) {
        g_jve_area_levels[area_idx] = level;
    }
}

static void apply_entry(const char* area_str, int area_len, JveLevel level) {
    std::string name(area_str, area_len);

    // Meta-category: "play" → ticks, audio, video
    if (name == "play") {
        set_area_level(static_cast<int>(JveArea::Ticks), level);
        set_area_level(static_cast<int>(JveArea::Audio), level);
        set_area_level(static_cast<int>(JveArea::Video), level);
        return;
    }
    // Meta-category: "all" → every area + all extended
    if (name == "all") {
        for (int i = 0; i < static_cast<int>(JveArea::COUNT); ++i) {
            g_jve_area_levels[i] = level;
        }
        for (auto& kv : g_extended_levels) {
            kv.second = level;
        }
        return;
    }
    // Direct core area
    int idx = parse_area(area_str, area_len);
    if (idx >= 0) {
        set_area_level(idx, level);
    }
    // Always store in extended map (handles both "ui" and "ui.find")
    g_extended_levels[name] = level;
}

// ---- Init ----

void jve_init_log() {
    // Default: all areas at WARN
    for (int i = 0; i < static_cast<int>(JveArea::COUNT); ++i) {
        g_jve_area_levels[i] = JveLevel::Warn;
    }

    const char* env = getenv("JVE_LOG");
    if (!env || env[0] == '\0') {
        return;
    }

    // Parse: "area:level,area:level,..."
    const char* p = env;
    while (*p) {
        // Skip leading whitespace/commas
        while (*p == ',' || *p == ' ') ++p;
        if (*p == '\0') break;

        // Find colon separator
        const char* colon = strchr(p, ':');
        if (!colon) break;  // malformed entry

        int area_len = static_cast<int>(colon - p);
        const char* level_start = colon + 1;

        // Find end of level (comma or end of string)
        const char* end = level_start;
        while (*end && *end != ',' && *end != ' ') ++end;
        int level_len = static_cast<int>(end - level_start);

        if (area_len > 0 && level_len > 0) {
            JveLevel level = parse_level(level_start, level_len);
            apply_entry(p, area_len, level);
        }

        p = end;
    }
}

// ---- Log output ----

void jve_log(JveArea area, JveLevel level, const char* fmt, ...) {
    // Timestamp
    time_t now = time(nullptr);
    struct tm tm_buf;
    localtime_r(&now, &tm_buf);

    char time_str[16];
    strftime(time_str, sizeof(time_str), "%H:%M:%S", &tm_buf);

    int area_idx = static_cast<int>(area);
    int level_idx = static_cast<int>(level);
    const char* area_name = (area_idx >= 0 && area_idx < static_cast<int>(JveArea::COUNT))
        ? AREA_NAMES[area_idx] : "???";
    const char* level_name = (level_idx >= 0 && level_idx <= static_cast<int>(JveLevel::None))
        ? LEVEL_NAMES[level_idx] : "???";

    // Format: [HH:MM:SS] [area] LEVEL: message
    fprintf(stderr, "[%s] [%s] %s: ", time_str, area_name, level_name);

    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);

    fputc('\n', stderr);
}

// ---- Hierarchical area check ----
// "ui.find" checks: extended["ui.find"] first, then parent "ui" (core area 6).

static bool jve_log_enabled_str(const char* area_name, JveLevel level) {
    // Check explicit level for this exact name
    auto it = g_extended_levels.find(area_name);
    if (it != g_extended_levels.end()) {
        return level >= it->second;
    }
    // Find parent: "ui.find" → "ui"
    const char* dot = strchr(area_name, '.');
    if (dot) {
        std::string parent(area_name, dot - area_name);
        // Check extended map for parent
        auto pit = g_extended_levels.find(parent);
        if (pit != g_extended_levels.end()) {
            return level >= pit->second;
        }
        // Check core area for parent
        int idx = parse_area(parent.c_str(), static_cast<int>(parent.size()));
        if (idx >= 0) {
            return level >= g_jve_area_levels[idx];
        }
    }
    // No parent match — default to WARN
    return level >= JveLevel::Warn;
}

static void jve_log_str(const char* area_name, JveLevel level, const char* msg) {
    time_t now = time(nullptr);
    struct tm tm_buf;
    localtime_r(&now, &tm_buf);

    char time_str[16];
    strftime(time_str, sizeof(time_str), "%H:%M:%S", &tm_buf);

    int level_idx = static_cast<int>(level);
    const char* level_name = (level_idx >= 0 && level_idx <= static_cast<int>(JveLevel::None))
        ? LEVEL_NAMES[level_idx] : "???";

    fprintf(stderr, "[%s] [%s] %s: %s\n", time_str, area_name, level_name, msg);
}

// ---- FFI exports ----

extern "C" {

void jve_log_init_ffi(void) {
    jve_init_log();
}

bool jve_log_enabled_ffi(int area, int level) {
    if (area < 0 || area >= static_cast<int>(JveArea::COUNT)) return false;
    if (level < 0 || level > static_cast<int>(JveLevel::None)) return false;
    return jve_log_enabled(static_cast<JveArea>(area), static_cast<JveLevel>(level));
}

void jve_log_ffi(int area, int level, const char* msg) {
    if (area < 0 || area >= static_cast<int>(JveArea::COUNT)) return;
    if (level < 0 || level > static_cast<int>(JveLevel::None)) return;
    jve_log(static_cast<JveArea>(area), static_cast<JveLevel>(level), "%s", msg);
}

bool jve_log_enabled_str_ffi(const char* area_name, int level) {
    if (!area_name) return false;
    if (level < 0 || level > static_cast<int>(JveLevel::None)) return false;
    return jve_log_enabled_str(area_name, static_cast<JveLevel>(level));
}

void jve_log_str_ffi(const char* area_name, int level, const char* msg) {
    if (!area_name || !msg) return;
    if (level < 0 || level > static_cast<int>(JveLevel::None)) return;
    if (!jve_log_enabled_str(area_name, static_cast<JveLevel>(level))) return;
    jve_log_str(area_name, static_cast<JveLevel>(level), msg);
}

} // extern "C"
