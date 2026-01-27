// Assert handler with stack trace support

#include "assert_handler.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <signal.h>

#ifdef __APPLE__
#include <execinfo.h>
#include <cxxabi.h>
#endif

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

    // Clean exit instead of abort() - avoids OS crash dialogs
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

// Install the SIGABRT handler - call early in main()
void jve_install_abort_handler() {
    struct sigaction sa;
    sa.sa_handler = sigabrt_handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGABRT, &sa, nullptr);
}
