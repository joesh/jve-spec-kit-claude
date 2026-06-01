--- Resolve bridge payload builder — sequence → drt_writer payload shape
--- (spec 023, supports T024 SendToResolve).
---
--- Pulls a single sequence (+ tracks + clips + referenced media) from the
--- project DB and reshapes them into the schema drt_writer.author expects:
---
---   {
---     project   = { name, fps },
---     media_refs = { {file_uuid, name, path, native_rate, duration_frames,
---                     start_tc_frame, track_type}, ... },
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

local M = {}

local function fps_number(seq)
    -- drt_writer accepts a fps number; sequences store num/den. We keep
    -- it exact for integer rates and division for fractional. Callers
    -- needing exact rationals work directly with seq.frame_rate.
    assert(seq.fps_numerator and seq.fps_denominator,
        "payload_builder: sequence missing fps_numerator/denominator")
    return seq.fps_numerator / seq.fps_denominator
end

local function load_clips_for_track(db, track_id)
    local stmt = assert(db:prepare([[
        SELECT id, media_id, source_in_frame, source_out_frame,
               sequence_start_frame, duration_frames, enabled, name
        FROM clips
        WHERE track_id = ?
        ORDER BY sequence_start_frame
    ]]), "payload_builder: prepare clips query failed")
    stmt:bind_value(1, track_id)
    local rows = {}
    while stmt:next() do
        rows[#rows+1] = {
            id            = stmt:value(0),
            media_id      = stmt:value(1),
            source_in     = stmt:value(2),
            source_out    = stmt:value(3),
            sequence_start = stmt:value(4),
            duration      = stmt:value(5),
            enabled       = stmt:value(6) == 1,
            name          = stmt:value(7),
        }
    end
    stmt:finalize()
    return rows
end

local function media_to_payload(media, track_type)
    -- drt_writer expects a flat media_ref record. We fold in track_type
    -- so the writer can pick video vs audio media-pool item shape.
    return {
        file_uuid        = media.id,
        name             = media.name or media:get_file_path(),
        path             = media:get_file_path(),
        native_rate      = media.frame_rate or media.fps,
        duration_frames  = media.duration_frames,
        start_tc_frame   = assert(media.start_tc_frame,
            "payload_builder: media missing start_tc_frame — "
            .. "TC must always be set (rule timecode-is-truth)"),
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

    local payload = {
        project = {
            name = seq.name,  -- Project file may not be loaded here; use sequence name as the project name surface. SendToResolve overrides if a project name is known.
            fps  = fps_number(seq),
        },
        media_refs = {},
        sequence = {
            name = seq.name,
            fps  = fps_number(seq),
            tracks = {},
        },
    }
    local media_seen = {}

    local video_tracks = Track.find_by_sequence(sequence_id, "video")
    local audio_tracks = Track.find_by_sequence(sequence_id, "audio")
    local all_tracks = {}
    for _, t in ipairs(video_tracks or {}) do all_tracks[#all_tracks+1] = t end
    for _, t in ipairs(audio_tracks or {}) do all_tracks[#all_tracks+1] = t end

    for _, t in ipairs(all_tracks) do
        local track_payload = {
            type  = t.track_type,
            clips = load_clips_for_track(db, t.id),
        }
        payload.sequence.tracks[#payload.sequence.tracks+1] = track_payload

        for _, c in ipairs(track_payload.clips) do
            if c.media_id and not media_seen[c.media_id] then
                media_seen[c.media_id] = true
                local m = Media.load(c.media_id)
                assert(m, string.format(
                    "payload_builder: clip %s references missing media %s",
                    tostring(c.id), tostring(c.media_id)))
                payload.media_refs[#payload.media_refs+1] =
                    media_to_payload(m, t.track_type)
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
