# Quickstart: Waveform Display Validation

## Prerequisites
- Built JVEEditor (`make -j4` passes, 0 warnings)
- A project with at least one audio clip on the timeline
- Test media files with known audio content (speech, music, silence)

## Validation Steps

### 1. Basic Waveform Display
1. Open a project with audio clips
2. Verify: audio clips show waveform inside the clip rectangle
3. Verify: waveform is a darker shade of the clip body color
4. Verify: video clips do NOT show waveform
5. Verify: gap clips do NOT show waveform

### 2. Progressive Generation
1. Delete the `~/Library/Caches/JVE/<name>_<project_id>/peaks/` directory
2. Reopen the project
3. Verify: clips initially appear as flat rectangles
4. Verify: waveforms progressively fill in (left to right) within a few seconds
5. Verify: UI remains responsive during generation

### 3. Zoom Behavior
1. With waveforms visible, zoom in on an audio clip
2. Verify: waveform detail increases (more peaks visible per pixel)
3. Zoom out to full timeline view
4. Verify: waveform coarsens (fewer peaks per pixel) without lag

### 4. Trim / Slip
1. Trim an audio clip (shorten from head or tail)
2. Verify: waveform updates instantly to show only the visible portion
3. Slip the clip (change source_in without moving timeline position)
4. Verify: waveform shifts to reflect the new source region
5. Verify: no peak regeneration occurs (check for new background jobs)

### 5. Track Toggle
1. Click the waveform toggle button in an audio track header
2. Verify: waveform disappears, clip shows flat rectangle
3. Click toggle again
4. Verify: waveform reappears immediately
5. Save and reopen project
6. Verify: toggle state persisted correctly

### 6. Cache Persistence
1. Close and reopen the project
2. Verify: waveforms appear immediately (no regeneration)
3. Check `~/Library/Caches/JVE/<name>_<project_id>/peaks/` directory exists with `.peaks` files

### 7. Media Change Detection
1. Replace a media file with a different audio file (same path, different content)
2. Verify: waveform regenerates to reflect new audio content
3. (If file watcher active): verify regeneration happens without reopening project

### 8. Offline Clips
1. Move a media file to a different location (make clip offline)
2. Verify: clip shows offline appearance, no waveform
3. Relink the clip to the file
4. Verify: waveform regenerates for the new file

### 9. Disabled Clips
1. Disable an audio clip (toggle enabled state)
2. Verify: waveform still shown but in disabled/dimmed color
3. Re-enable clip
4. Verify: waveform returns to normal color

### 10. Undo Safety
1. Delete an audio clip from the timeline
2. Verify: peak file NOT deleted from cache (still in undo stack)
3. Undo the delete
4. Verify: waveform appears immediately (from cached peaks)

## Performance Check
- Timeline with 10+ audio clips should repaint without visible stutter
- Peak generation for a 5-minute audio file should complete within 5 seconds
- Opening a project with cached peaks should show waveforms within 1 frame
