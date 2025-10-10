# Event Sourcing UUID Determinism

## Document Purpose

This document describes a critical requirement for event-sourced systems: **UUID determinism during command replay**. It explains why this matters, how violations manifest, how to detect them, and how to fix them.

## The Problem

### Symptom
Undo/replay fails with "Clip not found" errors when replaying from the beginning of the event log, but works fine when replaying from recent snapshots.

### Root Cause
Commands that create entities (clips, tracks, etc.) generate fresh UUIDs on each execution. During replay, these commands create entities with **different UUIDs** than the original execution. Later commands that reference the original UUIDs fail because those entities don't exist in the replayed state.

### Example Scenario
```
Original Execution:
  Command 51 (Overwrite): Creates clip with UUID "6fe18fda-..."
  Command 53 (MoveClipToTrack): Moves clip "6fe18fda-..." to track "video2"
  ✅ Success - clip exists with that UUID

Replay from Beginning:
  Command 51 (Overwrite): Creates clip with UUID "a1b2c3d4-..." (NEW!)
  Command 53 (MoveClipToTrack): Tries to move clip "6fe18fda-..."
  ❌ ERROR: Clip not found - that UUID doesn't exist!
```

## The Requirement

**All commands that create entities must produce identical UUIDs when replayed.**

This ensures **referential integrity** - any UUID mentioned in the event log is guaranteed to exist because replay recreates it with the same ID.

## Implementation Pattern

### Three-Step Pattern for Entity-Creating Commands

```lua
-- Step 1: Generate UUID on FIRST execution
local clip = Clip.create("New Clip", media_id)

-- Step 2: Check if we're replaying (clip_id already stored)
local existing_clip_id = command:get_parameter("clip_id")
if existing_clip_id then
    clip.id = existing_clip_id  -- Reuse UUID for replay
end

-- Step 3: Store UUID for future replays
command:set_parameter("clip_id", clip.id)

-- Now save to database
clip:save(db)
```

### Why This Works

1. **First execution**: Generate fresh UUID, store in command parameters
2. **Replay**: Retrieve stored UUID from parameters, assign to new entity
3. **Result**: Same UUID in both executions, referential integrity preserved

## Detection

### Symptoms to Watch For

1. **"Clip not found" errors during undo**
   - Error message: `WARNING: Clip.load: Clip not found: <uuid>`
   - Occurs during `replay_events()` call
   - Happens only when replaying from beginning (past snapshot boundary)

2. **Commands fail during replay but worked originally**
   - Commands like MoveClipToTrack, RippleEdit reference clips by ID
   - These commands executed successfully originally
   - Fail during replay because clip IDs don't match

3. **Replay succeeds from snapshots but fails from beginning**
   - Snapshots capture actual UUIDs from database
   - Replaying from snapshot uses those UUIDs
   - Replaying from empty state generates new UUIDs

### Diagnostic Steps

1. **Identify the failing command**
   ```
   ERROR: Failed to replay command 53 (MoveClipToTrack)
   WARNING: Clip.load: Clip not found: 6fe18fda-9fe6-4afd-8930-352e4a84277a
   ```

2. **Find where that UUID was created**
   ```bash
   sqlite3 project.db "SELECT sequence_number, command_type, command_args
                       FROM commands
                       WHERE command_args LIKE '%6fe18fda%'
                       ORDER BY sequence_number"
   ```

   Result:
   ```
   51|Overwrite|{"clip_id":"6fe18fda-...","duration":3000,...}
   53|MoveClipToTrack|{"clip_id":"6fe18fda-...",...}
   ```

3. **Check if creating command reuses UUID**
   - Open the command executor for that type (e.g., `command_executors["Overwrite"]`)
   - Look for `command:get_parameter("clip_id")` before entity creation
   - Look for UUID assignment: `clip.id = existing_clip_id`
   - If missing, you've found the bug

## Fix Process

### Step-by-Step Fix

