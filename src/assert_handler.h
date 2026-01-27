#pragma once

// Custom assert with stack trace
// Usage: JVE_ASSERT(condition, "message with context")
// On failure: prints stack trace, message, file:line, then aborts

#include <cstdlib>

#ifdef __cplusplus
extern "C" {
#endif

// Called on assert failure - prints stack trace and exits cleanly
void jve_assert_fail(const char* expr, const char* msg, const char* file, int line, const char* func);

// Install SIGABRT handler to catch standard assert() and abort()
// Call this early in main()
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
