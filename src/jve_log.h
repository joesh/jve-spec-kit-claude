#pragma once
// jve_log.h — Unified logging for JVE Editor (C++ and Lua via FFI)
//
// Intent-based levels: DETAIL < EVENT < WARN < ERROR < NONE
// Functional areas: ticks, audio, video, timeline, commands, database, ui, media
//
// Configured via single env var:
//   JVE_LOG=play:detail              # playback areas at detail
//   JVE_LOG=audio:event,commands:event
//   JVE_LOG=all:detail               # everything verbose
//   JVE_LOG=all:none                 # silent
//
// Default: all areas at WARN (WARN+ERROR on, EVENT+DETAIL off).

#include <cstdarg>
#include <cstdint>

// ---- Areas ----
enum class JveArea : int {
    Ticks    = 0,  // PlaybackController ticks, frame delivery, A/V sync drift
    Audio    = 1,  // AudioPump, SSE, AOP, mix params, buffer levels
    Video    = 2,  // GPUVideoSurface, TMB frame fetch, decode path
    Timeline = 3,  // Clip queries, track layout, edit operations, snapping
    Commands = 4,  // Command dispatch, undo/redo, execution
    Database = 5,  // SQL, persistence, project lifecycle
    Ui       = 6,  // Widgets, layout, focus, keyboard, inspector, bug_reporter
    Media    = 7,  // Import, relink, masterclip, offline, project open/new
    COUNT    = 8
};

// ---- Levels (most verbose → least) ----
enum class JveLevel : int {
    Detail = 0,  // Per-frame / per-cycle data
    Event  = 1,  // State transitions
    Warn   = 2,  // Suspicious but survived
    Error  = 3,  // Broken invariant
    None   = 4   // Suppress all output
};

// ---- Init (call once from main, before Lua) ----
void jve_init_log();

// ---- Level check (inlineable, zero overhead when disabled) ----
extern JveLevel g_jve_area_levels[static_cast<int>(JveArea::COUNT)];

inline bool jve_log_enabled(JveArea area, JveLevel level) {
    return level >= g_jve_area_levels[static_cast<int>(area)];
}

// ---- Log output (fprintf to stderr) ----
void jve_log(JveArea area, JveLevel level, const char* fmt, ...)
    __attribute__((format(printf, 3, 4)));

// ---- Convenience macros ----
#define JVE_LOG_DETAIL(area, ...) \
    do { if (jve_log_enabled(JveArea::area, JveLevel::Detail)) \
             jve_log(JveArea::area, JveLevel::Detail, __VA_ARGS__); } while(0)

#define JVE_LOG_EVENT(area, ...) \
    do { if (jve_log_enabled(JveArea::area, JveLevel::Event)) \
             jve_log(JveArea::area, JveLevel::Event, __VA_ARGS__); } while(0)

#define JVE_LOG_WARN(area, ...) \
    do { if (jve_log_enabled(JveArea::area, JveLevel::Warn)) \
             jve_log(JveArea::area, JveLevel::Warn, __VA_ARGS__); } while(0)

#define JVE_LOG_ERROR(area, ...) \
    do { if (jve_log_enabled(JveArea::area, JveLevel::Error)) \
             jve_log(JveArea::area, JveLevel::Error, __VA_ARGS__); } while(0)

// ---- FFI exports for Lua (C linkage) ----
#ifdef __cplusplus
extern "C" {
#endif

void jve_log_init_ffi(void);
bool jve_log_enabled_ffi(int area, int level);
void jve_log_ffi(int area, int level, const char* msg);

#ifdef __cplusplus
}
#endif
