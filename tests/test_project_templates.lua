require("test_env")

local database = require("core.database")
local project_templates = require("core.project_templates")
local Project = require("models.project")
local Sequence = require("models.sequence")
local Track = require("models.track")

local TMP_DIR = "/tmp/jve/test_project_templates"
os.execute("rm -rf " .. TMP_DIR)
os.execute("mkdir -p " .. TMP_DIR)

-- Use a temp database so model operations don't conflict
local setup_db_path = TMP_DIR .. "/setup.jvp"
assert(database.init(setup_db_path))

-- ===========================================================================
-- Test 1: TEMPLATES table is well-formed
-- ===========================================================================
print("  test: TEMPLATES table well-formed")
assert(#project_templates.TEMPLATES >= 9, "expected at least 9 templates")
for i, t in ipairs(project_templates.TEMPLATES) do
    assert(t.name and t.name ~= "", "template " .. i .. " missing name")
    assert(type(t.width) == "number" and t.width > 0, "template " .. i .. " bad width")
    assert(type(t.height) == "number" and t.height > 0, "template " .. i .. " bad height")
    assert(type(t.fps_num) == "number" and t.fps_num > 0, "template " .. i .. " bad fps_num")
    assert(type(t.fps_den) == "number" and t.fps_den > 0, "template " .. i .. " bad fps_den")
    assert(type(t.audio_rate) == "number" and t.audio_rate > 0, "template " .. i .. " bad audio_rate")
end

-- ===========================================================================
-- Test 2: get_template_path generates a valid .jvp
-- ===========================================================================
print("  test: get_template_path generates .jvp")
local template = project_templates.TEMPLATES[1]  -- Film 24fps
local path = project_templates.get_template_path(template)
assert(path, "get_template_path returned nil")

-- Verify file exists
local f = io.open(path, "rb")
assert(f, "template .jvp not created: " .. tostring(path))
f:close()

-- Open it and verify contents
database.init(path)
local pid = database.get_current_project_id()
assert(pid == "template_project", "expected template_project id, got: " .. tostring(pid))

local project = Project.load(pid)
assert(project, "failed to load template project")
assert(project.name == template.name, "project name mismatch: " .. tostring(project.name))

local seq = Sequence.find_most_recent()
assert(seq, "no sequence in template")
assert(seq.frame_rate.fps_numerator == template.fps_num,
    "fps_num mismatch: " .. tostring(seq.frame_rate.fps_numerator))
assert(seq.frame_rate.fps_denominator == template.fps_den,
    "fps_den mismatch: " .. tostring(seq.frame_rate.fps_denominator))
assert(seq.width == template.width, "width mismatch")
assert(seq.height == template.height, "height mismatch")
assert(seq.audio_sample_rate == template.audio_rate, "audio_rate mismatch")

-- 3 video + 3 audio tracks = 6 total
local track_count = Track.count_for_sequence(seq.id)
assert(track_count == 6, "expected 6 tracks, got: " .. tostring(track_count))

local video_tracks = Track.find_by_sequence(seq.id, "VIDEO")
assert(#video_tracks == 3, "expected 3 video tracks, got: " .. tostring(#video_tracks))

local audio_tracks = Track.find_by_sequence(seq.id, "AUDIO")
assert(#audio_tracks == 3, "expected 3 audio tracks, got: " .. tostring(#audio_tracks))

-- ===========================================================================
-- Test 3: get_template_path is idempotent (returns existing file)
-- ===========================================================================
print("  test: get_template_path idempotent")
-- Re-initialize setup db to avoid template db being active
database.init(setup_db_path)

local path2 = project_templates.get_template_path(template)
assert(path2 == path, "idempotent call returned different path")

-- ===========================================================================
-- Test 4: create_project_from_template creates a new project
-- ===========================================================================
print("  test: create_project_from_template")
-- Re-initialize setup db
database.init(setup_db_path)

local dest = TMP_DIR .. "/MyFilm.jvp"
local result = project_templates.create_project_from_template(template, "My Film Project", dest)
assert(result, "create_project_from_template returned nil")
assert(result.project_id, "missing project_id")
assert(result.sequence_id, "missing sequence_id")

-- Open the new project and verify
database.init(dest)
local new_pid = database.get_current_project_id()
assert(new_pid == result.project_id, "project_id mismatch")
assert(new_pid ~= "template_project", "project_id should not be template_project")

local new_project = Project.load(new_pid)
assert(new_project, "failed to load new project")
assert(new_project.name == "My Film Project",
    "project name mismatch: " .. tostring(new_project.name))

local new_seq = Sequence.load(result.sequence_id)
assert(new_seq, "failed to load sequence")
assert(new_seq.project_id == new_pid, "sequence project_id mismatch")
assert(new_seq.frame_rate.fps_numerator == template.fps_num, "fps mismatch in new project")
assert(new_seq.width == template.width, "width mismatch in new project")

-- Tracks carried over
local new_track_count = Track.count_for_sequence(result.sequence_id)
assert(new_track_count == 6, "expected 6 tracks in new project, got: " .. tostring(new_track_count))

-- ===========================================================================
-- Test 5: create_project_from_template asserts on empty name
-- ===========================================================================
print("  test: create_project_from_template rejects empty name")
database.init(setup_db_path)
local ok, err = pcall(project_templates.create_project_from_template, template, "", TMP_DIR .. "/bad.jvp")
assert(not ok, "should reject empty name")
assert(tostring(err):find("project_name required"), "wrong error: " .. tostring(err))

-- ===========================================================================
-- Test 6: create_project_from_template asserts on existing dest
-- ===========================================================================
print("  test: create_project_from_template rejects existing dest")
database.init(setup_db_path)
local ok2, err2 = pcall(project_templates.create_project_from_template, template, "Dup", dest)
assert(not ok2, "should reject existing dest")
assert(tostring(err2):find("dest already exists"), "wrong error: " .. tostring(err2))

-- ===========================================================================
-- Test 7: self-healing — delete template .jvp, get_template_path regenerates
-- ===========================================================================
print("  test: self-healing regeneration")
database.init(setup_db_path)

-- Delete the template file
os.remove(path)
local check = io.open(path, "rb")
assert(not check, "template file should be deleted")

-- Regenerate
local path3 = project_templates.get_template_path(template)
assert(path3 == path, "regenerated path should match original")

local check2 = io.open(path3, "rb")
assert(check2, "template should be regenerated")
check2:close()

-- Verify regenerated file is valid
database.init(path3)
local regen_seq = Sequence.find_most_recent()
assert(regen_seq, "no sequence in regenerated template")
assert(regen_seq.frame_rate.fps_numerator == template.fps_num, "regen fps mismatch")

-- ===========================================================================
-- Test 8: format_info produces expected string
-- ===========================================================================
print("  test: format_info")
database.init(setup_db_path)
local info = project_templates.format_info(project_templates.TEMPLATES[1])
assert(info:find("1920x1080"), "should contain resolution: " .. info)
assert(info:find("24fps"), "should contain fps: " .. info)
assert(info:find("48kHz"), "should contain audio rate: " .. info)

-- ===========================================================================
-- Test 9: format_info for non-integer fps
-- ===========================================================================
print("  test: format_info for 23.976fps")
local info2 = project_templates.format_info(project_templates.TEMPLATES[2])
assert(info2:find("23.976") or info2:find("24fps"), "should contain fps info: " .. info2)

-- ===========================================================================
-- Cleanup
-- ===========================================================================
database.shutdown()
os.execute("rm -rf " .. TMP_DIR)

print("✅ test_project_templates.lua passed")
