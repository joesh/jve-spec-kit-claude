local database = require("core.database")
local Command = require("command")
local command_manager = require("core.command_manager")
local metadata_schemas = require("ui.metadata_schemas")

local ClipInspectable = {}
ClipInspectable.__index = ClipInspectable

local function load_clip_properties(clip_id)
    local ok, props = pcall(database.load_clip_properties, clip_id)
    if ok and type(props) == "table" then
        return props
    end
    return {}
end

function ClipInspectable.new(opts)
    if not opts or not opts.clip_id then
        error("ClipInspectable.new requires clip_id")
    end

    local self = setmetatable({}, ClipInspectable)
    self.clip_id = opts.clip_id
    self.project_id = opts.project_id or "default_project"
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

local function coalesce(...)
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if value ~= nil then
            return value
        end
    end
    return nil
end

function ClipInspectable:get(field)
    if not field or field == "" then
        return nil
    end

    local properties = self:_ensure_properties()

    if self.metadata_overrides[field] ~= nil then
        return self.metadata_overrides[field]
    end

    local clip_table = self.clip_ref
    local clip_value = clip_table and clip_table[field] or nil

    local property_value = properties[field]
    return coalesce(clip_value, property_value)
end

function ClipInspectable:set(field, value)
    if not field or field == "" then
        return false, "Field is required"
    end

    local property_type = nil
    local default_value = nil
    local payload_value = value

    if type(value) == "table" then
        payload_value = value.value
        property_type = value.property_type or value.field_type
        default_value = value.default_value
    end

    if property_type == nil or property_type == "" then
        return false, "property_type is required"
    end

    local current = self:get(field)
    if current == payload_value then
        return true
    end

    local cmd = Command.create("SetClipProperty", self.project_id)
    cmd:set_parameter("clip_id", self.clip_id)
    cmd:set_parameter("property_name", field)
    cmd:set_parameter("value", payload_value)
    cmd:set_parameter("property_type", property_type)
    if default_value ~= nil then
        cmd:set_parameter("default_value", default_value)
    end

    local result = command_manager.execute(cmd)
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
