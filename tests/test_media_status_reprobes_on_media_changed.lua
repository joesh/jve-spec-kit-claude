--- Regression: media_status cache must be authoritative after media_changed.
--
-- After a Relink (or any mutation that emits media_changed), views re-read
-- clips from DB with fresh media paths and stamp clip.offline via
-- ensure_clip_status. That stamp is a no-op if the new path has no cache
-- entry, so views display offline=false for paths that may well be missing.
--
-- Contract: media_status must probe the changed media paths on media_changed
-- and populate status_cache before view reactive handlers run (priority < 100),
-- so ensure_clip_status always finds a cache entry for any media path in the
-- active project.
require("test_env")

local database = require("core.database")
local media_status = require("core.media.media_status")
local Signals = require("core.signals")
local Media = require("models.media")
local Project = require("models.project")

local db_path = "/tmp/jve/test_media_status_reprobe_" .. os.time() .. ".jvp"
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local project = Project.create("Reprobe Project", { fps_mismatch_policy = 'resample' })
project:save(db)
local good_path = "/tmp/jve/test_reprobe_exists.mov"
local f = io.open(good_path, "w"); f:write("x"); f:close()
local bad_path = "/tmp/jve/test_reprobe_missing_" .. os.time() .. ".mov"

local media = Media.create({
    id = "media_reprobe_1",
    project_id = project.id,
    file_path = good_path,
    name = "reprobe",
    duration_frames = 100,
    fps_numerator = 24,
    fps_denominator = 1,
})
media:save(db)
media_status.clear()
media_status.load_persisted(project.id)

-- Precondition: cache has no entry for good_path yet
assert(media_status.get(good_path) == nil,
    "precondition: cache must be empty before media_changed fires")

-- Fire media_changed as relink_clips would
Signals.emit("media_changed", { [media.id] = true })

-- Contract: cache must now reflect the current path's status
local after = media_status.get(good_path)
assert(after, "media_status must populate cache for changed media_id's current path")
assert(after.offline == false,
    "existing file must be cached as online (offline=false)")

-- Switch to missing path (simulates relink-to-offline)
media:set_file_path(bad_path)
media:save(db)
Signals.emit("media_changed", { [media.id] = true })

local after_bad = media_status.get(bad_path)
assert(after_bad, "media_status must cache new path after media_changed")
assert(after_bad.offline == true,
    "missing file must be cached as offline")
assert(after_bad.error_code == "FileNotFound",
    "missing file must report FileNotFound")

-- Verify the stamp now works for a fresh clip (this is the visible-bug fix)
local clip = { media_path = bad_path, offline = false }
media_status.ensure_clip_status(clip)
assert(clip.offline == true,
    "ensure_clip_status must stamp offline=true now that media_changed primed the cache")

-- Priority ordering: a default-priority (100) handler must see the cache
-- already populated by the probe (which is registered at priority 30).
local view_seen = nil
local view_id = Signals.connect("media_changed", function()
    view_seen = media_status.get(bad_path)
end, 100)
media_status.clear()
media_status.load_persisted(project.id)
Signals.emit("media_changed", { [media.id] = true })
assert(view_seen and view_seen.offline == true,
    "view-priority handler must see offline cache entry primed by probe")
Signals.disconnect(view_id)

-- ============================================================
-- NSF error paths
-- ============================================================

-- Half 1: nil input must assert (not silently no-op)
do
    local ok, err = pcall(function() media_status.reprobe_media_ids(nil) end)
    assert(not ok, "reprobe_media_ids(nil) must assert, not silently return")
    assert(tostring(err):find("must be a table", 1, true),
        "assert message must name the contract violation: " .. tostring(err))
end

-- Half 1: wrong-type input must assert
do
    local ok, err = pcall(function() media_status.reprobe_media_ids("not a table") end)
    assert(not ok, "reprobe_media_ids(string) must assert")
    assert(tostring(err):find("must be a table", 1, true),
        "assert message must name the contract violation: " .. tostring(err))
end

-- Half 1: stale/unknown media_id must assert (not silently skip)
do
    local ok, err = pcall(function()
        media_status.reprobe_media_ids({ ["nonexistent_media_id_xyz"] = true })
    end)
    assert(not ok, "reprobe_media_ids with unknown id must assert")
    assert(tostring(err):find("not found", 1, true),
        "assert message must indicate media not found: " .. tostring(err))
end

-- Half 1: empty string id must assert
do
    local ok = pcall(function()
        media_status.reprobe_media_ids({ [""] = true })
    end)
    assert(not ok, "reprobe_media_ids with empty-string id must assert")
end

-- Boundary: empty set is a legitimate no-op (no media changed → nothing to probe)
do
    local ok = pcall(function() media_status.reprobe_media_ids({}) end)
    assert(ok, "reprobe_media_ids({}) must succeed — empty set is legitimate")
end

database.shutdown()
os.remove(good_path)
os.remove(db_path)
os.remove(db_path .. "-shm")
os.remove(db_path .. "-wal")

print("✅ test_media_status_reprobes_on_media_changed.lua passed")
