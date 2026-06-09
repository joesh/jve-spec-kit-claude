require("test_env")

-- =============================================================================
-- DRT writer — Sm2Sequence.FieldsBlob.SeqRef + project.xml.Sm2MediaPool.
-- FieldsBlob.RootFolderRef must reference the freshly-minted seq_container and
-- mp_folder DbIds, NOT the seed UUIDs from DBID_SLOTS.
--
-- DOMAIN contract (T008 bisection 2026-06-01):
--   Resolve looks at SM_Project -> Sm2MediaPool -> RootFolderRef to find the
--   media-pool root, and at Sm2Sequence -> SeqRef to find the sequence
--   container XML. If either reference points to a UUID that doesn't exist
--   in the archive, Resolve loads the archive but renders no clip body in
--   the timeline (the TC start position is still correct, but the clip is
--   invisible). The seed UUIDs `09a19a21-...` (seq_container slot) and
--   `6cf9979b-...` (mp_folder slot) appear inside FieldsBlobs as UTF-16BE-
--   encoded hex (e.g. ASCII "09a19a21" → `00300039006100310039006100320031`)
--   and were missed by an earlier ASCII-only sweep, which kept the seed
--   intact in the output → unresolvable cross-reference → no render.
-- =============================================================================

local writer  = require("exporters.drt_writer")
local fixture = require("synthetic.helpers.drt_spike_fixture")

local SEED_SEQ_CONTAINER = "09a19a21-d424-41ef-945f-d598b9d4a4ac"
local SEED_MP_FOLDER     = "6cf9979b-3e45-4c7c-874f-4162010c5f8e"

local function utf16be_hex(uuid)
    local out = {}
    for i = 1, #uuid do
        out[#out+1] = string.format("00%02x", string.byte(uuid, i))
    end
    return table.concat(out)
end

local function check(cond, msg)
    assert(cond, "drt_writer fields-blob UUID sweep FAILED: " .. tostring(msg))
end

local OUT = fixture.out_path("test_drt_writer_fields_blob_uuid_sweep")
os.remove(OUT)
writer.author_a005_compatible(OUT, fixture.build_a005_payload())

local mpf = fixture.unzip_member(OUT, "MediaPool/Master/MpFolder.xml")
local pj  = fixture.unzip_member(OUT, "project.xml")

-- Seed UUIDs must NOT appear anywhere — neither ASCII nor UTF-16BE form.
for _, archive in ipairs({{"MpFolder.xml", mpf}, {"project.xml", pj}}) do
    local name, content = archive[1], archive[2]
    for _, seed in ipairs({SEED_SEQ_CONTAINER, SEED_MP_FOLDER}) do
        check(not content:find(seed, 1, true), string.format(
            "%s contains seed UUID %s in ASCII form — sweep missed it",
            name, seed))
        check(not content:find(utf16be_hex(seed), 1, true), string.format(
            "%s contains seed UUID %s in UTF-16BE-hex form — sweep "
            .. "missed the FieldsBlob encoding", name, seed))
    end
end

-- Positive check: SeqRef in MpFolder must equal the seq_container DbId,
-- and RootFolderRef in project.xml must equal the mp_folder DbId.
-- Both DbIds are observable as the <Sm2SequenceContainer> XML attribute and
-- <Sm2MpFolder> XML attribute in their respective files.
-- SeqRef is inside FieldsBlob hex, not as an element — derive its UTF-16BE form.
local seq_container_xml = fixture.unzip_member(OUT, "SeqContainer/*.xml")
local seq_container_dbid_from_seq =
    seq_container_xml:match('<Sm2SequenceContainer DbId="([^"]+)"')
check(seq_container_dbid_from_seq, "no Sm2SequenceContainer in SeqContainer")
local mp_folder_dbid = mpf:match('<Sm2MpFolder DbId="([^"]+)"')
check(mp_folder_dbid, "no Sm2MpFolder DbId")

-- Both minted DbIds (as UTF-16BE hex) MUST appear inside the FieldsBlobs.
local seq_container_utf16 = utf16be_hex(seq_container_dbid_from_seq)
local mp_folder_utf16     = utf16be_hex(mp_folder_dbid)
check(mpf:find(seq_container_utf16, 1, true),
    "MpFolder Sm2Sequence FieldsBlob does NOT contain UTF-16BE-encoded "
    .. "minted seq_container DbId " .. seq_container_dbid_from_seq
    .. " — SeqRef not retargeted, Resolve will fail to resolve the "
    .. "sequence container")
check(pj:find(mp_folder_utf16, 1, true),
    "project.xml Sm2MediaPool FieldsBlob does NOT contain UTF-16BE-"
    .. "encoded minted mp_folder DbId " .. mp_folder_dbid
    .. " — RootFolderRef not retargeted, Resolve will fail to load "
    .. "the media pool root")

os.remove(OUT)
print("✅ test_drt_writer_fields_blob_uuid_sweep.lua passed")
