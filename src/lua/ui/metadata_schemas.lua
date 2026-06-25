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
    -- TIMESTAMP: unix epoch seconds → "YYYY-MM-DD HH:MM:SS UTC".
    --   Display-only (read_only must be true); parse rejects all input.
    --   UTC is fixed: no localization layer in the codebase, and stable
    --   across machines for tests. Used for: synced_at on ClipGrade.
    TIMESTAMP = "TIMESTAMP",
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
    TIMESTAMP = "STRING",
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

-- Shared field declarations. Schemas that include the same field MUST
-- reference the same Lua table here so a label/type change updates every
-- schema in lockstep. Tested by test_inspector_schema_contract.lua: the
-- field reuse invariant asserts table identity across schemas.
local FIELDS = {
    -- File section
    name         = field { key = "name",         label = "Clip Name",      type = T.STRING  },
    media_id     = field { key = "media_id",     label = "Media ID",       type = T.STRING,   read_only = true },
    offline      = field { key = "offline",      label = "Offline",        type = T.BOOLEAN,  read_only = true },
    rate_display = field { key = "rate_display", label = "Frame Rate",     type = T.STRING,   read_only = true },

    -- Source Range section — see clip schema comment for multi_editable
    -- rationale (non-overlap invariant on the per-clip structural values).
    -- NLE terminology: "Record In/Out" = position on the timeline where
    -- the clip is laid down. "Source In/Out" = portion of source media used.
    sequence_start = field { key = "sequence_start", label = "Record In",      type = T.TIMECODE, multi_editable = false },
    duration       = field { key = "duration",       label = "Duration",       type = T.TIMECODE, multi_editable = false },
    source_in      = field { key = "source_in",      label = "Source In",      type = T.TIMECODE, multi_editable = false },
    source_out     = field { key = "source_out",     label = "Source Out",     type = T.TIMECODE, multi_editable = false },
    mark_in        = field { key = "mark_in",        label = "Mark In",        type = T.TIMECODE },
    mark_out       = field { key = "mark_out",       label = "Mark Out",       type = T.TIMECODE },
    playhead_frame = field { key = "playhead_frame", label = "Source Playhead",type = T.TIMECODE, read_only = true },

    -- Enable / Audio (clip-only — per-instance concerns)
    enabled = field { key = "enabled", label = "Enabled", type = T.BOOLEAN },
    volume  = field { key = "volume",  label = "Volume",  type = T.DOUBLE  },

    -- Color (clip-only — per-instance grade; spec 023)
    -- fidelity: spec 023 §5.5 — badge for non-primary clips.
    -- reproduction: spec 023 FR-015 — what JVE can display
    --   (full | approximate | not_shown). Find-able badge axis.
    -- source: provenance (e.g. 'resolve_readback').
    -- synced_at: timestamp of last sync.
    fidelity     = field { key = "fidelity",     label = "Grade Fidelity", type = T.STRING,   read_only = true },
    reproduction = field { key = "reproduction", label = "Grade Shown",    type = T.STRING,   read_only = true },
    source       = field { key = "source",       label = "Source",         type = T.STRING,   read_only = true },
    synced_at    = field { key = "synced_at",    label = "Last Synced",    type = T.TIMESTAMP, read_only = true },
}

-- Clip schema — Resolve-style grouping. Order matters.
local clip_sections = {
    { name = "File",         schema = { fields = { FIELDS.name, FIELDS.media_id, FIELDS.offline, FIELDS.rate_display } } },
    { name = "Source Range", schema = { fields = { FIELDS.sequence_start, FIELDS.duration, FIELDS.source_in, FIELDS.source_out, FIELDS.mark_in, FIELDS.mark_out, FIELDS.playhead_frame } } },
    { name = "Enable",       schema = { fields = { FIELDS.enabled } } },
    { name = "Audio",        schema = { fields = { FIELDS.volume } } },
    { name = "Color",        schema = { fields = { FIELDS.fidelity, FIELDS.reproduction, FIELDS.source, FIELDS.synced_at } } },
}

-- Master-clip schema — kind='master' sequences presented as Clips (the
-- canonical media asset). Same row as the sequence model but a different
-- lens (browser + source-viewer context). Reuses File section verbatim and
-- a trimmed Source Range (omits sequence_start / duration — record-side
-- concepts). Enable / Audio / Color are per-timeline-instance and excluded.
--
-- Channels: kind='channel_list' is a non-flat section — repeating rows
-- driven by MasterClipInspectable:iter_channels (one row per master AUDIO
-- track, ordered by tracks.track_index ASC). Phase 2 is read-only display
-- (track name + 1-based channel index). RenameTrack-from-inspector lands
-- in Phase 3. The flat-fields renderer skips this kind; a dedicated
-- channel_list_renderer mounts the rows on selection change.
local master_clip_sections = {
    { name = "File",         schema = { fields = { FIELDS.name, FIELDS.media_id, FIELDS.offline, FIELDS.rate_display } } },
    { name = "Source Range", schema = { fields = { FIELDS.source_in, FIELDS.source_out, FIELDS.mark_in, FIELDS.mark_out, FIELDS.playhead_frame } } },
    { name = "Channels",     kind = "channel_list" },
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
    clip        = clip_sections,
    sequence    = sequence_sections,
    master_clip = master_clip_sections,
}

function metadata_schemas.get_sections(schema_id)
    assert(schema_id ~= nil, "metadata_schemas.get_sections: schema_id is nil")
    local sections = SCHEMA_TABLE[schema_id]
    assert(sections, string.format(
        "metadata_schemas.get_sections: unknown schema_id %q", tostring(schema_id)))
    return sections
end

-- Both flat-field walkers skip non-flat sections (kind ~= 'flat_fields').
-- channel_list and any future non-flat kind have no `schema.fields`;
-- indexing it crashes. Mirrors the dispatch in ui.inspector.schema.build.
local function section_is_flat(section)
    return (section.kind or "flat_fields") == "flat_fields"
end

function metadata_schemas.get_field(schema_id, field_key)
    assert(schema_id ~= nil, "metadata_schemas.get_field: schema_id is nil")
    assert(field_key ~= nil and field_key ~= "",
        "metadata_schemas.get_field: field_key is nil or empty")
    local sections = metadata_schemas.get_sections(schema_id)
    for _, section in ipairs(sections) do
        if section_is_flat(section) then
            for _, f in ipairs(section.schema.fields) do
                if f.key == field_key then
                    return f
                end
            end
        end
    end
    return nil
end

function metadata_schemas.iter_fields_for_schema(schema_id)
    local sections = metadata_schemas.get_sections(schema_id)
    local flat = {}
    for _, section in ipairs(sections) do
        if section_is_flat(section) then
            for _, f in ipairs(section.schema.fields) do
                table.insert(flat, f)
            end
        end
    end
    local i = 0
    return function()
        i = i + 1
        return flat[i]
    end
end

return metadata_schemas
