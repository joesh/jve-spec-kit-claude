require("test_env")

-- =============================================================================
-- DRT writer — distinct exports mint distinct slot DbIds.
--
-- Authoring two archives at different out_paths with otherwise-identical
-- payloads must mint disjoint UUIDs for every Resolve-internal slot
-- (SM_Project, mp_folder, sequence, seq_container, …). If two such archives
-- are imported into the same Resolve instance with colliding project-level
-- DbIds, the second is rejected as a duplicate of the first.
--
-- Reproducibility: same out_path + same payload still produces the SAME
-- minted UUIDs — checked by authoring twice to path A and comparing.
-- =============================================================================

local writer  = require("exporters.drt_writer")
local fixture = require("helpers.drt_spike_fixture")

local function check(cond, msg)
    assert(cond, "DbId uniqueness FAILED: " .. tostring(msg))
end

local PATH_A = fixture.out_path("dbid_uniq_A")
local PATH_B = fixture.out_path("dbid_uniq_B")

os.remove(PATH_A); os.remove(PATH_B)

local result_a1 = writer.author_a005_compatible(PATH_A, fixture.build_a005_payload())
local result_b  = writer.author_a005_compatible(PATH_B, fixture.build_a005_payload())
local result_a2 = writer.author_a005_compatible(PATH_A, fixture.build_a005_payload())

local slot_count = 0
local collisions = {}
for slot, uuid_a in pairs(result_a1.dbids) do
    slot_count = slot_count + 1
    if result_b.dbids[slot] == uuid_a then
        collisions[#collisions + 1] = slot .. "=" .. uuid_a
    end
end

check(slot_count > 0, "no slots in result.dbids — writer changed shape?")
check(#collisions == 0, string.format(
    "out of %d slots, %d minted the same UUID across distinct exports: %s. "
    .. "Cause: _uuid_counter resets to a constant each author() call, so "
    .. "same seed_byte → same UUID. Resolve will reject the second import "
    .. "as a duplicate.",
    slot_count, #collisions,
    table.concat(collisions, ", ", 1, math.min(3, #collisions))))

-- Reproducibility: same out_path + same payload → byte-identical DbIds.
local repro_misses = {}
for slot, uuid_a1 in pairs(result_a1.dbids) do
    if result_a2.dbids[slot] ~= uuid_a1 then
        repro_misses[#repro_misses + 1] = string.format(
            "%s: %s vs %s", slot, uuid_a1, result_a2.dbids[slot])
    end
end
check(#repro_misses == 0, string.format(
    "two authors to the SAME path produced different DbIds for %d slots: "
    .. "%s. Same input must produce byte-identical output for diff/verify.",
    #repro_misses,
    table.concat(repro_misses, "; ", 1, math.min(3, #repro_misses))))

-- Per-clip thumbnail DbIds (Sm2TiVideoClip > Thumbnail > BtThumnail @DbId)
-- are minted fresh per clip and must also differ across distinct exports.
-- Resolve uses thumbnail DbIds as cache keys; colliding ones across two
-- imported archives in the same project would alias the second archive's
-- thumbnails onto the first.
local function collect_thumb_dbids(xml)
    local out = {}
    for d in xml:gmatch('<BtThumnail DbId="([^"]+)"') do out[#out + 1] = d end
    return out
end
-- Re-author the two distinct paths and compare freshly to avoid relying on
-- prior file contents (the earlier authors already cleaned up).
os.remove(PATH_A); os.remove(PATH_B)
writer.author_a005_compatible(PATH_A, fixture.build_a005_payload())
writer.author_a005_compatible(PATH_B, fixture.build_a005_payload())
local thumbs_a = collect_thumb_dbids(fixture.unzip_member(PATH_A, "SeqContainer/*.xml"))
local thumbs_b = collect_thumb_dbids(fixture.unzip_member(PATH_B, "SeqContainer/*.xml"))
check(#thumbs_a > 0,
    "no <BtThumnail DbId=...> found in PATH_A SeqContainer; writer "
    .. "may have stopped emitting per-clip thumbnail slots")
check(#thumbs_a == #thumbs_b, string.format(
    "PATH_A had %d BtThumnail DbIds, PATH_B had %d — same payload should "
    .. "produce same count", #thumbs_a, #thumbs_b))
local thumb_set_a = {}
for _, d in ipairs(thumbs_a) do thumb_set_a[d] = true end
local thumb_collisions = {}
for _, d in ipairs(thumbs_b) do
    if thumb_set_a[d] then thumb_collisions[#thumb_collisions + 1] = d end
end
check(#thumb_collisions == 0, string.format(
    "%d per-clip thumbnail DbIds collided across distinct exports: %s. "
    .. "Resolve uses these as cache keys; collision aliases the second "
    .. "archive's clip thumbnails onto the first.", #thumb_collisions,
    table.concat(thumb_collisions, ", ", 1, math.min(3, #thumb_collisions))))

os.remove(PATH_A); os.remove(PATH_B)

print("✅ test_drt_writer_dbid_uniqueness.lua passed")
