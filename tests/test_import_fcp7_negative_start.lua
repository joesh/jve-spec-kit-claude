#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local importer = require('importers.fcp7_xml_importer')

local TEST_DB = "/tmp/jve/test_import_fcp7_negative_start.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

-- Create the minimal schema required by the importer.
db:exec([[
    CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        settings TEXT NOT NULL DEFAULT '{}'
    );

    CREATE TABLE IF NOT EXISTS sequences (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        name TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'timeline',
        frame_rate REAL NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        timecode_start INTEGER NOT NULL DEFAULT 0,
        playhead_time INTEGER NOT NULL DEFAULT 0,
        selected_clip_ids TEXT,
        selected_edge_infos TEXT,
        viewport_start_time INTEGER NOT NULL DEFAULT 0,
        viewport_duration INTEGER NOT NULL DEFAULT 10000,
        mark_in_time INTEGER,
        mark_out_time INTEGER,
        current_sequence_number INTEGER
    );

    CREATE TABLE tracks (
        id TEXT PRIMARY KEY,
        sequence_id TEXT NOT NULL,
        name TEXT NOT NULL,
        track_type TEXT NOT NULL,
        track_index INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        locked INTEGER NOT NULL DEFAULT 0,
        muted INTEGER NOT NULL DEFAULT 0,
        soloed INTEGER NOT NULL DEFAULT 0,
        volume REAL NOT NULL DEFAULT 1.0,
        pan REAL NOT NULL DEFAULT 0.0
    );

    CREATE TABLE clips (
        id TEXT PRIMARY KEY,
        project_id TEXT,
        clip_kind TEXT NOT NULL DEFAULT 'timeline',
        name TEXT DEFAULT '',
        track_id TEXT,
        media_id TEXT,
        source_sequence_id TEXT,
        parent_clip_id TEXT,
        owner_sequence_id TEXT,
        start_time INTEGER NOT NULL,
        duration INTEGER NOT NULL,
        source_in INTEGER NOT NULL DEFAULT 0,
        source_out INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        offline INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT 0,
        modified_at INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE media (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        name TEXT NOT NULL,
        file_path TEXT UNIQUE NOT NULL,
        duration INTEGER NOT NULL,
        frame_rate REAL NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        audio_channels INTEGER NOT NULL DEFAULT 0,
        codec TEXT,
        created_at INTEGER,
        modified_at INTEGER,
        metadata TEXT DEFAULT '{}'
    );
]])

db:exec([[
    INSERT INTO projects (id, name)
    VALUES ('default_project', 'Default Project');
]])

db:exec([[
    CREATE TABLE tag_namespaces (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL
    );
]])

db:exec([[INSERT OR IGNORE INTO tag_namespaces(id, display_name) VALUES('bin', 'Bins');]])

db:exec([[
    CREATE TABLE tags (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        namespace_id TEXT NOT NULL,
        name TEXT NOT NULL,
        path TEXT NOT NULL,
        parent_id TEXT,
        sort_index INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
    );
]])

db:exec([[
    CREATE TABLE tag_assignments (
        tag_id TEXT NOT NULL,
        project_id TEXT NOT NULL,
        namespace_id TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        assigned_at INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(tag_id, entity_type, entity_id)
    );
]])

local FIXTURE_PATH = "fixtures/resolve/2025-07-08-anamnesis-PICTURE-LOCK-TWO more comps.xml"

local parsed = importer.import_xml(FIXTURE_PATH, 'default_project')
assert(parsed and parsed.success, "import_xml should succeed for complex Resolve export")

local created = importer.create_entities(parsed, db, 'default_project')
assert(created and created.success, "create_entities should persist imported data")

local clip_count_stmt = db:prepare("SELECT COUNT(*) FROM clips")
assert(clip_count_stmt:exec() and clip_count_stmt:next())
local clip_count = clip_count_stmt:value(0)
clip_count_stmt:finalize()
assert(clip_count > 0, "expected importer to create timeline clips")

local negative_start_stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE start_time < 0")
assert(negative_start_stmt:exec() and negative_start_stmt:next())
local negative_count = negative_start_stmt:value(0)
negative_start_stmt:finalize()

assert(negative_count == 0, string.format("found %d clips with negative start_time", negative_count))

print("✅ FCP7 importer handled negative start/end sentinels without producing negative clip positions")
