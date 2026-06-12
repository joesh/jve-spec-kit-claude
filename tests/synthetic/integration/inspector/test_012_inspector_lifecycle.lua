-- 012 Inspector Lifecycle — commit/discard/reset/bottom-bar integration test.
--
-- REPLACES (stub-heavy synthetic/lua/ tests):
--   test_inspector_commit_failure.lua
--   test_inspector_discard_pending_on_selection.lua
--   test_inspector_reset_and_bottom_bar.lua
--
-- DOMAIN RULES PINNED:
--   DR-COMMIT-FAIL  When inspectable:set returns (false, err), the widget
--                   must revert to the last model value and the error banner
--                   must surface the message (spec FR-015b, commit-failure path).
--   DR-COMMIT-OK    When inspectable:set succeeds, the widget shows the new
--                   value and any previous banner is cleared.
--   DR-DISCARD      Selection change discards pending un-applied multi-edit
--                   values — dirty flag clears, pending_value clears (FR-013a).
--   DR-DISCARD-ERR  A dirty+error field blur-reverts on selection change
--                   (red border gone) (FR-015b on discard path).
--   DR-BOTTOM-BAR   Apply+Reset bar is visible only in multi_edit mode, hidden
--                   in single / empty.
--   DR-APPLY-GATE   Apply is enabled only when there is at least one dirty
--                   valid field; Reset is enabled whenever any field is dirty.
--   DR-RESET-PEND   reset_pending reverts all dirty/errored fields and clears
--                   the error banner.
--
-- DROPPED scenarios (stub-call-order / implementation detail):
--   * mode≠single no-ops commit_single_field — behaviour is implicit; the domain
--     rule is that multi_edit uses Apply, not per-keystroke commit.
--   * exact begin_command_event/end_command_event call counts — internal plumbing.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        tests/synthetic/integration/inspector/test_012_inspector_lifecycle.lua

local qt_constants = require("core.qt_constants")
require("test_env")

local selection_binding = require("ui.inspector.selection_binding")

print("=== test_012_inspector_lifecycle.lua ===")

-- ── Helpers ────────────────────────────────────────────────────────────────

-- Build a minimal real ui_state: real Qt widgets for the parts the code
-- touches (banner, apply_button, reset_button, bottom_bar), nil for panels
-- we aren't testing here. field_widgets holds Entry-like objects (Lua
-- tables with the same surface as real field_widget.Entry).
local function make_real_ui_state(mode, field_entries)
    local banner     = qt_constants.WIDGET.CREATE_LABEL("")
    local bar        = qt_constants.WIDGET.CREATE()
    local apply_btn  = qt_constants.WIDGET.CREATE_BUTTON("Apply")
    local reset_btn  = qt_constants.WIDGET.CREATE_BUTTON("Reset")
    assert(banner,    "make_real_ui_state: CREATE_LABEL returned nil")
    assert(bar,       "make_real_ui_state: CREATE bar returned nil")
    assert(apply_btn, "make_real_ui_state: CREATE apply_btn returned nil")
    assert(reset_btn, "make_real_ui_state: CREATE reset_btn returned nil")

    local schema_view = { field_widgets = field_entries or {} }
    return {
        mode               = mode,
        error_banner       = banner,
        bottom_bar         = bar,
        apply_button       = apply_btn,
        reset_button       = reset_btn,
        active_schema_view = schema_view,
        _field_errors      = {},
        schema             = {
            deactivate   = function() end,
            activate     = function() end,
            apply_filter = function() end,
        },
        header_label = nil,  -- not tested here
    }, banner, bar, apply_btn, reset_btn, schema_view
end

