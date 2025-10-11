# Anti-Stale-Data Patterns

## Document Purpose

This document defines patterns to prevent stale object reference bugs in the event-sourced NLE architecture. These bugs occur when code retains references to entity objects (clips, tracks) whose properties have become outdated due to command execution.

## The Problem

### Symptom
Operations fail or behave incorrectly when using cached entity objects. For example:
- Drag from V2→V1 only nudges but doesn't change track
- Track checks pass but wrong track gets modified
- Selection operations work on wrong entities

### Root Cause
**Entity objects become stale after any command executes.** The in-memory clip object still shows `track_id = "video1"` even though the database and timeline_state have been updated to `track_id = "video2"`.

### Example Scenario
```lua
-- Time T0: Start drag, capture clip objects
local drag_clips = timeline_state.get_selected_clips()
-- drag_clips[1].track_id = "video1"

-- Time T1: First drag completes, executes MoveClipToTrack
-- Database now has clip on "video2"
-- BUT: drag_clips[1].track_id STILL shows "video1" (stale!)

-- Time T2: Second drag uses stale data
if drag_clips[1].track_id ~= target_track_id then  -- WRONG! Uses stale data
    -- This check fails because comparing stale "video1" to target "video1"
    -- when clip is actually on "video2"
end
```

## The Requirement

**Never use entity objects across command execution boundaries.**

Entity properties are only valid until the next command executes. After that, you must reload from timeline_state.

## Safe Patterns

### Pattern 1: Store IDs, Not Objects

```lua
-- ❌ WRONG: Storing full objects
view.drag_state = {
    clips = selected_clips  -- These will become stale!
}

-- ✅ CORRECT: Store only IDs
view.drag_state = {
    clip_ids = {}
}
for _, clip in ipairs(selected_clips) do
    table.insert(view.drag_state.clip_ids, clip.id)
end
```

### Pattern 2: Reload Before Use

```lua
-- ❌ WRONG: Using cached objects directly
for _, clip in ipairs(view.drag_state.clips) do
    if clip.track_id ~= target_track then  -- Stale data!
        move_clip(clip)
    end
end

-- ✅ CORRECT: Reload from source of truth
local all_clips = state_module.get_clips()
for _, clip_id in ipairs(view.drag_state.clip_ids) do
    local clip = find_clip_by_id(all_clips, clip_id)
    if clip and clip.track_id ~= target_track then  -- Fresh data!
        move_clip(clip)
    end
end
```

### Pattern 3: Use Helper Functions

```lua
-- Helper that always returns fresh data
local function get_fresh_clip(clip_id)
    local all_clips = state_module.get_clips()
    for _, clip in ipairs(all_clips) do
        if clip.id == clip_id then
            return clip
        end
    end
    return nil
end

-- Usage
local clip = get_fresh_clip(some_id)
if clip then
    -- Use clip.track_id, clip.start_time, etc - all fresh!
end
```

## Detection

### Runtime Checks

Add version stamps to detect stale access:

```lua
-- In timeline_state module
local state_version = 0

function M.reload_clips()
    -- ... load clips from DB ...
    state_version = state_version + 1  -- Increment on reload

    -- Stamp each clip with current version
    for _, clip in ipairs(clips) do
        clip._version = state_version
    end
end

function M.validate_clip_fresh(clip)
    if not clip then
        return false, "Clip is nil"
    end
    if clip._version ~= state_version then
        return false, string.format("Stale clip data (version %d, current %d)",
            clip._version or 0, state_version)
    end
    return true
end
```

### Static Analysis Checklist

When reviewing code that handles entities:

- [ ] Does this code span command execution? (press → move → release)
- [ ] Does it cache entity objects in state variables?
- [ ] Does it reload entities after commands execute?
- [ ] Could properties have changed between capture and use?
- [ ] Are IDs used instead of full objects where possible?

## High-Risk Code Patterns

### Multi-Phase User Interactions

Any interaction with phases is high-risk:

