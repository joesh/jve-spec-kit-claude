// Assert handler with stack trace support
//
// jve_set_lua_state() is called once at startup in main.cpp after creating
// the lua_State. Once set, all JVE_ASSERT failures throw JveAssertError,
// which LuaJIT's DWARF unwinder catches at lua_pcall boundaries and converts
// to Lua errors. Before the lua_State is set (early startup), _exit(134).

#include "assert_handler.h"
#include <lua.hpp>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unistd.h>
#include <signal.h>

#ifdef __APPLE__
#include <execinfo.h>
#include <cxxabi.h>
#endif

// Thread-local lua_State — set around lua_pcall sites so assert failures
// can throw instead of _exit when we're inside a Lua-callable context.
static thread_local lua_State* t_lua_state = nullptr;

void jve_set_lua_state(lua_State* L) {
    t_lua_state = L;
}

// Flag to prevent recursive abort handling
static volatile sig_atomic_t g_handling_abort = 0;

// Demangle C++ symbol names (macOS/Linux)
static const char* demangle(const char* symbol, char* buffer, size_t bufsize) {
#ifdef __APPLE__
    // Symbol format: "1  libfoo.dylib  0x123  _ZN3Foo3barEv + 42"
    // Find the mangled name (starts with _Z usually)
    const char* start = symbol;
    while (*start && *start != '_') start++;
    if (*start != '_') return symbol;

    const char* end = start;
    while (*end && *end != ' ' && *end != '+') end++;

    size_t len = end - start;
    if (len >= bufsize) return symbol;

    char mangled[256];
    if (len >= sizeof(mangled)) return symbol;
    memcpy(mangled, start, len);
    mangled[len] = '\0';

    int status = 0;
    size_t outlen = bufsize;
    char* demangled = abi::__cxa_demangle(mangled, buffer, &outlen, &status);
    if (status == 0 && demangled) {
        return demangled;
    }
#else
    (void)buffer;
    (void)bufsize;
#endif
    return symbol;
}

