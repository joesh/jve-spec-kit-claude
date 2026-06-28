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
local ClipLink = require("models.clip_link")
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

local function master_identity(master_id, ctx)
    -- Source-clip identity = the master's import_uuid (the Resolve pool
    -- item DbId adopted at import) or, for native never-imported masters,
    -- the master's own id. This is the value that drives the DRT media-pool
    -- item DbId and the timeline clip's MediaRef — NOT media.id. Post-dedup
    -- (spec 023 source-clip identity move) `media` is one row per FILE, so
    -- two source clips over one .mov share media.id; keying the pool by
    -- media.id would collapse them. Keying by the master's identity keeps
    -- a synced source clip and its plain counterpart as distinct pool items.
    local cached = ctx.identity_by_master[master_id]
    if cached then return cached end
    local master = Sequence.load(master_id)
    assert(master, "payload_builder: clip references missing master "
        .. tostring(master_id))
    assert(master.kind == "master", string.format(
        "payload_builder: clip's nested sequence %s is kind=%q, expected "
        .. "'master' (a timeline clip sent to Resolve must resolve to a "
        .. "source clip)", tostring(master_id), tostring(master.kind)))
    local identity = (type(master.import_uuid) == "string"
                      and master.import_uuid ~= "")
        and master.import_uuid or master.id
    ctx.identity_by_master[master_id] = identity
    return identity
end

local function load_media_cached(media_id, ctx)
    -- One Media.load per physical file, cached for the build. Both the
    -- clip-side source-range conversion and the pool-item emit need the media
    -- (kind + sample rate); loading once keeps them consistent and cheap.
    local cached = ctx.media_by_id[media_id]
    if cached then return cached end
    local m = Media.load(media_id)
    assert(m, "payload_builder: clip references missing media "
        .. tostring(media_id))
    ctx.media_by_id[media_id] = m
    return m
end

local function build_audio_routing(db, loaded, media)
    -- How this audio clip's channel reaches the Resolve timeline (gap #3,
    -- FR-007/008; research D11). Three kinds:
    --   • synced  — the clip's audio is V↔A-linked to a video master (the
    --     channel lives on a virtual track of the linked group). MediaTrackIdx
    --     is the virtual-track slot (2 = first linked track); the linkage
    --     itself is gap #5.
    --   • mono    — the clip reads ONE file channel: either pinned to a master
    --     AUDIO track (master_audio_track_id ≠ NULL — the importer's channel
    --     select) or a single-channel file. MediaTrackIdx = that 0-based channel.
    --   • stereo  — a composite clip reading the whole 2-channel file.
    --     MediaTrackIdx = 0 (the pair starts at channel 0).
    local synced = ClipLink.is_linked(loaded.id, db)
    local source_channel = loaded.resolved_media
        and loaded.resolved_media.source_channel
    assert(type(media.audio_channels) == "number" and media.audio_channels >= 1,
        "payload_builder: audio media missing audio_channels — id="
        .. tostring(media.id))

    -- The payload faithfully DESCRIBES every audio clip's routing, including
    -- synced ones (the producer is not the authoring gate). The writer's
    -- encode_virtual_audio_track_ba is the capability gate: it loud-fails on
    -- kind="synced" until gap #5 decodes the virtual-track slot. Asserting here
    -- instead would break the descriptor's completeness contract (and the
    -- producer-only test) and force gap #5 to re-add the synced descriptor.
    local kind, media_track_idx
    if synced then
        kind, media_track_idx = "synced", 2
    elseif loaded.master_audio_track_id ~= nil then
        -- pinned single channel: source_channel is the file channel it reads
        assert(type(source_channel) == "number", string.format(
            "payload_builder: clip %s is pinned to master_audio_track %s but its "
            .. "resolved ref carries no source_channel", tostring(loaded.id),
            tostring(loaded.master_audio_track_id)))
        kind, media_track_idx = "mono", source_channel
    elseif media.audio_channels == 2 then
        kind, media_track_idx = "stereo", 0
    elseif media.audio_channels == 1 then
        kind, media_track_idx = "mono", 0
    else
        -- A composite clip reading >2 channels would need the multi-channel
        -- "Adaptive" VirtualAudioTrackBA form, which the JVE model cannot
        -- represent (no audio-type concept) — loud-fail rather than silently
        -- mis-route as mono (FR-019; research D11 "9-channel forms OUT OF SCOPE").
        assert(false, string.format(
            "payload_builder: clip %s is an unpinned composite reading %d "
            .. "channels — only mono/stereo composites are emittable (a "
            .. "multichannel selection must pin a master AUDIO track)",
            tostring(loaded.id), media.audio_channels))
    end
    return {
        kind            = kind,
        media_track_idx = media_track_idx,
        source_channel  = source_channel,
    }
