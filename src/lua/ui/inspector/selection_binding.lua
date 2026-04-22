-- Inspector selection binding.
--
-- Receives selection updates from the selection hub, resolves each item to
-- an inspectable, computes the active schema (majority + stability
-- tiebreak), and drives the form into the right mode (empty / single /
-- multi_edit / multi_read_only / heterogeneous).
--
-- Pure helpers (testable in isolation):
--   compute_mode, compute_active_schema, resolve_inspectables,
--   detect_mixed_values.

local inspectable_factory = require("inspectable")
local command_manager     = require("core.command_manager")
local qt_constants        = require("core.qt_constants")
local log                 = require("core.logger").for_area("ui")

local M = {}

-- ----------------------------------------------------------------------
-- Pure helpers
-- ----------------------------------------------------------------------

--- Compute the selection mode from a resolved selection summary.
--  @param summary {size, schema_counts{id→count}, all_support_multi_edit}
--  @return mode string: "empty", "single", "multi_edit",
--                        "multi_read_only", "heterogeneous"
local function compute_mode(summary)
    if summary.size == 0 then return "empty" end
    local schemas_present = 0
    for _ in pairs(summary.schema_counts) do schemas_present = schemas_present + 1 end
    if schemas_present > 1 then return "heterogeneous" end
    if summary.size == 1 then return "single" end
    if summary.all_support_multi_edit then return "multi_edit" end
    return "multi_read_only"
end
M._compute_mode = compute_mode

--- Key a selection-item for identity tracking (tiebreak stability).
local function item_key(item)
    if item.clip_id and item.clip_id ~= "" then
        return "clip:" .. item.clip_id
    elseif item.sequence_id and item.sequence_id ~= "" then
        return "seq:" .. item.sequence_id
    end
    return tostring(item)
end
M._item_key = item_key

--- Compute active schema from the current selection (majority, tiebreak on
--- newly-clicked items not present in previous selection). Stable when the
--- set of schemas present is unchanged (FR-005a).
--  @param items         table   current selection (raw)
--  @param schema_counts table   {schema_id → count}
--  @param prev_schemas  table   set {schema_id = true} from previous selection
--  @param prev_active   string? previous active schema
--  @param prev_ids      table?  set of item-keys from previous selection
--  @return active_schema_id string
local function compute_active_schema(items, schema_counts, prev_schemas, prev_active, prev_ids)
    assert(type(schema_counts) == "table",
        "selection_binding.compute_active_schema: schema_counts required")

    -- Determine set of schemas present now.
    local current_schemas = {}
    local present_count = 0
    for id, c in pairs(schema_counts) do
        if c > 0 then
            current_schemas[id] = true
            present_count = present_count + 1
        end
    end
    assert(present_count > 0,
        "selection_binding.compute_active_schema: no schemas present — caller should have short-circuited")

    -- Stability rule: if the set of schemas present is unchanged AND we had
    -- an active schema, keep it.
    if prev_active and prev_schemas then
        local unchanged = true
        for k in pairs(current_schemas) do
            if not prev_schemas[k] then unchanged = false; break end
        end
        if unchanged then
            for k in pairs(prev_schemas) do
                if not current_schemas[k] then unchanged = false; break end
            end
        end
        if unchanged and current_schemas[prev_active] then
            return prev_active
        end
    end

    -- Majority. Ties broken by the first item in items[] whose key is not in
    -- prev_ids. If all items were in prev_ids (full overlap, schema set just
    -- changed), fall back to items[1].
    local max_count = 0
    for _, c in pairs(schema_counts) do
        if c > max_count then max_count = c end
    end
    local tied_schemas = {}
    for id, c in pairs(schema_counts) do
        if c == max_count then tied_schemas[id] = true end
    end
    local tied_count = 0
    local only_id = nil
    for id in pairs(tied_schemas) do
        tied_count = tied_count + 1
        only_id = id
    end
    if tied_count == 1 then return only_id end

    -- Resolve tie. Find first newly-clicked item among tied schemas.
    prev_ids = prev_ids or {}
    for _, item in ipairs(items) do
        local key = item_key(item)
        if not prev_ids[key] then
            -- item_type determines the schema; map.
            local schema = nil
            if item.item_type == "timeline_clip" or item.item_type == "master_clip" then
                schema = "clip"
            elseif item.item_type == "timeline_sequence" or item.item_type == "timeline" then
                schema = "sequence"
            end
            if schema and tied_schemas[schema] then return schema end
        end
    end

    -- Full overlap or no tied schema in new items — fall back to items[1]'s schema.
    for _, item in ipairs(items) do
        local schema = nil
        if item.item_type == "timeline_clip" or item.item_type == "master_clip" then
            schema = "clip"
        elseif item.item_type == "timeline_sequence" or item.item_type == "timeline" then
            schema = "sequence"
        end
        if schema and tied_schemas[schema] then return schema end
    end

    -- Exhaustion (should not happen if tied_schemas is nonempty).
    error("selection_binding.compute_active_schema: could not resolve tie")
