/* postkey.c — post a keystroke to a specific macOS pid via CGEventPostToPid.
 *
 * Why: macOS routes osascript "keystroke" to whatever app is *frontmost*.
 * A smoke runner launched from a terminal can't take frontmost from that
 * terminal (the OS keeps user-typed focus there), so osascript never
 * reaches JVE. CGEventPostToPid is the per-process variant: posts a real
 * CGEvent into the target process's event queue, regardless of frontmost
 * status. Real CGEvents trigger Qt's QShortcut machinery exactly like
 * user keystrokes do.
 *
 * Build (during make):
 *   clang -O2 -framework ApplicationServices -framework CoreFoundation \
 *         -o build/bin/jve_postkey tests/smoke/runner/postkey.c
 *
 * Usage:
 *   jve_postkey <pid> <keycode> [<modifier-mask>]
 *
 *   keycode       — macOS virtual key code (e.g. 7 = X, 0x12 = 1)
 *   modifier-mask — sum of CGEventFlags constants (default 0):
 *                       1 << 17 = shift
 *                       1 << 18 = control
 *                       1 << 19 = option
 *                       1 << 20 = command
 *
 * Exit codes:
 *   0  posted successfully
 *   1  usage error
 *   2  CGEventCreate failed
 *
 * Note: requires Accessibility permission for the calling process
 * (the runner inherits the terminal's permission), same prerequisite
 * the osascript path already needed.
 */
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char* argv[]) {
    if (argc < 3 || argc > 4) {
        fprintf(stderr, "usage: %s <pid> <keycode> [<modifier-mask>]\n", argv[0]);
        return 1;
    }
    pid_t pid = (pid_t)atoi(argv[1]);
    CGKeyCode keycode = (CGKeyCode)atoi(argv[2]);
    CGEventFlags flags = (argc == 4) ? (CGEventFlags)strtoull(argv[3], NULL, 10) : 0;

    CGEventRef down = CGEventCreateKeyboardEvent(NULL, keycode, true);
    CGEventRef up   = CGEventCreateKeyboardEvent(NULL, keycode, false);
    if (!down || !up) {
        fprintf(stderr, "CGEventCreateKeyboardEvent failed (keycode=%d)\n", keycode);
        if (down) CFRelease(down);
        if (up)   CFRelease(up);
        return 2;
    }
    if (flags) {
        CGEventSetFlags(down, flags);
        CGEventSetFlags(up,   flags);
    }

    CGEventPostToPid(pid, down);
    CGEventPostToPid(pid, up);

    CFRelease(down);
    CFRelease(up);
    return 0;
}