1. **Locate the command executor** that creates entities
   ```lua
   command_executors["Overwrite"] = function(command)
       -- Find the Clip.create() call
       local clip = Clip.create("New Clip", media_id)
   ```

2. **Add UUID reuse logic BEFORE setting other properties**
   ```lua
   local clip = Clip.create("New Clip", media_id)

   -- ADD THIS:
   local existing_clip_id = command:get_parameter("clip_id")
   if existing_clip_id then
       clip.id = existing_clip_id  -- Reuse for replay
   end
   ```

3. **Ensure UUID is stored in parameters**
   ```lua
   -- This should already exist, but verify:
   command:set_parameter("clip_id", clip.id)
   ```

4. **Test the fix**
   ```bash
   # With app closed, clear database past snapshot
   # Then run app and undo past that point
   # Should replay successfully without "not found" errors
   ```

## Commands to Audit

### High-Risk Commands (Create Entities)

These commands must implement UUID determinism:

- ✅ **Insert**: Creates clips - FIXED (line 1148-1152)
- ✅ **Overwrite**: Creates clips - FIXED (line 1337-1342)
- **SplitClip**: Creates right-side clip - CHECK THIS
- **CreateTrack**: Creates tracks - CHECK THIS
- **ImportMedia**: Creates media entries - CHECK THIS
- **AddMarker**: Creates markers - CHECK THIS

### Low-Risk Commands (Only Modify)

These commands don't create entities, only reference them:

- **MoveClipToTrack**: References existing clip
- **RippleEdit**: References existing clip
- **Nudge**: References existing clips
- **DeleteClip**: References existing clip

## Prevention

### Code Review Checklist

When reviewing or writing command executors:

- [ ] Does this command create any entities (clips, tracks, media, markers)?
- [ ] If yes, does it generate a UUID?
- [ ] Does it check for `command:get_parameter("<entity>_id")` before creation?
- [ ] Does it assign existing UUID if found: `entity.id = existing_id`?
- [ ] Does it store the UUID: `command:set_parameter("<entity>_id", entity.id)`?

### Testing Strategy

1. **Snapshot-Free Replay Test**
   - Disable snapshot creation temporarily
   - Execute series of commands that create and reference entities
   - Undo to beginning
   - Should replay successfully without "not found" errors

2. **UUID Consistency Test**
   - Execute command that creates entity, note UUID
   - Clear database, replay that command
   - Verify replayed entity has same UUID

## Related Issues

### Issue: NULL Parent Sequence Number

**Symptom**: Command has `parent_sequence_number = NULL`, breaking undo tree

**Cause**: `current_sequence_number` was NULL during command execution due to improper initialization

**Fix**: Check for NULL when loading undo position, default to HEAD if no commands exist

See: `command_manager.lua:38-60`

### Issue: Unchecked Database Operations

**Symptom**: Silent failures during replay, partial state corruption

**Cause**: Not checking return values from `Clip.load()`, `clip:save()`, `db:prepare()`

**Fix**: Add explicit checks with clear error messages

See: `command_manager.lua` (multiple locations, 2025-10-10 hardening pass)

## References

### Key Files

- **Command Manager**: `src/lua/core/command_manager.lua`
  - Command executors: line 568+
  - Replay system: line 1764+
  - Undo/redo: line 1936+

- **Command Model**: `src/lua/command.lua`
  - Parameter storage: line 61-73
  - Database persistence: line 102-198

- **Clip Model**: `src/lua/models/clip.lua`
  - UUID generation: line 7-14
  - Entity creation: line 17+

### Event Sourcing Principles

1. **Commands are immutable** - once logged, never modified
2. **State is derived** - always reproducible from event log
3. **Replay must be deterministic** - same commands → same state
4. **UUIDs must be stable** - same entities across replays
5. **References must resolve** - all IDs mentioned must exist

## Revision History

- **2025-10-10**: Initial documentation after fixing Overwrite UUID determinism bug
- Found by: Undo failing at sequence 100 when replaying from beginning
- Fixed by: Adding UUID reuse pattern to Overwrite command executor
