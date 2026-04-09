# Contract: Track Waveform Toggle

## UI: Track Header Button

### Placement
In the track header button row (alongside Mute, Solo, Record, Patch buttons).

### State
- Per-track boolean: `waveform_enabled` (default: true)
- Persisted in `sequence_track_layouts.track_heights_json` (extend existing JSON to include waveform toggle state per track)

### Lua Interface

```lua
-- In timeline_state or track_state:
state.get_track_waveform_enabled(track_id) → bool
state.set_track_waveform_enabled(track_id, enabled) → nil  -- persists + notifies listeners

-- Audio tracks only — video tracks always return false.
```

### Visual
- Button icon: waveform glyph or "W" label (consistent with existing button style)
- Active state: highlighted (waveform visible)
- Inactive state: dimmed (waveform hidden, flat clip body shown)

## Behavior Contract

- Default state for new tracks MUST be `true` (waveform enabled)
- Toggle MUST take effect immediately on next render (no delay)
- Toggle state MUST persist across project save/reopen
- Video tracks MUST always return `false` for `get_track_waveform_enabled`
- Toggle MUST NOT trigger peak regeneration — only controls display
