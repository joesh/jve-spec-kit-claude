--- Inspector channel-list renderer.
--
-- Populates a `kind='channel_list'` section (built empty by schema.lua)
-- with one row per master AUDIO channel, ordered by tracks.track_index ASC.
-- The data source is `inspectable:iter_channels()` — yielding rows of
-- `{display_index, name, track_id}` (see MasterClipInspectable:iter_channels).
--
-- Lifecycle (widget-pool reuse, per spec 012 Q2 — no rent/return):
--   * pool[i] is the i-th visible row at populate time — NOT the
--     display_index. The displayed display_index/name come from the
--     model on every call; slot identity is purely ordinal.
--   * First populate that surfaces N channels creates rows 1..N. On
--     subsequent populates, relabel the visible rows; hide unused
--     rows. The pool grows monotonically — pool size = max channel
--     count ever seen on this schema_view.
--   * The pool lives on `section_view._channel_pool` (created on first
--     call). Memory is bounded by max-channels-ever-seen.
--
-- Phase 3: each row's name is an editable QLineEdit. On editingFinished
-- (Enter or focus-out), if the user actually changed the text, the row
-- dispatches MasterClipInspectable:set_channel_name(track_id, new_text)
-- → SetTrackName (undoable; clearing the text drops the override and
-- the displayed label reverts to the derived form). The textChanged →
-- editingFinished dirty-gate matches field_widget's pattern so a
-- populate-time SET_TEXT never round-trips as a phantom rename.

local qt_constants  = require("core.qt_constants")
local qt_signals    = require("core.qt_signals")
local ui_constants  = require("core.ui_constants")
local runtime_mode  = require("core.runtime_mode")
local log           = require("core.logger").for_area("ui")

local M = {}

-- Focused-channel state, module-scope. Sticky: a focus_in on a channel
-- row stamps the (inspectable, track_id) pair here; subsequent commands
-- like MoveChannel read it. Cleared on fresh selection populate (when
-- the user picks a different master), NOT on focus_out — so the user
-- can click a channel name, focus drift to a non-channel widget, and
-- the keyboard shortcut still operates on the last channel they
-- focused. The Inspector itself has no shared focus registry; this is
-- the only owner.
M._focused_channel = nil

-- Drag-reorder mime type. Distinct from any timeline-clip mime so a
-- channel-row drag can't accidentally drop on a timeline strip and vice
-- versa.
local MIME_CHANNEL_REORDER = "application/x-jve-channel-reorder"

local focus_handler_seq = 0
local drag_handler_seq  = 0

-- Dirty-protocol hooks for non-flat sections (consumed by
-- selection_binding.discard_pending / any_dirty / populate_non_flat_sections
-- with opts.preserve_dirty). Stamped on `section_view._dirty_hooks` lazily
-- by populate; idempotent. selection_binding stays agnostic of row shape;
-- this module owns row identity (track_id) and dirty mechanics.
local function install_dirty_hooks(section_view, pool)
    if section_view._dirty_hooks then return end
    section_view._dirty_hooks = {
        iter_rows = function()
            local i = 0
            return function()
                i = i + 1
                return pool[i]
            end
        end,
        row_identity   = function(row) return row.track_id end,
        clear_row_dirty = function(row) row.dirty = false end,
    }
end

