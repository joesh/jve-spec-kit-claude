--- Resolve bridge payload builder — sequence → drt_writer payload shape
--- (spec 023, supports T024 SendToResolve).
---
--- Pulls a single sequence (+ tracks + clips + referenced media) from the
--- project DB and reshapes them into the schema drt_writer.author expects:
---
---   {
---     project   = { name, fps },
---     media_refs = { {file_uuid, name, file_path, native_rate,
---                     duration_frames, start_tc_frame, track_type}, ... },
---     sequence  = { name, fps,
---                   tracks = { { type, clips = { {...}, ... } }, ... } }
---   }
---
--- Boundary discipline:
---   • Single sequence only (drt_writer is single-sequence by design,
---     FR-002 + T008).
---   • Reads only the project DB — never probes media (rule
---     feedback_importers_no_media_probe; symmetric for exporters).
---   • TC stays in the existing dual-frame convention (source_in_frame is
---     absolute TC; media start_tc_frame is the file's tc origin) — no
---     unit conversion happens here.

local Sequence = require("models.sequence")
local Track    = require("models.track")
local Media    = require("models.media")
local Project  = require("models.project")
local Clip     = require("models.clip")
local database = require("core.database")

local M = {}

local function fps_number(seq)
    -- drt_writer accepts a fps number; sequences store num/den. We keep
    -- it exact for integer rates and division for fractional. Callers
    -- needing exact rationals work directly with seq.frame_rate.
    -- Sequence.load returns the rate nested under seq.frame_rate (see
    -- models/sequence.lua); flat seq.fps_* fields don't exist on the
    -- loaded object (rule 2.13 — no hidden shape assumptions).
    assert(type(seq.frame_rate) == "table"
            and seq.frame_rate.fps_numerator
            and seq.frame_rate.fps_denominator,
        "payload_builder: sequence missing frame_rate.fps_numerator/"
        .. "fps_denominator")
    return seq.frame_rate.fps_numerator / seq.frame_rate.fps_denominator
end

local function load_clips_for_track(db, track_id)
    -- V13: clips don't carry media_id as a column; the media link is
    -- via the source sequence's media_refs (`models/clip.lua::load`
    -- does the JOIN). Pre-V13 code reading `clips.media_id` would
    -- prepare-fail at runtime (column absent) — this loader uses
    -- Clip.load per id so the media linkage matches the V13 path.
    --
    -- Uses database.select_rows so the prepare-bind-exec-iter pattern
    -- is structurally enforced (the pre-2026-06-03 hand-rolled version
    -- skipped exec() and silently iterated 0 rows).
    local ids = database.select_rows(db,
        "SELECT id FROM clips WHERE track_id = ? "
        .. "ORDER BY sequence_start_frame",
        { track_id }, function(stmt) return stmt:value(0) end)
    local rows = {}
    for _, id in ipairs(ids) do
        local loaded = Clip.load(id)
        assert(loaded,
            "payload_builder: clip vanished between id-list and load: "
            .. tostring(id))
        rows[#rows + 1] = {
            id              = loaded.id,
            -- Clip.load resolves the media chain (nested master →
            -- media_ref → media) into clip.resolved_media; nil when the
            -- clip references a non-master sequence. The caller asserts
            -- a media link exists before authoring a DRT.
            media_uuid      = loaded.resolved_media
                                and loaded.resolved_media.id,
            source_in       = loaded.source_in,
            source_out      = loaded.source_out,
            sequence_start  = loaded.sequence_start,
            duration        = loaded.duration,
            enabled         = loaded.enabled,
            name            = loaded.name,
        }
    end
    return rows
end

local function media_native_rate(media)
    -- Media stores rate as {fps_numerator, fps_denominator}; drt_writer
    -- consumes a single number. Fail-fast on missing rate — every media
    -- row must carry one (rule 1.14 / 2.13).
    assert(type(media.frame_rate) == "table"
        and type(media.frame_rate.fps_numerator) == "number"
        and type(media.frame_rate.fps_denominator) == "number"
        and media.frame_rate.fps_denominator ~= 0,
        "payload_builder: media missing frame_rate {fps_numerator, "
        .. "fps_denominator} — id=" .. tostring(media.id))
    return media.frame_rate.fps_numerator
        / media.frame_rate.fps_denominator
end

