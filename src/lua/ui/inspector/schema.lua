-- Inspector schema builder.
--
-- For each schema (clip, sequence), build a set of collapsible sections
-- populated with field widgets. The sections are pre-built at mount time
-- and shown/hidden on activation — the flattened-widget-pool decision
-- (Q2 resolution).
--
-- Responsibilities:
--   - build(schema_id, ...) — produce a schema_view { sections[], field_widgets{} }
--   - activate(schema_view) / deactivate(schema_view) — show/hide all sections
--   - apply_filter(schema_view, query) — substring match section name OR any
--     field label; hide non-matching sections
--   - collapse-state persistence via persistent_widget (FR-021a)

local metadata_schemas    = require("ui.metadata_schemas")
local collapsible_section = require("ui.collapsible_section")
local qt_constants        = require("core.qt_constants")
local persistent_widget   = require("core.persistent_widget")
local field_widget        = require("ui.inspector.field_widget")
local log                 = require("core.logger").for_area("ui")

local M = {}

local function persisted_key(schema_id, section_name)
    return string.format("inspector.section.%s.%s.expanded", schema_id, section_name)
end

local function section_matches_filter(section_record, query)
    if query == nil or query == "" then return true end
    local q = query:lower()
    if section_record.name:lower():find(q, 1, true) then return true end
    for _, label in ipairs(section_record.field_labels) do
        if label:lower():find(q, 1, true) then return true end
    end
    return false
end

--- Build all sections for one schema.
-- @param schema_id      string "clip" or "sequence"
-- @param content_layout userdata Qt layout that the sections attach to
-- @param callbacks      { frame_rate=fn, on_commit=fn(entry, value), on_section_toggled=fn(schema_id, section_name, expanded) }
-- @return schema_view   { schema_id, sections[], field_widgets{key→entry}, visible }
function M.build(schema_id, content_layout, callbacks)
    assert(schema_id and schema_id ~= "", "schema.build: schema_id required")
    assert(content_layout, "schema.build: content_layout required")
    assert(type(callbacks) == "table", "schema.build: callbacks required")
    assert(type(callbacks.frame_rate) == "function", "schema.build: callbacks.frame_rate required")
    assert(type(callbacks.on_commit) == "function", "schema.build: callbacks.on_commit required")

    local schema_sections = metadata_schemas.get_sections(schema_id)
    local sections = {}
    local field_widgets = {}

    for _, section_def in ipairs(schema_sections) do
        local section_result = collapsible_section.create_section(section_def.name)
        assert(section_result and section_result.success,
            string.format("schema.build: create_section %q failed", section_def.name))
        local section_obj    = section_result.return_values.section
        local section_widget = section_result.return_values.section_widget

        local field_labels = {}
        for _, f in ipairs(section_def.schema.fields) do
            local entry = field_widget.create_field(section_widget, f, {
                frame_rate = callbacks.frame_rate,
                on_commit  = callbacks.on_commit,
                attach_row = function(row)
                    assert(section_obj.addContentWidget,
                        string.format("schema.build: section %q missing addContentWidget",
                            section_def.name))
                    local add_result = section_obj:addContentWidget(row)
                    if type(add_result) == "table" and add_result.success == false then
                        error(string.format(
                            "schema.build: addContentWidget failed for field %q in section %q",
                            f.key, section_def.name))
                    end
                end,
            })
            field_widgets[f.key] = entry
            table.insert(field_labels, f.label)
        end

        qt_constants.LAYOUT.ADD_WIDGET(content_layout, section_widget)
        qt_constants.DISPLAY.SET_VISIBLE(section_widget, false)

        -- Restore persisted collapse state.
        local key = persisted_key(schema_id, section_def.name)
        local expanded = persistent_widget.get(key, true)
        if section_obj.setExpanded then
            section_obj:setExpanded(expanded and true or false)
        end

        -- Wire a save-on-toggle handler. The collapsible_section module
        -- doesn't emit a signal; wrap setExpanded so our wrapper persists.
        if section_obj.setExpanded and not section_obj._inspector_wrap_installed then
            local original = section_obj.setExpanded
            section_obj.setExpanded = function(self, value)
                original(self, value)
                persistent_widget.set(key, value and true or false)
                if callbacks.on_section_toggled then
                    callbacks.on_section_toggled(schema_id, section_def.name, value)
                end
            end
            section_obj._inspector_wrap_installed = true
        end

        table.insert(sections, {
            name         = section_def.name,
            section_obj  = section_obj,
            widget       = section_widget,
            field_labels = field_labels,
            persisted_key = key,
        })
    end

    log.event("schema.build: schema=%s sections=%d fields=%d",
        schema_id, #sections, (function()
            local n = 0; for _ in pairs(field_widgets) do n = n + 1 end; return n
        end)())

    return {
        schema_id     = schema_id,
        sections      = sections,
        field_widgets = field_widgets,
        visible       = false,
    }
end

function M.activate(schema_view)
    for _, s in ipairs(schema_view.sections) do
        qt_constants.DISPLAY.SET_VISIBLE(s.widget, true)
    end
    schema_view.visible = true
end

function M.deactivate(schema_view)
    for _, s in ipairs(schema_view.sections) do
        qt_constants.DISPLAY.SET_VISIBLE(s.widget, false)
    end
    schema_view.visible = false
end

--- Case-insensitive substring filter. Empty or nil query shows all sections.
function M.apply_filter(schema_view, query)
    if not schema_view or not schema_view.visible then return end
    for _, s in ipairs(schema_view.sections) do
        local show = section_matches_filter(s, query)
        qt_constants.DISPLAY.SET_VISIBLE(s.widget, show)
    end
end

-- Exposed for unit tests
M._section_matches_filter = section_matches_filter
M._persisted_key = persisted_key

return M
