#pragma once

// Custom assert with stack trace
// Usage: JVE_ASSERT(condition, "message with context")
// On failure: prints stack trace + message, then:
//   - If inside lua_pcall (lua_State registered): throws JveAssertError → Lua error
//   - If outside Lua context (startup, background threads): _exit(134)

#include <cstdlib>

#ifdef __cplusplus
#include <stdexcept>

// Exception thrown by jve_assert_fail when inside a Lua pcall context.
// LuaJIT 2.1 on macOS ARM64 uses DWARF unwinding, so C++ exceptions thrown
// inside lua_CFunction calls properly unwind destructors and are caught by
// lua_pcall, which converts them to Lua errors.
class JveAssertError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

struct lua_State;

// Register the active lua_State for the current thread.
// Call once at startup after creating the lua_State. When registered,
// jve_assert_fail throws JveAssertError instead of _exit, allowing
// Lua pcall to catch C++ assertion failures.
void jve_set_lua_state(lua_State* L);

// Set-only guard: sets lua_State on construction, does NOT clear on destruction.
// t_lua_state is set once per thread and stays set for the thread's lifetime.
// Safe to use in existing code — constructor is a redundant set, destructor is no-op.
struct JveLuaStateGuard {
    JveLuaStateGuard(lua_State* L) { jve_set_lua_state(L); }
    ~JveLuaStateGuard() {}
    JveLuaStateGuard(const JveLuaStateGuard&) = delete;
    JveLuaStateGuard& operator=(const JveLuaStateGuard&) = delete;
};

extern "C" {
#endif

// Called on assert failure - prints stack trace, then throws or exits
void jve_assert_fail(const char* expr, const char* msg, const char* file, int line, const char* func);

// Install signal handlers (SIGABRT, SIGSEGV, SIGBUS) for crash diagnostics.
// Prints stack trace on crash instead of silent macOS crash report.
// Call this early in main().
void jve_install_abort_handler();

#ifdef __cplusplus
}
#endif

// Main assert macro - always enabled (no NDEBUG check during development)
#define JVE_ASSERT(expr, msg) \
    do { \
        if (!(expr)) { \
            jve_assert_fail(#expr, msg, __FILE__, __LINE__, __func__); \
        } \
    } while (0)

// Unconditional failure
#define JVE_FAIL(msg) \
    jve_assert_fail("(unconditional)", msg, __FILE__, __LINE__, __func__)
