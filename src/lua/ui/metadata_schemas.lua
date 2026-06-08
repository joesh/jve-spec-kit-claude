-- Inspector schema definitions for clip and sequence.
--
-- Exactly two schemas: "clip" and "sequence".
-- Section order is intentional (Resolve-style grouping); do not alphabetize.
-- Every field declared here MUST round-trip through a real consumer. No
-- aspirational fields. See specs/012-rewrite-the-inspector/research.md.
--
-- Contract: specs/012-rewrite-the-inspector/contracts/schema-definition-contract.md.

local metadata_schemas = {}

metadata_schemas.FIELD_TYPES = {
    STRING    = "STRING",
    TEXT_AREA = "TEXT_AREA",
    DROPDOWN  = "DROPDOWN",
    INTEGER   = "INTEGER",
    DOUBLE    = "DOUBLE",
    BOOLEAN   = "BOOLEAN",
    -- TIMECODE: integer frame → HH:MM:SS:FF at the active sequence's
    --   frame rate. The codebase stores all timeline positions (playhead,
    --   marks, clip sequence_start, start_timecode_frame) in absolute
    --   timecode space, so format/parse never adds or subtracts an offset.
    --   Used for: every TC field — durations, sequence start, playhead,
    --   marks, source-side positions.
    TIMECODE  = "TIMECODE",
}

metadata_schemas.PROPERTY_TYPES = {
    STRING   = "STRING",
    NUMBER   = "NUMBER",
    BOOLEAN  = "BOOLEAN",
    ENUM     = "ENUM",
    TIMECODE = "TIMECODE",
}

local FIELD_TO_PROPERTY = {
    STRING    = "STRING",
    TEXT_AREA = "STRING",
    DROPDOWN  = "ENUM",
    INTEGER   = "NUMBER",
    DOUBLE    = "NUMBER",
    BOOLEAN   = "BOOLEAN",
    TIMECODE  = "TIMECODE",
}

function metadata_schemas.get_property_type(field_type)
    assert(field_type ~= nil, "metadata_schemas.get_property_type: field_type is nil")
    local pt = FIELD_TO_PROPERTY[field_type]
    assert(pt, string.format(
        "metadata_schemas.get_property_type: unknown field_type %q", tostring(field_type)))
    return pt
end

local function field(def)
    assert(type(def) == "table",
        "metadata_schemas.field: definition must be a table")
    assert(def.key and def.key ~= "",
        "metadata_schemas.field: key is required and non-empty")
    assert(def.label and def.label ~= "",
        string.format("metadata_schemas.field %q: label is required and non-empty", def.key))
    assert(def.type, string.format(
        "metadata_schemas.field %q: type is required", def.key))
    assert(FIELD_TO_PROPERTY[def.type], string.format(
        "metadata_schemas.field %q: unknown type %q", def.key, tostring(def.type)))
    if def.type == "DROPDOWN" then
        assert(type(def.options) == "table" and #def.options > 0,
            string.format("metadata_schemas.field %q: DROPDOWN requires non-empty options", def.key))
    else
        assert(def.options == nil, string.format(
            "metadata_schemas.field %q: options only allowed on DROPDOWN fields", def.key))
    end
    local read_only = def.read_only
    if read_only == nil then read_only = false end
    assert(type(read_only) == "boolean",
        string.format("metadata_schemas.field %q: read_only must be boolean", def.key))
    -- multi_editable: whether Apply-in-multi-edit-mode may write this field.
    -- Default true. Set false for structural fields where replicating one
    -- value across N inspectables would violate an invariant — e.g., setting
    -- the same sequence_start on two clips on the same track produces
    -- VIDEO_OVERLAP (seen in TSO 2026-04-20 15:26:46).
    local multi_editable = def.multi_editable
    if multi_editable == nil then multi_editable = true end
    assert(type(multi_editable) == "boolean",
        string.format("metadata_schemas.field %q: multi_editable must be boolean", def.key))
    return {
        key            = def.key,
        label          = def.label,
        type           = def.type,
        default        = def.default,
        options        = def.options,
        read_only      = read_only,
        multi_editable = multi_editable,
    }
end

local T = metadata_schemas.FIELD_TYPES

