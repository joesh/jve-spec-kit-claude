require('test_env')

require("dkjson")  -- load module for persistence (module needed, not return value)

-- Use isolated temp dir for persistence file
local test_dir = "/tmp/jve/test_file_browser_" .. os.clock()
os.execute(string.format("mkdir -p %q", test_dir))
local test_json_path = test_dir .. "/file_browser_paths.json"

-- Stub qt_constants.FILE_DIALOG before loading module
local dialog_calls = {}
_G.qt_constants = {
    FILE_DIALOG = {
        OPEN_FILE = function(parent, title, filter, dir)
            table.insert(dialog_calls, { type = "OPEN_FILE", dir = dir })
            return "/Users/joe/footage/clip001.mp4"
        end,
        OPEN_FILES = function(parent, title, filter, dir)
            table.insert(dialog_calls, { type = "OPEN_FILES", dir = dir })
            return { "/Users/joe/footage/clip001.mp4", "/Users/joe/footage/clip002.mp4" }
        end,
        OPEN_DIRECTORY = function(parent, title, dir)
            table.insert(dialog_calls, { type = "OPEN_DIRECTORY", dir = dir })
            return "/Users/joe/exports/final"
        end,
    },
}

local file_browser = require("core.file_browser")

-- Override persistence path for testing
file_browser._set_persistence_path(test_json_path)

-----------------------------------------------------------------------
-- Test: extract_dir_from_path
-----------------------------------------------------------------------
print("  test extract_dir_from_path...")
assert(file_browser._extract_dir("/Users/joe/footage/clip001.mp4") == "/Users/joe/footage",
    "should extract parent dir from file path")
assert(file_browser._extract_dir("/Users/joe/footage") == "/Users/joe/footage",
    "should return dir itself when path is a directory (no extension)")
assert(file_browser._extract_dir(nil) == nil,
    "should return nil for nil input")
assert(file_browser._extract_dir("") == nil,
    "should return nil for empty string")
print("  ✓ extract_dir_from_path")

-----------------------------------------------------------------------
-- Test: open_file persists and recalls directory
-----------------------------------------------------------------------
print("  test open_file persistence...")
dialog_calls = {}

-- First call: no persisted path, no fallback -> empty string passed to dialog
local result = file_browser.open_file("test_import", nil, "Open", "All (*)")
assert(result == "/Users/joe/footage/clip001.mp4", "should return dialog result")
assert(#dialog_calls == 1)
assert(dialog_calls[1].dir == "", "first call with no history should pass empty dir")

-- Second call: should recall /Users/joe/footage from first result
dialog_calls = {}
local result2 = file_browser.open_file("test_import", nil, "Open", "All (*)")
assert(result2 == "/Users/joe/footage/clip001.mp4")
assert(dialog_calls[1].dir == "/Users/joe/footage",
    "second call should use persisted dir, got: " .. tostring(dialog_calls[1].dir))
print("  ✓ open_file persistence")

-----------------------------------------------------------------------
-- Test: fallback_dir used when no persisted path
-----------------------------------------------------------------------
print("  test fallback_dir...")
dialog_calls = {}
file_browser.open_file("brand_new_dialog", nil, "Open", "All (*)", "/default/path")
assert(dialog_calls[1].dir == "/default/path",
    "should use fallback when no persisted path, got: " .. tostring(dialog_calls[1].dir))
print("  ✓ fallback_dir")

-----------------------------------------------------------------------
-- Test: open_files works and persists
-----------------------------------------------------------------------
print("  test open_files...")
dialog_calls = {}
local files = file_browser.open_files("multi_import", nil, "Open", "All (*)")
assert(type(files) == "table" and #files == 2, "should return table of paths")
assert(dialog_calls[1].dir == "", "first call should pass empty dir")

-- Second call should recall dir from first file in result
dialog_calls = {}
file_browser.open_files("multi_import", nil, "Open", "All (*)")
assert(dialog_calls[1].dir == "/Users/joe/footage",
    "should recall dir from first file, got: " .. tostring(dialog_calls[1].dir))
print("  ✓ open_files")

-----------------------------------------------------------------------
-- Test: open_directory works and persists
-----------------------------------------------------------------------
print("  test open_directory...")
dialog_calls = {}
local dir = file_browser.open_directory("export_dir", nil, "Select")
assert(dir == "/Users/joe/exports/final", "should return directory")
assert(dialog_calls[1].dir == "")

-- Second call should recall the directory itself (not parent)
dialog_calls = {}
file_browser.open_directory("export_dir", nil, "Select")
assert(dialog_calls[1].dir == "/Users/joe/exports/final",
    "should recall directory, got: " .. tostring(dialog_calls[1].dir))
print("  ✓ open_directory")

-----------------------------------------------------------------------
-- Test: cancelled dialog (nil result) does NOT overwrite persisted path
-----------------------------------------------------------------------
print("  test cancelled dialog preserves path...")
-- Set up a dialog that returns nil (user cancelled)
_G.qt_constants.FILE_DIALOG.OPEN_FILE = function(_parent, _title, _filter, returned_dir)
    table.insert(dialog_calls, { type = "OPEN_FILE", dir = returned_dir })
    return nil
end

dialog_calls = {}
-- "test_import" already has /Users/joe/footage persisted from earlier
local cancelled = file_browser.open_file("test_import", nil, "Open", "All (*)")
assert(cancelled == nil, "should return nil on cancel")

-- Restore working dialog and verify path still persisted
_G.qt_constants.FILE_DIALOG.OPEN_FILE = function(_parent, _title, _filter, restored_dir)
    table.insert(dialog_calls, { type = "OPEN_FILE", dir = restored_dir })
    return "/somewhere/else/file.txt"
end
dialog_calls = {}
file_browser.open_file("test_import", nil, "Open", "All (*)")
assert(dialog_calls[1].dir == "/Users/joe/footage",
    "cancelled dialog should not overwrite persisted path, got: " .. tostring(dialog_calls[1].dir))
print("  ✓ cancelled dialog preserves path")

-----------------------------------------------------------------------
-- Test: JSON round-trip (fresh load from disk)
-----------------------------------------------------------------------
print("  test JSON round-trip from disk...")
-- Force fresh module state
package.loaded["core.file_browser"] = nil
local file_browser2 = require("core.file_browser")
file_browser2._set_persistence_path(test_json_path)

-- Should load paths saved by previous instance
dialog_calls = {}
_G.qt_constants.FILE_DIALOG.OPEN_FILE = function(_parent, _title, _filter, loaded_dir)
    table.insert(dialog_calls, { type = "OPEN_FILE", dir = loaded_dir })
    return "/dummy"
end
file_browser2.open_file("test_import", nil, "Open", "All (*)")
-- test_import was last set to /somewhere/else by the post-cancel verification call
assert(dialog_calls[1].dir == "/somewhere/else",
    "should load persisted path from disk, got: " .. tostring(dialog_calls[1].dir))
print("  ✓ JSON round-trip from disk")

-----------------------------------------------------------------------
-- Test: different names are independent
-----------------------------------------------------------------------
print("  test independent names...")
dialog_calls = {}
file_browser2.open_file("name_a", nil, "Open", "All (*)")
assert(dialog_calls[1].dir == "", "name_a should have no persisted path")
print("  ✓ independent names")

-- Cleanup
os.execute(string.format("rm -rf %q", test_dir))

print("✅ test_file_browser.lua passed")