end
M._compute_active_schema = compute_active_schema

--- Resolve a list of raw selection items into inspectables, partitioned
--- by schema. Items that can't be resolved are logged and dropped —
--- selection hub passes opaque items, not all are Inspector-relevant.
--  @return { inspectables_by_schema, schema_counts, names_by_schema }
local function resolve_inspectables(items)
    assert(type(items) == "table", "selection_binding.resolve_inspectables: items required")
    local inspectables_by_schema = {}
    local schema_counts = {}
    local names_by_schema = {}

    for _, item in ipairs(items) do
        local inspectable = item.inspectable
        local schema_id
        if inspectable then
            schema_id = inspectable:get_schema_id()
        elseif item.item_type == "timeline_sequence" or item.item_type == "timeline" then
            -- Factory asserts on missing project_id / sequence_id. Let those
            -- surface rather than silently dropping the item: a selection
            -- item that reaches this point without its identifying keys is
            -- an upstream bug, not an ignorable variant.
            inspectable = inspectable_factory.sequence({
                sequence_id = item.sequence_id or item.id,
                project_id  = item.project_id,
                sequence    = item.sequence,
            })
            schema_id = "sequence"
        elseif (item.item_type == "timeline_clip" or item.item_type == "master_clip")
            and item.clip_id and item.clip_id ~= "" then
            inspectable = inspectable_factory.clip({
                clip_id     = item.clip_id,
                project_id  = item.project_id,
                sequence_id = item.sequence_id,
                clip        = item.clip,
            })
            schema_id = "clip"
        end

        if inspectable and schema_id then
            inspectables_by_schema[schema_id] = inspectables_by_schema[schema_id] or {}
            table.insert(inspectables_by_schema[schema_id], inspectable)
            schema_counts[schema_id] = (schema_counts[schema_id] or 0) + 1
            names_by_schema[schema_id] = names_by_schema[schema_id] or {}
            local display = item.display_name
            if not display and inspectable.get_display_name then
                display = inspectable:get_display_name()
            end
            table.insert(names_by_schema[schema_id], display or "")
        end
    end

    return {
        inspectables_by_schema = inspectables_by_schema,
        schema_counts          = schema_counts,
        names_by_schema        = names_by_schema,
    }
end
M._resolve_inspectables = resolve_inspectables

--- For a field, detect whether all N inspectables share the same value.
--  @return first_value, all_same (bool)
local function detect_mixed_values(inspectables, field_key)
    assert(type(inspectables) == "table" and #inspectables > 0,
        "selection_binding.detect_mixed_values: inspectables required and non-empty")
    assert(field_key and field_key ~= "",
        "selection_binding.detect_mixed_values: field_key required")
    local first_value = inspectables[1]:get(field_key)
    for i = 2, #inspectables do
        if inspectables[i]:get(field_key) ~= first_value then
            return first_value, false
        end
    end
    return first_value, true
end
M._detect_mixed_values = detect_mixed_values

-- ----------------------------------------------------------------------
-- Side-effecting pieces (touch ui_state, widgets)
-- ----------------------------------------------------------------------

local function all_support_multi_edit(inspectables)
    for _, i in ipairs(inspectables) do
        if not (i.supports_multi_edit and i:supports_multi_edit()) then
            return false
        end
    end
    return true
