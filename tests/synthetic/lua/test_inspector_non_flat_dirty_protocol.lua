-- Inspector non-flat dirty protocol.
--
-- Phase 3.1 sweep: the flat-field path (any_dirty, discard_pending,
-- refresh_only_clean_fields) was previously the only consumer of the
-- per-widget `dirty` flag. With channel_list sections in play, those
-- helpers must also walk non-flat sections via section._dirty_hooks.
-- The renderer (channel_list_renderer) owns row identity (track_id) and
-- the dirty bit; selection_binding stays agnostic of row shape.
--
-- Real bugs this pins (both observable in the live editor pre-fix):
--   1. User typing in a channel-name cell would lose focus to an implied
--      re-pick because any_dirty only walked flat fields → "false" →
--      gate at update_selection did not drop the auto re-pick.
--   2. Schema-swap discard_pending only cleared flat fields → a stale
--      channel-row dirty bit carried into the next master's same-slot
--      row and corrupted its next refresh-time populate.
--
-- The renderer's SET_TEXT skip on preserve_dirty=true is covered under
-- --test mode (deferred memory todo) — qt_constants is not stubbed in
-- the synthetic unit harness, so the renderer's populate is not
-- exercised here.

require("test_env")

local sb = require("ui.inspector.selection_binding")

local pass, fail = 0, 0
local function check(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(string.format("FAIL: %s  got=%s want=%s",
            label, tostring(got), tostring(want))) end
end

-- Match the shape channel_list_renderer.install_dirty_hooks installs:
-- selection_binding contracts on iter_rows / clear_row_dirty (row_identity
-- is renderer-private — used by the renderer's own populate skip).
local function fake_non_flat_section(rows)
    return {
        name = "Channels",
        kind = "channel_list",
        _dirty_hooks = {
            iter_rows = function()
                local i = 0
                return function()
                    i = i + 1
                    return rows[i]
                end
            end,
            row_identity   = function(row) return row.track_id end,
            clear_row_dirty = function(row) row.dirty = false end,
        },
    }
end

local function flat_entry(initial_dirty)
    return {
        dirty       = initial_dirty,
        error       = false,
        clear_dirty = function(self) self.dirty = false end,
        blur_revert = function(self) self.dirty = false end,
    }
end

-- ─── any_dirty sees a non-flat dirty row when all flat fields are clean ──
do
    local rows = {
        { track_id = "t1", dirty = false },
        { track_id = "t2", dirty = true  },  -- user mid-rename
    }
    local schema_view = {
        field_widgets = { name = flat_entry(false) },
        sections      = { fake_non_flat_section(rows) },
    }
    check("any_dirty: non-flat row dirty + flat clean → true",
        sb._any_dirty(schema_view), true)
end

-- ─── any_dirty false when both flat and non-flat are clean ──────────────
do
    local rows = { { track_id = "t1", dirty = false } }
    local schema_view = {
        field_widgets = { name = flat_entry(false) },
        sections      = { fake_non_flat_section(rows) },
    }
    check("any_dirty: all clean → false",
        sb._any_dirty(schema_view), false)
end

-- ─── any_dirty true on flat alone (pre-existing contract preserved) ─────
do
    local rows = { { track_id = "t1", dirty = false } }
    local schema_view = {
        field_widgets = { name = flat_entry(true) },
        sections      = { fake_non_flat_section(rows) },
    }
    check("any_dirty: flat dirty + non-flat clean → true",
        sb._any_dirty(schema_view), true)
end

-- ─── discard_pending clears non-flat row dirty ──────────────────────────
do
    local rows = {
        { track_id = "t1", dirty = true },
        { track_id = "t2", dirty = true },
    }
    local flat_name = flat_entry(true)
    local schema_view = {
        field_widgets = { name = flat_name },
        sections      = { fake_non_flat_section(rows) },
    }
    sb._discard_pending(schema_view)
    check("discard_pending: flat field cleared", flat_name.dirty, false)
    check("discard_pending: non-flat row[1] cleared", rows[1].dirty, false)
    check("discard_pending: non-flat row[2] cleared", rows[2].dirty, false)
    check("discard_pending: any_dirty now false",
        sb._any_dirty(schema_view), false)
end

-- ─── discard_pending tolerates flat-only schema (no non-flat sections) ──
do
    local schema_view = {
        field_widgets = { name = flat_entry(true) },
        sections      = {
            { name = "File", kind = "flat_fields" },  -- no _dirty_hooks
        },
    }
    local ok = pcall(sb._discard_pending, schema_view)
    check("discard_pending: flat-only schema does not error", ok, true)
    check("discard_pending: flat-only entry cleared",
        schema_view.field_widgets.name.dirty, false)
end

print(string.format("\n%d passed, %d failed", pass, fail))
assert(fail == 0, "test_inspector_non_flat_dirty_protocol.lua: failures")
print("✅ test_inspector_non_flat_dirty_protocol.lua passed")
