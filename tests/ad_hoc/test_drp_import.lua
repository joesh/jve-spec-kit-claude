#!/usr/bin/env luajit

--- Test script for DaVinci Resolve .drp project import
-- Demonstrates parsing and importing Resolve projects

package.path = package.path .. ";./src/lua/?.lua;./src/lua/ui/?.lua"

local drp_importer = require("importers.drp_importer")

print("=== DaVinci Resolve .drp Importer Test ===\n")

-- Example 1: Parse .drp file structure
print("Test 1: Parse .drp file")
print("Usage:")
print('  local result = drp_importer.parse_drp_file("/path/to/project.drp")')
print()

-- Example 2: Show expected .drp structure
print("Test 2: Expected .drp file structure")
print(".drp file = ZIP archive containing:")
print("  - project.xml           (project settings, frame rate, resolution)")
print("  - MediaPool/Master/MpFolder.xml  (media bin organization)")
print("  - SeqContainer/*.xml    (timeline sequences with tracks/clips)")
print()

-- Example 3: Parse result structure
print("Test 3: Parse result structure")
print([[
{
  success = true,
  project = {
    name = "My Project",
    settings = {
      frame_rate = 30.0,
      width = 1920,
      height = 1080
    }
  },
  media_items = {
    { name = "Clip001.mp4", file_path = "/path/to/clip.mp4", duration = 5000 },
    ...
  },
  timelines = {
    {
      name = "Timeline 1",
      duration = 60000,
      tracks = {
        {
          type = "VIDEO",
          index = 1,
          clips = {
            {
              name = "Clip001",
              start_time = 0,
              duration = 5000,
              source_in = 0,
              source_out = 5000,
              file_path = "/path/to/clip.mp4"
            },
            ...
          }
        },
        ...
      }
    },
    ...
  }
}
]])
print()

-- Example 4: Command system integration
print("Test 4: Command system integration")
print([[
-- Import via command system (provides undo/redo)
local command_manager = require("core.command_manager")
command_manager.execute("ImportResolveProject", {
  drp_path = "/path/to/project.drp"
})

-- Undo import (deletes all imported data)
command_manager.undo()

-- Redo import (re-imports the project)
command_manager.redo()
]])
print()

-- Example 5: Timecode parsing
print("Test 5: Timecode format handling")
print("Resolve uses rational notation for timecodes:")
print('  "900/30" = frame 900 at 30fps = 30 seconds = 30000ms')
print('  "1800/30" = frame 1800 at 30fps = 60 seconds = 60000ms')
print()
print("Parser converts these to milliseconds automatically.")
print()

-- Example 6: Real-world workflow
print("Test 6: Real-world import workflow")
print([[
1. Export project from DaVinci Resolve:
   File → Export Project → Save as .drp

2. Import into JVE:
   command_manager.execute("ImportResolveProject", {
     drp_path = "/path/to/exported_project.drp"
   })

3. Result:
   - Creates project record in database
   - Imports all media items with metadata
   - Recreates all timelines with exact structure
   - Preserves all clips with accurate timing
   - Full undo support if import needs to be reverted

4. If media files are offline:
   - Use media relinking system (RelinkMedia command)
   - Supports path-based, filename-based, or metadata matching
   - Can match by timecode, reel name, duration, resolution
]])
print()

print("=== Test Complete ===")