end

local function ids_set(items)
    local s = {}
    for _, item in ipairs(items) do s[item_key(item)] = true end
    return s
end

local function format_split_header(schema_counts, active_schema_id)
    local parts = {}
    local schema_order = {"clip", "sequence"}
    for _, id in ipairs(schema_order) do
        local c = schema_counts[id] or 0
        if c > 0 then
            local label = (id == "clip" and (c == 1 and "clip" or "clips"))
                       or (id == "sequence" and (c == 1 and "sequence" or "sequences"))
            table.insert(parts, string.format("%d %s", c, label))
        end
    end
    local summary = table.concat(parts, ", ")
    local editing_count = schema_counts[active_schema_id] or 0
    local editing_label = (active_schema_id == "clip" and (editing_count == 1 and "clip" or "clips"))
                       or (active_schema_id == "sequence" and (editing_count == 1 and "sequence" or "sequences"))
    return string.format("%s — editing %d %s", summary, editing_count, editing_label)
end
M._format_split_header = format_split_header

local function format_single_header(schema_id, display_name)
    if schema_id == "sequence" then
        return string.format("Timeline: %s", display_name or "")
    end
    return string.format("Clip: %s", display_name or "")
end

local function format_multi_header(schema_id, count, read_only)
    local base
    if schema_id == "clip" then
        base = string.format("Clips: %d selected", count)
    else
        base = string.format("Timelines: %d selected", count)
    end
    if read_only then base = base .. " (read-only)" end
    return base
end

local function set_header(ui_state, text)
    if ui_state.header_label then
        qt_constants.PROPERTIES.SET_TEXT(ui_state.header_label, text)
    end
end

local function load_single(schema_view, inspectable)
    for key, entry in pairs(schema_view.field_widgets) do
        local ok, value = pcall(inspectable.get, inspectable, key)
        if not ok then value = nil end
        entry:set_value(value)
    end
end

local function load_multi(schema_view, inspectables)
    for key, entry in pairs(schema_view.field_widgets) do
        local first, all_same = detect_mixed_values(inspectables, key)
        if all_same then
            entry:set_value(first)
        else
            entry:set_mixed(true)
        end
    end
end

local function refresh_only_clean_fields(schema_view, inspectables, size)
    for key, entry in pairs(schema_view.field_widgets) do
        if not entry.dirty then
            if size == 1 then
                local ok, value = pcall(inspectables[1].get, inspectables[1], key)
                if not ok then value = nil end
                entry:set_value(value)
            else
                local first, all_same = detect_mixed_values(inspectables, key)
                if all_same then entry:set_value(first) else entry:set_mixed(true) end
            end
        end
    end
end
M._refresh_only_clean_fields = refresh_only_clean_fields

local function discard_pending(schema_view)
    for _, entry in pairs(schema_view.field_widgets) do
        entry:clear_dirty()
        if entry.error then entry:blur_revert() end
    end
end
M._discard_pending = discard_pending

local function any_dirty_invalid(schema_view)
    for _, entry in pairs(schema_view.field_widgets) do
        if entry.dirty and entry.error then return true end
    end
    return false
end

local function any_dirty(schema_view)
    for _, entry in pairs(schema_view.field_widgets) do
        if entry.dirty then return true end
    end
    return false
end

local function update_apply_button(ui_state)
    -- Bottom bar (Apply + Reset) is visible in multi-edit mode only.
    if ui_state.bottom_bar then
        qt_constants.DISPLAY.SET_VISIBLE(ui_state.bottom_bar,
            ui_state.mode == "multi_edit")
    end
    if ui_state.mode == "multi_edit" and ui_state.active_schema_view then
        local dirty = any_dirty(ui_state.active_schema_view)
        local invalid = any_dirty_invalid(ui_state.active_schema_view)
        if ui_state.apply_button then
            qt_constants.CONTROL.SET_ENABLED(ui_state.apply_button,
                dirty and not invalid)
        end
        -- Reset is enabled whenever ANY dirty field exists (valid or not).
        if ui_state.reset_button then
            qt_constants.CONTROL.SET_ENABLED(ui_state.reset_button, dirty)
        end
    end
