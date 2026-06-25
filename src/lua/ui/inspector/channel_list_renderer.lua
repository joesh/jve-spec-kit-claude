--- Inspector channel-list renderer.
--
-- Populates a `kind='channel_list'` section (built empty by schema.lua)
-- with one row per master AUDIO channel, ordered by tracks.track_index ASC.
-- The data source is `inspectable:iter_channels()` — yielding rows of
-- `{channel_index, name, track_id}` (see MasterClipInspectable:iter_channels).
--
-- Lifecycle (widget-pool reuse, per spec 012 Q2 — no rent/return):
--   * pool[i] is the i-th visible row at populate time — NOT the
--     channel_index. The displayed channel_index/name come from the
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
local log           = require("core.logger").for_area("ui")

local M = {}

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

    local commit_conn = qt_signals.connect(name_edit, "editingFinished", function()
        if entry._programmatic then return end
        if not entry.dirty then return end
        entry.dirty = false
        local text = qt_constants.PROPERTIES.GET_TEXT(name_edit) or ""
        assert(entry.inspectable and entry.track_id, string.format(
            "channel_list_renderer: row committed without bound identity "
            .. "(track_id=%s, inspectable=%s)",
            tostring(entry.track_id), tostring(entry.inspectable)))
        local ok, err = entry.inspectable:set_channel_name(entry.track_id, text)
        if not ok then
            log.warn("channel_list_renderer: set_channel_name failed: %s",
                tostring(err))
        end
    end)
    assert(commit_conn, "channel_list_renderer: editingFinished connect failed")

    local add_result = section_obj:addContentWidget(row)
    if type(add_result) == "table" and add_result.success == false then
        error("channel_list_renderer: addContentWidget failed for channel row")
    end

    return entry
end

--- Populate section_view's channel-list section from inspectable:iter_channels.
--- Pool grows monotonically; unused slots hide. Called on every selection
--- change to a master-clip inspectable (selection_binding.load_single).
function M.populate(section_view, inspectable)
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

    local n = 0
    for ch in inspectable:iter_channels() do
        n = n + 1
        assert(type(ch) == "table" and ch.channel_index and ch.name and ch.track_id,
            string.format("channel_list_renderer: iter_channels row %d malformed", n))
        local row = pool[n]
        if not row then
            row = build_row(section_view.section_obj)
            pool[n] = row
        end
        -- Rebind identity for the editingFinished closure on every populate;
        -- the row widget persists across selection swaps but the underlying
        -- master/track changes. _programmatic guards textChanged so the
        -- SET_TEXT below doesn't flip dirty and stage a phantom rename.
        row.track_id      = ch.track_id
        row.inspectable   = inspectable
        row._programmatic = true
        qt_constants.PROPERTIES.SET_TEXT(row.index_label, tostring(ch.channel_index))
        qt_constants.PROPERTIES.SET_TEXT(row.name_edit, ch.name)
        row._programmatic = false
        row.dirty         = false
        qt_constants.DISPLAY.SET_VISIBLE(row.widget, true)
    end

    -- Hide rows beyond the current channel count (pool reuse, no widget churn).
    for i = n + 1, #pool do
        qt_constants.DISPLAY.SET_VISIBLE(pool[i].widget, false)
    end

    log.event("channel_list_renderer: populated section=%s rows=%d pool=%d",
        section_view.name, n, #pool)
end

return M
