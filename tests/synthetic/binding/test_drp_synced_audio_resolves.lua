#!/usr/bin/env luajit
-- Regression: every dual-system synced-audio reference in a DRP must resolve
-- to a pooled media file after import.
--
-- Domain: Resolve pools the SAME physical WAV under multiple MediaPoolItem ids
-- — one per sync relationship (a field recorder track synced to several camera
-- clips appears as several pool entries, same path, different ids). All of
-- those ids name one file, hence one media. A camera clip's sync linkage
-- references whichever pool id matches its own sync source; if the importer
-- registers the file under only one of its ids, every camera that referenced a
-- different id loses its synced audio (and the importer warns "synced audio
-- pool_id … not in media_by_uuid"). So: every synced_audio_pool_id stamped on
-- a video pool item MUST resolve to a materialized media entry.
--
-- Before the fix, ~371 distinct synced WAV ids in `anamnesis joe edit.drp`
-- were unresolvable because the file was registered under only its first id.
-- Run via: jve --test <abs path>.
local test_env = require("test_env")
local drp = require("importers.drp_importer")

print("=== test_drp_synced_audio_resolves.lua ===")

local fixture = test_env.require_fixture("tests/fixtures/resolve/anamnesis joe edit.drp")
local result = drp.parse_drp_file(fixture)
assert(result.success, "parse failed: " .. tostring(result.error))

-- The set of pool ids that resolve to a materialized media entry: an entry's
-- own file_uuid plus every alias id it carries for the same physical file.
local resolvable = {}
for _, mi in pairs(result.media_items) do
    if mi.file_uuid and mi.file_uuid ~= "" then resolvable[mi.file_uuid] = true end
    for alias in pairs(mi.alt_uuids or {}) do resolvable[alias] = true end
end

-- Every synced_audio_pool_id stamped on a video pool item must resolve.
local total, unresolved = 0, {}
for _, mi in pairs(result.media_items) do
    for _, pool_id in ipairs(mi.synced_audio_pool_ids or {}) do
        total = total + 1
        if not resolvable[pool_id] then
            unresolved[#unresolved + 1] = pool_id
        end
    end
end

print(string.format("  synced_audio_pool_ids stamped: %d ; unresolved: %d",
    total, #unresolved))
assert(total > 0, "fixture should stamp synced_audio_pool_ids (dual-system edit)")

if #unresolved > 0 then
    local sample = {}
    for i = 1, math.min(5, #unresolved) do sample[i] = unresolved[i] end
    error(string.format(
        "%d synced-audio references do not resolve to a pooled media file "
        .. "(same WAV registered under only one of its pool ids). e.g. %s",
        #unresolved, table.concat(sample, ", ")))
end

print("  ✓ every synced-audio reference resolves to a pooled media file")
print("\n✅ test_drp_synced_audio_resolves.lua passed")
