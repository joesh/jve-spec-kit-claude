--- DRT writer — author a Resolve-canonical .drt archive from a JVE payload.
---
--- Format: .drt = ZIP of
---   project.xml                            project envelope + TimelineHandleVec
---   MediaPool/Master/MpFolder.xml          per-timeline wrapper + media-pool items
---   SeqContainer/<seq_container_dbid>.xml  one per sequence (tracks + clips)
---   Gallery.xml                            color-still gallery (carried verbatim)
---
--- Strategy: load Resolve-authored verbatim templates from drt_canonical/,
--- mint fresh UUIDs per export, substitute payload-driven fields. SeqContainer
--- is built fresh; other files are template + sweep. Schema detail and the
--- list of borrowed-verbatim FieldsBlobs are documented in
--- specs/023-resolve-color-bridge/phase0-findings.md §§A–K and tracked in
--- todo_drt_writer_resolve_canonical_shape.md.
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

local enc            = require("exporters.drt_binary")
local identity_marker = require("exporters.drt_identity_marker")

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

-- Per-export-minted DbId slots. `ref` is the reference UUID as it appears
-- in the verbatim templates; `seed` is the entropy byte fed to fresh_uuid
-- (distinct per slot so two slots can never collide). The writer mints one
-- fresh UUID per slot and sweeps the template, replacing every occurrence
-- of `ref` with the minted value. Per-export minting is required because
-- Resolve treats matching SM_Project DbId as "same project — replace?".
-- Gallery is referenced from SM_Project FieldsBlob; Gallery.xml is left
-- verbatim (no minted alternative).
local DBID_SLOTS = {
    sm_project           = { ref = "1b5606b3-a688-4e51-8e0b-5419c3920167", seed = 0x01 },
    sm_config            = { ref = "3f8d11fa-9f8e-4b9a-abe0-e3da14b14c37", seed = 0x02 },
    sm_multi_sys         = { ref = "365cdf7d-752f-4e04-a717-2104a8d7cfe2", seed = 0x03 },
    sm_media_pool        = { ref = "5c050c82-bcf9-498e-9d66-780afde902cc", seed = 0x04 },
    sm_group_list        = { ref = "07d5f5bb-1a7b-4f5a-afce-74c0fe4694b3", seed = 0x05 },
    lockable_blob_map    = { ref = "85470bbb-51f6-4fd4-9a66-51320ee4f681", seed = 0x06 },
    media_pool_lockable  = { ref = "80cc20f6-6d21-42df-86e4-8a4d63094d16", seed = 0x07 },
    power_node_list      = { ref = "207dfe44-2b14-4752-ab99-6345b1631585", seed = 0x08 },
    mp_folder            = { ref = "6cf9979b-3e45-4c7c-874f-4162010c5f8e", seed = 0x10 },
    mp_folder_unique_id  = { ref = "ac079579-635c-4165-a592-f12984bc1cfb", seed = 0x11 },
    mp_timeline_clip     = { ref = "9d3a9478-efa8-43f7-b419-6c64b4c0b733", seed = 0x20 },
    mp_timeline_unique   = { ref = "4fa3ff10-7d93-49db-8f23-b6cdcaaecc01", seed = 0x21 },
    timeline             = { ref = "dffcf5b8-3bdb-499a-b375-8fdf94f5e5c4", seed = 0x30 },
    sequence             = { ref = "1e46c9dd-80b8-4977-aaec-35f0498cd16b", seed = 0x40 },
    unique_sequence_id   = { ref = "d108fed5-430a-4f5f-8433-0f4b63144e30", seed = 0x41 },
    seq_container        = { ref = "09a19a21-d424-41ef-945f-d598b9d4a4ac", seed = 0x50 },
    plm_ver_table        = { ref = "6b42ab53-487b-4e39-8236-03df47a32e93", seed = 0x60 },
    lm_version           = { ref = "3c943505-3438-4067-808b-31b5f9702a4d", seed = 0x61 },
    ptzr_preset_outer    = { ref = "9329dc34-fb30-433f-9218-f3eb22a880d6", seed = 0x80 },
    ptzr_preset_timeline = { ref = "b4da443a-0706-457f-b7e1-03e570fef353", seed = 0x81 },
}

-- Hard-coded text values in templates that must be replaced with payload
-- content. The empty reference was authored as project "JVE_T008_reference"
-- with sequence "JVE_T008_ref_seq".
local REFERENCE_PROJECT_NAME  = "JVE_T008_reference"
local REFERENCE_SEQUENCE_NAME = "JVE_T008_ref_seq"
local REFERENCE_PROJECT_CFG   = "JVE_T008_reference.Cfg"