end
M._update_apply_button = update_apply_button

--- Discard all pending edits: revert every dirty field to its last-model
--- value. Bound to the Reset button. No DB writes.
function M.reset_pending(ui_state)
    local schema_view = ui_state.active_schema_view
    if not schema_view then return end
    for _, entry in pairs(schema_view.field_widgets) do
        if entry.dirty or entry.error then
            entry:blur_revert()
        end
    end
    -- Clear the error banner state — errors only exist on dirty fields.
    ui_state._field_errors = {}
    if ui_state.error_banner then
        qt_constants.DISPLAY.SET_VISIBLE(ui_state.error_banner, false)
    end
    update_apply_button(ui_state)
end

-- ----------------------------------------------------------------------
-- Public API
-- ----------------------------------------------------------------------

--- Route a selection update into the Inspector.
--  @param items            list of selection items
--  @param source_panel_id  string
--  @param ui_state         Inspector module state (see init.lua)
function M.update_selection(items, source_panel_id, ui_state)
    assert(type(items) == "table", "selection_binding.update_selection: items must be a table")
    assert(ui_state, "selection_binding.update_selection: ui_state required")

    if source_panel_id == "inspector" then return end

    -- Discard any pending un-Applied edits from the previous mode (FR-013a).
    if ui_state.active_schema_view then
        discard_pending(ui_state.active_schema_view)
    end

    local resolved = resolve_inspectables(items)
    local size = 0
    for _, c in pairs(resolved.schema_counts) do size = size + c end

    if size == 0 then
        -- Empty or all-unresolvable selection.
        if ui_state.active_schema_view then
            ui_state.schema.deactivate(ui_state.active_schema_view)
        end
        ui_state.active_schema_view = nil
        ui_state.active_schema_id   = nil
        ui_state.active_inspectables = {}
        ui_state.mode = "empty"
        ui_state.prev_item_ids       = ids_set(items)
        ui_state.prev_schemas_present = {}
        set_header(ui_state, "No editable selection")
        update_apply_button(ui_state)
        return
    end

    local schemas_present = {}
    for id, c in pairs(resolved.schema_counts) do
        if c > 0 then schemas_present[id] = true end
    end

    local active_schema_id = compute_active_schema(
        items,
        resolved.schema_counts,
        ui_state.prev_schemas_present,
        ui_state.active_schema_id,
        ui_state.prev_item_ids
    )

    local active_inspectables = resolved.inspectables_by_schema[active_schema_id] or {}
    local active_names        = resolved.names_by_schema[active_schema_id] or {}
    local supports_multi      = all_support_multi_edit(active_inspectables)

    local summary = {
        size = #active_inspectables,
        schema_counts = { [active_schema_id] = #active_inspectables },
        all_support_multi_edit = supports_multi,
    }
    local mode = compute_mode(summary)
    local is_heterogeneous = false
    for id in pairs(schemas_present) do
        if id ~= active_schema_id then is_heterogeneous = true; break end
    end

    -- Switch active schema view.
    if ui_state.active_schema_view and ui_state.active_schema_id ~= active_schema_id then
        ui_state.schema.deactivate(ui_state.active_schema_view)
    end
    ui_state.active_schema_view  = ui_state.schema_views[active_schema_id]
    ui_state.active_schema_id    = active_schema_id
    ui_state.active_inspectables = active_inspectables
    ui_state.mode                = mode
    ui_state.source_panel_id     = source_panel_id

    ui_state.schema.activate(ui_state.active_schema_view)
    ui_state.schema.apply_filter(ui_state.active_schema_view, ui_state.filter_query or "")

    -- Header.
    local base
    if is_heterogeneous then
        base = format_split_header(resolved.schema_counts, active_schema_id)
    elseif mode == "single" then
        base = format_single_header(active_schema_id, active_names[1])
    elseif mode == "multi_edit" then
        base = format_multi_header(active_schema_id, #active_inspectables, false)
    elseif mode == "multi_read_only" then
        base = format_multi_header(active_schema_id, #active_inspectables, true)
    end
    -- Store the base label (schema-identity only, no mark summary) so
    -- change_listeners can reconstruct the header when marks mutate.
    ui_state.base_header = base
    -- Mark summary (FR-018)
    local header = base
    if source_panel_id == "timeline" or active_schema_id == "sequence" then
        local mark_summary = ui_state.build_mark_summary and ui_state.build_mark_summary()
        if mark_summary and mark_summary ~= "" then
            header = header .. "\n" .. mark_summary
        end
    end
    set_header(ui_state, header)

    -- Load values.
    if mode == "single" or mode == "multi_read_only" then
        load_single(ui_state.active_schema_view, active_inspectables[1])
    elseif mode == "multi_edit" then
        load_multi(ui_state.active_schema_view, active_inspectables)
    end

    update_apply_button(ui_state)

    ui_state.prev_item_ids        = ids_set(items)
    ui_state.prev_schemas_present = schemas_present

    log.event("inspector.update_selection: mode=%s schema=%s size=%d",
        mode, active_schema_id, #active_inspectables)
end

--- Apply all pending dirty fields to the entire active_inspectables set.
--  Called when the Apply button is clicked (multi_edit mode only).
function M.apply_multi_edit(ui_state)
    assert(ui_state.mode == "multi_edit",
        "selection_binding.apply_multi_edit: must be in multi_edit mode")
    local schema_view = ui_state.active_schema_view
    assert(schema_view, "selection_binding.apply_multi_edit: no active schema")
    assert(not any_dirty_invalid(schema_view),
        "selection_binding.apply_multi_edit: refusing — invalid pending field(s)")

    local pending = {}
    for key, entry in pairs(schema_view.field_widgets) do
        -- Skip fields that can't be safely replicated across N items.
        -- E.g. clip.timeline_start: applying same value to two clips on one
        -- track raises VIDEO_OVERLAP (TSO 2026-04-20 15:26:46). Per-clip
        -- positioning belongs in single-edit mode, not multi-edit Apply.
        if entry.dirty and entry.pending_value ~= nil and entry.multi_editable then
            pending[key] = {
                value         = entry.pending_value,
                property_type = entry.property_type,
                default_value = entry.default_value,
            }
        end
    end

    command_manager.begin_command_event("ui")
    for _, inspectable in ipairs(ui_state.active_inspectables) do
        for key, payload in pairs(pending) do
            local ok, err = inspectable:set(key, payload)
            if not ok then
                log.warn("inspector.apply: %s.%s failed: %s",
                    inspectable:get_schema_id(), key, tostring(err))
            end
        end
    end
    command_manager.end_command_event()

    for key, payload in pairs(pending) do
        local entry = schema_view.field_widgets[key]
        if entry then entry:set_value(payload.value) end
    end
    update_apply_button(ui_state)
end

--- Single-field commit, called by field_widget.on_commit for a single-edit
--- selection. Multi-edit holds values until Apply.
function M.commit_single_field(ui_state, entry, value)
    if ui_state.mode ~= "single" then return end
    assert(#ui_state.active_inspectables == 1,
        "selection_binding.commit_single_field: expected one inspectable")
    local inspectable = ui_state.active_inspectables[1]
    local payload = {
        value         = value,
        property_type = entry.property_type,
        default_value = entry.default_value,
    }
    command_manager.begin_command_event("ui")
    local ok, err = inspectable:set(entry.field_key, payload)
    command_manager.end_command_event()
    if ok then
        entry:set_value(value)  -- clears dirty/error/mixed
        -- Successful commit clears any lingering banner state for this field.
        if ui_state.on_error then ui_state.on_error(entry, nil) end
    else
        -- Commit rejected (e.g. Clip.save raised VIDEO_OVERLAP). The typed
        -- value is stale — revert the widget so the user sees the real
        -- DB state, and surface the underlying error in the Inspector's
        -- error banner so they know WHY the edit was rejected.
        log.warn("inspector.commit: %s.%s failed: %s",
            inspectable:get_schema_id(), entry.field_key, tostring(err))
        entry:blur_revert()
        if ui_state.on_error then
            ui_state.on_error(entry, tostring(err))
        end
    end
end

return M