```lua
-- RISKY: Mouse down → move → up
on_mouse_down:
    view.drag_clips = get_selected_clips()  -- ⚠️ Cached objects

on_mouse_move:
    -- Preview uses cached clips - OK if read-only

on_mouse_up:
    execute_command()  -- Clips change in DB!
    for clip in view.drag_clips do
        -- ⚠️ STALE! Don't use clip.track_id here
    end
```

### Loops with Commands

```lua
-- RISKY: Executing commands inside loop
for _, clip in ipairs(selected_clips) do  -- ⚠️ Cached at loop start
    execute_move_command(clip.id)
    -- Now clip.track_id is stale!
    if clip.track_id == "video1" then  -- ⚠️ WRONG!
        -- ...
    end
end

-- SAFER: Reload each iteration
for _, clip_id in ipairs(selected_clip_ids) do
    execute_move_command(clip_id)
    local fresh_clip = get_fresh_clip(clip_id)  -- ✅ Reload
    if fresh_clip.track_id == "video1" then
        -- ...
    end
end
```

## Implementation Guidelines

### For View Modules (timeline_view, etc)

1. **Never store full entity objects in view state**
   - Store IDs only: `drag_state.clip_ids`
   - Not: `drag_state.clips`

2. **Reload before decisions**
   - Before checking properties: reload from timeline_state
   - Before executing commands: use fresh IDs only

3. **Use objects transiently**
   - Get fresh object
   - Use it immediately
   - Don't cache it

### For State Modules (timeline_state, etc)

1. **Provide ID-based accessors**
   ```lua
   function M.get_clip_by_id(clip_id)
       -- Always returns fresh from current state
   end
   ```

2. **Add version tracking** (optional but recommended)
   ```lua
   function M.validate_clip_fresh(clip)
       -- Detect stale access attempts
   end
   ```

3. **Document staleness in comments**
   ```lua
   -- Returns clip objects valid only until next reload_clips()
   function M.get_clips()
   ```

## Testing Strategy

### Manual Testing

1. **Two-step operation test**
   - Perform operation that modifies entity
   - Immediately perform second operation on same entity
   - Verify second operation sees fresh data

2. **Rapid successive operations**
   - Execute same command multiple times quickly
   - Each should see results of previous execution

### Automated Detection

Add assertions in development builds:

```lua
if DEV_MODE then
    function assert_clip_fresh(clip, context)
        local ok, err = timeline_state.validate_clip_fresh(clip)
        if not ok then
            error(string.format("STALE CLIP ACCESS in %s: %s (clip: %s)",
                context, err, clip.id:sub(1,8)))
        end
    end
end
```

## Related Issues

### Issue: Drag V2→V1 Only Nudges

**Date**: 2025-10-10

**Symptom**: First drag V1→V2 works. Second drag V2→V1 only nudges, doesn't change track.

**Cause**: `view.drag_state.clips` cached at drag start with `track_id = "video1"`. After first drag executed MoveClipToTrack, clips in database updated to V2, but cached objects still showed V1. Second drag compared stale V1 against target V1, saw "no change needed".

**Fix**: Reload clips before track comparison:
```lua
-- Get fresh clip data
local all_clips = state_module.get_clips()
local current_clips = {}
for _, drag_clip in ipairs(view.drag_state.clips) do
    for _, clip in ipairs(all_clips) do
        if clip.id == drag_clip.id then
            table.insert(current_clips, clip)
            break
        end
    end
end

-- Now use current_clips for decisions
```

**Prevention**: Should have stored `view.drag_state.clip_ids` instead of full objects.

## References

### Key Files

- **timeline_view.lua**: Multi-phase mouse interactions, high stale-data risk
- **keyboard_shortcuts.lua**: Multi-command loops, reload between iterations
- **timeline_state.lua**: Source of truth for entity data

### Event Sourcing Principles

1. **Commands mutate state** - Every command execution invalidates cached entities
2. **State is derived** - Only database + event log are authoritative
3. **Queries are transient** - `get_clips()` returns snapshot valid only until next command
4. **IDs are stable** - Clip/track IDs never change, safe to cache
5. **Properties are volatile** - All other fields can change at any time

## Revision History

- **2025-10-10**: Initial documentation after fixing V2→V1 drag bug
- Root cause: Stale object references in drag state
- Prevention: Store IDs only, reload before property access
