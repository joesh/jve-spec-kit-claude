# Quickstart: RelinkClips

## Verify the Feature

### 1. Import a DRP project
```bash
./build/bin/JVEEditor
# File → Open → select a .drp file → converts to .jvp
# Verify clips appear on timeline
```

### 2. Trigger offline state
The imported DRP references files on external volumes. If those volumes are unmounted, clips show as offline (red "OFFLINE" overlay).

### 3. Reconnect Media (Cmd+Shift+R)
- Dialog shows count of offline clips
- Clip list shows each offline clip with name + old path
- Pick search directory containing the media files
- Click "Matching Rules..." to configure (defaults: Filename + Timecode on)
- Click "Relink" → progress bar + live results per clip
- Review results (check/x icons in clip list)
- Click "Apply" to commit

### 4. Verify Reconnection
- Timeline clips no longer show "OFFLINE"
- Playback shows correct video/audio at correct TC positions
- Source viewer shows correct frames when double-clicking clips
- 2-pop sync maintained (video + audio aligned)

### 5. Verify Undo
- Cmd+Z → all clips revert to offline
- Any new media records for segment files are removed
- Cmd+Shift+Z → reconnection restored

### 6. Verify TC Offset Adjustment
- Enable "Accept Trimmed Media" in matching rules
- Search dir with media-managed copies (different start TC)
- Clips whose TC range falls within the managed copy reconnect
- Source_in/source_out adjusted correctly — playback shows same content as before

### 7. Verify Segment Files
- Enable "Accept Filename Suffixes" in matching rules
- Search dir with segment files (e.g., `clip_001.mov`, `clip_002.mov`)
- Each clip connects to the segment containing its TC range
- New media records created for segment files
- Undo removes the segment media records

### 8. Run Tests
```bash
make -j4
# All tests pass: luacheck 0 warnings, Lua tests, C++ tests, binding tests, integration tests
```