end

local function load_clips_for_track(db, track_id, ctx, seq_fps, track_type)
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
        -- Clip.load resolves the media chain (nested master → media_ref →
        -- media) into clip.resolved_media; nil when the clip references a
        -- non-master sequence. media_uuid carries the SOURCE-CLIP identity
        -- (the master's), which is what the DRT MediaRef and pool item key
        -- on; source_media_id is the physical-file row used only to load
        -- the file's metadata (path/rate/duration/TC) for the pool item.
        -- Clip source units are model-native: video-master clips carry frames,
        -- audio-only-master clips (standalone .wav) carry SAMPLES. The Resolve
        -- timeline clip is frame-domain at the conformed sequence fps (D10), so
        -- an audio-only-master clip's range is converted samples → frames here,
        -- at the payload boundary; the fractional remainder preserves sample
        -- accuracy in <In>. The discriminant is the MEDIA kind (width == 0),
        -- NOT the track type — an A/V file cut onto an audio track keeps its
        -- frame-domain source range (it has a video master).
        local source_media_id = loaded.resolved_media
                                and loaded.resolved_media.id
        local source_in, source_out = loaded.source_in, loaded.source_out
        local m
        if source_media_id then
            m = load_media_cached(source_media_id, ctx)
            if not m:is_video() then
                assert(type(seq_fps) == "number" and seq_fps > 0,
                    "payload_builder: seq_fps required to conform audio clip "
                    .. "source range — clip=" .. tostring(loaded.id))
                assert(type(m.audio_sample_rate) == "number"
                    and m.audio_sample_rate > 0,
                    "payload_builder: audio-only media missing audio_sample_rate "
                    .. "— id=" .. tostring(source_media_id))
                source_in  = source_in  * seq_fps / m.audio_sample_rate
                source_out = source_out * seq_fps / m.audio_sample_rate
            end
        end
        -- gap #3: how an audio clip's channel routes to Resolve (mono/stereo/
        -- synced + MediaTrackIdx). Video clips carry no routing.
        local routing = nil
        if track_type == "AUDIO" then
            assert(m, string.format(
                "payload_builder: audio clip %s resolves to no media — cannot "
                .. "derive routing", tostring(loaded.id)))
            routing = build_audio_routing(db, loaded, m)
        end
        rows[#rows + 1] = {
            id              = loaded.id,
            media_uuid      = master_identity(loaded.sequence_id, ctx),
            source_media_id = source_media_id,
            source_in       = source_in,
            source_out      = source_out,
            sequence_start  = loaded.sequence_start,
            duration        = loaded.duration,
            enabled         = loaded.enabled,
            name            = loaded.name,
            routing         = routing,
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

local function media_to_payload(media, track_type, file_uuid, seq_fps)
    -- drt_writer expects a flat media_ref record. We fold in track_type
    -- so the writer can pick video vs audio media-pool item shape. The
    -- pool item's identity (file_uuid) is the SOURCE-CLIP identity passed
    -- by the caller (the master's import_uuid / id), not media.id — two
    -- source clips over one file emit two pool items sharing this media's
    -- file/rate/duration/TC but carrying distinct identities.
    assert(type(file_uuid) == "string" and file_uuid ~= "",
        "payload_builder: media_to_payload requires a source-clip identity "
        .. "(file_uuid) — id=" .. tostring(media.id))
    assert(type(media.name) == "string" and media.name ~= "",
        "payload_builder: media missing name — id=" .. tostring(media.id))
    assert(type(media.duration) == "number" and media.duration > 0,
        "payload_builder: media duration must be positive (video frames / "
        .. "audio samples) — id=" .. tostring(media.id)
        .. " duration=" .. tostring(media.duration))

    -- TC origin, native rate, and duration are kind-dependent. Video media
    -- carry their own frame-domain values: get_start_tc() (frames at the
    -- file's native fps) and duration in native frames. Audio-only media
    -- (width == 0) have NO video TC — their origin lives in
    -- get_audio_start_tc() (samples at the file sample rate), and duration is
    -- in samples. The Resolve timeline clip is FRAME-domain at the conformed
    -- (sequence) fps (research D10), so an audio item is emitted with
    -- native_rate = seq fps and its sample-domain origin/duration converted to
    -- frames. The sample-domain values feed only the Sm2MpAudioClip TracksBA
    -- (gap #2), never the timeline clip's <In>/<MediaFrameRate>.
    local is_video = media:is_video()
    local native_rate, start_tc_frame, duration_frames
    if is_video then
        local tc_origin = media:get_start_tc()
        assert(type(tc_origin) == "number",
            "payload_builder: video media has no TC origin — TC must always be "
            .. "set (rule timecode-is-truth) — id=" .. tostring(media.id))
        native_rate     = media_native_rate(media)
        start_tc_frame  = tc_origin
        duration_frames = media.duration
    else
        assert(type(seq_fps) == "number" and seq_fps > 0,
            "payload_builder: seq_fps required to conform audio-only media to "
            .. "the timeline fps — id=" .. tostring(media.id))
        local samples, tc_rate = media:get_audio_start_tc()
        assert(type(samples) == "number" and type(tc_rate) == "number"
            and tc_rate > 0,
            "payload_builder: media has no TC origin (neither video frames nor "
            .. "audio samples) — TC must always be set (rule timecode-is-truth) "
            .. "— id=" .. tostring(media.id))
        assert(type(media.audio_sample_rate) == "number"
            and media.audio_sample_rate > 0,
            "payload_builder: audio media missing audio_sample_rate — id="
            .. tostring(media.id))
        -- The TC origin (samples) and the clip source range (samples, converted
        -- in load_clips_for_track) are sample-counts of the SAME file, so they
        -- must share one denominator. get_audio_start_tc's rate (probe metadata)
        -- and the audio_sample_rate column are written by independent paths;
        -- assert they agree rather than silently scaling the two ends to
        -- different frame bases (which would skew <In> = source_in − start_tc).
        assert(tc_rate == media.audio_sample_rate, string.format(
            "payload_builder: audio media TC rate (%s) != audio_sample_rate "
            .. "column (%s) — sample counts of one file must share a rate — "
            .. "id=%s", tostring(tc_rate), tostring(media.audio_sample_rate),
            tostring(media.id)))
        native_rate     = seq_fps
        start_tc_frame  = samples * seq_fps / media.audio_sample_rate
        duration_frames = media.duration * seq_fps / media.audio_sample_rate
    end

    -- Media kind drives the media-pool item the writer emits: video media →
    -- Sm2MpVideoClip, audio-only media → Sm2MpAudioClip (gap #2).
    local kind = is_video and "video" or "audio"

    local payload = {
        file_uuid        = file_uuid,
        name             = media.name,
        kind             = kind,
        -- drt_writer's media_ref contract (drt_writer.lua §author doc)
        -- names this field file_path; build_clip_element and the
        -- media-pool item emitters read media.file_path.
        file_path        = media:get_file_path(),
        native_rate      = native_rate,
        duration_frames  = duration_frames,
        start_tc_frame   = start_tc_frame,
        track_type       = track_type,
        -- Source-file mtime (µs) for the Clip blob's date/f13; nil = unknown.
        file_mtime_us    = media.file_mtime_us,
    }

    -- Standalone-audio media-pool item fields (Sm2MpAudioClip TracksBA, gap #2):
    -- the file's native sample-domain shape. nil for video media.
    if kind == "audio" then
        -- audio_sample_rate already asserted in the audio TC branch above
        -- (kind=="audio" iff that branch ran). Channels has no prior assert.
        assert(type(media.audio_channels) == "number" and media.audio_channels > 0,
            "payload_builder: audio media missing audio_channels — id="
            .. tostring(media.id))
        payload.sample_rate      = media.audio_sample_rate
        payload.num_channels     = media.audio_channels
        payload.duration_samples = media.duration   -- audio master duration is samples
    else
        -- Video media-pool item descriptors synthesized from this media
        -- (gap #4, T021, FR-010/011): intrinsic resolution, codec, and the
        -- embedded-audio shape. No borrowing the A005 template — assert each.
        assert(type(media.width) == "number" and media.width > 0
            and type(media.height) == "number" and media.height > 0,
            "payload_builder: video media missing intrinsic width/height — id="
            .. tostring(media.id))
        assert(type(media.codec) == "string" and media.codec ~= "",
            "payload_builder: video media missing codec — id=" .. tostring(media.id))
        payload.width  = media.width
        payload.height = media.height
        payload.codec  = media.codec
        -- Embedded audio reflects reality: a video file with an audio stream
        -- carries it (with an EXACT sample count captured at import), a silent
        -- video carries none. The payload is honest either way; the writer's
        -- A005-class video template is what currently requires embedded audio
        -- (it loud-fails on a silent video — todo_026_pure_video_no_embedded_audio).
        if media.audio_channels and media.audio_channels > 0 then
            assert(type(media.audio_sample_rate) == "number" and media.audio_sample_rate > 0,
                "payload_builder: video media has audio_channels but no "
                .. "audio_sample_rate — id=" .. tostring(media.id))
            assert(type(media.audio_duration_samples) == "number"
                and media.audio_duration_samples > 0,
                "payload_builder: video media has embedded audio but no exact "
                .. "sample count (media.audio_duration_samples) — id="
                .. tostring(media.id))
            payload.embedded_audio = {
                sample_rate      = media.audio_sample_rate,
                num_channels     = media.audio_channels,
                duration_samples = media.audio_duration_samples,
            }
        end
    end

    return payload
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
    -- One pool item per SOURCE CLIP (master identity), deduped across the
    -- whole sequence; ctx caches the per-master identity lookup and loaded
    -- media. seq_fps conforms audio-only media to the timeline (D10).
    local media_seen = {}
    local ctx = { identity_by_master = {}, media_by_id = {} }
    local seq_fps = fps_number(seq)

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
            clips = load_clips_for_track(db, t.id, ctx, seq_fps, t.track_type),
        }
        payload.sequence.tracks[#payload.sequence.tracks+1] = track_payload

        for _, clip_row in ipairs(track_payload.clips) do
            -- media_uuid is the source-clip identity (master's); pool items
            -- dedupe on it so each source clip emits once. source_media_id
            -- is the physical file row whose metadata fills the pool item.
            local identity = clip_row.media_uuid
            -- Rule 2.13: no silent skip of media links. If a clip exists
            -- on a track, it must resolve to a source clip and a file.
            assert(identity and identity ~= "", string.format(
                "payload_builder: clip %s has no source-clip identity",
                tostring(clip_row.id)))
            assert(clip_row.source_media_id and clip_row.source_media_id ~= "",
                string.format("payload_builder: clip %s resolves to no media "
                    .. "file (nested sequence is not a master?)",
                    tostring(clip_row.id)))

            if not media_seen[identity] then
                media_seen[identity] = true
                local m = load_media_cached(clip_row.source_media_id, ctx)
                payload.media_refs[#payload.media_refs+1] =
                    media_to_payload(m, wire_type, identity, seq_fps)
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
