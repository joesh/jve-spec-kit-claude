# Plan: Unified Viewer Architecture

## Core Insight

**A viewer views a sequence.** That's it.

- Masterclip IS a sequence (kind="masterclip")
- Timeline IS a sequence (kind="timeline")
- The viewer doesn't know or care which kind

```
Viewer {
  sequence_id    -- which sequence to view
  playhead       -- position within sequence
  video_surface  -- display widget
}
```

The viewer calls `sequence:get_frame(position)` and displays whatever comes back. The sequence knows how to provide its content (trivial for masterclip, composite for timeline).

**There is no "source mode" vs "timeline mode"** - just viewing different sequences.
**There is no "resolver"** - the sequence IS the object that knows how to render itself.

## Current Problems

1. **Single viewer_panel** with mode-switching via title change
2. **Singleton state** (global `video_surface`, `viewer_widget` variables)
3. **media_cache.active_path** assumes one active source
4. **playback_controller** tightly coupled to single viewer

## Architecture Changes

### 1. Viewer Instance (NEW: `src/lua/ui/viewer.lua`)

Factory that creates independent viewer instances:

```lua
local Viewer = {}

function Viewer.create(viewer_id)
  return {
    id = viewer_id,
    sequence_id = nil,
    playhead = 0,
    video_surface = qt_constants.WIDGET.CREATE_GPU_VIDEO_SURFACE(),
    widget = nil,  -- container widget
    title_label = nil,
    mark_bar = nil,

    set_sequence = function(self, seq_id) ... end,
    set_playhead = function(self, pos) ... end,
    get_widget = function(self) ... end,
  }
end
```

Each instance owns:
- Its own video_surface
- Its own sequence_id reference
- Its own playhead position
- Its own mark_bar widget

### 2. Renderer Module (Video Compositor + Audio Mixer)

**Sequence stays a data model** - tracks, clips, positions, metadata.
**Rendering is a separate concern** in a new Renderer module:

```lua
-- src/lua/core/renderer.lua
local Renderer = {}

-- Video: point in time → single frame
function Renderer.get_video_frame(sequence, position)
  -- Resolves clips at position
  -- Composites layers (opacity, effects)
  -- Masterclip: trivial (single clip)
  -- Timeline: complex (multiple tracks)
  return frame
end

-- Audio: range of time → mixed buffer
function Renderer.get_audio_samples(sequence, start_position, num_samples)
  -- Resolves audio clips in range
  -- Mixes (levels, panning, effects)
  -- Returns PCM buffer
  return pcm_buffer
end
```

**Key difference**: Video is frame-by-frame. Audio is chunked (e.g., 4096 samples).

The viewer calls Renderer, not Sequence:
```lua
local frame = Renderer.get_video_frame(self.sequence, self.playhead)
self.video_surface:show(frame)
```

### 3. Media Cache Contexts (REQUIRED)

Two viewers need independent frame access. Refactor `media_cache.lua`:

```lua
-- Shared (unchanged):
M.reader_pool = {}  -- LRU pool of open readers, benefits all viewers

-- Per-viewer (new):
M.contexts = {
  [viewer_id] = {
    active_path = nil,     -- which file this viewer is showing
    video_cache = {},      -- frame cache for this viewer
    center_idx = nil,      -- prefetch window center
  }
}
```

Reader pool stays shared. Each viewer gets independent frame caching.

### 3b. Audio Constraint

- Only one audio output device (OS constraint)
- When one viewer plays, others pause (coordination rule)
- Each viewer's playback controller feeds audio to shared device
- `audio_playback` module handles device; each playback_controller queues to it

### 4. Playback Controller Per-Viewer

Each viewer has its **own playback controller instance** (not singleton):

```lua
viewer.playback_controller = PlaybackController.create()
-- Each viewer draws its own transport controls
-- Each has independent state (playing, position, speed)
```

**Coordination rule**: Only one viewer can play at a time.
```lua
function viewer:start_playback()
  -- Pause all other viewers first
  for _, other in ipairs(all_viewers) do
    if other ~= self then other:pause() end
  end
  self.playback_controller:play()
end
```

### 5. Layout Changes

Create viewers in `layout.lua`:

```lua
local viewer1 = Viewer.create("viewer_1")
local viewer2 = Viewer.create("viewer_2")

-- Add to center_splitter (nested in top_splitter)
qt_constants.LAYOUT.ADD_WIDGET(center_splitter, viewer1:get_widget())
qt_constants.LAYOUT.ADD_WIDGET(center_splitter, viewer2:get_widget())
```

Register both with focus_manager.

### 6. Remove Mode Switching

Delete from timeline_panel.lua:
- The selection_hub listener that switches "modes"
- All `playback_controller.timeline_mode` logic
- Title-changing code

Each viewer just views its assigned sequence. Clicking a viewer makes it active for playback input.

## Files to Modify

| File | Change |
|------|--------|
| `src/lua/core/renderer.lua` | NEW: video compositor + audio mixer |
| `src/lua/ui/viewer.lua` | NEW: viewer instance factory with own playback_controller |
| `src/lua/ui/viewer_panel.lua` | DELETE (replaced by viewer.lua) |
| `src/lua/core/media/media_cache.lua` | Add per-viewer contexts |
| `src/lua/core/playback/playback_controller.lua` | Make instantiable (not singleton) |
| `src/lua/ui/layout.lua` | Create 2 viewers, center_splitter |
| `src/lua/ui/timeline/timeline_panel.lua` | Remove mode-switching listener |
| `src/lua/ui/source_viewer_state.lua` | DELETE (absorbed into viewer instance) |
| `src/lua/ui/panel_manager.lua` | Update for center_splitter |

## Implementation Order

1. **Create `renderer.lua`** - video compositor + audio mixer
2. **Refactor playback_controller** - make instantiable, not singleton
3. **Create `viewer.lua`** - factory using renderer, own playback_controller
4. **Refactor media_cache** - per-viewer contexts
5. **Update layout** - create 2 viewers side-by-side
6. **Remove old code** - delete viewer_panel.lua, source_viewer_state, mode-switching
7. **Add coordination** - only one viewer plays at a time

## Verification

1. Launch app - see two viewers side by side
2. Double-click masterclip in browser → loads in active viewer
3. Click other viewer → it becomes active
4. Double-click another clip → loads in now-active viewer
5. Both viewers display independently
6. JKL affects only active viewer
7. Click timeline tab → that viewer shows timeline sequence
8. Arrow keys step through active viewer's sequence

## Future Enhancement (Not This Phase)

**Single-viewer mode with focus-based switching** (like Resolve):
- Show only one viewer at a time
- Timeline focus → show timeline sequence in viewer
- Browser focus → show selected masterclip in viewer
- This is just layout/visibility change - architecture supports it
- Skip for now, implement later

## Open Questions

None - model is clear. Viewer views a sequence. Period.
