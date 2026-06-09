// input_bindings.cpp — synthetic input via macOS CGEventPost
//
// **STAGED — does not work from inside the JVEEditor --test process.**
//
// Original intent: post real keyboard/mouse events to the OS HID event
// tap so they flow through the same path physical input takes: OS
// dispatch → app activation → Qt::QShortcutMap → registered QShortcut
// handlers. The theory is correct (CGEventPost produces real OS
// events). The practice is not: macOS routes synthetic events to the
// currently-foregrounded app, and a process that calls CGEventPost
// against itself in --test mode is not foregrounded (no Dock
// activation, no user gesture). Result: events go nowhere reachable
// from our own QShortcut map. Confirmed empirically 2026-05-20 against
// `tests/synthetic/binding/test_qt_send_key_event.lua` (handler fired 0 times).
//
// Why it's kept in tree: spec 020's Phase 1 calls for an external
// test-runner process that foregrounds JVE via osascript (or a similar
// activation tool) and then drives input from outside. CGEventPost
// works correctly in that direction (external app → foregrounded JVE).
// The Qt::Key → mac VK translation table and the modifier mapping
// below are the parts worth keeping; the runner will link or re-use
// them. See specs/020-debug-terminal/spec.md FR-101.
//
// macOS-only by design. Linux/Windows runners will need their own
// equivalents (XTest, SendInput) the day we cross-compile.

#include <ApplicationServices/ApplicationServices.h>

#include <QApplication>
#include <QPoint>
#include <QWidget>

extern "C" {
#include <lua.h>
#include <lauxlib.h>
}

// ─── Qt::Key → macOS virtual keycode table ─────────────────────────────────
//
// macOS virtual keycodes are the values CGEventCreateKeyboardEvent
// expects (Carbon HIToolbox/Events.h kVK_* enums, US layout). Tests
// pass Qt::Key values from core.keyboard_constants for portability;
// this table maps the keys our keymap actually binds. Add entries as
// needed — unmapped keys assert with the Qt::Key value so the test
// author knows what to extend.

struct KeyMapping { int qt_key; CGKeyCode mac_vk; };

static constexpr KeyMapping kKeyMap[] = {
    // Letters
    { Qt::Key_A, 0x00 }, { Qt::Key_B, 0x0B }, { Qt::Key_C, 0x08 },
    { Qt::Key_D, 0x02 }, { Qt::Key_E, 0x0E }, { Qt::Key_F, 0x03 },
    { Qt::Key_G, 0x05 }, { Qt::Key_H, 0x04 }, { Qt::Key_I, 0x22 },
    { Qt::Key_J, 0x26 }, { Qt::Key_K, 0x28 }, { Qt::Key_L, 0x25 },
    { Qt::Key_M, 0x2E }, { Qt::Key_N, 0x2D }, { Qt::Key_O, 0x1F },
    { Qt::Key_P, 0x23 }, { Qt::Key_Q, 0x0C }, { Qt::Key_R, 0x0F },
    { Qt::Key_S, 0x01 }, { Qt::Key_T, 0x11 }, { Qt::Key_U, 0x20 },
    { Qt::Key_V, 0x09 }, { Qt::Key_W, 0x0D }, { Qt::Key_X, 0x07 },
    { Qt::Key_Y, 0x10 }, { Qt::Key_Z, 0x06 },
    // Digits (top row)
    { Qt::Key_0, 0x1D }, { Qt::Key_1, 0x12 }, { Qt::Key_2, 0x13 },
    { Qt::Key_3, 0x14 }, { Qt::Key_4, 0x15 }, { Qt::Key_5, 0x17 },
    { Qt::Key_6, 0x16 }, { Qt::Key_7, 0x1A }, { Qt::Key_8, 0x1C },
    { Qt::Key_9, 0x19 },
    // Punctuation / navigation
    { Qt::Key_Space,     0x31 }, { Qt::Key_Return,    0x24 },
    { Qt::Key_Tab,       0x30 }, { Qt::Key_Escape,    0x35 },
    { Qt::Key_Backspace, 0x33 }, { Qt::Key_Delete,    0x75 },
    { Qt::Key_Left,      0x7B }, { Qt::Key_Right,     0x7C },
    { Qt::Key_Up,        0x7E }, { Qt::Key_Down,      0x7D },
    { Qt::Key_Comma,     0x2B }, { Qt::Key_Period,    0x2F },
    { Qt::Key_Slash,     0x2C }, { Qt::Key_Semicolon, 0x29 },
    { Qt::Key_Apostrophe, 0x27 }, { Qt::Key_BracketLeft,  0x21 },
    { Qt::Key_BracketRight, 0x1E }, { Qt::Key_Backslash, 0x2A },
    { Qt::Key_Minus,     0x1B }, { Qt::Key_Equal,     0x18 },
    { Qt::Key_QuoteLeft, 0x32 },
    // Function keys
    { Qt::Key_F1, 0x7A }, { Qt::Key_F2, 0x78 }, { Qt::Key_F3, 0x63 },
    { Qt::Key_F4, 0x76 }, { Qt::Key_F5, 0x60 }, { Qt::Key_F6, 0x61 },
    { Qt::Key_F7, 0x62 }, { Qt::Key_F8, 0x64 }, { Qt::Key_F9, 0x65 },
    { Qt::Key_F10, 0x6D }, { Qt::Key_F11, 0x67 }, { Qt::Key_F12, 0x6F },
};

