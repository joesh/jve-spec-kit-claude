#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local importer = require('importers.fcp7_xml_importer')

local TEST_DB = "/tmp/jve/test_import_fcp7_negative_start.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

-- Create the minimal schema required by the importer.
db:exec(require('import_schema'))

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

local negative_start_stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE start_value < 0")
assert(negative_start_stmt:exec() and negative_start_stmt:next())
local negative_count = negative_start_stmt:value(0)
negative_start_stmt:finalize()

assert(negative_count == 0, string.format("found %d clips with negative start_value", negative_count))

print("✅ FCP7 importer handled negative start/end sentinels without producing negative clip positions")