local function media_to_payload(media, track_type)
    -- drt_writer expects a flat media_ref record. We fold in track_type
    -- so the writer can pick video vs audio media-pool item shape.
    -- Media.load exposes duration as `duration` (native frames) and the
    -- TC origin via `get_start_tc()` (frames at native rate, from
    -- metadata) — there are no flat duration_frames/start_tc_frame
    -- fields on the loaded object.
    assert(type(media.name) == "string" and media.name ~= "",
        "payload_builder: media missing name — id=" .. tostring(media.id))
    assert(type(media.duration) == "number" and media.duration > 0,
        "payload_builder: media duration must be positive native frames — "
        .. "id=" .. tostring(media.id)
        .. " duration=" .. tostring(media.duration))
    local tc_origin = media:get_start_tc()
    assert(type(tc_origin) == "number",
        "payload_builder: media has no TC origin — TC must always be set "
        .. "(rule timecode-is-truth) — id=" .. tostring(media.id))
    return {
        file_uuid        = media.id,
        name             = media.name,
        -- drt_writer's media_ref contract (drt_writer.lua §author doc)
        -- names this field file_path; build_clip_element and the
        -- media-pool item emitters read media.file_path.
        file_path        = media:get_file_path(),
        native_rate      = media_native_rate(media),
        duration_frames  = media.duration,
        start_tc_frame   = tc_origin,
        track_type       = track_type,
    }
end

--- Build the drt_writer payload for one sequence.
--- @param db lsqlite3 connection
--- @param project_id string
--- @param sequence_id string
--- @return table payload — ready to pass to drt_writer.author
function M.build(db, project_id, sequence_id)
    assert(type(db) == "table" or type(db) == "userdata",
        "payload_builder.build: db connection required")
    assert(type(project_id) == "string" and project_id ~= "",
        "payload_builder.build: project_id required")
    assert(type(sequence_id) == "string" and sequence_id ~= "",
        "payload_builder.build: sequence_id required")

    local seq = Sequence.load(sequence_id)
    assert(seq, "payload_builder.build: sequence not found: " .. sequence_id)

    local project = Project.load(project_id, db)
    assert(project, "payload_builder.build: project not found: " .. project_id)
    assert(type(project.name) == "string" and project.name ~= "",
        "payload_builder.build: project missing name — id=" .. project_id)

    local payload = {
        project = {
            name = project.name,
            fps  = fps_number(seq),
        },
        media_refs = {},
        sequence = {
            name   = seq.name,
            fps    = fps_number(seq),
            -- drt_writer's media-pool folder XML requires the timeline
            -- resolution. Schema permits NULL width/height only on
            -- masters without video; an editing sequence being sent to
            -- Resolve must carry both.
            width  = assert(seq.width,
                "payload_builder: sequence missing width — id="
                .. tostring(sequence_id)),
            height = assert(seq.height,
                "payload_builder: sequence missing height — id="
                .. tostring(sequence_id)),
            tracks = {},
        },
    }
    local media_seen = {}

    -- schema CHECK(track_type IN ('VIDEO','AUDIO')) so query is uppercase;
    -- drt_writer's wire contract uses lowercase 'video'/'audio', so we
    -- normalise on emit.
    local video_tracks = Track.find_by_sequence(sequence_id, "VIDEO")
    local audio_tracks = Track.find_by_sequence(sequence_id, "AUDIO")
    assert(type(video_tracks) == "table",
        "payload_builder: Track.find_by_sequence(VIDEO) returned non-table "
        .. "for sequence " .. tostring(sequence_id))
    assert(type(audio_tracks) == "table",
        "payload_builder: Track.find_by_sequence(AUDIO) returned non-table "
        .. "for sequence " .. tostring(sequence_id))
    local all_tracks = {}
    for _, t in ipairs(video_tracks) do all_tracks[#all_tracks+1] = t end
    for _, t in ipairs(audio_tracks) do all_tracks[#all_tracks+1] = t end

    for _, t in ipairs(all_tracks) do
        assert(t.track_type == "VIDEO" or t.track_type == "AUDIO",
            string.format("payload_builder: unexpected track_type %q on "
                .. "track %s (schema CHECK should make this impossible)",
                tostring(t.track_type), tostring(t.id)))
        local wire_type = (t.track_type == "VIDEO") and "video" or "audio"
        local track_payload = {
            type  = wire_type,
            clips = load_clips_for_track(db, t.id),
        }
        payload.sequence.tracks[#payload.sequence.tracks+1] = track_payload

        for _, clip_row in ipairs(track_payload.clips) do
            local media_uuid = clip_row.media_uuid
            -- Rule 2.13: no silent skip of media links. If a clip exists
            -- on a track, it must point to valid media.
            assert(media_uuid and media_uuid ~= "", string.format(
                "payload_builder: clip %s has no media link",
                tostring(clip_row.id)))

            if not media_seen[media_uuid] then
                media_seen[media_uuid] = true
                local m = Media.load(media_uuid)
                assert(m, string.format(
                    "payload_builder: clip %s references missing "
                    .. "media %s", tostring(clip_row.id),
                    tostring(media_uuid)))
                payload.media_refs[#payload.media_refs+1] =
                    media_to_payload(m, wire_type)
            end
        end
    end

    assert(#payload.sequence.tracks > 0,
        "payload_builder: sequence has no tracks — nothing to send")
    assert(#payload.media_refs > 0,
        "payload_builder: sequence has no media — nothing to send")
    return payload
end

return M