-- Reference values inside the Sm2MpVideoClip template
-- (drt_canonical/full_reference_mp_video_clip_a005.xml). See phase0-findings.md
-- §K3 for substitution rationale. The template is a PRISTINE pool item from
-- a real Resolve 20.3 DRT export of the A005 fixture (2026-06-10 t050b
-- probe): single embedded-AAC channel group whose FieldsBlob MediaRef
-- equals the template's own BtAudioInfo DbId. The previous kitchen-sink
-- capture carried a custom-audio channel map whose MediaRef dangled in
-- our single-media DRTs — Resolve materialized the pool item as a broken
-- "' import'" placeholder (empty File Path, garbage name). The MpFolder
-- back-ref UUID is the capture project's mp_folder DbId (NOT the
-- empty-reference's — those differ), so it gets handled inline rather
-- than via the REFERENCE_DBIDS sweep.
local A005_TEMPLATE_DBID                = "07caaf98-6659-4345-8968-de92c0b17e50"
local A005_TEMPLATE_MP_FOLDER_BACKREF   = "fe7a26e6-8c49-49a6-be20-f21689c9a41f"
local A005_TEMPLATE_UNIQUE_MP_ITEM_ID   = "297f29a9-65e8-499a-bcec-1d42da0ec926"
local A005_TEMPLATE_NAME                = "A005_C052_0925BL_001.mp4"
-- ctime-style date inside the re-encoded <Clip> blobs. Template residue
-- (the reference capture's file mtime): Resolve binds by directory +
-- filename, not by this string — live-verified 2026-06-10 by a linked
-- import whose blob date predated the actual file by two years. A
-- general-media writer should stat the real file mtime; gated with the
-- rest of the a005-class limits.
local A005_TEMPLATE_CLIP_DATE           = "Mon May 27 00:09:20 2024"

-- ─── UUID minting ───────────────────────────────────────────────────────────
--
-- Counter-based + per-export entropy: the counter is seeded from a hash of
-- the output path so distinct exports produce distinct minted DbIds (Resolve
-- would otherwise reject the second-imported archive as a duplicate of the
-- first when the project-level UUIDs collide). Same out_path + same payload
-- still produce byte-identical bytes — reproducibility preserved for
-- verification and diff-based regression.

local function hash_uint24(s)
    local h = 0
    for i = 1, #s do
        h = (h * 31 + s:byte(i)) % 0x1000000   -- FNV-style, 24-bit
    end
    return h
end

local function fresh_uuid(seed_byte, state)
    state.uuid_counter = state.uuid_counter + 1
    local k = state.uuid_counter
    -- (counter, seed) embedded directly so two calls with different seeds
    -- or different counters can never collide. Format: 8-4-4-4-12;
    -- version=4, variant in {8,9,a,b}.
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
    assert(s ~= nil, "drt_writer.xml_text: nil input — callers must "
        .. "provide a non-nil value (use self_close for empty elements)")
    s = tostring(s)
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

-- Replace every reference DbId that appears in `template` with the
-- correspondingly-named minted DbId from `dbids`. Each REFERENCE_DBIDS
-- entry lives in some subset of the archive's XMLs — we don't know which
-- without parsing — so missing-in-this-file is silent. Drift IS caught at
-- the end: if any reference DbId remains in the output after substitution,
-- it means we either forgot to mint a fresh value or Resolve renamed the
-- field but our REFERENCE_DBIDS table still calls the old slot.
--
-- UUIDs appear in TWO encodings in the archive:
--   1. Plain ASCII — XML attributes, element text, MediaPool back-refs
--   2. UTF-16BE-as-hex inside <FieldsBlob>...</FieldsBlob> hex strings —
--      e.g. ASCII "09a19a21" → hex `00300039006100310039006100320031`.
-- Both must be swept. Missing the UTF-16BE form was the 2026-06-01 T008
-- kill: SeqRef inside Sm2Sequence's FieldsBlob and RootFolderRef inside
-- Sm2MediaPool's FieldsBlob still carried seed UUIDs, so Resolve couldn't
-- resolve the timeline → seq-container link and rendered no clip body in
-- the timeline (TC start was correct, but the clip itself was invisible).
local function uuid_utf16be_hex(uuid)
    local out = {}
    for i = 1, #uuid do
        out[#out+1] = string.format("00%02x", string.byte(uuid, i))
    end
    return table.concat(out)
end

local function sweep_reference_dbids(template, dbids)
    for slot, info in pairs(DBID_SLOTS) do
        local fresh = dbids[slot]
        assert(fresh, "drt_writer.sweep_reference_dbids: slot '" .. slot
            .. "' not minted before sweep")
        if fresh ~= info.ref then
            template = plain_gsub(template, info.ref, fresh)
            template = plain_gsub(template,
                uuid_utf16be_hex(info.ref),
                uuid_utf16be_hex(fresh))
        end
    end
    for slot, info in pairs(DBID_SLOTS) do
        assert(not template:find(info.ref, 1, true), string.format(
            "drt_writer.sweep_reference_dbids: reference DbId '%s' "
            .. "(slot '%s') survived substitution — template carries this "
            .. "DbId in an unexpected location",
            info.ref, slot))
        assert(not template:find(uuid_utf16be_hex(info.ref), 1, true),
            string.format(
                "drt_writer.sweep_reference_dbids: UTF-16BE-encoded "
                .. "reference DbId '%s' (slot '%s') survived "
                .. "substitution — FieldsBlob carries this seed UUID",
                info.ref, slot))
    end
    return template
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

-- <In> = file-relative source-in frames. JVE payloads carry integer frames;
-- the sub-frame `<frames>|<hex_LE_double>` form is unreachable by current
-- JVE model state (all source_in / start_tc_frame are integers — see
-- feedback_timecode_is_truth and feedback_clip_lua_field_names). If JVE ever
-- adopts sub-frame source-in this assert will fire and force a deliberate
-- format extension rather than a silent precision loss.
local function build_in_element(in_offset)
    assert(in_offset == math.floor(in_offset), string.format(
        "drt_writer.build_in_element: in_offset must be integer frames, "
        .. "got %s. Sub-frame source-in is not part of JVE's model; if "
        .. "you're reaching this assert, extend the writer + drp_importer "
        .. "together with the `<frames>|<hex_LE_double>` form.",
        tostring(in_offset)))
    if in_offset == 0 then
        return self_close("In")
    end
    return text_elem("In", tostring(in_offset))
end

-- Restored: still referenced by audio clip path until #14 lands.
local VIRTUAL_AUDIO_TRACK_BA_MONO_A1 =
    "000000010000000200000014004300680061006e006e0065006c0073004200" ..
    "410000000c000000000c000000020000000100004001000000120041007500" ..
    "640069006f0054007900700065000000020000000001"

-- MediaTimemapBA — un-retimed timing curve for the clip.
--
-- Observed REF format from resolve_authored_single_clip.drp (108-frame A005
-- clip at 23.976 native rate) is **41 bytes** (not 9), shape:
--   02 | be(d) | 0×8 | be(d + 1/numerator) | 0×8 | be(d)
-- where d = (duration_frames - 1) / native_rate in seconds, and the
-- middle epsilon `1/numerator` (with native_rate = numerator / 1001)
-- is empirically `1/24000` for 23.976 fps. Format is otherwise opaque —
-- Resolve probably encodes a 3-keyframe curve (start/peak/end) with
-- implicit x-coords, but full decode is deferred. Tracked in
-- todo_drt_media_timemap_ba_format.md.
--
-- The 9-byte 0x02 form (just `02 + be(d)`) is documented by drp_binary's
-- decoder as "no speed info" and was the first thing this writer emitted —
-- but the empirical Resolve refusal to render the clip (only TC start
-- shown, no clip body in TL — 2026-05-31) suggests Resolve's parser
-- treats the short form as malformed for visible clips. Emitting the
-- long form unblocks the spike acceptance test.
local function build_media_timemap_ba(duration_frames, media_native_rate)
    assert(type(duration_frames) == "number" and duration_frames > 0,
        "drt_writer.build_media_timemap_ba: positive duration_frames required")
    assert(type(media_native_rate) == "number" and media_native_rate > 0,
        "drt_writer.build_media_timemap_ba: positive media_native_rate required")
    -- Epsilon constant derives from native_rate's numerator (24000 for
    -- 23.976 = 24000/1001). For non-23.976 rates this constant must be
    -- reverse-engineered — fail-fast so a future caller's wrong-rate
    -- output doesn't silently confuse Resolve.
    local TWENTYFOURTHOUSAND_INV = 1 / 24000
    assert(math.abs(media_native_rate - 24000 / 1001) < 1e-6,
        string.format("drt_writer.build_media_timemap_ba: epsilon constant "
        .. "1/24000 was empirically derived from 23.976 fps "
        .. "(24000/1001) only — got native_rate=%.6f. Re-derive from a "
        .. "Resolve-authored DRP at this rate before extending.",
        media_native_rate))
    local d_secs = (duration_frames - 1) / media_native_rate
    local d_plus = d_secs + TWENTYFOURTHOUSAND_INV
    local zeros = "0000000000000000"
    return "02" .. enc.encode_be_double(d_secs)
        .. zeros .. enc.encode_be_double(d_plus)
        .. zeros .. enc.encode_be_double(d_secs)
end

-- PreConformMediaExtents — 16-byte blob copied verbatim from
-- resolve_authored_single_clip. Format-level decode tracked in
-- todo_drt_preconform_media_extents_decode.md.
local PRECONFORM_MEDIA_EXTENTS = "00000100000030c20000010000003042"

-- Sm2MpTimelineClip <FieldsBlob>: protobuf-ish zstd-compressed wrapper
-- describing the media-pool timeline-item (Type, MediaExtents,
-- ChannelVecBA, ChannelIdx). The empty-reference template's version
-- carried TWO embedded MediaRef pointers to its own slot UUID (a stale
-- 9d3a9478-... self-reference that, after our outer-DbId sweep, dangles
-- to nothing in JVE-authored output → Resolve rejected the timeline-item's
-- media binding and refused to render any clip body).
--
-- ONE per exported timeline (MpFolder.xml: 1× Sm2MpTimelineClip wrapper),
-- independent of how many clips the timeline contains — per-clip data
-- lives in SeqContainer/*.xml's Sm2TiVideoClip/Sm2TiAudioClip elements
-- synthesized by build_clip_element (drt_writer.lua:396+). The "_BORROWED"
-- suffix replaced an earlier "_SINGLE_CLIP" name that misleadingly hinted
-- at a clip-count constraint — there is none; "single_clip" referred only
-- to the source-fixture filename (resolve_authored_single_clip.drp).
-- Borrowed verbatim from that fixture; encodes Type/MediaExtents/etc but
-- WITHOUT the dangling MediaRef pointers. Substituted into the empty-
-- reference template's Sm2MpTimelineClip element before any DbId sweep.
-- See todo_drt_inner_fieldsblob_uuids.md for the broader leak class.
local SM2_MP_TIMELINE_CLIP_FIELDS_BLOB_BORROWED =
    "00000002000000ae8128b52ffd6004001d0500a2481d2a9039cd019fb131c47a" ..
    "fffc65fa22ee36ca76a9aa2ad1991d5b0afe7f44340be9da28b946482f112172" ..
    "a7777777778f297777556941e5cd25737d1d0414a8b04dd8b09d4ea30b073e00" ..
    "1416e72175da52ab04a30ca5adc1a775081161e48d8a971cbade58601cd064e2" ..
    "2243c28130c61a0cb622581100091b9a3424904a20b5d547e80a32d321abe3cc" ..
    "c28a606ed6ca39a54d5484373961cdccdf664e4cb831"
local EMPTY_REF_MP_TIMELINE_CLIP_FIELDS_BLOB =
    "00000002000000eb8128b52ffd60d600050700420d282e804d9a0373c1e38249" ..
    "9627e51467ac989c3662512092904700d80d44a9dd2d39f7393f16aa29da7f29" ..
    "b068ef9d02efbdf7de7b011b3c1a3b33250e5ead5e2fa918ab25a6e5145b69bd" ..
    "9c5e35ab56365d78b562b3d54c6cc4b76bba1492c74ae850c2d3d021a66b31a3" ..
    "bbb999bdf890c2208220e5c8b9e9727642cc62cc742752dc8d1d2b0e3c02794e" ..
    "702af43c1a5100a00a424c4e3e2481d65a44d2a2921618005b3b48836c006fda" ..
    "05872efba2610a2ed66a2cd3f59a0db78880d0fb7c301718ac938d8e330eab3c" ..
    "b9b12b3794365c11dce48435337f9b3975e6c6"

-- Sm2TiVideoClip / Sm2TiAudioClip <FieldsBlob>: per-clip color/effect state
-- payload (zstd-compressed, protobuf-like TLV inside). Resolve refuses to
-- instantiate a clip on the timeline when this element is empty
-- (`<FieldsBlob/>`) — symptom observed 2026-05-31: import succeeded with
-- correct timeline TC start, but no clip body on tracks. Borrowed verbatim
-- from resolve_authored_single_clip.drp (Strategy 1, same pattern as the
-- other borrowed FieldsBlobs — phase0-findings §K).
--
-- Caveat: the video blob's payload embeds a hard-coded reference to its
-- linked audio clip's DbId ("1235499f-..."). Borrowing means every JVE
-- export carries that dangling pointer. Tolerable for the single-clip
-- spike (Resolve appears to treat broken sync links as non-fatal); the
-- inner-DbId leak is tracked in todo_drt_inner_fieldsblob_uuids.md and
-- will be fixed when we synthesize these blobs from JVE state.
-- Pulled 2026-06-01 from the CURRENT resolve_authored_single_clip.drp (Joe
-- re-exported after adding the clip to TL — the prior values were from an
-- older single-clip reference where the audio half had different DbIds).
local TI_VIDEO_CLIP_FIELDS_BLOB =
    "00000002000000618128b52ffd2079bd0200c206131bd0a539000000000092ec" ..
    "fd54eae496726f22870121025e45919d027777777781824141401a53655bb8b6" ..
    "6cbaaa27326964cf546d8f277a5c269e6c8b985caae86a78731450fc60149330" ..
    "010200196ec4338704"
local TI_AUDIO_CLIP_FIELDS_BLOB =
    "00000002000000528128b52ffd206945020082050f16a037ad013f67370938ea" ..
    "d29636d9df17f845d84cdb298043099c67f29ad65ed444a245a4317983067b44" ..
    "cfa2693ca682d6a684af5ba2bc5057a902030040865bee3b7348"

local function build_clip_element(clip, media, track_type, state)
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
    assert(type(media.native_rate) == "number" and media.native_rate > 0,
        "drt_writer.build_clip_element: media.native_rate required "
        .. "(media file's native fps; drives <MediaFrameRate> and "
        .. "MediaStartTime — independent of the sequence's fps)")
    assert(type(media.file_path) == "string" and media.file_path ~= "",
        "drt_writer.build_clip_element: media.file_path required")
    assert(track_type == "video" or track_type == "audio",
        "drt_writer.build_clip_element: track_type must be 'video' or 'audio', "
        .. "got " .. tostring(track_type))
    assert(type(clip.enabled) == "boolean",
        "drt_writer.build_clip_element: clip.enabled boolean required for "
        .. "clip " .. clip.id .. " — <Flags> carries the disabled bit and "
        .. "omitting it would silently re-enable the clip in Resolve")

    local in_offset = clip.source_in - media.start_tc_frame
    assert(in_offset >= 0, string.format(
        "drt_writer.build_clip_element: clip %s source_in (%d) < media "
        .. "start_tc_frame (%d) — source_in below file TC origin invalid",
        clip.id, clip.source_in, media.start_tc_frame))

    local media_start_seconds = media.start_tc_frame / media.native_rate
    local tag = (track_type == "audio") and "Sm2TiAudioClip" or "Sm2TiVideoClip"
    local is_video = (track_type == "video")

    -- Child order pinned to Resolve's schema. Empty self-closing elements
    -- are still present (Resolve's parser checks for them).
    local parts = {
        text_elem("FieldsBlob",
            is_video and TI_VIDEO_CLIP_FIELDS_BLOB or TI_AUDIO_CLIP_FIELDS_BLOB),
        self_close("PrettyType"),
        text_elem("Name", clip.name),
        -- <Start> is ABSOLUTE project-epoch frames (phase0-findings §B).
        -- JVE's clip.sequence_start is also absolute (sequence.lua:1007,
        -- placement commands store args.playhead which is absolute TC). Same
        -- coordinate system both sides — no conversion.
        text_elem("Start", math.floor(clip.sequence_start)),
        text_elem("Duration", math.floor(clip.duration)),
        self_close("LinkedItemSync"),
        text_elem("WasDisbanded", "false"),
        self_close("MarkersBA"),
        text_elem("UiMemento", "0"),
        -- <Flags> bit 2 = item disabled (live-probed 2026-06-10:
        -- SetClipEnabled(False) + DRT export flips exactly 0 → 2;
        -- drp_importer reads the same bit back via Flags % 4 < 2).
        text_elem("Flags", clip.enabled and "0" or "2"),
        text_elem("PriorityIndex", "0"),
        self_close("EffectFiltersBA"),
        self_close("ImportExportMetadataBA"),
        text_elem("RenderTextEnabled",  is_video and "true"  or "false"),
        text_elem("RenderTextGanged",   is_video and "true"  or "false"),
        text_elem("RenderTextPrefixed", is_video and "true"  or "false"),
        build_in_element(in_offset),
        text_elem("MixedFrameRateAlignment", "0"),
        text_elem("MediaRef",       clip.media_uuid),
        -- Bare integer for integral seconds (Resolve writes "0" not
        -- "0.000000000"); fixed-point otherwise. Matches the byte shape
        -- observed in resolve_authored_single_clip and anamnesis-gold.
        text_elem("MediaStartTime",
            media_start_seconds == math.floor(media_start_seconds)
                and tostring(math.floor(media_start_seconds))
                or string.format("%.9f", media_start_seconds)),
        text_elem("MediaFilePath",  media.file_path),
        self_close("MediaReelNumber"),
        text_elem("MediaFrameRate", enc.encode_le_double(media.native_rate)
                                    .. "0000000000000000"),
        text_elem("MediaTimemapBA",
            build_media_timemap_ba(clip.duration, media.native_rate)),
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
        -- Empirically observed in resolve_authored_single_clip.drp; meaning
        -- not yet decoded but emitting "0" correlated with Resolve refusing
        -- to render the clip in the timeline (only TC start visible). See
        -- todo_drt_current_selector_idx.md.
        parts[#parts + 1] = text_elem("CurrentSelectorIdx", "1083179008")
        parts[#parts + 1] = text_elem("IsPreConformed", "false")
        parts[#parts + 1] = text_elem("PreConformMediaExtents",
            PRECONFORM_MEDIA_EXTENTS)
        parts[#parts + 1] = self_close("MediaMetadata")
        local thumb_dbid = fresh_uuid(0x90, state)
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
            VIRTUAL_AUDIO_TRACK_BA_MONO_A1)
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

local function build_track_element(track, seq_dbid, media_by_uuid, state)
    assert(type(track.clips) == "table",
        "drt_writer.build_track_element: track.clips array required")
    assert(track.type == "video" or track.type == "audio",
        "drt_writer.build_track_element: track.type must be 'video' or "
        .. "'audio', got " .. tostring(track.type))
    local type_value = (track.type == "audio") and 1 or 0
    local track_dbid = fresh_uuid(0x70, state)

    local items = {}
    for _, c in ipairs(track.clips) do
        local media = media_by_uuid[c.media_uuid]
        assert(media, "drt_writer.build_track_element: track clip references "
            .. "unknown media_uuid " .. tostring(c.media_uuid))
        items[#items + 1] = elem("Element",
            build_clip_element(c, media, track.type, state))
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

local function build_seq_container_xml(seq, seq_dbid, container_dbid, state,
                                       media_by_uuid)
    assert(type(seq.tracks) == "table" and #seq.tracks >= 1,
        "drt_writer.build_seq_container_xml: sequence.tracks non-empty array")

    local video_tracks, audio_tracks = {}, {}
    for _, t in ipairs(seq.tracks) do
        local rendered = build_track_element(t, seq_dbid, media_by_uuid, state)
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

-- ─── Sm2MpVideoClip — kitchen-sink borrowed, per-media substituted ──────────
--
-- See phase0-findings.md §K. Without these media-pool items the timeline
-- clips' <MediaRef>UUID</MediaRef> pointers dangle and Resolve drops every
-- clip on import (silently — no error dialog; just an empty timeline).
--
-- Substitutions (the only ones we vary today):
--   • outer Sm2MpVideoClip @DbId  → media.file_uuid (matches MediaRef)
--   • <MpFolder> back-ref         → minted mp_folder DbId
--   • <UniqueMediaPoolItemId>     → fresh-minted UUID
--   • <Name>                      → basename(media.file_path) if different
--
-- Everything else (FieldsBlob zstd payloads, embedded BtVideoInfo /
-- BtAudioInfo blobs with hard-coded path/rate/resolution) is borrowed
-- verbatim — see §K3 for consequences (payload's media must use A005's
-- baked-in path for this spike, full payload-driven authoring deferred
-- per §K4).

local function basename(path)
    local b = path:match("([^/]+)$")
    assert(b, "drt_writer.basename: cannot extract basename from '"
        .. tostring(path) .. "' — caller passed an empty or all-slash path")
    return b
end

-- The full_reference_mp_video_clip_a005.xml template carries A005's
-- BtVideoInfo with a baked Time blob (NumFrames=108, FrameRate=23.976,
-- UniqueId=85fba73b-...). We rewrite the Time blob per payload via
-- exporters.drt_binary.encode_bt_video_time so JVE parses back the
-- correct media duration/rate (test_drt_writer_file_roundtrip).
--
-- Other A005-baked fields not yet rewritten (BtVideoInfo/Clip path,
-- Geometry/Resolution, BtAudioInfo/TracksBA, outer FieldsBlob/
-- MediaExtents) are invisible to JVE's parser but visible to Resolve.
-- All tracked in todo_drt_writer_resolve_canonical_shape.md with the
-- per-field status updated after the Time-blob rewrite.

local TIME_ELEM_PATTERN = "<Time>([0-9a-f]+)</Time>"

local function build_media_pool_video_item(media, dbids, state)
    assert(type(media.file_uuid) == "string" and media.file_uuid ~= "",
        "drt_writer.build_media_pool_video_item: media.file_uuid required")
    assert(type(media.file_path) == "string" and media.file_path ~= "",
        "drt_writer.build_media_pool_video_item: media.file_path required")
    local ext = media.file_path:match("%.([^.]+)$")
    assert(ext == "mp4" or ext == "mov",
        "drt_writer.build_media_pool_video_item: only .mp4/.mov media "
        .. "supported by this writer pass (phase0-findings §K3); got '"
        .. tostring(ext) .. "' for " .. media.file_path
        .. ". Audio (Sm2MpAudioClip) deferred per §K4.")
    assert(type(media.native_rate) == "number" and media.native_rate > 0,
        "drt_writer.build_media_pool_video_item: media.native_rate "
        .. "required (positive number); got " .. tostring(media.native_rate))
    assert(type(media.duration_frames) == "number"
        and media.duration_frames > 0 and media.duration_frames % 1 == 0,
        "drt_writer.build_media_pool_video_item: media.duration_frames "
        .. "required (positive integer); got " .. tostring(media.duration_frames))

    local tpl = load_template("full_reference_mp_video_clip_a005.xml")
    tpl = plain_gsub_required(tpl,
        A005_TEMPLATE_DBID, media.file_uuid)
    tpl = plain_gsub_required(tpl,
        A005_TEMPLATE_MP_FOLDER_BACKREF, dbids.mp_folder)
    tpl = plain_gsub_required(tpl,
        A005_TEMPLATE_UNIQUE_MP_ITEM_ID, fresh_uuid(0xa0, state))

    -- Rewrite BtVideoInfo/Time blob from payload. Per-media UniqueId is
    -- minted so two media in one DRT can't collide on the Time blob's
    -- own UUID field (decoded back by drp_binary.decode_bt_video_time).
    local new_time_hex = enc.encode_bt_video_time({
        num_frames = media.duration_frames,
        frame_rate = media.native_rate,
        unique_id  = fresh_uuid(0xa1, state),
    })
    local replaced
    tpl, replaced = tpl:gsub(TIME_ELEM_PATTERN,
        "<Time>" .. new_time_hex .. "</Time>", 1)
    assert(replaced == 1,
        "drt_writer.build_media_pool_video_item: failed to substitute "
        .. "<Time> blob in A005 template — template structure changed?")

    local name = basename(media.file_path)
    if name ~= A005_TEMPLATE_NAME then
        tpl = plain_gsub_required(tpl, A005_TEMPLATE_NAME, name)
    end

    -- Rewrite the BtVideoInfo/BtAudioInfo <Clip> blobs from the payload.
    -- These carry the directory/filename Resolve binds media by on import
    -- (live-dissected 2026-06-10: the template's canned blobs froze a
    -- 2024 host path, so every import elsewhere came in silently offline
    -- — srcS=None — which read_timeline then classifies non_media,
    -- breaking position/content matching). Date string + codec are
    -- template residue scoped by this writer's a005-class media gate
    -- (same posture as the opaque varint tail — see
    -- drt_binary.encode_bt_clip_blob).
    local directory = media.file_path:match("^(.*)/[^/]+$")
    assert(directory and directory ~= "", string.format(
        "drt_writer.build_media_pool_video_item: media.file_path must be "
        .. "absolute with a directory component, got %q", media.file_path))
    local clip_common = {
        directory = directory,
        filename  = name,
        date      = A005_TEMPLATE_CLIP_DATE,
    }
    local video_blob = enc.encode_bt_clip_blob({
        directory = clip_common.directory,
        filename  = clip_common.filename,
        date      = clip_common.date,
        codec     = "avc1",
        clip_name = name,
        clip_uuid = fresh_uuid(0xa2, state),
    })
    local audio_blob = enc.encode_bt_clip_blob({
        directory = clip_common.directory,
        filename  = clip_common.filename,
        date      = clip_common.date,
        codec     = "AAC",
    })
    local clip_blobs = { video_blob, audio_blob }
    local clip_i = 0
    local clips_replaced
    tpl, clips_replaced = tpl:gsub("<Clip>[0-9a-f]+</Clip>", function()
        clip_i = clip_i + 1
        return "<Clip>" .. clip_blobs[clip_i] .. "</Clip>"
    end)
    assert(clips_replaced == 2, string.format(
        "drt_writer.build_media_pool_video_item: expected exactly 2 "
        .. "<Clip> blobs in the A005 template (BtVideoInfo + BtAudioInfo),"
        .. " substituted %d — template structure changed?", clips_replaced))

    return "  <Element>\n" .. tpl .. "  </Element>\n"
end

-- Walk every clip on every track of a sequence and return its overall
-- timeline-frame extent: earliest sequence_start and latest end (= start +
-- duration). Drives MediaExtents — see anamnesis-gold dissection
-- (phase0-findings.md §K). Asserts on an empty sequence rather than
-- returning sentinel zeros: an empty timeline shouldn't reach the canonical-
-- writer path in the first place (T008 has clips by construction).
local function compute_seq_extents_frames(seq)
    assert(type(seq.tracks) == "table" and #seq.tracks > 0,
        "drt_writer.compute_seq_extents_frames: seq.tracks required")
    local earliest, latest
    for _, track in ipairs(seq.tracks) do
        assert(type(track.clips) == "table",
            "drt_writer.compute_seq_extents_frames: track.clips required "
            .. "(empty table OK, nil not OK)")
        for _, clip in ipairs(track.clips) do
            assert(type(clip.sequence_start) == "number"
                and type(clip.duration) == "number",
                "drt_writer.compute_seq_extents_frames: "
                .. "clip.sequence_start + clip.duration required")
            local s = clip.sequence_start
            local e = s + clip.duration
            if not earliest or s < earliest then earliest = s end
            if not latest   or e > latest   then latest   = e end
        end
    end
    assert(earliest and latest,
        "drt_writer.compute_seq_extents_frames: no clips in sequence "
        .. tostring(seq.name) .. " — MediaExtents undefined")
    return earliest, latest
end

-- ─── project.xml + MpFolder.xml — template-substitute ───────────────────────
--
-- Both files are loaded verbatim from drt_canonical/ and have their reference
-- DbIds + reference names swapped for freshly minted ones / payload values.

-- One <Element><Sm2TiItemLockableBlob>…</Sm2TiItemLockableBlob></Element>
-- carrying the identity marker for `clip_id`. Mirrors the template's
-- existing <Sm2MediaPoolLockableBlob> child shape: FieldsBlob, BlobOwner,
-- DbSavedTime. <BlobOwner> = clip_id = the Sm2Ti DbId we emit at
-- build_clip_element (drt_writer.lua:509), so drp_importer's
-- parse_resolve_markers links the marker to the right clip on re-import,
-- and for a fresh export `Sm2Ti DbId == live GetUniqueId()` so the
-- helper-side GetMarkerByCustomData finds the same identity marker via
-- the live API (inbound-findings.md §2 + §5).
local function build_identity_marker_element(clip_id, item_dbid)
    local fields_blob_hex = enc.encode_clip_marker_fields_blob({
        identity_marker.for_clip(clip_id),
    })
    return elem("Element", elem("Sm2TiItemLockableBlob", table.concat({
        text_elem("FieldsBlob", fields_blob_hex),
        text_elem("BlobOwner", clip_id),
        text_elem("DbSavedTime", "0"),
    }), {DbId = item_dbid}))
end

-- All clip ids in payload-order across the sequence's tracks. The DRT
-- writer is single-sequence by design (spec 023 T008 scope) so there's
-- no cross-sequence dedup concern; within one sequence each clip.id is
-- unique by JVE's model invariant (clips.id PRIMARY KEY).
local function collect_clip_ids(seq)
    assert(type(seq.tracks) == "table",
        "drt_writer.collect_clip_ids: sequence.tracks required")
    local ids = {}
    for _, track in ipairs(seq.tracks) do
        assert(type(track.clips) == "table",
            "drt_writer.collect_clip_ids: track.clips array required "
            .. "(track.type=" .. tostring(track.type) .. ")")
        for _, c in ipairs(track.clips) do
            assert(type(c.id) == "string" and c.id ~= "",
                "drt_writer.collect_clip_ids: every clip needs an id "
                .. "(identity marker carrier — FR-002)")
            ids[#ids + 1] = c.id
        end
    end
    return ids
end

local function build_project_xml(template, payload, dbids, state)
    -- Required scalars (template drift = silent leak of reference content).
    -- Order: longer `.Cfg` form replaces first because it contains
    -- the shorter REFERENCE_PROJECT_NAME as a prefix.
    template = plain_gsub_required(template,
        REFERENCE_PROJECT_CFG, payload.project.name .. ".Cfg")
    template = plain_gsub_required(template,
        REFERENCE_PROJECT_NAME, payload.project.name)
    -- Inject one identity-marker Sm2TiItemLockableBlob per clip into the
    -- template's <LocableBlobSet>. This is the file-level carrier of the
    -- live-API identity (spec.md:116 — "DRT carries `clip.id` via both
    -- carriers"). The Sm2Ti DbId carrier was already emitted at
    -- build_clip_element:509 via DbId=clip.id; this completes the pair.
    -- After Resolve imports the DRT, GetMarkerByCustomData(clip_id)
    -- returns the marker → live-API identity is anchored without
    -- requiring the helper's post-import stamp pass to mutate state.
    local marker_elements = {}
    for _, clip_id in ipairs(collect_clip_ids(payload.sequence)) do
        marker_elements[#marker_elements + 1] =
            build_identity_marker_element(clip_id, fresh_uuid(0x06, state))
    end
    if #marker_elements > 0 then
        template = plain_gsub_required(template,
            "</LocableBlobSet>",
            table.concat(marker_elements) .. "</LocableBlobSet>")
    end
    return sweep_reference_dbids(template, dbids)
end

local function build_mp_folder_xml(template, payload, seq, dbids, state)
    assert(type(payload.media_refs) == "table",
        "drt_writer.build_mp_folder_xml: payload.media_refs required")
    assert(type(seq.width) == "number" and seq.width > 0,
        "drt_writer.build_mp_folder_xml: sequence.width required (positive)")
    assert(type(seq.height) == "number" and seq.height > 0,
        "drt_writer.build_mp_folder_xml: sequence.height required (positive)")
    -- Anchor the sequence-name substitution to <Name>...</Name> so it can't
    -- accidentally match a hex sequence inside any FieldsBlob. Both
    -- `JVE_T008_ref_seq` occurrences in the template are <Name> children
    -- (one in the Sm2Sequence, one in the Sm2MpTimelineClip wrapper);
    -- plain_gsub_required uses string.gsub under the hood and replaces all.
    template = plain_gsub_required(template,
        "<Name>" .. REFERENCE_SEQUENCE_NAME .. "</Name>",
        "<Name>" .. seq.name .. "</Name>")
    -- The reference's Sm2Sequence carries a FrameRate hex blob hard-coded to
    -- 24.0 (the empty reference's project rate) and Resolution hard-coded to
    -- 1920×1080. Both substituted from payload.
    local ref_frame_rate_hex =
        "00000000000038400000000000000000"   -- LE double 24.0 + 0
    local ref_resolution_hex =
        "00000000000007800000000000000438"   -- BE int64 1920 + 1080
    local our_frame_rate_hex = enc.encode_le_double(seq.fps)
        .. "0000000000000000"
    local our_resolution_hex =
        string.format("%016x%016x", seq.width, seq.height)
    template = plain_gsub_required(template,
        ref_frame_rate_hex, our_frame_rate_hex)
    template = plain_gsub_required(template,
        ref_resolution_hex, our_resolution_hex)

    -- MediaExtents: two LE doubles [earliest_real_sec, latest_real_sec] in
    -- absolute project-epoch seconds (per anamnesis-gold dissection — see
    -- phase0-findings.md §K). The empty reference encodes (3600.0, 0.0)
    -- because its timeline has no clips; if we don't substitute, the empty-
    -- content extent leaks into JVE-authored DRPs and Resolve treats the
    -- sequence as having no media → empty timeline.
    -- compute_seq_extents_frames returns absolute project-epoch frames
    -- (clip.sequence_start is absolute throughout JVE; see sequence.lua:1007).
    local earliest_frame, latest_frame = compute_seq_extents_frames(seq)
    local earliest_sec = earliest_frame / seq.fps
    local latest_sec   = latest_frame   / seq.fps
    local ref_extents_hex =
        "000000000020ac400000000000000000"   -- LE doubles 3600.0 + 0.0
    local our_extents_hex =
        enc.encode_le_double(earliest_sec)
        .. enc.encode_le_double(latest_sec)
    template = plain_gsub_required(template,
        ref_extents_hex, our_extents_hex)

    -- Replace the empty-reference Sm2MpTimelineClip FieldsBlob with a
    -- borrowed-from-fixture version (one wrapper per exported timeline;
    -- clip count is independent — handled by per-clip Sm2TiVideoClip
    -- synthesis in SeqContainer/*.xml). The empty-ref blob embeds
    -- dangling MediaRef pointers to its own slot UUID; after sweep,
    -- those dangle and Resolve refuses to render the timeline's clip body.
    template = plain_gsub_required(template,
        EMPTY_REF_MP_TIMELINE_CLIP_FIELDS_BLOB,
        SM2_MP_TIMELINE_CLIP_FIELDS_BLOB_BORROWED)

    template = sweep_reference_dbids(template, dbids)

    -- Inject one Sm2MpVideoClip per media_ref. Without these, timeline
    -- clips' <MediaRef> pointers dangle → Resolve drops the clips → empty
    -- timeline. Substitutions happen AFTER the DbId sweep so the items
    -- carry payload media UUIDs, not freshly-minted ones.
    local items = {}
    for _, m in ipairs(payload.media_refs) do
        items[#items + 1] = build_media_pool_video_item(m, dbids, state)
    end
    template = plain_gsub_required(template,
        "</MediaVec>", table.concat(items) .. " </MediaVec>")

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

--- Author a DRP archive at out_path from a JVE payload.
---
--- SCOPE (spec 023 T008 spike): single-sequence; media must be
--- `.mp4`/`.mov` matching the A005 baked-in template (native_rate ≈
--- 23.976 fps, duration 108 frames). The Mp video item template
--- carries A005's BtVideoInfo/BtAudioInfo verbatim — non-A005 media
--- would corrupt the descriptor. See `phase0-findings.md §K3/K4` +
--- `todo_drt_writer_resolve_canonical_shape.md` for the synthesize-
--- from-payload follow-up that lifts these constraints. Asserts at
--- `build_media_pool_video_item` enforce the constraints; this
--- docstring documents them so callers know up-front.
---
--- @param out_path string  absolute path to write
--- @param payload  table {
---     project    = { name, fps },
---     media_refs = { { file_uuid, file_path, duration_frames,
---                       start_tc_frame, native_rate }, ... },
---     sequence   = { name, fps, width, height,
---                    tracks = { { type="video"|"audio",
---                                 clips = { { id, media_uuid,
---                                             sequence_start, duration,
---                                             source_in, name }, ... }
---                               }, ... }
---                  }
---   }
--- The writer is single-sequence by design (spec 023 T008 scope; FR-002 +
--- phase0-findings §K3). Multi-sequence DRTs would require a second pass.
--- All numeric fields are integers in their native unit:
---   clip.sequence_start, clip.duration   timeline frames at seq.fps
---   clip.source_in                       absolute project-epoch frames
---   media.start_tc_frame                 media's TC origin (native frames)
--- Authors an A005-compatible DRT.
--- QUARANTINE: This is a spike specifically for 23.976fps mp4/mov media.
--- (See drt_writer.lua top-level comment).
function M.author_a005_compatible(out_path, payload)
    assert(type(out_path) == "string" and out_path ~= "",
        "drt_writer.author: out_path required")
    -- ...
    for _, m in ipairs(payload.media_refs) do
        -- Rule 2.13 quarantine gate (review item #23)
        assert(math.abs(m.native_rate - 24000/1001) < 1e-4,
            "drt_writer: author_a005_compatible requires 23.976fps media")
        local ext = m.file_path:match("%.([^%.]+)$")
        assert(ext == "mp4" or ext == "mov",
            "drt_writer: author_a005_compatible requires mp4/mov media")
    end
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
    assert(type(payload.sequence) == "table",
        "drt_writer.author: payload.sequence (singular) required. The "
        .. "writer is single-sequence by design — see FR-002 + spec 023 "
        .. "T008 scope; multi-sequence DRTs are out of scope.")
    local seq = payload.sequence
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

    -- Seed the UUID counter from a hash of out_path: distinct exports get
    -- distinct minted DbIds (no cross-archive collision in the same Resolve
    -- instance) while same path + same payload still produces byte-identical
    -- output (reproducibility for verification / diff regression).
    -- Rule 2.13: Counter is now local to this call, making the writer
    -- re-entrant (review item #18).
    local state = {
        uuid_counter = hash_uint24(out_path)
    }

    local dbids = {}
    -- Rule 2.5: Use canonical slot map to satisfy DRY (review item #19).
    for key, slot in pairs(DBID_SLOTS) do
        dbids[key] = fresh_uuid(slot.seed, state)
    end

    -- Load templates and apply substitutions.
    local project_xml = build_project_xml(
        load_template("empty_reference_project.xml"), payload, dbids, state)
    local mp_folder_xml = build_mp_folder_xml(
        load_template("empty_reference_mp_folder.xml"), payload, seq, dbids, state)
    local gallery_xml = load_template("empty_reference_gallery.xml")
    local seq_container_xml = build_seq_container_xml(
        seq, dbids.sequence, dbids.seq_container, state, media_by_uuid)

    -- Fresh unique stage dir per call so concurrent authors (parallel test
    -- processes, parallel Claude sessions) don't collide on /tmp paths.
    -- mktemp -d returns a freshly-minted empty directory; no rm-first needed.
    local h = assert(io.popen("mktemp -d -t jve_drt_stage.XXXXXX"),
        "drt_writer.author: mktemp -d failed")
    local stage = h:read("*l")
    h:close()
    assert(stage and stage ~= "",
        "drt_writer.author: mktemp -d returned empty path")
    local mp_dir = stage .. "/MediaPool/Master"
    local ok_mp, mp_err = qt_fs_mkdir_p(mp_dir)
    assert(ok_mp, "drt_writer.author: mkdir " .. mp_dir .. " failed: " .. tostring(mp_err))
    local sc_dir = stage .. "/SeqContainer"
    local ok_sc, sc_err = qt_fs_mkdir_p(sc_dir)
    assert(ok_sc, "drt_writer.author: mkdir " .. sc_dir .. " failed: " .. tostring(sc_err))

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

    return {
        path = out_path,
        stage = stage,
        dbids = dbids,
        emit_order = M.compute_emit_order(seq),
    }
end

--- The canonical (clip_id, track_type, track_index, record_start) list
--- in the order the writer emits clips into the DRT.
---
--- Single source of truth for the position-match key the helper uses on
--- the other side of import_timeline (helper-protocol §import_timeline:
--- helper looks up live items by `(track_type, track_index,
--- record_start)`). SendToResolve used to re-derive this in its own
--- `build_clip_positions`, which had to mirror this partition by hand —
--- a writer regression that changed emit order would have silently
--- broken every position-match.
---
--- Track index assignment: VideoTrackVec then AudioTrackVec, preserving
--- JVE order within each type — matches `build_seq_container_xml`'s
--- partition above.
function M.compute_emit_order(seq)
    assert(type(seq) == "table" and type(seq.tracks) == "table",
        "drt_writer.compute_emit_order: seq.tracks (array) required")
    local order = {}
    local video_idx, audio_idx = 0, 0
    for _, track in ipairs(seq.tracks) do
        assert(track.type == "video" or track.type == "audio",
            "drt_writer.compute_emit_order: track.type must be 'video' "
            .. "or 'audio', got " .. tostring(track.type))
        local track_index
        if track.type == "video" then
            video_idx = video_idx + 1
            track_index = video_idx
        else
            audio_idx = audio_idx + 1
            track_index = audio_idx
        end
        for _, clip in ipairs(track.clips) do
            order[#order + 1] = {
                clip_id      = clip.id,
                track_type   = track.type,
                track_index  = track_index,
                record_start = clip.sequence_start,
            }
        end
    end
    return order
end

return M
