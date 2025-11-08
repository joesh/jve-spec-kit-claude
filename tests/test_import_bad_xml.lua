#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local fcp7_importer = require('importers.fcp7_xml_importer')
local Command = require('command')

local function write_bad_xml(path)
    local handle = assert(io.open(path, 'w'))
    handle:write([[<?xml version="1.0" encoding="UTF-8"?>
<xmeml version="4">
  <sequence id="bad_sequence">
    <name>Broken Sequence</name>
    <rate>
      <timebase>24</timebase>
      <ntsc>FALSE</ntsc>
    </rate>
    <media>
      <video>
        <track>
          <clipitem id="clip_missing_path">
            <name>ClipMissingPath</name>
            <start>0</start>
            <end>50</end>
            <in>0</in>
            <out>50</out>
            <file id="file_missing_path">
              <name>MissingPath.mov</name>
              <duration>50</duration>
            </file>
          </clipitem>
          <clipitem id="clip_missing_file">
            <name>ClipMissingFile</name>
            <start>50</start>
            <end>100</end>
            <in>0</in>
            <out>50</out>
            <file id="file_reference_only" />
          </clipitem>
        </track>
      </video>
    </media>
  </sequence>
</xmeml>
]])
    handle:close()
end

local function init_db(path)
    os.remove(path)
    assert(database.set_path(path))
    local db = database.get_connection()

    db:exec([[CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        settings TEXT NOT NULL DEFAULT '{}',
        created_at INTEGER DEFAULT 0,
        modified_at INTEGER DEFAULT 0
    );]])

    db:exec([[        CREATE TABLE IF NOT EXISTS sequences (
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
]])

    db:exec([[CREATE TABLE tracks (
        id TEXT PRIMARY KEY,
        sequence_id TEXT NOT NULL,
        name TEXT,
        track_type TEXT NOT NULL,
        track_index INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        locked INTEGER NOT NULL DEFAULT 0,
        muted INTEGER NOT NULL DEFAULT 0,
        soloed INTEGER NOT NULL DEFAULT 0,
        volume REAL NOT NULL DEFAULT 1.0,
        pan REAL NOT NULL DEFAULT 0.0
    );]])

    db:exec([[CREATE TABLE media (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        file_path TEXT UNIQUE,
        name TEXT,
        duration INTEGER NOT NULL DEFAULT 0,
        frame_rate REAL NOT NULL DEFAULT 0,
        width INTEGER NOT NULL DEFAULT 0,
        height INTEGER NOT NULL DEFAULT 0,
        audio_channels INTEGER NOT NULL DEFAULT 0,
        codec TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL DEFAULT 0,
        modified_at INTEGER NOT NULL DEFAULT 0,
        metadata TEXT NOT NULL DEFAULT '{}'
    );]])

    db:exec([[                CREATE TABLE clips (
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

]])

    db:exec([[CREATE TABLE commands (
        id TEXT PRIMARY KEY,
        parent_id TEXT,
        parent_sequence_number INTEGER,
        sequence_number INTEGER UNIQUE NOT NULL,
        command_type TEXT NOT NULL,
        command_args TEXT,
        pre_hash TEXT,
        post_hash TEXT,
        timestamp INTEGER,
        playhead_time INTEGER DEFAULT 0,
        selected_clip_ids TEXT DEFAULT '[]',
        selected_edge_infos TEXT DEFAULT '[]',
        selected_clip_ids_pre TEXT DEFAULT '[]',
        selected_edge_infos_pre TEXT DEFAULT '[]'
    );]])

    db:exec([[INSERT INTO projects (id, name) VALUES ('test_project', 'Test Project');]])
    return db
end

local function run_test()
    local xml_path = os.tmpname() .. '.xml'
    write_bad_xml(xml_path)

    local db_path = '/tmp/test_import_bad_xml.db'
    local db = init_db(db_path)

    local parsed = fcp7_importer.import_xml(xml_path, 'test_project')
    assert(parsed.success, 'import_xml should succeed even with bad data')

    local entities = fcp7_importer.create_entities(parsed, db, 'test_project')
    assert(entities.success, entities.error or 'create_entities failed')

    -- Ensure clip loading succeeds without throwing
    local sequences = database.load_sequences('test_project')
    assert(#sequences >= 1, 'expected at least one imported sequence')

    for _, seq in ipairs(sequences) do
        local ok, clips = pcall(database.load_clips, seq.id)
        assert(ok, 'load_clips should not throw for imported data')
        assert(#clips >= 0, 'load_clips should return a table')
    end

    os.remove(xml_path)
    os.remove(db_path)
end

run_test()

print('✅ Bad XML import handled without crashing')
