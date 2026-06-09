-- Domain behavior under test:
--
-- A media row's identity (its primary key in the DB) must be a stable
-- function of its source: the file's DRP MediaRef DbId (file_uuid). The
-- consequence Joe cares about: re-importing the same DRP into the same
-- destination must produce the same media.id values, so per-media-id
-- caches (peak files keyed by `<media_id>.peaks`, future content caches)
-- survive the re-import instead of being orphaned.
--
-- Pre-fix behavior: importer_core called Media.create without passing
-- `id`, so each import generated a fresh uuid for every media row. Two
-- imports of the same DRP produced two disjoint sets of media_ids; all
-- previously-generated peak files became orphans on disk and the cache
-- had to be rebuilt from scratch. That's the "have to wait for the
-- waveforms to regenerate" Joe was paying for on every re-import.
--
-- Why a regression test exists here:
-- The bug is only visible across a re-import. Single-import tests pass
-- because the importer is internally consistent — fresh ids work fine
-- in isolation. The breakage is in cross-session continuity, which only
-- a re-import can exercise.

require("test_env")

local database = require("core.database")
local test_env = require("test_env")

local fixture_path = test_env.resolve_repo_path(
    "tests/fixtures/resolve/sample_project.drp")
local JVP_PATH = "/tmp/jve/test_drp_reimport_stable_ids.jvp"

local function reset_jvp()
    os.remove(JVP_PATH)
    os.remove(JVP_PATH .. "-wal")
    os.remove(JVP_PATH .. "-shm")
end

print("\n=== test_drp_reimport_stable_media_ids ===")

-- Snapshot all (id, file_path, file_uuid) rows in the current project.
-- Returns a list keyed by file_path so we can compare across imports
-- without depending on row order.
local function snapshot_media()
    local db = assert(database.get_connection(),
        "no database connection after import")
    local stmt = assert(db:prepare(
        "SELECT id, file_path, file_uuid FROM media ORDER BY file_path"))
    assert(stmt:exec())
    local rows_by_path = {}
    while stmt:next() do
        rows_by_path[stmt:value(1)] = {
            id = stmt:value(0),
            file_path = stmt:value(1),
            file_uuid = stmt:value(2),
        }
    end
    stmt:finalize()
    return rows_by_path
end

-- ---------------------------------------------------------------------------
-- Step 1: First import. Capture media (id, path, uuid) per row.
-- ---------------------------------------------------------------------------
print("\n--- Step 1: first import ---")
reset_jvp()
local ok1, err1 = require("core.commands.open_project")._convert_drp_to_jvp(fixture_path, JVP_PATH, nil, {audio_sample_rate = 48000})
assert(ok1, "first import failed: " .. tostring(err1))

local first = snapshot_media()
local media_count = 0
local with_uuid = 0
for _, row in pairs(first) do
    media_count = media_count + 1
    if row.file_uuid and row.file_uuid ~= "" then
        with_uuid = with_uuid + 1
    end
end
assert(media_count > 0, "fixture must produce at least one media row")
assert(with_uuid > 0, "fixture must have at least one media row with file_uuid "
    .. "(otherwise this test can't observe stability)")
print(string.format("  %d media rows (%d with file_uuid)", media_count, with_uuid))

-- ---------------------------------------------------------------------------
-- Step 2: Each media row's id MUST equal its file_uuid (when one exists).
-- This is the spec invariant: media.id IS the DRP MediaRef DbId for
-- DRP-imported media. Without it, peak_cache (and any other per-media-id
-- cache) cannot survive a re-import.
-- ---------------------------------------------------------------------------
print("\n--- Step 2: media.id == file_uuid for DRP-imported rows ---")
local mismatches = {}
for path, row in pairs(first) do
    if row.file_uuid and row.file_uuid ~= "" then
        if row.id ~= row.file_uuid then
            table.insert(mismatches, string.format(
                "  %s: id=%s, file_uuid=%s", path, row.id, row.file_uuid))
        end
    end
end
assert(#mismatches == 0, string.format(
    "REGRESSION: %d media row(s) have id != file_uuid. The DRP MediaRef "
    .. "DbId IS the media's identity; importer should pass it through to "
    .. "Media.create as `id`. First few mismatches:\n%s",
    #mismatches, table.concat({mismatches[1] or "",
        mismatches[2] or "", mismatches[3] or ""}, "\n")))

-- ---------------------------------------------------------------------------
-- Step 3: Re-import the same DRP into the same destination. Capture
-- media rows again and assert id-stability per file_path.
-- ---------------------------------------------------------------------------
print("\n--- Step 3: re-import + verify stable ids ---")
database.shutdown()  -- release the DB before convert reopens
local ok2, err2 = require("core.commands.open_project")._convert_drp_to_jvp(fixture_path, JVP_PATH, nil, {audio_sample_rate = 48000})
assert(ok2, "second import failed: " .. tostring(err2))

local second = snapshot_media()

-- Same set of file_paths should be present.
local first_paths = {}
for path in pairs(first) do first_paths[path] = true end
for path in pairs(second) do
    assert(first_paths[path], string.format(
        "second import added a path that wasn't in the first: %s", path))
    first_paths[path] = nil
end
assert(next(first_paths) == nil, string.format(
    "second import dropped a path: %s", tostring(next(first_paths))))

-- ids must match per-path for every row that carries a file_uuid.
local id_changes = {}
for path, row1 in pairs(first) do
    local row2 = second[path]
    if row1.file_uuid and row1.file_uuid ~= "" then
        if row1.id ~= row2.id then
            table.insert(id_changes, string.format(
                "  %s: first_id=%s, second_id=%s (file_uuid=%s)",
                path, row1.id, row2.id, row1.file_uuid))
        end
    end
end
assert(#id_changes == 0, string.format(
    "REGRESSION: %d media row(s) got a different id on re-import. The "
    .. "downstream consequence is orphaned peak files, regenerated waveforms, "
    .. "and any other per-media-id cache invalidated for no good reason. "
    .. "First few:\n%s",
    #id_changes, table.concat({id_changes[1] or "",
        id_changes[2] or "", id_changes[3] or ""}, "\n")))

print(string.format("  %d media rows preserved id across re-import", media_count))

reset_jvp()
print("\n✅ test_drp_reimport_stable_media_ids passed")
