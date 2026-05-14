-- 015 / FR-010, FR-010a — C++ binding smoke for patch drag-drop.
--
-- Runs in --test mode: ./build/bin/JVEEditor --test tests/integration/test_patch_drag_drop_bindings.lua
--
-- This is the integration counterpart to test_patch_drag_drop_dispatch.lua.
-- That test covers Lua decision logic with stubs. THIS test covers the
-- C++ bindings end-to-end: qt_install_drop_target installs a real Qt
-- event filter, qt_synthetic_drop dispatches a real QDropEvent through
-- QApplication::sendEvent, and the production filter parses the mime
-- payload and fires the Lua handler.
--
-- We deliberately do NOT test qt_install_drag_source's full QDrag::exec
-- path here — exec runs a nested OS event loop and depends on real
-- mouse-grab semantics that can't be driven from a script. The drag
-- *payload-construction* is unit-tested in test_patch_drag_drop_dispatch.
-- The full end-to-end (mouse press → threshold → QDrag::exec → drop on
-- another widget) is exercised by manual UI testing.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local patch_drag_logic = require("ui.timeline.patch_drag_logic")

assert(type(qt_constants) == "table",
    "test must run via JVEEditor --test (qt_constants not present)")
assert(type(qt_constants.CONTROL.INSTALL_DROP_TARGET) == "function",
    "INSTALL_DROP_TARGET binding missing — stale build?")
assert(type(qt_constants.CONTROL.SYNTHETIC_DROP) == "function",
    "SYNTHETIC_DROP binding missing — stale build?")
assert(type(qt_constants.CONTROL.INSTALL_DRAG_SOURCE) == "function",
    "INSTALL_DRAG_SOURCE binding missing — stale build?")

print("=== test_patch_drag_drop_bindings.lua ===")

local MIME = "application/x-jve-patch-drag"

-- ============================================================================
-- 1. Drop-target round-trip: payload bytes survive the QMimeData boundary
-- ============================================================================
do
    local target = qt_constants.WIDGET.CREATE()
    local captured = nil
    _G["__bindings_test_drop_handler_1"] = function(x, y, payload)
        captured = { x = x, y = y, payload = payload }
    end
    qt_constants.CONTROL.INSTALL_DROP_TARGET(target, MIME,
        "__bindings_test_drop_handler_1")

    local payload = patch_drag_logic.build_payload({
        sequence_id          = "seq-uuid-aaa",
        track_type           = "VIDEO",
        source_track_index   = 1,
        home_rec_track_index = 1,
        project_id           = "proj-uuid",
    })
    qt_constants.CONTROL.SYNTHETIC_DROP(target, MIME, payload, 42, 99)

    assert(captured, "drop handler must have been invoked")
    assert(captured.x == 42, "x coord propagates through QDropEvent")
    assert(captured.y == 99, "y coord propagates through QDropEvent")

    local parsed = patch_drag_logic.parse_payload(captured.payload)
    assert(parsed.sequence_id == "seq-uuid-aaa",
        "payload bytes round-trip through QMimeData")
    assert(parsed.track_type == "VIDEO", "track_type roundtrips")
    assert(parsed.source_track_index == 1, "source_track_index roundtrips")
    assert(parsed.home_rec_track_index == 1, "home_rec_track_index roundtrips")
    print("  ✓ INSTALL_DROP_TARGET + SYNTHETIC_DROP: payload bytes round-trip")
end

-- ============================================================================
-- 2. Mime mismatch: filter ignores drops with a different mime type
-- ============================================================================
do
    local target = qt_constants.WIDGET.CREATE()
    local invoked = false
    _G["__bindings_test_drop_handler_2"] = function()
        invoked = true
    end
    qt_constants.CONTROL.INSTALL_DROP_TARGET(target, MIME,
        "__bindings_test_drop_handler_2")

    -- Send a drop with a DIFFERENT mime type — filter must not fire.
    qt_constants.CONTROL.SYNTHETIC_DROP(target, "application/x-something-else",
        "irrelevant-payload", 0, 0)

    assert(invoked == false,
        "drop with unmatched mime must NOT fire the handler")
    print("  ✓ filter rejects mime mismatch (no false dispatch)")
end

-- ============================================================================
-- 3. Two drop targets on two widgets — each only fires for its own widget
-- ============================================================================
do
    local target_a = qt_constants.WIDGET.CREATE()
    local target_b = qt_constants.WIDGET.CREATE()
    local fired_a, fired_b = 0, 0
    _G["__bindings_test_drop_handler_3a"] = function() fired_a = fired_a + 1 end
    _G["__bindings_test_drop_handler_3b"] = function() fired_b = fired_b + 1 end
    qt_constants.CONTROL.INSTALL_DROP_TARGET(target_a, MIME,
        "__bindings_test_drop_handler_3a")
    qt_constants.CONTROL.INSTALL_DROP_TARGET(target_b, MIME,
        "__bindings_test_drop_handler_3b")

    local payload = patch_drag_logic.build_payload({
        sequence_id = "s", track_type = "AUDIO",
        source_track_index = 2, home_rec_track_index = 2, project_id = "p",
    })
    qt_constants.CONTROL.SYNTHETIC_DROP(target_a, MIME, payload, 1, 1)
    qt_constants.CONTROL.SYNTHETIC_DROP(target_a, MIME, payload, 2, 2)
    qt_constants.CONTROL.SYNTHETIC_DROP(target_b, MIME, payload, 3, 3)

    assert(fired_a == 2, "target_a should have received exactly 2 drops, got "
        .. tostring(fired_a))
    assert(fired_b == 1, "target_b should have received exactly 1 drop, got "
        .. tostring(fired_b))
    print("  ✓ multiple drop targets dispatched independently")
end

print("✅ test_patch_drag_drop_bindings.lua passed")
os.exit(0)
