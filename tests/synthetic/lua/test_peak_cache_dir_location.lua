-- Domain behavior under test:
--   The peak cache is derived, regenerable data. It MUST live in a
--   filesystem location that:
--     1. Is excluded from cloud-sync providers (iCloud Drive, Dropbox,
--        Google Drive, OneDrive). On macOS that means ~/Library/Caches.
--     2. Is keyed by project so the user can identify which project's
--        cache they're looking at (project name + project_id).
--
-- Why a regression test exists here:
--   pre-2026-06-08 the cache lived at `<project>.jvp-cache/peaks` —
--   sibling to the .jvp file. Users whose .jvp sits in iCloud-synced
--   storage (Desktop & Documents in iCloud, common default on macOS)
--   wound up with peak files getting evicted to the cloud and then
--   re-downloaded on every verifier touch. A 6s peak verifier became
--   a 360s peak verifier in observed sessions (TSO 2026-06-08).
--   Caches belong in ~/Library/Caches; that's what the convention is
--   for, and the OS explicitly excludes it from cloud sync + backup.

require("test_env")
local database = require("core.database")
local Project = require("models.project")

local DB_PATH = "/tmp/jve/test_peak_cache_dir_location.db"
local PROJECT_ID = "abc12345-6789-4abc-def0-123456789012"
local PROJECT_NAME = "My Project"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    local db = database.get_connection()
    db:exec(require("import_schema"))
    return db
end

print("--- test_peak_cache_dir_location ---")

fresh_db()
Project.create(PROJECT_NAME, {
    id = PROJECT_ID,
    fps_mismatch_policy = "passthrough",
    settings = {
        master_clock_hz = 192000,
        default_fps = { num = 24, den = 1 }
    }
}):save()

local cache_dir = database.get_peak_cache_dir(PROJECT_ID)
assert(cache_dir and cache_dir ~= "",
    "get_peak_cache_dir(project_id) returned nil/empty")

print("returned path: " .. cache_dir)

-- 1. NOT under ~/Documents (might be iCloud-synced with Desktop & Documents)
local home = assert(os.getenv("HOME"), "HOME unset")
assert(not cache_dir:find(home .. "/Documents/", 1, true),
    string.format("peak cache must not live under ~/Documents (got %s) — "
        .. "iCloud Drive Desktop & Documents Sync evicts files there", cache_dir))

-- 2. NOT under ~/Library/Mobile Documents (explicit iCloud Drive root)
assert(not cache_dir:find(home .. "/Library/Mobile Documents/", 1, true),
    string.format("peak cache must not live under ~/Library/Mobile Documents (got %s) — "
        .. "that's the iCloud Drive container", cache_dir))

-- 3. Under ~/Library/Caches (macOS-standard cache location: excluded from
-- iCloud sync, Time Machine, and migration; the OS may purge under storage
-- pressure, which is fine for regenerable peak files).
assert(cache_dir:find(home .. "/Library/Caches/", 1, true),
    string.format("peak cache must live under ~/Library/Caches (got %s)", cache_dir))

-- 4. Path includes the project_id so a user inspecting ~/Library/Caches
-- can tell which project a cache belongs to even when names collide.
assert(cache_dir:find(PROJECT_ID, 1, true),
    string.format("peak cache path must include project_id (got %s)", cache_dir))

-- 5. Path includes the project name (or a sanitized form of it) so the
-- user can read the cache directory and identify the project.
-- "My Project" contains a space — accept "My Project" or "My_Project" or "MyProject".
local name_present = cache_dir:find("My Project", 1, true)
    or cache_dir:find("My_Project", 1, true)
    or cache_dir:find("MyProject", 1, true)
assert(name_present,
    string.format("peak cache path must include project name (got %s)", cache_dir))

-- 6. Side effect: the path must exist on disk AS A DIRECTORY after the call.
-- io.open() succeeds for both regular files and directories on macOS, so a
-- "did this exist" check via io.open would silently pass if a prior bug
-- left a regular file at this path. Stat via /usr/bin/test -d.
local handle = assert(io.popen(string.format("/bin/test -d %q && echo ok", cache_dir),
    "r"), "io.popen failed")
local out = handle:read("*l") or ""
handle:close()
assert(out == "ok",
    string.format("peak cache path is not a directory on disk: %s (test -d failed)", cache_dir))

-- 7. Failure path: passing an empty string must surface (nil, err), not
-- silently succeed against CWD. Regression guard for the QDir::mkpath("")
-- = true behavior. The binding stub in test_env mirrors this contract.
local ok_empty, err_empty = qt_fs_mkdir_p("")
assert(ok_empty == nil and type(err_empty) == "string" and err_empty ~= "",
    "qt_fs_mkdir_p(\"\") must return (nil, <non-empty error>); got "
    .. tostring(ok_empty) .. ", " .. tostring(err_empty))

print("✅ test_peak_cache_dir_location.lua passed")