void jve_assert_fail(const char* expr, const char* msg, const char* file, int line, const char* func) {
    fprintf(stderr, "\n");
    fprintf(stderr, "╔══════════════════════════════════════════════════════════════╗\n");
    fprintf(stderr, "║                      ASSERTION FAILED                        ║\n");
    fprintf(stderr, "╚══════════════════════════════════════════════════════════════╝\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "  Expression: %s\n", expr);
    fprintf(stderr, "  Message:    %s\n", msg);
    fprintf(stderr, "  Location:   %s:%d\n", file, line);
    fprintf(stderr, "  Function:   %s\n", func);
    fprintf(stderr, "\n");

#ifdef __APPLE__
    fprintf(stderr, "Stack trace:\n");
    fprintf(stderr, "─────────────────────────────────────────────────────────────────\n");

    void* callstack[64];
    int frames = backtrace(callstack, 64);
    char** symbols = backtrace_symbols(callstack, frames);

    if (symbols) {
        char demangled_buf[512];
        // Skip first 2 frames (this function and the assert macro)
        for (int i = 2; i < frames; i++) {
            const char* name = demangle(symbols[i], demangled_buf, sizeof(demangled_buf));
            fprintf(stderr, "  [%2d] %s\n", i - 2, name);
        }
        free(symbols);
    } else {
        fprintf(stderr, "  (unable to get stack trace)\n");
    }
    fprintf(stderr, "─────────────────────────────────────────────────────────────────\n");
#else
    fprintf(stderr, "  (stack trace not available on this platform)\n");
#endif

    fprintf(stderr, "\n");
    fflush(stderr);

    // If we're inside a Lua pcall context, throw so the error propagates
    // as a Lua error instead of killing the process.
    if (t_lua_state) {
        std::string error_msg = std::string("JVE_ASSERT failed: ") + msg +
            " [" + file + ":" + std::to_string(line) + " " + func + "]";
        throw JveAssertError(error_msg);
    }

    // No Lua context (startup, background threads): hard exit
    _exit(134);  // 134 = 128 + SIGABRT(6), mimics abort exit code
}

// Print stack trace (reusable)
static void print_stack_trace() {
#ifdef __APPLE__
    fprintf(stderr, "Stack trace:\n");
    fprintf(stderr, "─────────────────────────────────────────────────────────────────\n");

    void* callstack[64];
    int frames = backtrace(callstack, 64);
    char** symbols = backtrace_symbols(callstack, frames);

    if (symbols) {
        for (int i = 2; i < frames; i++) {
            fprintf(stderr, "  [%2d] %s\n", i - 2, symbols[i]);
        }
        free(symbols);
    }
    fprintf(stderr, "─────────────────────────────────────────────────────────────────\n");
#endif
}

// SIGABRT handler - catches abort() from standard assert() and other sources
static void sigabrt_handler(int sig) {
    (void)sig;

    // Prevent recursive handling
    if (g_handling_abort) {
        _exit(134);
    }
    g_handling_abort = 1;

    fprintf(stderr, "\n");
    fprintf(stderr, "╔══════════════════════════════════════════════════════════════╗\n");
    fprintf(stderr, "║                      ABORT CAUGHT                            ║\n");
    fprintf(stderr, "╚══════════════════════════════════════════════════════════════╝\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "  A standard assert() or abort() was triggered.\n");
    fprintf(stderr, "  (Use JVE_ASSERT for better diagnostics)\n");
    fprintf(stderr, "\n");

    print_stack_trace();

    fprintf(stderr, "\n");
    fflush(stderr);

    _exit(134);
}

// Flag to prevent recursive signal handling (SIGSEGV/SIGBUS)
static volatile sig_atomic_t g_handling_crash = 0;

// SIGSEGV/SIGBUS handler — catches null dereferences, use-after-free, etc.
// If inside a Lua pcall context, routes to Lua error (longjmp) so the app
// survives. Otherwise prints stack trace and exits.
static void crash_signal_handler(int sig) {
    // Prevent recursive handling (crash inside the handler)
    if (g_handling_crash) {
        _exit(128 + sig);
    }
    g_handling_crash = 1;

    const char* sig_name = (sig == SIGSEGV) ? "SIGSEGV" :
                           (sig == SIGBUS)  ? "SIGBUS"  : "SIGNAL";

    fprintf(stderr, "\n");
    fprintf(stderr, "╔══════════════════════════════════════════════════════════════╗\n");
    fprintf(stderr, "║                    CRASH: %-8s                           ║\n", sig_name);
    fprintf(stderr, "╚══════════════════════════════════════════════════════════════╝\n");
    fprintf(stderr, "\n");
    fprintf(stderr, "  Signal %d (%s): memory access violation\n", sig, sig_name);
    fprintf(stderr, "  Likely cause: use-after-free, null deref, or dangling pointer\n");
    fprintf(stderr, "\n");

    print_stack_trace();

    fprintf(stderr, "\n");
    fflush(stderr);

    // If we have a Lua state, route through Lua's error system (longjmp to
    // nearest pcall). The app survives — Lua surfaces the error as a stack trace.
    // SA_RESETHAND ensures if luaL_error itself crashes, the OS default handler
    // takes over (core dump) instead of infinite recursion.
    if (t_lua_state) {
        g_handling_crash = 0;  // allow future signals after longjmp recovery
        luaL_error(t_lua_state, "CRASH: %s (signal %d) — memory access violation", sig_name, sig);
        // luaL_error never returns (longjmp)
    }

    _exit(128 + sig);
}

// Install signal handlers - call early in main()
void jve_install_abort_handler() {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;

    // SIGABRT: standard assert() and abort()
    sa.sa_handler = sigabrt_handler;
    sigaction(SIGABRT, &sa, nullptr);

    // SIGSEGV + SIGBUS: null deref, use-after-free, alignment faults
    // SA_RESETHAND: reset to default after first delivery so a crash inside
    // the handler produces a normal core dump instead of infinite recursion.
    sa.sa_handler = crash_signal_handler;
    sa.sa_flags = SA_RESETHAND;
    sigaction(SIGSEGV, &sa, nullptr);
    sigaction(SIGBUS, &sa, nullptr);
}
