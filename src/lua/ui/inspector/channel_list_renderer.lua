--- Inspector channel-list renderer.
--
-- Populates a `kind='channel_list'` section (built empty by schema.lua)
-- with one row per master AUDIO channel, ordered by tracks.track_index ASC.
-- The data source is `inspectable:iter_channels()` — yielding rows of
-- `{channel_index, name}` (see MasterClipInspectable:iter_channels).
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
--   * Phase 3 note: when per-row edits land, store ch.channel_index
--     on the row entry so edit handlers reference identity, not slot.
--
-- This renderer is read-only in Phase 2; Phase 3 rewires each row to
-- a RenameTrack edit through inspectable:set.

local qt_constants  = require("core.qt_constants")
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

    local name_label = qt_constants.WIDGET.CREATE_LABEL("")
    assert(name_label, "channel_list_renderer: CREATE_LABEL (name) returned nil")
    qt_constants.PROPERTIES.SET_STYLE(name_label, ui_constants.STYLES.FIELD_LABEL)
    qt_constants.LAYOUT.ADD_WIDGET(layout, name_label)
    qt_constants.LAYOUT.SET_STRETCH_FACTOR(layout, name_label, 1)

    local add_result = section_obj:addContentWidget(row)
    if type(add_result) == "table" and add_result.success == false then
        error("channel_list_renderer: addContentWidget failed for channel row")
    end

    return { widget = row, index_label = index_label, name_label = name_label }
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
        assert(type(ch) == "table" and ch.channel_index and ch.name,
            string.format("channel_list_renderer: iter_channels row %d malformed", n))
        local row = pool[n]
        if not row then
            row = build_row(section_view.section_obj)
            pool[n] = row
        end
        qt_constants.PROPERTIES.SET_TEXT(row.index_label, tostring(ch.channel_index))
        qt_constants.PROPERTIES.SET_TEXT(row.name_label, ch.name)
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
