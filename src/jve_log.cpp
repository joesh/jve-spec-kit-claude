// jve_log.cpp — Unified logging implementation
//
// Parses JVE_LOG env var, writes formatted output to stderr.
// Both C++ macros and Lua FFI call into this single implementation.

#include "jve_log.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>

// ---- Global level array (default: WARN for all areas) ----
JveLevel g_jve_area_levels[static_cast<int>(JveArea::COUNT)];

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
    // Meta-category: "play" → ticks, audio, video
    if (area_len == 4 && strncasecmp(area_str, "play", 4) == 0) {
        set_area_level(static_cast<int>(JveArea::Ticks), level);
        set_area_level(static_cast<int>(JveArea::Audio), level);
        set_area_level(static_cast<int>(JveArea::Video), level);
        return;
    }
    // Meta-category: "all" → every area
    if (area_len == 3 && strncasecmp(area_str, "all", 3) == 0) {
        for (int i = 0; i < static_cast<int>(JveArea::COUNT); ++i) {
            g_jve_area_levels[i] = level;
        }
        return;
    }
    // Direct area
    int idx = parse_area(area_str, area_len);
    if (idx >= 0) {
        set_area_level(idx, level);
    }
    // Unknown area name → silently ignored (typo tolerance for env vars)
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

} // extern "C"
