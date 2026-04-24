-- T027 / CT-R10 (013): export parity.
-- Calling Sequence:resolve_in_range twice with identical args except
-- context.export_mode flipped must yield byte-identical output for the same
-- DB state. FR-019: export-only policies apply ABOVE the resolver, never inside.
-- Expected to FAIL until T030 lands.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_resolve_export_parity.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_rate, width, height, created_at, modified_at) "
    .. "VALUES ('m', 'p1', 'm', 'master', 24, 1, 48000, 1920, 1080, 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_rate, width, height, created_at, modified_at) "
    .. "VALUES ('e', 'p1', 'e', 'nested', 24, 1, 48000, 1920, 1080, 0, 0)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('e-v1', 'e', 'V1', 'VIDEO', 1)"))
assert(db:exec(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, created_at, modified_at) "
    .. "VALUES ('med', 'p1', 'x', '/tmp/vid.mov', 100, 24, 1, 0, 0)"))
assert(db:exec(
    "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
    .. "source_in_frame, source_out_frame, timeline_start_frame, duration_frames, "
    .. "enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mr', 'p1', 'm', 'm-v1', 'med', 0, 100, 0, 100, 1, 1.0, 0, 0, 0)"))
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, nested_sequence_id, "
    .. "name, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, "
    .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('c', 'p1', 'e', 'e-v1', 'm', 'c', 0, 100, 0, 100, 'passthrough', 1, 1.0, 0, 0, 0)"))

local Sequence = require("models.sequence")
local function entry_shape_signature(entries)
    -- A shape signature that differs iff any ResolvedEntry field differs.
    local parts = {}
    for i, e in ipairs(entries) do
        parts[i] = string.format(
            "%s|%s|%d|%d|%d|%d|%s|%s",
            tostring(e.media_path), tostring(e.media_kind),
            e.source_in or -1, e.source_out or -1,
            e.timeline_start or -1, e.duration or -1,
            tostring(e.enabled), table.concat(e.provenance or {}, ","))
    end
    return table.concat(parts, "\n")
end

local preview = Sequence:resolve_in_range("e", 0, 200, {
    recursing_into = {},
    depth = 0,
    export_mode = false,
    project_fps_mismatch_policy = "passthrough",
})
local exported = Sequence:resolve_in_range("e", 0, 200, {
    recursing_into = {},
    depth = 0,
    export_mode = true,
    project_fps_mismatch_policy = "passthrough",
})

assert(entry_shape_signature(preview) == entry_shape_signature(exported),
    "FR-019: preview and export resolver output must be identical")

print("✅ test_resolve_export_parity.lua passed")