-- Minimal entry that mirrors field_widget.Entry's surface used by
-- selection_binding. Real widget for the value read-back.
local function make_entry(opts)
    opts = opts or {}
    local widget = qt_constants.WIDGET.CREATE_LINE_EDIT(opts.initial_text or "")
    assert(widget, "make_entry: CREATE_LINE_EDIT returned nil")

    local e = {
        field_key         = opts.field_key or "name",
        field_type        = "STRING",
        property_type     = "STRING",
        dirty             = opts.dirty and true or false,
        error             = opts.err and true or false,
        pending_value     = opts.pending,
        _last_model_value = opts.model_value,
        widget            = widget,
        -- track calls:
        set_value_calls   = {},
        blur_revert_calls = 0,
        clear_dirty_calls = 0,
    }
    function e:set_value(v)
        table.insert(self.set_value_calls, v)
        qt_constants.PROPERTIES.SET_TEXT(widget, tostring(v or ""))
        self.dirty = false
        self.pending_value = nil
    end
    function e:blur_revert()
        self.blur_revert_calls = self.blur_revert_calls + 1
        self.error = false
        if self._last_model_value ~= nil then
            qt_constants.PROPERTIES.SET_TEXT(widget, tostring(self._last_model_value))
        end
    end
    function e:clear_dirty()
        self.clear_dirty_calls = self.clear_dirty_calls + 1
        self.dirty = false
        self.pending_value = nil
    end
    function e:set_error(flag) self.error = flag and true or false end
    return e
end

