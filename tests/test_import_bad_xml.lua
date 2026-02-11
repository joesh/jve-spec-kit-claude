#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local fcp7_importer = require('importers.fcp7_xml_importer')
local _Command = require('command')  -- luacheck: no unused

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

    db:exec(require('import_schema'))
    db:exec([[INSERT OR IGNORE INTO tag_namespaces(id, display_name) VALUES('bin', 'Bins');]])
    db:exec([[INSERT INTO projects (id, name, created_at, modified_at) VALUES ('test_project', 'Test Project', strftime('%s','now'), strftime('%s','now'));]])
    return db
end

local function run_test()
    local xml_path = os.tmpname() .. '.xml'
    write_bad_xml(xml_path)

    local db_path = '/tmp/jve/test_import_bad_xml.db'
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
