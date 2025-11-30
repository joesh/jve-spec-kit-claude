#!/usr/bin/env luajit

--- Test script for DaVinci Resolve SQLite database import
-- Demonstrates importing projects from Resolve's disk database format

package.path = package.path .. ";./src/lua/?.lua;./src/lua/ui/?.lua"

local resolve_db_importer = require("importers.resolve_database_importer")

print("=== DaVinci Resolve SQLite Database Importer Test ===\n")

-- Example 1: Analyze database schema
print("Test 1: Analyze Resolve database schema")
print([[
-- Diagnostic tool to understand Resolve's database structure
local result = resolve_db_importer.analyze_schema("/path/to/resolve.db")

if result.success then
  print("Found " .. result.table_count .. " tables:")
  for table_name, columns in pairs(result.schema) do
    print("  " .. table_name .. ":")
    for _, col in ipairs(columns) do
      print("    - " .. col.name .. " (" .. col.type .. ")")
    end
  end
end
]])
print()

-- Example 2: Import from database
print("Test 2: Import Resolve project from disk database")
print([[
local result = resolve_db_importer.import_from_database("/path/to/resolve.db")

if result.success then
  print("Project: " .. result.project.name)
  print("Media items: " .. #result.media_items)
  print("Timelines: " .. #result.timelines)

  for _, timeline in ipairs(result.timelines) do
    print("  Timeline: " .. timeline.name)
    print("    Tracks: " .. #timeline.tracks)
    for _, track in ipairs(timeline.tracks) do
      print("      " .. track.type .. track.index .. ": " .. #track.clips .. " clips")
    end
  end
end
]])
print()

-- Example 3: Database locations
print("Test 3: Resolve database file locations")
print([[
macOS:
  ~/Movies/DaVinci Resolve/Resolve Disk Database/Resolve Projects/Users/{user}/Projects/{project}/

Windows:
  %APPDATA%\Blackmagic Design\DaVinci Resolve\Resolve Disk Database\Resolve Projects\Users\{user}\Projects\{project}\

Linux:
  ~/.local/share/DaVinciResolve/Resolve Disk Database/Resolve Projects/Users/{user}/Projects/{project}/

Look for files with .resolve extension or SQLite .db files.
]])
print()

-- Example 4: Command system integration
print("Test 4: Command system integration")
print([[
-- Import via command system (provides undo/redo)
local command_manager = require("core.command_manager")
command_manager.execute("ImportResolveDatabase", {
  db_path = "/path/to/resolve.db"
})

-- Undo import (deletes all imported data)
command_manager.undo()

-- Redo import (re-imports the project)
command_manager.redo()
]])
print()

-- Example 5: Schema version compatibility
print("Test 5: Schema version compatibility")
print([[
The importer supports multiple Resolve versions by trying different SQL queries:

- Resolve 18+: Uses tables like 'project', 'timeline', 'track', 'clipItem'
- Resolve 17: Uses tables like 'settings', 'sequence', 'tracks', 'clips'
- Generic fallback: Attempts to read any SQLite database with similar structure

The importer will automatically detect which schema version is present and
use the appropriate queries.
]])
print()

-- Example 6: Key differences from .drp import
print("Test 6: Disk database vs .drp file format")
print([[
Disk Database (.db):
  ✓ Live working state (includes unsaved changes)
  ✓ Render cache metadata
  ✓ Collaboration locks and user sessions
  ✓ Full version history
  ✓ Direct SQL queries (faster for large projects)
  ✗ Not portable (absolute file paths)

.drp Export File:
  ✓ Portable snapshot (ZIP archive)
  ✓ Relative file paths
  ✓ Smaller file size
  ✗ No render cache info
  ✗ No collaboration metadata
  ✗ Requires ZIP extraction step

Use disk database import when:
- You want the absolute latest state (including auto-saves)
- You need render cache or collaboration metadata
- Performance matters for large projects

Use .drp import when:
- You're moving projects between machines
- You want a specific project snapshot
- You don't have access to the live database
]])
print()

-- Example 7: Real-world workflow
print("Test 7: Real-world import workflow")
print([[
1. Locate Resolve project database:
   find ~/Movies/DaVinci\ Resolve/Resolve\ Disk\ Database -name "*.db"

2. Analyze schema (optional, for debugging):
   local schema = resolve_db_importer.analyze_schema("/path/to/project.db")

3. Import project:
   command_manager.execute("ImportResolveDatabase", {
     db_path = "/Users/you/Movies/DaVinci Resolve/.../project.db"
   })

4. Result:
   - Creates project record in JVE database
   - Imports all media items with file paths
   - Recreates all timelines with exact structure
   - Preserves all clips with frame-accurate timing
   - Full undo support if import needs to be reverted

5. If media files are offline:
   - Use media relinking system (RelinkMedia command)
   - Supports path-based, filename-based, or metadata matching
   - Can match by timecode, reel name, duration, resolution

6. Timeline editing:
   - All imported clips are now native JVE clips
   - Full undo/redo support for all edits
   - Event sourcing ensures deterministic replay
   - Can export back to FCP7 XML, Premiere XML, or EDL
]])
print()

print("=== Test Complete ===")
print()
print("Note: This importer queries Resolve's SQLite database using multiple")
print("SQL patterns to support different Resolve versions (17, 18, 19+).")
print("The actual schema varies by version, so the importer tries all known")
print("table/column naming conventions and uses the first successful query.")
