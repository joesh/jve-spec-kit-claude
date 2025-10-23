#!/usr/bin/env luajit

-- FCP7 XML importer integration test using the Resolve fixture.

package.path = "src/lua/?.lua;src/lua/?/init.lua;" .. package.path

local database = require("core.database")
local importer = require("importers.fcp7_xml_importer")
local Project = require("models.project")

local fixture_path = "tests/fixtures/resolve/sample_timeline_fcp7xml.xml"

local function assert_true(label, value)
    if not value then
        io.stderr:write(label .. "\n")
        os.exit(1)
    end
end

local function assert_eq(label, actual, expected)
    if actual ~= expected then
        io.stderr:write(string.format("%s: expected %s, got %s\n", label, tostring(expected), tostring(actual)))
        os.exit(1)
    end
end

local function assert_close(label, actual, expected, tolerance)
    tolerance = tolerance or 1e-6
    if type(actual) ~= "number" or type(expected) ~= "number" or math.abs(actual - expected) > tolerance then
        io.stderr:write(string.format("%s: expected %.4f, got %.4f\n", label, expected, actual))
        os.exit(1)
    end
end

local function run_sql(db, sql)
    local stmt = db:prepare(sql)
    assert_true("prepare failed for: " .. sql, stmt ~= nil)
    assert_true("exec failed for: " .. sql, stmt:exec())
    stmt:finalize()
end

local function fetch_one(db, sql, param)
    local stmt = db:prepare(sql)
    assert_true("prepare failed for: " .. sql, stmt ~= nil)
    if param then
        stmt:bind_value(1, param)
    end
    assert_true("exec failed for: " .. sql, stmt:exec())
    local row = nil
    if stmt:next() then
        row = stmt
    end
    return row, stmt
end

local tmp_path = os.tmpname() .. ".jvp"
os.remove(tmp_path)
assert_true("set_path", database.set_path(tmp_path))

local db = database.get_connection()
assert_true("db connection", db ~= nil)

local schema_statements = {
    [[CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT,
        created_at INTEGER,
        modified_at INTEGER,
        settings TEXT
    )]],
    [[CREATE TABLE sequences (
        id TEXT PRIMARY KEY,
        project_id TEXT,
        name TEXT,
        frame_rate REAL,
        width INTEGER,
        height INTEGER,
        timecode_start INTEGER
    )]],
    [[CREATE TABLE tracks (
        id TEXT PRIMARY KEY,
        sequence_id TEXT,
        name TEXT,
        track_type TEXT,
        track_index INTEGER,
        enabled INTEGER,
        locked INTEGER,
        muted INTEGER,
        soloed INTEGER,
        volume REAL,
        pan REAL
    )]],
    [[CREATE TABLE media (
        id TEXT PRIMARY KEY,
        project_id TEXT,
        name TEXT,
        file_path TEXT,
        duration INTEGER,
        frame_rate REAL,
        width INTEGER,
        height INTEGER,
        audio_channels INTEGER,
        codec TEXT,
        created_at INTEGER,
        modified_at INTEGER,
        metadata TEXT
    )]],
    [[CREATE TABLE clips (
        id TEXT PRIMARY KEY,
        track_id TEXT,
        media_id TEXT,
        start_time INTEGER,
        duration INTEGER,
        source_in INTEGER,
        source_out INTEGER,
        enabled INTEGER
    )]]
}

for _, sql in ipairs(schema_statements) do
    run_sql(db, sql)
end

local project = Project.create("Import Test", {id = "default_project"})
assert_true("project allocated", project ~= nil)
assert_true("project saved", project:save(db))

