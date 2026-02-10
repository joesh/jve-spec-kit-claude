require("test_env")

-- Test that DRP importer parses folders and master clips from MediaPool

local drp_importer = require("importers.drp_importer")

local DRP_PATH = "fixtures/resolve/sample_project.drp"

-- Check fixture exists
local f = io.open(DRP_PATH, "r")
assert(f, "Missing fixture: " .. DRP_PATH)
f:close()

print("Parsing DRP file...")
local result = drp_importer.parse_drp_file(DRP_PATH)

assert(result.success, "parse_drp_file failed: " .. tostring(result.error))
assert(result.project, "Missing project in parse result")
assert(result.project.name, "Missing project name")
print("  Project: " .. result.project.name)

-- Check folders are parsed
assert(result.folders, "Missing folders array in parse result")
print("  Folders: " .. #result.folders)
for _, folder in ipairs(result.folders) do
    print("    - " .. folder.name .. " (parent=" .. tostring(folder.parent_id) .. ")")
end

-- Check pool master clips are parsed
assert(result.pool_master_clips, "Missing pool_master_clips array in parse result")
print("  Pool master clips: " .. #result.pool_master_clips)
for i, clip in ipairs(result.pool_master_clips) do
    if i <= 5 then  -- Just show first 5
        print("    - " .. clip.name .. " (folder=" .. tostring(clip.folder_id) .. ")")
    end
end

-- Check media items still work
assert(result.media_items, "Missing media_items array")
print("  Media items: " .. #result.media_items)

-- Check timelines still work
assert(result.timelines, "Missing timelines array")
print("  Timelines: " .. #result.timelines)
for _, tl in ipairs(result.timelines) do
    print("    - " .. tl.name)
end

print("✅ test_drp_import_master_clips.lua passed")
