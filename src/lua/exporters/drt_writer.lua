--- DRT writer — author a Resolve-canonical .drt archive from a JVE payload.
---
--- Format: .drt = ZIP of
---   project.xml                            project envelope + TimelineHandleVec
---   MediaPool/Master/MpFolder.xml          per-timeline wrapper + media-pool items
---   SeqContainer/<seq_container_dbid>.xml  one per sequence (tracks + clips)
---   Gallery.xml                            color-still gallery (carried verbatim)
---
--- Resolve-acceptance shape (vs JVE-importer-only):
--- The earlier minimal writer emitted `<Project>` / `<Sm2SequenceContainer>` with
--- tracks-as-direct-children and no media-pool envelope. JVE's own importer was
--- tolerant; Resolve refused with "Failed to import project" because the schema
--- it validates is far richer (SM_Project root with ~30 wrapper children,
--- Sm2MpTimelineClip/Sm2Timeline/Sm2Sequence wrapping each timeline, version
--- comment header, separate VideoTrackVec / AudioTrackVec). T008 spike + the
--- 2026-05-31 kitchen-sink dissection (specs/023-resolve-color-bridge/
--- phase0-findings.md §§A–J) mapped the required schema.
---
--- This writer takes the canonical-rewrite path (Strategy 1, Joe's choice):
---   • Load Resolve-authored verbatim XML templates from drt_canonical/
---   • Mint fresh UUIDs for every per-export entity (no two JVE exports
---     collide when imported to the same Resolve instance)
---   • Substitute UUIDs + names + FrameRate + Resolution in the templates
---   • Build the SeqContainer XML fresh (tracks + clips) per the dissected schema
---   • Stage + zip
---
--- Borrowed verbatim from the empty-reference DRP (and explicitly NOT
--- regenerated from JVE state in this pass):
---   • SM_Project root FieldsBlob (project-wide settings: render text flags,
---     gallery ref, fusion sizing version, etc.)
---   • SM_Config FieldsBlob (large color-engine setup blob)
---   • Sm2Sequence FieldsBlob (color setup per-sequence; also large)
---   • LmVersionTable + LmVersion FieldsBlob/Body (the "Version 1" default
---     grade ladder for the sequence-level version)
---   • Gallery.xml in its entirety
---   • PTZRPreset / Sm2MediaPool / Sm2GroupList / Sm2LockableBlobMap / LmPowerNodeList
---     wrappers
--- These deferred encodings are tracked in
--- `~/.claude/projects/.../memory/todo_drt_writer_resolve_canonical_shape.md`.
--- For the first round of timeline content this is enough; if Resolve flags
--- a specific borrowed FieldsBlob during import we'll regenerate that one.
---
--- Round-trip contract (per FR-011b, feedback_timecode_is_truth):
---   • Per-clip identity (clip.id)      → Sm2Ti{Video,Audio}Clip.DbId attr
---   • Per-clip media identity          → <MediaRef> text == clip.media_uuid
---   • Source-in is ABSOLUTE TC; writer subtracts media.start_tc_frame to
---     produce file-relative <In> the importer adds back to recompute absolute.
---
--- Importer prohibition: this writer NEVER probes media. Every value comes
--- from the payload (feedback_importers_no_media_probe — symmetric outbound).

local M = {}

local enc = require("exporters.drt_binary")

-- ─── Canonical-template loading ─────────────────────────────────────────────
--
-- The four reference XMLs are committed at src/lua/exporters/drt_canonical/
-- as Resolve-authored byte-identical templates. Loaded once per author() call
-- (cheap — total <30 KB).

local function script_dir()
    local info = debug.getinfo(1, "S")
    local src = info.source
    assert(src:sub(1, 1) == "@",
        "drt_writer: cannot resolve script directory (source not a path)")
    local path = src:sub(2)
    return (path:gsub("/[^/]+$", ""))
end

local function read_file(path)
    local h = assert(io.open(path, "rb"),
        "drt_writer: cannot open canonical template " .. path)
    local body = h:read("*a")
    h:close()
    return body
end

local function load_template(name)
    return read_file(script_dir() .. "/drt_canonical/" .. name)
end

-- Reference DbIds as they appear in the verbatim templates. We replace each
-- one with a freshly-minted UUID per export so two JVE-authored DRTs imported
-- into the same Resolve instance do not collide (Resolve treats matching
-- SM_Project DbId as "same project — replace?").
local REFERENCE_DBIDS = {
    sm_project           = "1b5606b3-a688-4e51-8e0b-5419c3920167",
    sm_config            = "3f8d11fa-9f8e-4b9a-abe0-e3da14b14c37",
    sm_multi_sys         = "365cdf7d-752f-4e04-a717-2104a8d7cfe2",
    sm_media_pool        = "5c050c82-bcf9-498e-9d66-780afde902cc",
    sm_group_list        = "07d5f5bb-1a7b-4f5a-afce-74c0fe4694b3",
    lockable_blob_map    = "85470bbb-51f6-4fd4-9a66-51320ee4f681",
    media_pool_lockable  = "80cc20f6-6d21-42df-86e4-8a4d63094d16",
    power_node_list      = "207dfe44-2b14-4752-ab99-6345b1631585",
    -- Per-timeline UUIDs (in the empty reference, single timeline)
    mp_folder            = "6cf9979b-3e45-4c7c-874f-4162010c5f8e",
    mp_folder_unique_id  = "ac079579-635c-4165-a592-f12984bc1cfb",
    mp_timeline_clip     = "9d3a9478-efa8-43f7-b419-6c64b4c0b733",
    mp_timeline_unique   = "4fa3ff10-7d93-49db-8f23-b6cdcaaecc01",
    timeline             = "dffcf5b8-3bdb-499a-b375-8fdf94f5e5c4",
    sequence             = "1e46c9dd-80b8-4977-aaec-35f0498cd16b",
    unique_sequence_id   = "d108fed5-430a-4f5f-8433-0f4b63144e30",
    seq_container        = "09a19a21-d424-41ef-945f-d598b9d4a4ac",
    plm_ver_table        = "6b42ab53-487b-4e39-8236-03df47a32e93",
    lm_version           = "3c943505-3438-4067-808b-31b5f9702a4d",
    ptzr_preset_outer    = "9329dc34-fb30-433f-9218-f3eb22a880d6",
    ptzr_preset_timeline = "b4da443a-0706-457f-b7e1-03e570fef353",
    -- Gallery is referenced from SM_Project FieldsBlob; keeping verbatim by
    -- leaving Gallery.xml intact (no minted alternative).
}

-- Hard-coded text values in templates that must be replaced with payload
-- content. The empty reference was authored as project "JVE_T008_reference"
-- with sequence "JVE_T008_ref_seq".
local REFERENCE_PROJECT_NAME  = "JVE_T008_reference"
local REFERENCE_SEQUENCE_NAME = "JVE_T008_ref_seq"
local REFERENCE_PROJECT_CFG   = "JVE_T008_reference.Cfg"

-- ─── UUID minting ───────────────────────────────────────────────────────────
--
-- Deterministic, counter-based (workflow/resume safety — no Date.now /
-- Math.random). Caller seeds the writer's counter at the start of author();
-- each mint advances it by one.

local function fresh_uuid(seed_byte)
    M._uuid_counter = (M._uuid_counter or 0) + 1
    local k = M._uuid_counter
    -- Embed (counter, seed_byte) directly into the UUID so two calls with
    -- different seeds OR different counters can never collide. (The earlier
    -- mod-16 nibble formula collided when counter differences happened to be
    -- multiples of 16 — caught by manual archive inspection.)
    -- Format: 8-4-4-4-12; version=4, variant in {8,9,a,b}.
    return string.format(
        "%08x-%04x-4%03x-%s%03x-%012x",
        k % 0x100000000,
        math.floor(k / 0x10000) % 0x10000,
        seed_byte % 0x1000,
        ({"8","9","a","b"})[(seed_byte % 4) + 1],
        (seed_byte * 17 + k * 23) % 0x1000,
        (k * 0x9E3779B1 + seed_byte * 0x85EBCA6B) % 0x1000000000000)
end

-- ─── XML helpers ────────────────────────────────────────────────────────────

local function xml_text(s)
    s = tostring(s or "")
    s = s:gsub("&", "&amp;")
    s = s:gsub("<", "&lt;")
    s = s:gsub(">", "&gt;")
    return s
end
local function xml_attr(s)
    return (xml_text(s):gsub('"', "&quot;"))
end

local function open_tag(name, attrs)
    if not attrs or not next(attrs) then return "<" .. name .. ">" end
    local parts = {"<", name}
    for k, v in pairs(attrs) do
        parts[#parts + 1] = string.format(' %s="%s"', k, xml_attr(v))
    end
    parts[#parts + 1] = ">"
    return table.concat(parts)
end

local function elem(name, body, attrs)
    return open_tag(name, attrs) .. tostring(body) .. "</" .. name .. ">"
end

local function text_elem(name, text, attrs)
    return elem(name, xml_text(text), attrs)
end

local function self_close(name, attrs)
    if not attrs or not next(attrs) then return "<" .. name .. "/>" end
    local parts = {"<", name}
    for k, v in pairs(attrs) do
        parts[#parts + 1] = string.format(' %s="%s"', k, xml_attr(v))
    end
    parts[#parts + 1] = "/>"
    return table.concat(parts)
end

-- Global plaintext replacement (used for swapping out reference UUIDs and
-- reference name strings within the loaded templates). All caller-provided
-- replacement strings are treated as literal text (no `%` pattern surprises).
-- Returns (result, replacement_count).
local function plain_gsub(haystack, needle, replacement)
    local repl_safe = replacement:gsub("%%", "%%%%")
    local needle_pat = needle:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0")
    return haystack:gsub(needle_pat, repl_safe)
end

-- Required substitution: fail-fast if the template doesn't contain the needle
-- (catches template drift on payload-driven fields like ProjectName whose
-- absence would silently leak the reference content into the export).
local function plain_gsub_required(haystack, needle, replacement)
    local result, n = plain_gsub(haystack, needle, replacement)
    assert(n > 0, "drt_writer: required substitution target '" .. needle ..
        "' not found in template (template drift? regenerate canonical files)")
    return result
end

-- ─── Per-clip XML emission ──────────────────────────────────────────────────
--
-- One Sm2TiVideoClip / Sm2TiAudioClip element per timeline placement. Child
-- order MUST match Resolve's schema (validated at import) — see
-- phase0-findings.md §B for the full list.
--
-- Source-in encoding (FR-011b + feedback_timecode_is_truth):
--   in_offset = clip.source_in - media.start_tc_frame   -- file-relative
--   <In> = <in_offset> when integer, or "<frames>|<hex_LE_double_subframe>"
--   when sub-frame. JVE payloads carry integer frames; the sub-frame form
--   is only emitted if a non-integer source_in is passed (defensive).

local function build_in_element(in_offset)
    if in_offset == 0 then
        return self_close("In")
    end
    local frames = math.floor(in_offset)
    local subframe = in_offset - frames
    if subframe == 0 then
        return text_elem("In", tostring(frames))
    end
    return text_elem("In", string.format("%d|%s",
        frames, enc.encode_le_double(subframe)))
end

-- VirtualAudioTrackBA: per-audio-clip routing blob. Per phase0-findings §F,
-- audio clips encode their source-channel routing via MediaTrackIdx + a
-- VirtualAudioTrackBA blob. For Phase 1 we emit the kitchen-sink-observed
-- "single mono channel routed to Audio N" form. Synced-audio (idx=2) is not
-- yet payload-driven (deferred — todo_drt_writer_resolve_canonical_shape).
local function build_virtual_audio_track_ba(audio_type)
    -- Observed shape in kitchen-sink: count=1 outer + 2 inner TLV fields
    -- (ChannelsBA payload + AudioType int=1). Bake the observed bytes
    -- verbatim — exact format-level encoding can be migrated to drt_binary
    -- later if we need to vary it.
    if audio_type == 2 then
        -- A3-style: stereo file embedded ch 1; subtype 2 in ChannelsBA
        return "000000010000000200000014004300680061006e006e0065006c0073004200" ..
               "410000000c000000000c000000020000000100004002000000120041007500" ..
               "640069006f0054007900700065000000020000000001"
    end
    -- A1-style: mono embedded ch 1; subtype 1 in ChannelsBA
    return "000000010000000200000014004300680061006e006e0065006c0073004200" ..
           "410000000c000000000c000000020000000100004001000000120041007500" ..
           "640069006f0054007900700065000000020000000001"
end

-- MediaTimemapBA — un-retimed default. Format from kitchen-sink dissection:
--   leading 0x02 0x40 + 8-byte BE double = duration-extent in seconds.
-- For a clip with no retime, this is just the clip's source duration in
-- seconds, encoded BE. Resolve sets this per-source-clip; for our purposes
-- emitting the source duration suffices.
local function build_media_timemap_ba(source_duration_seconds)
    assert(type(source_duration_seconds) == "number"
        and source_duration_seconds > 0,
        "drt_writer.build_media_timemap_ba: positive number required")
    -- 8-byte BE double: pack manually since drt_binary's
    -- encode_le_double is LE. We reverse the LE bytes.
    local le_hex = enc.encode_le_double(source_duration_seconds)
    assert(#le_hex == 16,
        "drt_writer: LE double encoding must be 16 hex chars, got " .. #le_hex)
    -- Reverse byte order: hex pairs swapped from end to start.
    local be_hex = {}
    for i = 15, 1, -2 do
        be_hex[#be_hex + 1] = le_hex:sub(i, i + 1)
    end
    return "0240" .. table.concat(be_hex)
end

-- PreConformMediaExtents — observed value carried verbatim across every clip
-- in the kitchen-sink reference. 16-byte blob; format-level decode deferred.
local PRECONFORM_MEDIA_EXTENTS = "00000100000030c20000010000003042"

local function build_clip_element(clip, media, native_rate, track_type)
    assert(type(clip.id) == "string" and clip.id ~= "",
        "drt_writer.build_clip_element: clip.id required")
    assert(type(clip.name) == "string" and clip.name ~= "",
        "drt_writer.build_clip_element: clip.name required "
        .. "(display name on <Name>; emitter does not derive)")
    assert(type(clip.media_uuid) == "string" and clip.media_uuid ~= "",
        "drt_writer.build_clip_element: clip.media_uuid required")
    assert(type(clip.sequence_start) == "number" and clip.sequence_start >= 0,
        "drt_writer.build_clip_element: clip.sequence_start non-negative required")
    assert(type(clip.duration) == "number" and clip.duration > 0,
        "drt_writer.build_clip_element: clip.duration positive required")
    assert(type(clip.source_in) == "number" and clip.source_in >= 0,
        "drt_writer.build_clip_element: clip.source_in non-negative (absolute TC)")
    assert(type(media) == "table",
        "drt_writer.build_clip_element: media table required for clip "
        .. clip.id .. " (media_uuid=" .. clip.media_uuid .. ")")
    assert(type(media.start_tc_frame) == "number"
        and media.start_tc_frame >= 0,
        "drt_writer.build_clip_element: media.start_tc_frame required")
    assert(type(media.file_path) == "string" and media.file_path ~= "",
        "drt_writer.build_clip_element: media.file_path required")
    assert(type(media.duration_frames) == "number"
        and media.duration_frames > 0,
        "drt_writer.build_clip_element: media.duration_frames required "
        .. "(for MediaTimemapBA encoding)")

    local in_offset = clip.source_in - media.start_tc_frame
    assert(in_offset >= 0, string.format(
        "drt_writer.build_clip_element: clip %s source_in (%d) < media "
        .. "start_tc_frame (%d) — source_in below file TC origin invalid",
        clip.id, clip.source_in, media.start_tc_frame))

    local media_start_seconds = media.start_tc_frame / native_rate
    local source_dur_seconds  = media.duration_frames / native_rate
    local tag = (track_type == "audio") and "Sm2TiAudioClip" or "Sm2TiVideoClip"
    local is_video = (track_type ~= "audio")

    -- Child order pinned to Resolve's schema. Empty self-closing elements
    -- are still present (Resolve's parser checks for them).
    local parts = {
        self_close("FieldsBlob"),
        self_close("PrettyType"),
        text_elem("Name", clip.name),
        text_elem("Start", math.floor(clip.sequence_start)),
        text_elem("Duration", math.floor(clip.duration)),
        self_close("LinkedItemSync"),
        text_elem("WasDisbanded", "false"),
        self_close("MarkersBA"),
        text_elem("UiMemento", "0"),
        text_elem("Flags", "0"),
        text_elem("PriorityIndex", "0"),
        self_close("EffectFiltersBA"),
        self_close("ImportExportMetadataBA"),
        text_elem("RenderTextEnabled",  is_video and "true"  or "false"),
        text_elem("RenderTextGanged",   is_video and "true"  or "false"),
        text_elem("RenderTextPrefixed", is_video and "true"  or "false"),
        build_in_element(in_offset),
        text_elem("MixedFrameRateAlignment", "0"),
        text_elem("MediaRef",       clip.media_uuid),
        text_elem("MediaStartTime", string.format("%.9f", media_start_seconds)),
        text_elem("MediaFilePath",  media.file_path),
        self_close("MediaReelNumber"),
        text_elem("MediaFrameRate", enc.encode_le_double(native_rate)
                                    .. "0000000000000000"),
        text_elem("MediaTimemapBA", build_media_timemap_ba(source_dur_seconds)),
        text_elem("LastChangedTime", "0"),
        text_elem("LastRenderedTime", "0"),
        text_elem("IsMarkedForCaching", "false"),
        text_elem("IsForceConformed",   "true"),
        text_elem("MatchConflictState", "0"),
        text_elem("UseOppositeSrcForLeftEye",  "false"),
        text_elem("UseOppositeSrcForRightEye", "false"),
        self_close("RenderCacheBA"),
    }
    if is_video then
        parts[#parts + 1] = text_elem("CurrentSelectorIdx", "0")
        parts[#parts + 1] = text_elem("IsPreConformed", "false")
        parts[#parts + 1] = text_elem("PreConformMediaExtents",
            PRECONFORM_MEDIA_EXTENTS)
        parts[#parts + 1] = self_close("MediaMetadata")
        local thumb_dbid = fresh_uuid(0x90)
        parts[#parts + 1] = elem("Thumbnail",
            elem("BtThumnail", table.concat({
                self_close("FieldsBlob"),
                text_elem("ImgWidth",  "-1"),
                text_elem("ImgHeight", "-1"),
                self_close("Buffer"),
            }), {DbId = thumb_dbid}))
        parts[#parts + 1] = text_elem("ThumbnailDirtyFlag", "true")
    else
        parts[#parts + 1] = text_elem("VirtualAudioTrackBA",
            build_virtual_audio_track_ba(1))
        parts[#parts + 1] = text_elem("MediaTrackIdx", "0")
    end

    return elem(tag, table.concat(parts), {DbId = clip.id})
end

-- ─── Per-track XML emission ─────────────────────────────────────────────────
--
-- One Sm2TiTrack per track of either type. Clips are nested inside
-- <Items><Element>...</Element></Items> per the find_track_clips contract
-- (drp_importer.lua:193 — see prior writer's note on this trap).

local TRACK_FIELDS_BLOB_NUM_LAYERS =
    "000000010000000100000012004e0075006d004c00610079006500720073000000020000000000"

local function build_track_element(track, seq_dbid, media_by_uuid, native_rate)
    assert(type(track.clips) == "table",
        "drt_writer.build_track_element: track.clips array required")
    local track_kind = (track.type == "audio") and "audio" or "video"
    local type_value = (track_kind == "audio") and 1 or 0
    local track_dbid = fresh_uuid(0x70)

    local items = {}
    for _, c in ipairs(track.clips) do
        local media = media_by_uuid[c.media_uuid]
        assert(media, "drt_writer.build_track_element: track clip references "
            .. "unknown media_uuid " .. tostring(c.media_uuid))
        items[#items + 1] = elem("Element",
            build_clip_element(c, media, native_rate, track_kind))
    end

    return elem("Element", elem("Sm2TiTrack", table.concat({
        text_elem("FieldsBlob", TRACK_FIELDS_BLOB_NUM_LAYERS),
        text_elem("Type", tostring(type_value)),
        text_elem("SubType", "0"),
        text_elem("Flags", "0"),
        text_elem("Sequence", seq_dbid),
        elem("Items", table.concat(items)),
        self_close("FusionCompHolderItems"),
        self_close("UserDefinedName"),
        self_close("LayersVec"),
    }), {DbId = track_dbid}))
end

-- ─── SeqContainer body — VideoTrackVec + AudioTrackVec ──────────────────────
--
-- Resolve's schema separates video and audio tracks into siblings
-- (<VideoTrackVec> and <AudioTrackVec>) rather than interleaving by index.

local function build_seq_container_xml(seq, seq_dbid, container_dbid,
                                       media_by_uuid)
    assert(type(seq.tracks) == "table" and #seq.tracks >= 1,
        "drt_writer.build_seq_container_xml: sequence.tracks non-empty array")
    local native_rate = seq.fps

    local video_tracks, audio_tracks = {}, {}
    for _, t in ipairs(seq.tracks) do
        local rendered = build_track_element(t, seq_dbid, media_by_uuid,
                                             native_rate)
        if t.type == "audio" then
            audio_tracks[#audio_tracks + 1] = rendered
        else
            video_tracks[#video_tracks + 1] = rendered
        end
    end

    local body = table.concat({
        self_close("FieldsBlob"),
        elem("VideoTrackVec", table.concat(video_tracks)),
        elem("AudioTrackVec", table.concat(audio_tracks)),
        self_close("SubtitleTrackVec"),
        self_close("GeometryTrackVec"),
        text_elem("DbSavedTime", "0"),
    })
    return '<?xml version="1.0" encoding="UTF-8"?>\n' ..
        '<!--DbAppVer="20.3.2.0009" DbPrjVer="15"-->\n' ..
        elem("Sm2SequenceContainer", body, {DbId = container_dbid})
end

-- ─── project.xml + MpFolder.xml — template-substitute ───────────────────────
--
-- Both files are loaded verbatim from drt_canonical/ and have their reference
-- DbIds + reference names swapped for freshly minted ones / payload values.

local function build_project_xml(template, payload, dbids)
    -- Required scalars (template drift = silent leak of reference content).
    -- Order: longer `.Cfg` form replaces first because it contains
    -- the shorter REFERENCE_PROJECT_NAME as a prefix.
    template = plain_gsub_required(template,
        REFERENCE_PROJECT_CFG, payload.project.name .. ".Cfg")
    template = plain_gsub_required(template,
        REFERENCE_PROJECT_NAME, payload.project.name)
    -- DbId sweep: each ref DbId appears in some files but not others; this
    -- function runs over project.xml only, so DbIds that live exclusively in
    -- MpFolder.xml or SeqContainer/*.xml won't be present here. Use the
    -- non-asserting form.
    for key, ref_dbid in pairs(REFERENCE_DBIDS) do
        local fresh = dbids[key]
        if fresh and fresh ~= ref_dbid then
            template = plain_gsub(template, ref_dbid, fresh)
        end
    end
    return template
end

local function build_mp_folder_xml(template, payload, seq, dbids)
    template = plain_gsub_required(template, REFERENCE_SEQUENCE_NAME, seq.name)
    -- The reference's Sm2Sequence carries a FrameRate hex blob hard-coded to
    -- 23.976 and Resolution hard-coded to 1920×1080. Swap with payload values
    -- so the MpFolder metadata correctly advertises the timeline shape.
    -- Empty reference was authored as a 24.0 fps project; the kitchen-sink
    -- fixture happens to be 23.976. We're substituting against the EMPTY
    -- reference template, so the needle is the 24.0 hex.
    local ref_frame_rate_hex =
        "00000000000038400000000000000000"   -- LE double 24.0 + 0
    local ref_resolution_hex =
        "00000000000007800000000000000438"   -- BE int64 1920 + 1080
    local our_frame_rate_hex = enc.encode_le_double(seq.fps)
        .. "0000000000000000"
    local our_resolution_hex = string.format(
        "%016x%016x", seq.width or 1920, seq.height or 1080)
    template = plain_gsub_required(template,
        ref_frame_rate_hex, our_frame_rate_hex)
    template = plain_gsub_required(template,
        ref_resolution_hex, our_resolution_hex)

    -- DbId sweep — not every ref DbId lives in MpFolder.xml; use silent form.
    for key, ref_dbid in pairs(REFERENCE_DBIDS) do
        local fresh = dbids[key]
        if fresh and fresh ~= ref_dbid then
            template = plain_gsub(template, ref_dbid, fresh)
        end
    end
    return template
end

-- ─── Filesystem + zip ───────────────────────────────────────────────────────

local function write_file(path, body)
    local h = assert(io.open(path, "wb"),
        "drt_writer: cannot open " .. path .. " for write")
    h:write(body)
    h:close()
end

local function shell_quote(s) return "'" .. s:gsub("'", [['\'']]) .. "'" end

-- ─── Public API ─────────────────────────────────────────────────────────────

--- Author a .drt at out_path from a JVE payload.
--- @param out_path string  absolute path to write
--- @param payload  table {
---     project    = { name, fps, [width=1920], [height=1080] },
---     media_refs = { { file_uuid, file_path, duration_frames,
---                       start_tc_frame }, ... },
---     sequences  = { { name, fps, [width], [height],
---                      tracks = { { type="video"|"audio",
---                                   clips = { { id, media_uuid,
---                                               sequence_start, duration,
---                                               source_in, name }, ... }
---                                 }, ... }
---                    }, ... }   -- (T009 wire allows ≥1; T004 round-trip uses 1)
---   }
--- @return table  { path, stage }
function M.author(out_path, payload)
    assert(type(out_path) == "string" and out_path ~= "",
        "drt_writer.author: out_path required")
    assert(type(payload) == "table",
        "drt_writer.author: payload table required")
    assert(type(payload.project) == "table"
        and type(payload.project.name) == "string"
        and payload.project.name ~= "",
        "drt_writer.author: payload.project.name required")
    assert(type(payload.project.fps) == "number" and payload.project.fps > 0,
        "drt_writer.author: payload.project.fps required (positive)")
    assert(type(payload.media_refs) == "table",
        "drt_writer.author: payload.media_refs required (array)")
    assert(type(payload.sequences) == "table" and #payload.sequences >= 1,
        "drt_writer.author: payload.sequences must be a non-empty array")
    assert(#payload.sequences == 1, "drt_writer.author: only single-sequence "
        .. "payloads are supported in this writer pass (FR-002 scope); got "
        .. #payload.sequences)
    local seq = payload.sequences[1]
    assert(type(seq.name) == "string" and seq.name ~= "",
        "drt_writer.author: sequence.name required")
    assert(type(seq.fps) == "number" and seq.fps > 0,
        "drt_writer.author: sequence.fps required (positive)")

    -- Index media_refs for clip → media lookup.
    local media_by_uuid = {}
    for _, m in ipairs(payload.media_refs) do
        assert(type(m.file_uuid) == "string" and m.file_uuid ~= "",
            "drt_writer.author: each media_ref needs a file_uuid")
        media_by_uuid[m.file_uuid] = m
    end

    -- Reset and seed the deterministic UUID counter for this export.
    M._uuid_counter = 0
    local dbids = {}
    local seeds = {
        sm_project = 0x01, sm_config = 0x02, sm_multi_sys = 0x03,
        sm_media_pool = 0x04, sm_group_list = 0x05, lockable_blob_map = 0x06,
        media_pool_lockable = 0x07, power_node_list = 0x08,
        mp_folder = 0x10, mp_folder_unique_id = 0x11,
        mp_timeline_clip = 0x20, mp_timeline_unique = 0x21,
        timeline = 0x30, sequence = 0x40, unique_sequence_id = 0x41,
        seq_container = 0x50, plm_ver_table = 0x60, lm_version = 0x61,
        ptzr_preset_outer = 0x80, ptzr_preset_timeline = 0x81,
    }
    for key, seed in pairs(seeds) do dbids[key] = fresh_uuid(seed) end

    -- Load templates and apply substitutions.
    local project_xml = build_project_xml(
        load_template("empty_reference_project.xml"), payload, dbids)
    local mp_folder_xml = build_mp_folder_xml(
        load_template("empty_reference_mp_folder.xml"), payload, seq, dbids)
    local gallery_xml = load_template("empty_reference_gallery.xml")
    local seq_container_xml = build_seq_container_xml(
        seq, dbids.sequence, dbids.seq_container, media_by_uuid)

    -- Stage tree under /tmp; nuke any prior leftover.
    local stage = "/tmp/jve_drt_stage_" .. tostring(M._uuid_counter)
    os.execute("rm -rf " .. shell_quote(stage))
    assert(os.execute("mkdir -p " .. shell_quote(stage
        .. "/MediaPool/Master")) == 0,
        "drt_writer.author: mkdir MediaPool/Master failed")
    assert(os.execute("mkdir -p " .. shell_quote(stage
        .. "/SeqContainer")) == 0,
        "drt_writer.author: mkdir SeqContainer failed")

    write_file(stage .. "/project.xml", project_xml)
    write_file(stage .. "/MediaPool/Master/MpFolder.xml", mp_folder_xml)
    write_file(stage .. "/Gallery.xml", gallery_xml)
    write_file(string.format("%s/SeqContainer/%s.xml",
        stage, dbids.seq_container), seq_container_xml)

    os.remove(out_path)
    local zip_cmd = string.format("cd %s && zip -q -X -r %s . > /dev/null",
        shell_quote(stage), shell_quote(out_path))
    local rc = os.execute(zip_cmd)
    assert(rc == 0, "drt_writer.author: zip exited non-zero (" .. tostring(rc)
        .. ") — is `zip` on PATH?")

    return { path = out_path, stage = stage, dbids = dbids }
end

return M
