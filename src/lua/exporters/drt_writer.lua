--- DRT writer — author the minimal-viable .drt archive (the on-disk
--- format Resolve's "import DRP/DRT" path consumes) from a JVE payload.
---
--- Format (subset of the Resolve container the importer already reads):
---   <archive>.drt = ZIP of:
---     project.xml                            project metadata
---     MediaPool/Master/MpFolder.xml          per-sequence timeline entries
---                                            (gates parse_drp_file's seq
---                                            pickup via timeline_metadata_map)
---     SeqContainer/seq_<i>.xml               one per sequence, with tracks +
---                                            clips carrying identity (`DbId`)
---
--- DRT vs DRP: same archive shape (zip of project.xml + MediaPool + SeqContainer).
--- JVE's own DRP importer is tolerant of the minimal subset this module
--- emits today (T004 round-trip green). **Resolve's importer is NOT** —
--- spike 2026-05-31 (phase0-findings.md §"T008 spike") confirmed Resolve
--- rejects this archive ("Failed to import project") because it lacks the
--- bulk of Resolve's persistence schema (DbId attrs, version comment,
--- TimelineHandleVec, Sm2MpTimelineClip/Sm2Timeline/Sm2Sequence wrapping
--- with FieldsBlobs, separate VideoTrackVec/AudioTrackVec, etc.). The
--- Resolve-accepted writer is a rewrite gated on Joe's decision; the
--- reference shape is `tests/fixtures/resolve/t008_reference_empty_timeline.drp`.
---
--- Round-trip contract (per FR-002, FR-011b, feedback_timecode_is_truth):
---   • Per-clip identity field (clip.id) → Sm2Ti{Video,Audio}Clip.DbId attr
---   • Per-clip media identity         → <MediaRef> text == media.file_uuid
---   • Source-in is ABSOLUTE TC in native units; the writer subtracts
---     `media.start_tc_frame` to produce the file-relative `<In>` value
---     the importer recomposes back into absolute TC.
---
--- Importer prohibition: this writer NEVER probes media. Every value comes
--- from the payload table (see `feedback_importers_no_media_probe` for the
--- symmetric inbound rule).

local M = {}

local enc = require("exporters.drt_binary")

-- ─── UUID minting (for synthesized container IDs) ────────────────────

-- Resolve's DbIds are UUIDv4-shaped text in <Sm2*>. The writer mints fresh
-- ids for the folder/timeline/sequence containers; clip + media ids come
-- straight from the payload (the round-trip identity surface).
local function fresh_uuid_v4(seed_byte)
    -- Pseudo-UUID. Deterministic (counter-based) so workflow resume and
    -- byte-stable archive emission stay reproducible — no Date.now /
    -- Math.random.
    M._uuid_counter = (M._uuid_counter or 0) + 1
    local function nibble(i)
        return string.format("%x",
            (seed_byte + i * 17 + M._uuid_counter * 31) % 16)
    end
    local function hexchars(n)
        local out = {}
        for i = 1, n do out[i] = nibble(i) end
        return table.concat(out)
    end
    return string.format("%s-%s-4%s-%s%s-%s",
        hexchars(8), hexchars(4), hexchars(3),
        ({"8","9","a","b"})[(seed_byte % 4) + 1], hexchars(3),
        hexchars(12))
end

-- ─── XML emission ────────────────────────────────────────────────────

-- Escape XML special chars in element text. Attribute escaping adds `"`
-- since the writer emits attrs in double quotes.
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

-- ─── XML builders per file ───────────────────────────────────────────

local function build_project_xml(project)
    assert(type(project) == "table" and type(project.name) == "string"
        and project.name ~= "",
        "drt_writer: payload.project.name required")
    assert(type(project.fps) == "number" and project.fps > 0,
        "drt_writer: payload.project.fps required (positive number)")

    local body = table.concat({
        text_elem("ProjectName", project.name),
        text_elem("TimelineFrameRate", string.format("%.6f", project.fps)),
        text_elem("TimelineResolutionWidth", project.width or 1920),
        text_elem("TimelineResolutionHeight", project.height or 1080),
    })
    return '<?xml version="1.0" encoding="UTF-8"?>\n' .. elem("Project", body)
end

