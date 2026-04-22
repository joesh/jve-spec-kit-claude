--- ClipInspectable: Inspector-facing adapter for a single clip.
---
--- Three data sources, consulted in this order on get():
---   1. metadata_overrides — values written during the current edit
---      session; not yet flushed to the model/DB but authoritative to
---      the Inspector until Apply commits.
---   2. clip_ref — the live clip object from timeline_state (columns:
---      name, enabled, timeline_start, duration, source_in, source_out,
---      marks, rate, …). Preferred for clip-row fields so the Inspector
---      stays in sync with timeline edits without a DB roundtrip.
---   3. properties — rows from the `properties` table loaded via
---      database.load_clip_properties(). Lazy and cached per instance.
---
--- Writes flow through SetClipProperty (always scoped to the clip's
--- owning sequence for per-sequence undo). TIMECODE payloads are
--- integer-frames only; rate is single-sourced on the owning entity and
--- must not be duplicated into the payload.
---
--- @file clip.lua
local database = require("core.database")
local Command = require("command")
local command_manager = require("core.command_manager")
local metadata_schemas = require("ui.metadata_schemas")

local ClipInspectable = {}
ClipInspectable.__index = ClipInspectable

-- Lazy loader for the clip's user-metadata properties. Called only when
-- a field is NOT present on clip_ref, so the DB roundtrip only happens
-- for genuine custom-metadata reads (unusual in the schema-driven
-- Inspector — every declared schema field is a clip-row column).
local function load_clip_properties(clip_id)
    return database.load_clip_properties(clip_id)
end

function ClipInspectable.new(opts)
    if not opts or not opts.clip_id then
        error("ClipInspectable.new requires clip_id")
    end

    local self = setmetatable({}, ClipInspectable)
    self.clip_id = opts.clip_id
    if not opts.project_id or opts.project_id == "" then
        error("ClipInspectable.new requires project_id")
    end
    self.project_id = opts.project_id
    self.sequence_id = opts.sequence_id
    self.clip_ref = opts.clip -- optional table representing live clip state
    self.metadata_overrides = opts.metadata or {}
    self._property_cache = nil
    return self
end

function ClipInspectable:get_schema_id()
    return "clip"
end

function ClipInspectable:refresh()
    self._property_cache = nil
end

function ClipInspectable:get_display_name()
    if self.clip_ref then
        return self.clip_ref.label or self.clip_ref.name or self.clip_ref.id or self.clip_id
    end
    local props = self:_ensure_properties()
    return props.name or self.clip_id
end

function ClipInspectable:_ensure_properties()
    if not self._property_cache then
        self._property_cache = load_clip_properties(self.clip_id)
    end
    return self._property_cache
end

local function format_rate_display(rate)
    if type(rate) ~= "table" then return nil end
    local num, den = rate.fps_numerator, rate.fps_denominator
    if type(num) ~= "number" or type(den) ~= "number" or den == 0 then
        return nil
    end
    if num % den == 0 then
        return string.format("%d fps", math.floor(num / den + 0.5))
    end
    return string.format("%.3f fps", num / den)
end

function ClipInspectable:get(field)
    if not field or field == "" then
        return nil
    end

    -- Synthetic display field (no backing column).
    if field == "rate_display" then
        local clip_table = self.clip_ref
        if clip_table and clip_table.rate then
            return format_rate_display(clip_table.rate)
        end
    end

    -- Edit-session overrides win.
    if self.metadata_overrides[field] ~= nil then
        return self.metadata_overrides[field]
    end

    -- When clip_ref is provided, treat it as authoritative for every
    -- schema field — an explicit nil on clip_ref means "the column has
    -- no value right now" (e.g. mark_in unset), not "fall back to DB".
    -- This keeps the Inspector off the DB hot path; custom user-metadata
    -- fields (not in any current schema) are the only case that needs
    -- _ensure_properties, and they're accessed only when no clip_ref
    -- was supplied (rare).
    if self.clip_ref then
        return self.clip_ref[field]
    end

    return self:_ensure_properties()[field]
end

function ClipInspectable:set(field, value)
    if not field or field == "" then
        return false, "Field is required"
    end

    assert(type(value) == "table", string.format(
        "ClipInspectable:set(%s): expected payload table {value, property_type[, default_value]}, got %s",
        field, type(value)))
    local payload_value = value.value
    local property_type = value.property_type
    local default_value = value.default_value

    assert(property_type and property_type ~= "", string.format(
        "ClipInspectable:set(%s): payload.property_type is required", field))

    -- TIMECODE branch (012 Inspector rewrite, Q3 resolution): integer frames only;
    -- rate lives on the owning entity and is NEVER carried in the payload.
    if property_type == "TIMECODE" then
        assert(type(payload_value) == "number",
            string.format("ClipInspectable:set(%s): TIMECODE value must be a number, got %s",
                field, type(payload_value)))
        assert(payload_value == math.floor(payload_value),
            string.format("ClipInspectable:set(%s): TIMECODE value must be integer frames, got %s",
                field, tostring(payload_value)))
        assert(payload_value >= 0,
            string.format("ClipInspectable:set(%s): TIMECODE value must be non-negative, got %d",
                field, payload_value))
    end

    local current = self:get(field)
    if current == payload_value then
        return true
    end

    assert(self.sequence_id and self.sequence_id ~= "",
        "ClipInspectable:set requires self.sequence_id (per 006-per-sequence-undo " ..
        "FR-001: SetClipProperty must be scoped to the sequence the clip lives in, " ..
        "otherwise it lands on the global stack and leaks into other tabs' undo views)")
    local cmd = Command.create("SetClipProperty", self.project_id)
    cmd:set_parameters({
        ["clip_id"] = self.clip_id,
        -- Route this command onto its owning sequence's undo stack.
        -- See set_clip_property.lua SPEC.args for rationale.
        ["sequence_id"] = self.sequence_id,
        ["property_name"] = field,
        ["value"] = payload_value,
        ["property_type"] = property_type,
    })
    if default_value ~= nil then
        cmd:set_parameter("default_value", default_value)
    end
    -- No __skip_timeline_reload: SetClipProperty emits __timeline_mutations
    -- (see core/commands/set_clip_property.lua) so apply_command_mutations
    -- patches the timeline's clip cache with a precise delta — no full
    -- reload. Skipping the UI refresh branch left the cache stale and was
    -- the root cause of "edit clip name → label stays on timeline".
    -- __skip_timeline_cache was a dead flag (never read, rule 2.17).
    -- cmd.stack_id was explicitly "global" — stale and wrong per the
    -- per-sequence undo design. Stack routing derives from SPEC.args
    -- (command_manager.lua:1400), not from caller hints.
    cmd:set_parameter("__skip_selection_snapshot", true)
    cmd.skip_selection_snapshot = true

    local result = command_manager.execute_interactive(cmd)
    if not result.success then
        return false, result.error_message or "unknown error"
    end

    if self.clip_ref then
        self.clip_ref[field] = payload_value
    end
    if self._property_cache then
        self._property_cache[field] = payload_value
    end
    self.metadata_overrides[field] = payload_value
    return true
end

function ClipInspectable:iter_fields()
    return metadata_schemas.iter_fields_for_schema(self:get_schema_id())
end

function ClipInspectable:supports_multi_edit()
    return true
end

return ClipInspectable
