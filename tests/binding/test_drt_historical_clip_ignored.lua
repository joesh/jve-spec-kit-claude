#!/usr/bin/env luajit

-- Regression: Resolve embeds <OriginalClip> history blocks inside timelines
-- to record a clip's previous state after a replace/relink. Two invariants:
--
--   (1) The raw-XML media catch-all must NOT create phantom media entries
--       from these history blocks — they record past state, not content the
--       timeline plays.
--
--   (2) The substitution history itself must be PRESERVED as metadata on
--       the parent (active) clip, so downstream consumers (Inspector,
--       relink fallback, history view) can surface it.
--
-- The gold DRT has a single <OriginalClip> block: the Render.mov on track
-- V2 was substituted from D:\Reshoots\IMG_3270.MOV.

require('test_env')

local drp_importer = require("importers.drp_importer")

local function fail(msg)
    io.stderr:write(msg .. "\n")
    os.exit(1)
end

local fixture = "/Users/joe/Local/jve-spec-kit-claude/tests/fixtures/media/anamnesis/"
    .. "2026-02-28-anamnesis joe edit-mm/"
    .. "2026-02-28-anamnesis-GOLD-MASTER-CANDIDATE.drt"

local r = drp_importer.parse_drp_file(fixture)
if not r.success then fail("parse failed: " .. tostring(r.error)) end

-- Invariant 1: no phantom media_item for the historical Windows path.
local phantom_path = [[D:\Reshoots\IMG_3270.MOV]]
for key, mi in pairs(r.media_items or {}) do
    if mi.file_path == phantom_path or key == phantom_path then
        fail(string.format(
            "phantom media_item present for historical <OriginalClip> path: %s "
            .. "(duration=%s, frame_rate=%s) — Pass 4 is harvesting history blocks",
            phantom_path, tostring(mi.duration), tostring(mi.frame_rate)))
    end
end

-- Invariant 2: real IMG_3270.MOV media (active timeline references) still
-- present with valid metadata.
local found_real = false
for _, mi in pairs(r.media_items or {}) do
    if (mi.name or "") == "IMG_3270.MOV"
       and mi.file_path ~= phantom_path
       and (mi.duration or 0) > 0 then
        found_real = true
        break
    end
end
if not found_real then
    fail("no real IMG_3270.MOV media_item with non-zero duration — fix over-reached")
end

-- Invariant 3: the active clip that was substituted carries the
-- original-clip metadata.  Find the Render.mov clip on the gold timeline.
local active_with_history = nil
for _, tl in ipairs(r.timelines or {}) do
    for _, track in ipairs(tl.tracks or {}) do
        for _, clip in ipairs(track.clips or {}) do
            if (clip.name or ""):find("IMG_3270.MOV Render", 1, true)
               and clip.original_clip then
                active_with_history = clip
                break
            end
        end
    end
end

if not active_with_history then
    fail("active Render.mov clip has no original_clip metadata — "
        .. "substitution history was lost during parse")
end

local orig = active_with_history.original_clip
if (orig.file_path or "") ~= phantom_path then
    fail(string.format(
        "original_clip.file_path = %q, expected %q",
        tostring(orig.file_path), phantom_path))
end
if (orig.name or "") ~= "IMG_3270.MOV" then
    fail("original_clip.name = " .. tostring(orig.name) .. ", expected IMG_3270.MOV")
end

-- Invariant 4: the substitution history survives through import_into_project
-- into the DB as a property row on the saved clip. If this fails, downstream
-- consumers (Inspector, relink) can't see it — data is lost on persist.
local database = require("core.database")
local TEST_DB = "/tmp/jve/test_drt_historical_clip_ignored.db"
os.remove(TEST_DB)
database.init(TEST_DB)
local db = database.get_connection()
local schema_sql = require('import_schema')
assert(db:exec(schema_sql), "schema creation failed")
assert(db:exec([[
    INSERT INTO projects (id, name, created_at, modified_at, fps_mismatch_policy)
    VALUES ('hp', 'Host', 0, 0, 'passthrough');
]]), "bootstrap failed")

local importer_core = require("importers.importer_core")
local import_result = importer_core.import_into_project('hp', r, {})

-- Find the saved clip whose parse-side original_clip pointed at phantom_path.
-- Query via Property rows for property_name='original_clip'.
local stmt = db:prepare([[
    SELECT clip_id, property_value FROM properties
    WHERE property_name = 'original_clip'
]])
assert(stmt, "property query prepare failed")
assert(stmt:exec(), "property query exec failed")
local json = require("dkjson")
local matched = false
while stmt:next() do
    local encoded = stmt:value(1)
    local decoded = encoded and json.decode(encoded)
    local value = decoded and decoded.value or decoded
    if value and value.file_path == phantom_path then
        matched = true
        break
    end
end
stmt:finalize()
os.remove(TEST_DB)

if not matched then
    fail("import_into_project did not persist original_clip property row "
        .. "containing the historical Windows path — data lost on persist")
end

-- Reference import_result so it isn't reported as unused (some linters care).
assert(import_result and import_result.clip_ids)

print("✅ test_drt_historical_clip_ignored.lua passed")
