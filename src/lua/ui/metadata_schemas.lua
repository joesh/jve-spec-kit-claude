-- User-Configurable Metadata Schemas for FCP7 Clone Inspector
-- This file defines all metadata schemas that appear in the Inspector panel
-- Users can modify this file to add custom fields, change field types, or create new schemas
-- Like Emacs: Everything is customizable and extensible!

local metadata_schemas = {}

-- Define field types available to users
metadata_schemas.FIELD_TYPES = {
    STRING = "string",
    INTEGER = "integer", 
    DOUBLE = "double",
    BOOLEAN = "boolean",
    TIMECODE = "timecode",
    DROPDOWN = "dropdown",
    TEXT_AREA = "text_area"
}

-- Helper function to create fields
local function create_field(key, label, field_type, default_value, options)
    local default_val
    if default_value ~= nil then
        default_val = default_value
    else
        default_val = ""
    end
    
    
    return {
        key = key,
        label = label,
        type = field_type or metadata_schemas.FIELD_TYPES.STRING,
        default = default_val,
        options = options -- For dropdown fields
    }
end

-- Inspector-relevant schemas (matching C++ Inspector categories)
metadata_schemas.clip_inspector_schemas = {
    
    ["Search"] = {
        description = "Search and filter clips",
        fields = {
            create_field("search_query", "Search", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("search_type", "Search In", metadata_schemas.FIELD_TYPES.DROPDOWN, "All Fields", 
                        {"All Fields", "Name", "Description", "Keywords", "Scene", "Take"})
        }
    },

    ["Camera"] = {
        description = "Camera and lens technical information",
        fields = {
            create_field("camera:make", "Camera Make", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("camera:model", "Camera Model", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("camera:serial", "Serial Number", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("lens:make", "Lens Make", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("lens:model", "Lens Model", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("lens:focal_length", "Focal Length", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("camera:iso", "ISO", metadata_schemas.FIELD_TYPES.INTEGER, 100),
            create_field("camera:fps", "Frame Rate", metadata_schemas.FIELD_TYPES.STRING, "24.0")
        }
    },

    ["Production"] = {
        description = "Production workflow and organization", 
        fields = {
            create_field("production:scene", "Scene", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("production:take", "Take", metadata_schemas.FIELD_TYPES.INTEGER, 1),
            create_field("production:shot", "Shot", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("production:director", "Director", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("production:dp", "DP", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("production:location", "Location", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("production:date", "Shoot Date", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("production:notes", "Notes", metadata_schemas.FIELD_TYPES.TEXT_AREA, "")
        }
    },

    ["Transform Properties"] = {
        description = "Video transform and positioning controls",
        fields = {
            create_field("transform:position_x", "Position X", metadata_schemas.FIELD_TYPES.DOUBLE, 0.0),
            create_field("transform:position_y", "Position Y", metadata_schemas.FIELD_TYPES.DOUBLE, 0.0),
            create_field("transform:scale_x", "Scale X", metadata_schemas.FIELD_TYPES.DOUBLE, 100.0),
            create_field("transform:scale_y", "Scale Y", metadata_schemas.FIELD_TYPES.DOUBLE, 100.0),
            create_field("transform:rotation", "Rotation", metadata_schemas.FIELD_TYPES.DOUBLE, 0.0),
            create_field("transform:anchor_x", "Anchor X", metadata_schemas.FIELD_TYPES.DOUBLE, 0.0),
            create_field("transform:anchor_y", "Anchor Y", metadata_schemas.FIELD_TYPES.DOUBLE, 0.0),
            create_field("transform:opacity", "Opacity", metadata_schemas.FIELD_TYPES.DOUBLE, 100.0)
        }
    },

    ["Review"] = {
        description = "Review and approval workflow tracking",
        fields = {
            create_field("review:status", "Status", metadata_schemas.FIELD_TYPES.DROPDOWN, "Pending", 
                        {"Pending", "In Review", "Approved", "Rejected", "Needs Changes"}),
            create_field("review:reviewer", "Reviewer", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("review:date", "Review Date", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("review:notes", "Review Notes", metadata_schemas.FIELD_TYPES.TEXT_AREA, ""),
            create_field("review:priority", "Priority", metadata_schemas.FIELD_TYPES.DROPDOWN, "Normal",
                        {"Low", "Normal", "High", "Urgent"}),
            create_field("review:version", "Version", metadata_schemas.FIELD_TYPES.STRING, "")
        }
    },

    ["Cropping Properties"] = {
        description = "Video cropping and framing controls", 
        fields = {
            create_field("crop:left", "Crop Left", metadata_schemas.FIELD_TYPES.DOUBLE, 0.0),
            create_field("crop:right", "Crop Right", metadata_schemas.FIELD_TYPES.DOUBLE, 0.0),
            create_field("crop:top", "Crop Top", metadata_schemas.FIELD_TYPES.DOUBLE, 0.0),
            create_field("crop:bottom", "Crop Bottom", metadata_schemas.FIELD_TYPES.DOUBLE, 0.0),
            create_field("crop:feather", "Feather", metadata_schemas.FIELD_TYPES.DOUBLE, 0.0)
        }
    },

    ["Composite Properties"] = {
        description = "Video composite and blending controls",
        fields = {
            create_field("composite:blend_mode", "Blend Mode", metadata_schemas.FIELD_TYPES.DROPDOWN, "Normal",
                        {"Normal", "Multiply", "Screen", "Overlay", "Soft Light", "Hard Light", "Add", "Subtract"}),
            create_field("composite:opacity", "Opacity", metadata_schemas.FIELD_TYPES.DOUBLE, 100.0),
            create_field("composite:drop_shadow", "Drop Shadow", metadata_schemas.FIELD_TYPES.BOOLEAN, false),
            create_field("composite:motion_blur", "Motion Blur", metadata_schemas.FIELD_TYPES.BOOLEAN, false)
        }
    },

    ["Premiere Project"] = {
        description = "Adobe Premiere Pro internal clip metadata",
        fields = {
            create_field("premiere:project_name", "Project Name", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("premiere:sequence_name", "Sequence", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("premiere:bin_path", "Bin Path", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("premiere:proxy_attached", "Proxy Attached", metadata_schemas.FIELD_TYPES.BOOLEAN, false),
            create_field("premiere:offline", "Offline", metadata_schemas.FIELD_TYPES.BOOLEAN, false)
        }
    },

    ["Audio"] = {
        description = "Audio technical specifications and metadata",
        fields = {
            create_field("audio:format", "Audio Format", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("audio:sample_rate", "Sample Rate", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("audio:bit_depth", "Bit Depth", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("audio:channels", "Channels", metadata_schemas.FIELD_TYPES.INTEGER, 2),
            create_field("audio:codec", "Codec", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("audio:bitrate", "Bitrate", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("audio:duration", "Duration", metadata_schemas.FIELD_TYPES.STRING, "00:00:00:00")
        }
    },

    ["IPTC Core"] = {
        description = "Press and journalism metadata standards",
        fields = {
            create_field("iptc:headline", "Headline", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("iptc:description", "Description", metadata_schemas.FIELD_TYPES.TEXT_AREA, ""),
            create_field("iptc:keywords", "Keywords", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("iptc:creator", "Creator", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("iptc:copyright", "Copyright", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("iptc:source", "Source", metadata_schemas.FIELD_TYPES.STRING, "")
        }
    },

    ["Dublin Core"] = {
        description = "Standard metadata elements for digital resources",
        fields = {
            create_field("dc:title", "Title", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("dc:creator", "Creator", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("dc:subject", "Subject", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("dc:description", "Description", metadata_schemas.FIELD_TYPES.TEXT_AREA, ""),
            create_field("dc:publisher", "Publisher", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("dc:date", "Date", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("dc:type", "Type", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("dc:format", "Format", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("dc:identifier", "Identifier", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("dc:language", "Language", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("dc:rights", "Rights", metadata_schemas.FIELD_TYPES.STRING, "")
        }
    },

    ["Dynamic Media"] = {
        description = "Video production and workflow metadata",
        fields = {
            create_field("dynamic:timecode_in", "Timecode In", metadata_schemas.FIELD_TYPES.STRING, "00:00:00:00"),
            create_field("dynamic:timecode_out", "Timecode Out", metadata_schemas.FIELD_TYPES.STRING, "00:00:00:00"),
            create_field("dynamic:good_take", "Good Take", metadata_schemas.FIELD_TYPES.BOOLEAN, false),
            create_field("dynamic:circle_take", "Circle Take", metadata_schemas.FIELD_TYPES.BOOLEAN, false),
            create_field("dynamic:sync_offset", "Sync Offset", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("dynamic:color_space", "Color Space", metadata_schemas.FIELD_TYPES.STRING, "")
        }
    },

    ["EXIF"] = {
        description = "Camera technical metadata from image files",
        fields = {
            create_field("exif:make", "Camera Make", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("exif:model", "Camera Model", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("exif:datetime", "Date/Time", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("exif:exposure_time", "Exposure Time", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("exif:f_number", "F-Number", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("exif:iso", "ISO Speed", metadata_schemas.FIELD_TYPES.INTEGER, 100),
            create_field("exif:focal_length", "Focal Length", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("exif:flash", "Flash", metadata_schemas.FIELD_TYPES.STRING, ""),
            create_field("exif:white_balance", "White Balance", metadata_schemas.FIELD_TYPES.STRING, "")
        }
    }
}

-- EMACS-STYLE EXTENSIBILITY: Users can add custom schemas by modifying this file
-- Example custom schema:
--[[
metadata_schemas.clip_inspector_schemas["Custom VFX"] = {
    description = "Custom VFX pipeline metadata",
    fields = {
        create_field("vfx:shot_id", "VFX Shot ID", metadata_schemas.FIELD_TYPES.STRING, ""),
        create_field("vfx:complexity", "Complexity", metadata_schemas.FIELD_TYPES.DROPDOWN, "Simple", 
                    {"Simple", "Medium", "Complex", "Hero"}),
        create_field("vfx:artist", "VFX Artist", metadata_schemas.FIELD_TYPES.STRING, ""),
        create_field("vfx:render_time", "Render Time", metadata_schemas.FIELD_TYPES.STRING, ""),
        create_field("vfx:notes", "VFX Notes", metadata_schemas.FIELD_TYPES.TEXT_AREA)
    }
}
--]]

-- Function to get all inspector schemas
function metadata_schemas.get_clip_inspector_schemas()
    return metadata_schemas.clip_inspector_schemas
end

-- Function to add custom schema (for user extensibility)
function metadata_schemas.add_custom_schema(name, schema)
    metadata_schemas.clip_inspector_schemas[name] = schema
end

-- Function to add custom field to existing schema
function metadata_schemas.add_custom_field(schema_name, field)
    if metadata_schemas.clip_inspector_schemas[schema_name] then
        table.insert(metadata_schemas.clip_inspector_schemas[schema_name].fields, field)
        return true
    end
    return false
end

return metadata_schemas