static bool qt_key_to_mac_vk(int qt_key, CGKeyCode& out) {
    for (const auto& m : kKeyMap) {
        if (m.qt_key == qt_key) { out = m.mac_vk; return true; }
    }
    return false;
}

// Translate Qt::KeyboardModifiers → CGEventFlags. On macOS Qt swaps
// Control and Meta: Qt::ControlModifier == Cmd, Qt::MetaModifier == Ctrl.
static CGEventFlags qt_mods_to_cg_flags(int qt_mods) {
    CGEventFlags f = 0;
    if (qt_mods & Qt::ShiftModifier)   f |= kCGEventFlagMaskShift;
    if (qt_mods & Qt::ControlModifier) f |= kCGEventFlagMaskCommand;
    if (qt_mods & Qt::AltModifier)     f |= kCGEventFlagMaskAlternate;
    if (qt_mods & Qt::MetaModifier)    f |= kCGEventFlagMaskControl;
    return f;
}

// ─── Helpers ───────────────────────────────────────────────────────────────

static void post_key_event(CGKeyCode vk, CGEventFlags flags, bool keyDown) {
    CGEventRef event = CGEventCreateKeyboardEvent(nullptr, vk, keyDown);
    CGEventSetFlags(event, flags);
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

// ─── qt_send_key_click(_unused, qt_key, qt_modifiers) ──────────────────────
//
// First arg kept as widget-or-nil for API symmetry with the earlier
// QTest binding (the smoke tests pass app.main_window). With
// CGEventPost the event goes to whichever app currently owns focus —
// the caller is responsible for activating the JVE window first via
// qt_constants.DISPLAY.ACTIVATE().
static int lua_send_key_click(lua_State* L) {
    int qt_key = static_cast<int>(luaL_checkinteger(L, 2));
    int qt_mods = static_cast<int>(luaL_optinteger(L, 3, 0));

    CGKeyCode vk;
    if (!qt_key_to_mac_vk(qt_key, vk)) {
        return luaL_error(L,
            "qt_send_key_click: Qt::Key value %d not in CGEvent translation "
            "table — add it to kKeyMap in input_bindings.cpp", qt_key);
    }
    CGEventFlags flags = qt_mods_to_cg_flags(qt_mods);

    post_key_event(vk, flags, /*keyDown=*/true);
    post_key_event(vk, flags, /*keyDown=*/false);

    lua_pushboolean(L, 1);
    return 1;
}

static int lua_send_key_press(lua_State* L) {
    int qt_key = static_cast<int>(luaL_checkinteger(L, 2));
    int qt_mods = static_cast<int>(luaL_optinteger(L, 3, 0));

    CGKeyCode vk;
    if (!qt_key_to_mac_vk(qt_key, vk)) {
        return luaL_error(L, "qt_send_key_press: Qt::Key %d not in translation table", qt_key);
    }
    post_key_event(vk, qt_mods_to_cg_flags(qt_mods), /*keyDown=*/true);
    lua_pushboolean(L, 1);
    return 1;
}

static int lua_send_key_release(lua_State* L) {
    int qt_key = static_cast<int>(luaL_checkinteger(L, 2));
    int qt_mods = static_cast<int>(luaL_optinteger(L, 3, 0));

    CGKeyCode vk;
    if (!qt_key_to_mac_vk(qt_key, vk)) {
        return luaL_error(L, "qt_send_key_release: Qt::Key %d not in translation table", qt_key);
    }
    post_key_event(vk, qt_mods_to_cg_flags(qt_mods), /*keyDown=*/false);
    lua_pushboolean(L, 1);
    return 1;
}

// ─── Mouse ─────────────────────────────────────────────────────────────────
//
// Mouse coords are widget-local; we translate via QWidget::mapToGlobal.
// Without a real widget pointer we can't position the event accurately,
// so the widget arg IS required here (unlike the key variants above).

static int mouse_button_to_cg(int b, CGEventType& down, CGEventType& up,
                              CGMouseButton& cg_btn) {
    switch (b) {
        case 1:
            down = kCGEventLeftMouseDown;  up = kCGEventLeftMouseUp;
            cg_btn = kCGMouseButtonLeft;   return 1;
        case 2:
            down = kCGEventRightMouseDown; up = kCGEventRightMouseUp;
            cg_btn = kCGMouseButtonRight;  return 1;
        case 3:
            down = kCGEventOtherMouseDown; up = kCGEventOtherMouseUp;
            cg_btn = kCGMouseButtonCenter; return 1;
    }
    return 0;
}

static void post_mouse_event(CGEventType type, CGPoint loc,
                             CGMouseButton btn, CGEventFlags flags,
                             int click_count) {
    CGEventRef event = CGEventCreateMouseEvent(nullptr, type, loc, btn);
    CGEventSetFlags(event, flags);
    if (click_count > 0) {
        CGEventSetIntegerValueField(event, kCGMouseEventClickState, click_count);
    }
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}

static int lua_send_mouse_click(lua_State* L) {
    QWidget* widget = get_widget<QWidget>(L, 1);
    if (!widget) {
        return luaL_error(L, "qt_send_mouse_click: widget required");
    }
    int btn_int = static_cast<int>(luaL_checkinteger(L, 2));
    int x = static_cast<int>(luaL_checkinteger(L, 3));
    int y = static_cast<int>(luaL_checkinteger(L, 4));
    int qt_mods = static_cast<int>(luaL_optinteger(L, 5, 0));

    CGEventType down, up;
    CGMouseButton cg_btn;
    if (!mouse_button_to_cg(btn_int, down, up, cg_btn)) {
        return luaL_error(L,
            "qt_send_mouse_click: button must be 1/2/3 (Left/Right/Middle); got %d",
            btn_int);
    }

    QPoint global = widget->mapToGlobal(QPoint(x, y));
    CGPoint loc = CGPointMake(global.x(), global.y());
    CGEventFlags flags = qt_mods_to_cg_flags(qt_mods);

    post_mouse_event(down, loc, cg_btn, flags, 1);
    post_mouse_event(up,   loc, cg_btn, flags, 1);

    lua_pushboolean(L, 1);
    return 1;
}

static int lua_send_mouse_double_click(lua_State* L) {
    QWidget* widget = get_widget<QWidget>(L, 1);
    if (!widget) {
        return luaL_error(L, "qt_send_mouse_double_click: widget required");
    }
    int btn_int = static_cast<int>(luaL_checkinteger(L, 2));
    int x = static_cast<int>(luaL_checkinteger(L, 3));
    int y = static_cast<int>(luaL_checkinteger(L, 4));
    int qt_mods = static_cast<int>(luaL_optinteger(L, 5, 0));

    CGEventType down, up;
    CGMouseButton cg_btn;
    if (!mouse_button_to_cg(btn_int, down, up, cg_btn)) {
        return luaL_error(L, "qt_send_mouse_double_click: button must be 1/2/3; got %d", btn_int);
    }

    QPoint global = widget->mapToGlobal(QPoint(x, y));
    CGPoint loc = CGPointMake(global.x(), global.y());
    CGEventFlags flags = qt_mods_to_cg_flags(qt_mods);

    // Double-click is signaled by clickState=2 on the second pair.
    post_mouse_event(down, loc, cg_btn, flags, 1);
    post_mouse_event(up,   loc, cg_btn, flags, 1);
    post_mouse_event(down, loc, cg_btn, flags, 2);
    post_mouse_event(up,   loc, cg_btn, flags, 2);

    lua_pushboolean(L, 1);
    return 1;
}