-- Clip schema — Resolve-style grouping. Order matters.
local clip_sections = {
    {
        name = "File",
        schema = { fields = {
            field { key = "name",        label = "Clip Name",   type = T.STRING  },
            field { key = "media_id",    label = "Media ID",    type = T.STRING,   read_only = true },
            field { key = "offline",     label = "Offline",     type = T.BOOLEAN,  read_only = true },
            field { key = "rate_display",label = "Frame Rate",  type = T.STRING,   read_only = true },
        }},
    },
    {
        name = "Source Range",
        schema = { fields = {
            -- sequence_start / duration / source_in / source_out are per-clip
            -- structural values. Applying the same value to N clips on the
            -- same track violates non-overlap (VIDEO_OVERLAP in the clips
            -- UNIQUE/CHECK invariant). multi_editable = false: user can still
            -- edit per-clip in single-edit mode, but multi-edit Apply skips
            -- these fields entirely.
            -- NLE terminology: "Record In/Out" = position on the timeline
            -- where the clip is laid down. "Source In/Out" = portion of the
            -- source media used.
            field { key = "sequence_start",  label = "Record In",   type = T.TIMECODE, multi_editable = false },
            field { key = "duration",        label = "Duration",    type = T.TIMECODE, multi_editable = false },
            field { key = "source_in",       label = "Source In",   type = T.TIMECODE, multi_editable = false },
            field { key = "source_out",      label = "Source Out",  type = T.TIMECODE, multi_editable = false },
            field { key = "mark_in",         label = "Mark In",        type = T.TIMECODE },
            field { key = "mark_out",        label = "Mark Out",       type = T.TIMECODE },
            field { key = "playhead_frame",  label = "Source Playhead",type = T.TIMECODE, read_only = true },
        }},
    },
    {
        name = "Enable",
        schema = { fields = {
            field { key = "enabled", label = "Enabled", type = T.BOOLEAN },
        }},
    },
    {
        name = "Audio",
        schema = { fields = {
            field { key = "volume",  label = "Volume", type = T.DOUBLE },
        }},
    },
    {
        name = "Color",
        schema = { fields = {
            -- fidelity: spec 023 §5.5 — badge for non-primary clips.
            -- source: provenance (e.g. 'resolve_readback').
            -- synced_at: timestamp of last sync.
            field { key = "fidelity",  label = "Grade Fidelity", type = T.STRING,   read_only = true },
            field { key = "source",    label = "Source",         type = T.STRING,   read_only = true },
            field { key = "synced_at",  label = "Last Synced",    type = T.INTEGER,  read_only = true },
        }},
    },
}

-- Sequence schema — viewport fields intentionally excluded per /analyze I1.
-- Sequence field keys MUST match actual column names in the `sequences` table
-- (schema.sql). SetSequenceMetadata's whitelist and the SQL column name are
-- the same string. SequenceInspectable:get translates to the model's
-- (sometimes renamed) field names internally.
local sequence_sections = {
    {
        name = "Project",
        schema = { fields = {
            field { key = "name",                 label = "Timeline Name",     type = T.STRING   },
            field { key = "frame_rate_display",   label = "Frame Rate",        type = T.STRING,   read_only = true },
            field { key = "width",                label = "Width",             type = T.INTEGER,  read_only = true },
            field { key = "height",               label = "Height",            type = T.INTEGER,  read_only = true },
            field { key = "audio_sample_rate",           label = "Audio Sample Rate", type = T.INTEGER,  read_only = true },
            field { key = "start_timecode_frame", label = "Start Timecode",    type = T.TIMECODE },
        }},
    },
    {
        name = "Viewport",
        schema = { fields = {
            field { key = "playhead_frame", label = "Playhead", type = T.TIMECODE },
        }},
    },
    {
        name = "Marks",
        schema = { fields = {
            field { key = "mark_in_frame",  label = "Mark In",  type = T.TIMECODE },
            field { key = "mark_out_frame", label = "Mark Out", type = T.TIMECODE },
        }},
    },
}

local SCHEMA_TABLE = {
    clip     = clip_sections,
    sequence = sequence_sections,
}

function metadata_schemas.get_sections(schema_id)
    assert(schema_id ~= nil, "metadata_schemas.get_sections: schema_id is nil")
    local sections = SCHEMA_TABLE[schema_id]
    assert(sections, string.format(
        "metadata_schemas.get_sections: unknown schema_id %q", tostring(schema_id)))
    return sections
end

function metadata_schemas.get_field(schema_id, field_key)
    assert(schema_id ~= nil, "metadata_schemas.get_field: schema_id is nil")
    assert(field_key ~= nil and field_key ~= "",
        "metadata_schemas.get_field: field_key is nil or empty")
    local sections = metadata_schemas.get_sections(schema_id)
    for _, section in ipairs(sections) do
        for _, f in ipairs(section.schema.fields) do
            if f.key == field_key then
                return f
            end
        end
    end
    return nil
end

function metadata_schemas.iter_fields_for_schema(schema_id)
    local sections = metadata_schemas.get_sections(schema_id)
    local flat = {}
    for _, section in ipairs(sections) do
        for _, f in ipairs(section.schema.fields) do
            table.insert(flat, f)
        end
    end
    local i = 0
    return function()
        i = i + 1
        return flat[i]
    end
end

return metadata_schemas