local parsed = importer.import_xml(fixture_path, "default_project")
assert_true("import_xml success", parsed and parsed.success)
assert_true("parsed sequences", #parsed.sequences > 0)

assert_eq("sequence count", #parsed.sequences, 1)
local sequence_info = parsed.sequences[1]
assert_eq("sequence name parsed", sequence_info.name, "Timeline 1 (Resolve)")
assert_eq("video track count parsed", #sequence_info.video_tracks, 3)
assert_eq("audio track count parsed", #sequence_info.audio_tracks, 2)
assert_eq("primary video track clip count", #sequence_info.video_tracks[1].clips, 25)
assert_eq("secondary video track clip count", #sequence_info.video_tracks[2].clips, 1)
assert_eq("tertiary video track clip count", #sequence_info.video_tracks[3].clips, 0)

local aggregated_media_count = 0
for _ in pairs(parsed.media_files) do
    aggregated_media_count = aggregated_media_count + 1
end
assert_eq("aggregated media map count", aggregated_media_count, 24)

local media_key = "A001_C037_0921FG_001.mp4 2"
local media_info = parsed.media_files[media_key]
assert_true("media entry present", media_info ~= nil)
assert_eq("media path decoded", media_info.path, "/Users/Shared/Adobe/Premiere Pro/24.0/Tutorial/Going Home project/Footage/A001_C037_0921FG_001.mp4")
assert_close("media frame rate parsed", media_info.frame_rate, 23.976, 1e-3)
assert_eq("media width parsed", media_info.width, 1920)
assert_eq("media height parsed", media_info.height, 1080)
assert_eq("media audio channels parsed", media_info.audio_channels, 2)

local created = importer.create_entities(parsed, db, "default_project")
assert_true("create_entities success", created and created.success)
assert_true("sequence inserted", #created.sequence_ids == #parsed.sequences)
assert_eq("tracks inserted count", #created.track_ids, 5)
assert_eq("clips inserted count", #created.clip_ids, 27)
assert_eq("media inserted count", #created.media_ids, 23)

do
    local row, stmt = fetch_one(db, "SELECT name, frame_rate FROM sequences LIMIT 1")
    assert_true("sequence row", row ~= nil)
    local seq_name = row:value(0)
    local seq_rate = row:value(1)
    assert_true("sequence name populated", seq_name and #seq_name > 0)
    assert_eq("sequence frame rate", math.floor(seq_rate + 0.5), 24)
    stmt:finalize()
end

do
    local row, stmt = fetch_one(db, "SELECT COUNT(*) FROM tracks")
    assert_true("track count row", row ~= nil)
    local track_count = row:value(0)
    assert_true("track count > 0", track_count > 0)
    stmt:finalize()
end

do
    local row, stmt = fetch_one(db, "SELECT COUNT(*) FROM tracks WHERE track_type = 'VIDEO'")
    assert_true("video track count row", row ~= nil)
    assert_eq("video track count correct", row:value(0), 3)
    stmt:finalize()
end

do
    local row, stmt = fetch_one(db, "SELECT COUNT(*) FROM tracks WHERE track_type = 'AUDIO'")
    assert_true("audio track count row", row ~= nil)
    assert_eq("audio track count correct", row:value(0), 2)
    stmt:finalize()
end

do
    local row, stmt = fetch_one(db, "SELECT start_time, duration, source_out FROM clips LIMIT 1")
    assert_true("clip row", row ~= nil)
    local start_time = row:value(0)
    local duration = row:value(1)
    local source_out = row:value(2)
    assert_eq("clip start at zero", start_time, 0)
    assert_true("clip duration positive", duration > 0)
    assert_true("clip source_out > start", source_out > start_time)
    stmt:finalize()
end

do
    local row, stmt = fetch_one(
        db,
        [[SELECT clips.start_time, clips.duration, clips.source_in, clips.source_out
          FROM clips
          JOIN media ON clips.media_id = media.id
          WHERE media.name = ?
          LIMIT 1]],
        "A001_C037_0921FG_001.mp4"
    )
    assert_true("clip join row", row ~= nil)
    assert_eq("clip join start time", row:value(0), 0)
    assert_eq("clip join duration", row:value(1), 333)
    assert_eq("clip join source_in", row:value(2), 0)
    assert_eq("clip join source_out", row:value(3), 333)
    stmt:finalize()
end

do
    local row, stmt = fetch_one(
        db,
        "SELECT file_path, frame_rate, width, height, audio_channels, duration FROM media WHERE name = ?",
        "A001_C037_0921FG_001.mp4"
    )
    assert_true("media row present", row ~= nil)
    assert_eq("media path persisted", row:value(0), "/Users/Shared/Adobe/Premiere Pro/24.0/Tutorial/Going Home project/Footage/A001_C037_0921FG_001.mp4")
    assert_close("media frame rate stored", row:value(1), 23.976, 1e-3)
    assert_eq("media width stored", row:value(2), 1920)
    assert_eq("media height stored", row:value(3), 1080)
    assert_eq("media channels stored", row:value(4), 2)
    assert_eq("media duration stored", row:value(5), 333)
    stmt:finalize()
end

do
    local row, stmt = fetch_one(db, "SELECT COUNT(*) FROM media WHERE file_path LIKE '%FogTL.mp4%'")
    assert_true("fog media count row", row ~= nil)
    assert_eq("fog clip with missing path omitted", row:value(0), 0)
    stmt:finalize()
end

do
    local row, stmt = fetch_one(db, "SELECT file_path, duration FROM media LIMIT 1")
    assert_true("media row", row ~= nil)
    local file_path = row:value(0)
    local duration = row:value(1)
    assert_true("media path populated", file_path and #file_path > 0)
    assert_true("media duration positive", duration > 0)
    stmt:finalize()
end

os.remove(tmp_path)
print("✅ FCP7 XML importer test passed")