-- ── DR-COMMIT-FAIL ─────────────────────────────────────────────────────────
print("-- DR-COMMIT-FAIL: failed commit → widget reverts, error banner shown --")
do
    local entry = make_entry({ field_key = "sequence_start", model_value = 1000 })
    local ui_state = {
        mode               = "single",
        error_banner       = qt_constants.WIDGET.CREATE_LABEL(""),
        bottom_bar         = qt_constants.WIDGET.CREATE(),
        apply_button       = nil,
        reset_button       = nil,
        active_schema_view = { field_widgets = { sequence_start = entry } },
        _field_errors      = {},
        on_error           = nil,
    }
    assert(ui_state.error_banner, "DR-COMMIT-FAIL: error_banner widget required")

    -- Capture on_error calls.
    local error_calls = {}
    ui_state.on_error = function(e, msg) table.insert(error_calls, { entry = e, msg = msg }) end

    local failing_inspectable = {
        sequence_id   = "seq-x",
        get_schema_id = function() return "clip" end,
        set = function(_self, _field, _payload)
            return false, "VIDEO_OVERLAP: clips cannot overlap on a video track"
        end,
    }
    ui_state.active_inspectables = { failing_inspectable }

    selection_binding.commit_single_field(ui_state, entry, 9999)

    assert(entry.blur_revert_calls == 1, string.format(
        "DR-COMMIT-FAIL: blur_revert must be called exactly once; got %d",
        entry.blur_revert_calls))
    assert(#entry.set_value_calls == 0, string.format(
        "DR-COMMIT-FAIL: set_value(stale) must NOT be called; got %d calls",
        #entry.set_value_calls))
    assert(#error_calls == 1, string.format(
        "DR-COMMIT-FAIL: on_error must be called once; got %d", #error_calls))
    assert(error_calls[1].msg and
           tostring(error_calls[1].msg):find("VIDEO_OVERLAP", 1, true),
        "DR-COMMIT-FAIL: error message must contain the underlying reason")
    print("  PASS DR-COMMIT-FAIL")
end

-- ── DR-COMMIT-OK ───────────────────────────────────────────────────────────
print("-- DR-COMMIT-OK: successful commit → widget updated, banner cleared --")
do
    local entry = make_entry({ field_key = "name", model_value = "OldName" })
    local ui_state = {
        mode               = "single",
        error_banner       = qt_constants.WIDGET.CREATE_LABEL(""),
        bottom_bar         = qt_constants.WIDGET.CREATE(),
        apply_button       = nil,
        reset_button       = nil,
        active_schema_view = { field_widgets = { name = entry } },
        _field_errors      = {},
        on_error           = nil,
    }
    assert(ui_state.error_banner, "DR-COMMIT-OK: error_banner required")

    local error_calls = {}
    ui_state.on_error = function(e, msg) table.insert(error_calls, { entry = e, msg = msg }) end

    local succeeding_inspectable = {
        sequence_id   = "seq-x",
        get_schema_id = function() return "clip" end,
        set           = function() return true end,
    }
    ui_state.active_inspectables = { succeeding_inspectable }

    selection_binding.commit_single_field(ui_state, entry, "NewName")

    assert(#entry.set_value_calls == 1, string.format(
        "DR-COMMIT-OK: set_value must be called exactly once; got %d", #entry.set_value_calls))
    assert(entry.set_value_calls[1] == "NewName", string.format(
        "DR-COMMIT-OK: set_value must carry the new value; got %q",
        tostring(entry.set_value_calls[1])))
    assert(entry.blur_revert_calls == 0,
        "DR-COMMIT-OK: blur_revert must NOT be called on success")
    assert(#error_calls == 1 and error_calls[1].msg == nil, string.format(
        "DR-COMMIT-OK: on_error must be called with nil to clear banner; got %s",
        tostring(error_calls[1] and error_calls[1].msg)))
    print("  PASS DR-COMMIT-OK")
end

-- ── DR-DISCARD ─────────────────────────────────────────────────────────────
print("-- DR-DISCARD: selection change discards pending multi-edit values (FR-013a) --")
do
    -- Simulate three entries: dirty-valid, clean, dirty+error.
    local e_dirty = make_entry({ field_key = "a", dirty = true, pending = "typed" })
    local e_clean = make_entry({ field_key = "b", dirty = false })
    local e_err   = make_entry({ field_key = "c", dirty = true, err = true, model_value = 100 })

    selection_binding._discard_pending({ field_widgets = { a = e_dirty, b = e_clean, c = e_err } })

    -- dirty-valid: clear_dirty fires
    assert(e_dirty.clear_dirty_calls == 1, string.format(
        "DR-DISCARD: dirty-valid: clear_dirty must fire once; got %d",
        e_dirty.clear_dirty_calls))
    assert(e_dirty.pending_value == nil,
        "DR-DISCARD: dirty-valid: pending_value must be cleared")
    assert(e_dirty.blur_revert_calls == 0,
        "DR-DISCARD: dirty-valid: blur_revert must NOT fire (no error)")

    -- clean: clear_dirty still fires (idempotent)
    assert(e_clean.clear_dirty_calls == 1, string.format(
        "DR-DISCARD: clean: clear_dirty must still fire; got %d",
        e_clean.clear_dirty_calls))
    assert(e_clean.blur_revert_calls == 0,
        "DR-DISCARD: clean: blur_revert must NOT fire")

    -- dirty+error: clear_dirty AND blur_revert both fire
    assert(e_err.clear_dirty_calls == 1, string.format(
        "DR-DISCARD: dirty+error: clear_dirty must fire; got %d", e_err.clear_dirty_calls))
    assert(e_err.blur_revert_calls == 1, string.format(
        "DR-DISCARD: dirty+error: blur_revert must fire (drops red border); got %d",
        e_err.blur_revert_calls))
    print("  PASS DR-DISCARD")
end

-- ── DR-DISCARD-ERR: same as DR-DISCARD but focuses on error clearing ────────
print("-- DR-DISCARD-ERR: dirty+error field loses error state after discard --")
do
    local entry = make_entry({ field_key = "mark_in", dirty = true, err = true, model_value = 50 })
    assert(entry.error, "precondition: entry must start in error state")

    selection_binding._discard_pending({ field_widgets = { mark_in = entry } })

    assert(not entry.error, "DR-DISCARD-ERR: error flag must be cleared after discard")
    print("  PASS DR-DISCARD-ERR")
end

-- ── DR-BOTTOM-BAR ──────────────────────────────────────────────────────────
print("-- DR-BOTTOM-BAR: Apply+Reset bar visible only in multi_edit --")
do
    for _, tc in ipairs({
        { mode = "single",     want_visible = false },
        { mode = "empty",      want_visible = false },
        { mode = "multi_edit", want_visible = true  },
    }) do
        local ui_state, _, bar = make_real_ui_state(tc.mode, {})
        selection_binding._update_apply_button(ui_state)

        -- Read the actual visibility from the widget. We use a Lua-side
        -- proxy: DISPLAY.SET_VISIBLE was already called — we verify by
        -- re-calling in the opposite direction and confirming no crash,
        -- then checking via GET_VISIBLE if available.
        -- Since there's no GET_VISIBLE binding, we rely on the call
        -- sequence above being the only writer, and trace it through
        -- a wrapper around DISPLAY.SET_VISIBLE.
        -- Approach: wrap DISPLAY.SET_VISIBLE before calling, unwrap after.
        local last_visibility
        local orig_sv = qt_constants.DISPLAY.SET_VISIBLE
        qt_constants.DISPLAY.SET_VISIBLE = function(w, v)
            if w == bar then last_visibility = v end
            orig_sv(w, v)
        end
        selection_binding._update_apply_button(ui_state)
        qt_constants.DISPLAY.SET_VISIBLE = orig_sv

        assert(last_visibility == tc.want_visible, string.format(
            "DR-BOTTOM-BAR: mode=%s: bar visibility must be %s; got %s",
            tc.mode, tostring(tc.want_visible), tostring(last_visibility)))
    end
    print("  PASS DR-BOTTOM-BAR")
end

-- ── DR-APPLY-GATE ──────────────────────────────────────────────────────────
print("-- DR-APPLY-GATE: Apply enabled state reflects dirty+valid, Reset reflects any dirty --")
do
    local cases = {
        {
            label      = "dirty-valid",
            dirty      = true,  err = false,
            want_apply = true,  want_reset = true,
        },
        {
            label      = "dirty-invalid",
            dirty      = true,  err = true,
            want_apply = false, want_reset = true,
        },
        {
            label      = "no-dirty",
            dirty      = false, err = false,
            want_apply = false, want_reset = false,
        },
    }
    for _, tc in ipairs(cases) do
        local entry = make_entry({ dirty = tc.dirty, err = tc.err })
        local ui_state, _, _, apply_btn, reset_btn =
            make_real_ui_state("multi_edit", { entry })

        local last_apply, last_reset
        local orig_se = qt_constants.CONTROL.SET_ENABLED
        qt_constants.CONTROL.SET_ENABLED = function(w, v)
            if w == apply_btn then last_apply = v end
            if w == reset_btn then last_reset = v end
            orig_se(w, v)
        end
        selection_binding._update_apply_button(ui_state)
        qt_constants.CONTROL.SET_ENABLED = orig_se

        assert(last_apply == tc.want_apply, string.format(
            "DR-APPLY-GATE %s: Apply enabled must be %s; got %s",
            tc.label, tostring(tc.want_apply), tostring(last_apply)))
        assert(last_reset == tc.want_reset, string.format(
            "DR-APPLY-GATE %s: Reset enabled must be %s; got %s",
            tc.label, tostring(tc.want_reset), tostring(last_reset)))
    end
    print("  PASS DR-APPLY-GATE")
end

-- ── DR-RESET-PEND ──────────────────────────────────────────────────────────
print("-- DR-RESET-PEND: reset_pending reverts dirty/errored fields + clears banner --")
do
    local e_dirty = make_entry({ dirty = true, model_value = 1000 })
    local e_both  = make_entry({ dirty = true, err = true, model_value = 2000 })
    local e_clean = make_entry({ dirty = false, model_value = 3000 })
    local ui_state, banner = make_real_ui_state("multi_edit", {
        e_dirty, e_both, e_clean,
    })
    ui_state._field_errors = { k = "stale error" }

    -- Pass-through wrap to verify banner hidden call.
    local banner_hidden_called = false
    local orig_sv = qt_constants.DISPLAY.SET_VISIBLE
    qt_constants.DISPLAY.SET_VISIBLE = function(w, v)
        if w == banner and v == false then banner_hidden_called = true end
        orig_sv(w, v)
    end
    selection_binding.reset_pending(ui_state)
    qt_constants.DISPLAY.SET_VISIBLE = orig_sv

    assert(e_dirty.blur_revert_calls == 1, string.format(
        "DR-RESET-PEND: dirty field must revert; got blur_revert_calls=%d",
        e_dirty.blur_revert_calls))
    assert(e_both.blur_revert_calls == 1, string.format(
        "DR-RESET-PEND: dirty+error field must revert; got blur_revert_calls=%d",
        e_both.blur_revert_calls))
    assert(e_clean.blur_revert_calls == 0,
        "DR-RESET-PEND: clean field must NOT be reverted")
    assert(next(ui_state._field_errors) == nil,
        "DR-RESET-PEND: error table must be cleared")
    assert(banner_hidden_called,
        "DR-RESET-PEND: banner widget must be hidden via SET_VISIBLE(false)")
    print("  PASS DR-RESET-PEND")
end

-- ── DR-RESET-PEND no-schema safe ──────────────────────────────────────────
print("-- DR-RESET-PEND: no active schema → safe no-op --")
do
    local ui_state = { mode = "multi_edit" }  -- no active_schema_view
    local ok = pcall(selection_binding.reset_pending, ui_state)
    assert(ok, "DR-RESET-PEND: no active schema must not raise")
    print("  PASS DR-RESET-PEND no-schema safe")
end

print("\n✅ test_012_inspector_lifecycle.lua passed")