-- One <Sm2MpTimelineClip> per authored sequence. The importer's
-- timeline_metadata_map is keyed by Sm2Sequence.DbId; FrameRate / Resolution
-- live on that element. Sm2Sequence.DbId must match the <Sequence> text the
-- SeqContainer XML emits in its <Sm2TiTrack>, otherwise the importer skips
-- the sequence as "no MediaPool metadata."
local function build_mp_folder_xml(folder_id, seq_descriptors)
    local entries = {}
    for _, sd in ipairs(seq_descriptors) do
        entries[#entries + 1] = open_tag("Sm2MpTimelineClip") ..
            text_elem("MpFolder", folder_id) ..
            open_tag("Sm2Timeline", {DbId = sd.timeline_id}) ..
                text_elem("Name", sd.name) ..
                open_tag("Sequence") ..
                    open_tag("Sm2Sequence", {DbId = sd.seq_id}) ..
                        text_elem("FrameRate", enc.encode_le_double(sd.fps)) ..
                        text_elem("Resolution",
                            enc.encode_resolution(sd.width, sd.height)) ..
                    "</Sm2Sequence>" ..
                "</Sequence>" ..
            "</Sm2Timeline>" ..
        "</Sm2MpTimelineClip>"
    end

    local body = text_elem("Name", "Master") .. table.concat(entries)
    return '<?xml version="1.0" encoding="UTF-8"?>\n' ..
        elem("Sm2MpFolder", body, {DbId = folder_id})
end

-- Emit one Sm2TiVideoClip / Sm2TiAudioClip.
-- For source-in: parser computes `source_in_native = media_tc_origin + <In>`
-- where media_tc_origin = round(MediaStartTime × native_rate). Writer
-- inverts: <In> = source_in - media.start_tc_frame, MediaStartTime =
-- media.start_tc_frame / native_rate. Per `feedback_timecode_is_truth`,
-- source_in is ABSOLUTE TC; <In> is always file-relative.
local function build_clip_xml(clip, media, native_rate, track_type)
    assert(type(clip.id) == "string" and clip.id ~= "",
        "drt_writer: clip.id required (round-trip identity field)")
    assert(type(clip.media_uuid) == "string" and clip.media_uuid ~= "",
        "drt_writer: clip.media_uuid required (round-trip media link)")
    assert(type(clip.sequence_start) == "number" and clip.sequence_start >= 0,
        "drt_writer: clip.sequence_start must be non-negative integer")
    assert(type(clip.duration) == "number" and clip.duration > 0,
        "drt_writer: clip.duration must be positive integer")
    assert(type(clip.source_in) == "number" and clip.source_in >= 0,
        "drt_writer: clip.source_in must be non-negative integer (absolute TC)")
    assert(type(media) == "table",
        "drt_writer: clip references unknown media_uuid " .. clip.media_uuid)
    assert(type(media.start_tc_frame) == "number" and media.start_tc_frame >= 0,
        "drt_writer: media.start_tc_frame required (file TC origin in "
        .. "native units; 0 for tc=0 files)")
    assert(type(media.file_path) == "string" and media.file_path ~= "",
        "drt_writer: media.file_path required (importer's raw-XML grep "
        .. "pass at drp_importer.lua:2217 reads MediaFilePath even without "
        .. "a structured pool entry)")

    local in_offset = clip.source_in - media.start_tc_frame
    assert(in_offset >= 0, string.format(
        "drt_writer: clip %s source_in (%d) < media start_tc_frame (%d) — "
        .. "source_in below file TC origin is invalid",
        clip.id, clip.source_in, media.start_tc_frame))

    local media_start_seconds = media.start_tc_frame / native_rate
    local tag = (track_type == "audio") and "Sm2TiAudioClip" or "Sm2TiVideoClip"
    local body = table.concat({
        text_elem("Name", clip.name or "clip"),
        text_elem("Start", math.floor(clip.sequence_start)),
        text_elem("Duration", math.floor(clip.duration)),
        text_elem("In", math.floor(in_offset)),
        text_elem("MediaFilePath", media.file_path),
        text_elem("MediaRef", clip.media_uuid),
        text_elem("MediaStartTime", string.format("%.9f", media_start_seconds)),
        text_elem("MediaFrameRate", enc.encode_le_double(native_rate)),
    })
    return elem(tag, body, {DbId = clip.id})
end

local function build_track_xml(track, seq_id, media_by_uuid, native_rate)
    assert(type(track.clips) == "table",
        "drt_writer: track.clips required (array; empty table OK for "
        .. "tracks with no clips, but field must be present)")
    local track_type = (track.type == "audio") and "audio" or "video"
    local type_value = (track_type == "audio") and 1 or 0
    local clip_xmls = {}
    for _, c in ipairs(track.clips) do
        local media = media_by_uuid[c.media_uuid]
        clip_xmls[#clip_xmls + 1] = build_clip_xml(c, media, native_rate, track_type)
    end
    -- DRP layout: clips live under <Items><Element><Sm2Ti*Clip/></Element></Items>
    -- inside the track (per `find_track_clips` in drp_importer.lua:193). Putting
    -- clip elements as direct children of Sm2TiTrack makes them invisible to the
    -- importer — which is exactly the silent-track-empty bug a naive writer hits.
    local items_body = {}
    for _, c_xml in ipairs(clip_xmls) do
        items_body[#items_body + 1] = elem("Element", c_xml)
    end
    return open_tag("Sm2TiTrack") ..
        text_elem("Type", type_value) ..
        text_elem("Sequence", seq_id) ..
        elem("Items", table.concat(items_body)) ..
        "</Sm2TiTrack>"
end

local function build_seq_xml(seq_descriptor, sequence, media_by_uuid)
    assert(type(sequence.tracks) == "table" and #sequence.tracks >= 1,
        "drt_writer: sequence.tracks must be a non-empty array (at least "
        .. "one video or audio track per sequence)")
    local native_rate = sequence.fps
    local tracks_xml = {}
    for _, t in ipairs(sequence.tracks) do
        tracks_xml[#tracks_xml + 1] = build_track_xml(
            t, seq_descriptor.seq_id, media_by_uuid, native_rate)
    end
    return '<?xml version="1.0" encoding="UTF-8"?>\n' ..
        elem("Sm2SequenceContainer", table.concat(tracks_xml))
end

-- ─── Filesystem + zip ────────────────────────────────────────────────

local function write_file(path, body)
    local h = assert(io.open(path, "wb"),
        "drt_writer: cannot open " .. path .. " for write")
    h:write(body)
    h:close()
end

local function shell_quote(s)
    return "'" .. s:gsub("'", [['\'']]) .. "'"
end

-- ─── Public API ──────────────────────────────────────────────────────

--- Author a .drt at `out_path` from `payload`. Overwrites if present.
--- Returns `{path, stage, seq_descriptors}` — stage is left on disk for
--- debugging (harmless under /tmp).
--- @param out_path string  absolute path to write .drt
--- @param payload  table   see module header for shape
function M.author(out_path, payload)
    assert(type(out_path) == "string" and out_path ~= "",
        "drt_writer.author: out_path required")
    assert(type(payload) == "table",
        "drt_writer.author: payload required (table)")
    assert(type(payload.media_refs) == "table",
        "drt_writer.author: payload.media_refs required (array)")
    assert(type(payload.sequences) == "table" and #payload.sequences >= 1,
        "drt_writer.author: payload.sequences must be a non-empty array")

    local media_by_uuid = {}
    for _, m in ipairs(payload.media_refs) do
        assert(type(m.file_uuid) == "string" and m.file_uuid ~= "",
            "drt_writer.author: every media_ref needs a file_uuid")
        media_by_uuid[m.file_uuid] = m
    end

    M._uuid_counter = 0
    local folder_id = fresh_uuid_v4(0x10)

    local seq_descriptors = {}
    for i, seq in ipairs(payload.sequences) do
        assert(type(seq.name) == "string" and seq.name ~= "",
            "drt_writer.author: sequence.name required")
        assert(type(seq.fps) == "number" and seq.fps > 0,
            "drt_writer.author: sequence.fps required (positive)")
        seq_descriptors[i] = {
            timeline_id = fresh_uuid_v4(0x20 + i),
            seq_id      = fresh_uuid_v4(0x30 + i),
            name        = seq.name,
            fps         = seq.fps,
            width       = seq.width or (payload.project and payload.project.width) or 1920,
            height      = seq.height or (payload.project and payload.project.height) or 1080,
        }
    end

    -- Stage tree under /tmp; nuke any leftover before re-staging so a
    -- prior call's residue cannot leak into this archive.
    local stage = "/tmp/jve_drt_stage_" .. tostring(M._uuid_counter)
    os.execute("rm -rf " .. shell_quote(stage))
    assert(os.execute("mkdir -p " .. shell_quote(stage .. "/MediaPool/Master")) == 0,
        "drt_writer.author: mkdir MediaPool/Master failed")
    assert(os.execute("mkdir -p " .. shell_quote(stage .. "/SeqContainer")) == 0,
        "drt_writer.author: mkdir SeqContainer failed")

    write_file(stage .. "/project.xml",
        build_project_xml(payload.project or {
            name = "Untitled",
            fps  = payload.sequences[1].fps,
        }))
    write_file(stage .. "/MediaPool/Master/MpFolder.xml",
        build_mp_folder_xml(folder_id, seq_descriptors))
    for i, seq in ipairs(payload.sequences) do
        write_file(string.format("%s/SeqContainer/seq_%03d.xml", stage, i),
            build_seq_xml(seq_descriptors[i], seq, media_by_uuid))
    end

    os.remove(out_path)
    local zip_cmd = string.format("cd %s && zip -q -X -r %s . > /dev/null",
        shell_quote(stage), shell_quote(out_path))
    local rc = os.execute(zip_cmd)
    assert(rc == 0,
        "drt_writer.author: zip exited non-zero (" .. tostring(rc) ..
        ") — is `zip` on PATH?")

    return { path = out_path, stage = stage,
             seq_descriptors = seq_descriptors }
end

return M