local function build_row(section_obj)
    local row = qt_constants.WIDGET.CREATE()
    assert(row, "channel_list_renderer: WIDGET.CREATE returned nil")
    local layout = qt_constants.LAYOUT.CREATE_HBOX()
    assert(layout, "channel_list_renderer: CREATE_HBOX returned nil")
    qt_constants.LAYOUT.SET_ON_WIDGET(row, layout)
    qt_constants.LAYOUT.SET_MARGINS(layout,
        ui_constants.LAYOUT.FIELD_MARGIN_LEFT,
        ui_constants.LAYOUT.FIELD_MARGIN_TOP,
        ui_constants.LAYOUT.FIELD_MARGIN_RIGHT,
        ui_constants.LAYOUT.FIELD_MARGIN_BOTTOM)
    qt_constants.LAYOUT.SET_SPACING(layout, ui_constants.LAYOUT.FIELD_SPACING)

    -- Visible drag-handle affordance — discovers the drag-reorder
    -- gesture. Six-dot braille pattern (U+283F) is the widely-recognized
    -- "grip" glyph in modern Mac/iOS reorder lists. Sits left of the
    -- index gutter; matches the row height.
    local grip = qt_constants.WIDGET.CREATE_LABEL("\xe2\xa0\xbf")  -- ⠿
    assert(grip, "channel_list_renderer: CREATE_LABEL (grip) returned nil")
    qt_constants.PROPERTIES.SET_STYLE(grip, ui_constants.STYLES.CHANNEL_DRAG_GRIP)
    qt_constants.PROPERTIES.SET_ALIGNMENT(grip,
        qt_constants.PROPERTIES.ALIGN_CENTER)
    qt_constants.LAYOUT.ADD_WIDGET(layout, grip)

    -- Reuse the inspector's standard FIELD_LABEL style (Tier-3 token,
    -- per ui_constants.STYLES) so the index gutter aligns with the
    -- field-label column in adjacent flat-field sections.
    local index_label = qt_constants.WIDGET.CREATE_LABEL("")
    assert(index_label, "channel_list_renderer: CREATE_LABEL (index) returned nil")
    qt_constants.PROPERTIES.SET_STYLE(index_label, ui_constants.STYLES.FIELD_LABEL)
    qt_constants.PROPERTIES.SET_ALIGNMENT(index_label,
        qt_constants.PROPERTIES.ALIGN_RIGHT)
    qt_constants.LAYOUT.ADD_WIDGET(layout, index_label)

    local name_edit = qt_constants.WIDGET.CREATE_LINE_EDIT("")
    assert(name_edit, "channel_list_renderer: CREATE_LINE_EDIT returned nil")
    qt_constants.PROPERTIES.SET_STYLE(name_edit, ui_constants.STYLES.STRING_FIELD)
    qt_constants.LAYOUT.ADD_WIDGET(layout, name_edit)
    qt_constants.LAYOUT.SET_STRETCH_FACTOR(layout, name_edit, 1)

    -- entry shape: identity (track_id, inspectable) is rebound by populate
    -- on each selection; the closures here read the LIVE values so wiring
    -- once at build is correct. _programmatic suppresses dirty during
    -- populate's SET_TEXT (no phantom commit on every selection swap).
    local entry = {
        widget       = row,
        index_label  = index_label,
        name_edit    = name_edit,
        dirty        = false,
        _programmatic = false,
        track_id     = nil,
        inspectable  = nil,
    }

    local text_conn = qt_signals.connect(name_edit, "textChanged", function()
        if entry._programmatic then return end
        entry.dirty = true
    end)
    assert(text_conn, "channel_list_renderer: textChanged connect failed")

    -- Focus tracking: stamp module-scope _focused_channel on focus_in so
    -- MoveChannel can resolve which row to move. _G[handler_name] is a
    -- distinct slot per row because qt_set_focus_handler takes a global
    -- function name; the field_widget pattern (field_widget.lua:411-426)
    -- is the model. Sticky — no focus_out clearance, so the user can
    -- click-then-shortcut from a non-channel widget.
    focus_handler_seq = focus_handler_seq + 1
    local focus_handler_name = string.format(
        "channel_list_renderer_focus_%d", focus_handler_seq)
    _G[focus_handler_name] = function(event)
        assert(event, string.format(
            "channel_list_renderer focus handler %q: event is nil",
            focus_handler_name))
        if event.focus_in and entry.track_id and entry.inspectable then
            M._focused_channel = {
                inspectable = entry.inspectable,
                track_id    = entry.track_id,
            }
        end
    end
    -- luacheck: globals qt_set_focus_handler
    runtime_mode.assert_production(qt_set_focus_handler,
        "channel_list_renderer: qt_set_focus_handler binding missing")
    if qt_set_focus_handler then
        qt_set_focus_handler(name_edit, focus_handler_name)
    end

    local commit_conn = qt_signals.connect(name_edit, "editingFinished", function()
        if entry._programmatic then return end
        if not entry.dirty then return end
        local text = qt_constants.PROPERTIES.GET_TEXT(name_edit)
        assert(type(text) == "string",
            "channel_list_renderer: GET_TEXT returned non-string on bound name_edit")
        assert(entry.inspectable and entry.track_id, string.format(
            "channel_list_renderer: row committed without bound identity "
            .. "(track_id=%s, inspectable=%s)",
            tostring(entry.track_id), tostring(entry.inspectable)))
        -- set_channel_name only returns (false, err) via the command-harness
        -- soft-fail path; SetTrackName itself has no user-facing failure mode
        -- (no name validation / uniqueness / length constraints). A failure
        -- here is a wiring/routing bug — assert per 1.14 rather than swallow.
        local ok, err = entry.inspectable:set_channel_name(entry.track_id, text)
        assert(ok, err)
        entry.dirty = false
    end)
    assert(commit_conn, "channel_list_renderer: editingFinished connect failed")

    -- Drag-reorder: the row is BOTH a drag source (carries its track_id
    -- as payload) AND a drop target (receives a peer row's track_id and
    -- moves it to this row's display slot). Each handler reads LIVE
    -- entry fields (track_id, inspectable, display_index) so rebinding
    -- at populate-time is the only mutation needed when the master
    -- changes — no re-installing filters.
    drag_handler_seq = drag_handler_seq + 1
    local provider_name = string.format(
        "channel_list_renderer_drag_payload_%d", drag_handler_seq)
    _G[provider_name] = function()
        -- Empty string when the row isn't bound to a channel: signals
        -- no payload (Qt's drag start will still fire, but the mime
        -- match on the drop side filters self-drops harmlessly).
        return tostring(entry.track_id or "")
    end

    local drop_handler_name = string.format(
        "channel_list_renderer_drop_handler_%d", drag_handler_seq)
    _G[drop_handler_name] = function(_x, _y, payload)
        assert(type(payload) == "string",
            "channel_list_renderer drop handler: payload must be a string")
        if payload == "" then return end
        if not (entry.track_id and entry.inspectable and entry.display_index) then
            return  -- hidden / unbound row; ignore stray events
        end
        if payload == entry.track_id then return end  -- self-drop is a no-op
        local ok, err = entry.inspectable:move_channel(payload, entry.display_index)
        assert(ok, err)
    end

    -- luacheck: globals qt_install_drag_source qt_install_drop_target
    runtime_mode.assert_production(qt_install_drag_source,
        "channel_list_renderer: qt_install_drag_source binding missing")
    runtime_mode.assert_production(qt_install_drop_target,
        "channel_list_renderer: qt_install_drop_target binding missing")
    if qt_install_drag_source then
        qt_install_drag_source(row, MIME_CHANNEL_REORDER, provider_name)
    end
    if qt_install_drop_target then
        qt_install_drop_target(row, MIME_CHANNEL_REORDER, drop_handler_name)
    end

    local add_result = section_obj:addContentWidget(row)
    if type(add_result) == "table" and add_result.success == false then
        error("channel_list_renderer: addContentWidget failed for channel row")
    end

    return entry
end

--- Populate section_view's channel-list section from inspectable:iter_channels.
--- Pool grows monotonically; unused slots hide.
---
--- Called from two paths with different semantics (see selection_binding):
---   * load_single        — fresh selection, opts.preserve_dirty omitted/false:
---                          clobber every row (the inspectable changed).
---   * refresh_only_clean_fields — model notify on the SAME inspectable,
---                          opts.preserve_dirty=true: skip SET_TEXT on rows
---                          with an in-flight user edit (row.dirty AND
---                          same identity), matching the flat-field
---                          "don't overwrite a typing user" contract.
function M.populate(section_view, inspectable, opts)
    assert(section_view, "channel_list_renderer.populate: section_view required")
    assert(section_view.kind == "channel_list", string.format(
        "channel_list_renderer.populate: section %q has kind=%q, expected 'channel_list'",
        tostring(section_view.name), tostring(section_view.kind)))
    assert(section_view.section_obj,
        "channel_list_renderer.populate: section_view.section_obj required")
    assert(inspectable and type(inspectable.iter_channels) == "function",
        "channel_list_renderer.populate: inspectable must implement iter_channels()")

    section_view._channel_pool = section_view._channel_pool or {}
    local pool = section_view._channel_pool
    install_dirty_hooks(section_view, pool)

    local preserve_dirty = opts and opts.preserve_dirty == true

    -- Fresh selection (preserve_dirty=false) means the user picked a
    -- different master OR a non-master entirely; the prior focused
    -- channel no longer applies. Refresh-only flows (preserve_dirty=true)
    -- keep it — the same master is just re-pulling its data.
    if not preserve_dirty
        and M._focused_channel
        and M._focused_channel.inspectable ~= inspectable then
        M._focused_channel = nil
    end

    local n = 0
    for ch in inspectable:iter_channels() do
        n = n + 1
        assert(type(ch) == "table" and ch.display_index and ch.name and ch.track_id,
            string.format("channel_list_renderer: iter_channels row %d malformed", n))
        local row = pool[n]
        if not row then
            row = build_row(section_view.section_obj)
            pool[n] = row
        end
        -- Preserve in-flight edit: dirty row addressing the SAME (track_id,
        -- inspectable) as the incoming channel. Identity match guards against
        -- a selection-swap leaving the prior master's typed text in place.
        local keep_user_edit = preserve_dirty
            and row.dirty
            and row.track_id    == ch.track_id
            and row.inspectable == inspectable
        if not keep_user_edit then
            row.track_id      = ch.track_id
            row.inspectable   = inspectable
            row._programmatic = true
            qt_constants.PROPERTIES.SET_TEXT(row.index_label, tostring(ch.display_index))
            qt_constants.PROPERTIES.SET_TEXT(row.name_edit, ch.name)
            row._programmatic = false
            row.dirty         = false
        end
        -- display_index always reflects the model's current ordinal so
        -- a drop on this row routes to the right slot, even if the row
        -- kept its in-flight name edit above (keep_user_edit doesn't
        -- gate this — it gates the visible label only).
        row.display_index = ch.display_index
        qt_constants.DISPLAY.SET_VISIBLE(row.widget, true)
    end

    -- Hide unused slots AND drop their identity so a stale focus / drop
    -- event on an off-screen row can't dispatch against the previous
    -- master (rename via name_edit, reorder via drop target).
    for i = n + 1, #pool do
        qt_constants.DISPLAY.SET_VISIBLE(pool[i].widget, false)
        pool[i].track_id      = nil
        pool[i].inspectable   = nil
        pool[i].display_index = nil
        pool[i].dirty         = false
    end

    log.event("channel_list_renderer: populated section=%s rows=%d pool=%d preserve_dirty=%s",
        section_view.name, n, #pool, tostring(preserve_dirty))
end

--- The most recently focused (inspectable, track_id) pair, or nil if no
--- channel has been focused (or focus was cleared by a fresh selection).
--- Consumed by MoveChannel to resolve "which channel do I move?".
function M.get_focused_channel()
    return M._focused_channel
end

return M
