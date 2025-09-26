# Quickstart: Video Editor M1 Foundation

## Test Scenario: Complete Editor Workflow

This quickstart validates the core M1 user journey from project creation through editing operations to persistence.

### Prerequisites
- JVE Editor M1 application built and installed
- Sample media files available for testing
- All panels (Project Browser, Timeline, Inspector, Viewers) visible

### Step 1: Project Setup
1. **Launch JVE Editor**
   - Verify all panels are visible: Project Browser, Timeline, Inspector, Viewers
   - Verify empty state with no projects loaded
   
2. **Create New Project**
   - Create project "M1_Test_Project"
   - Verify .jve file created and project appears in interface
   - Verify Project Browser shows empty media library

3. **Import Media References**
   - Import sample video and audio files
   - Verify media appears in Project Browser with thumbnails
   - Verify metadata populated (duration, frame rate, format info)

### Step 2: Sequence Creation
1. **Create Sequence**
   - Create new sequence "Main_Timeline" with 30fps
   - Verify sequence appears in Project Browser
   - Verify Timeline panel shows empty tracks (V1, A1, A2)

2. **Timeline Layout**
   - Verify track headers show V1, A1, A2 labels
   - Verify timeline ruler shows timecode
   - Verify playhead at 00:00:00:00

### Step 3: Editing Operations
1. **Place Clips**
   - Drag video clip from Project Browser to V1 track
   - Drag audio clips to A1 and A2 tracks
   - Verify clips appear with correct duration and position
   - Verify clip blocks show names and durations

2. **Clip Selection**
   - Click single clip → verify Inspector shows properties
   - Shift+click to extend selection → verify multi-selection
   - Cmd+click to toggle clips → verify selection changes
   - Verify Inspector shows tri-state controls for mixed values

3. **Inspector Properties**
   - Select single clip → edit speed property → verify Timeline updates
   - Select multiple clips → edit color property → verify applied to all
   - Switch to Metadata tab → edit keywords → verify persistence
   - Test per-property undo → verify specific property reverts

### Step 4: Editing Commands
1. **Split Operation**
   - Position playhead at 10 second mark
   - Press Cmd+B (blade) → verify clip splits at playhead
   - Verify Timeline shows two clips with correct boundaries
   - Verify command logged for deterministic replay

2. **Ripple Delete**
   - Select middle clip segment
   - Execute ripple delete → verify gap closes
   - Verify downstream clips shift left automatically
   - Verify sync badges if audio/video affected differently

3. **Edge Selection & Roll**
   - Click between adjacent clips to select edge
   - Cmd+click to select multiple edges
   - Drag edge → verify roll operation (one clip shorter, adjacent longer)
   - Verify total sequence duration unchanged

### Step 5: Keyboard Shortcuts
1. **Playhead Control**
   - J key → verify playhead moves backward
   - K key → verify playhead stops
   - L key → verify playhead moves forward
   - Verify Viewers update with timecode overlays (no video playback yet)

2. **Additional Shortcuts**
   - Spacebar → verify play/pause toggle (playhead only in M1)
   - Arrow keys → verify frame-by-frame movement
   - Cmd+B → verify blade/split operation

### Step 6: Persistence & Replay
1. **Save Project**
   - Save project → verify atomic write to .jve file
   - Verify no WAL/SHM sidecar files created
   - Verify file safe to copy during save operation

2. **Reload Test**
   - Close project
   - Reopen .jve file → verify identical state restored
   - Verify all clips, properties, and selection state preserved
   - Verify command log intact for replay

3. **Deterministic Replay**
   - Execute sequence of commands (split, move, property changes)
   - Save, reload, and replay command sequence
   - Verify identical post-hash states
   - Verify undo/redo chain intact

### Step 7: Error Handling
1. **Invalid Operations**
   - Attempt to delete referenced media → verify error with hint
   - Enter invalid property value → verify validation error
   - Attempt overlapping clip placement → verify prevented with feedback

2. **Recovery**
   - Test undo after each error → verify clean state restoration
   - Test project save after errors → verify data integrity maintained

### Expected Results
- ✅ All panels functional and responsive
- ✅ Complete editing workflow from import to export works
- ✅ Multi-selection and tri-state properties function correctly
- ✅ Keyboard shortcuts respond appropriately 
- ✅ Project persistence maintains exact state across sessions
- ✅ Command determinism enables reliable replay
- ✅ Error handling provides clear feedback with recovery options

### Success Criteria
1. **Usability**: Editor feels responsive and professional
2. **Data Integrity**: No data loss or corruption during operations
3. **Performance**: UI updates complete within 16ms for smooth interaction
4. **Reliability**: Command replay produces identical results consistently
5. **Constitutional Compliance**: All operations follow TDD patterns and library-first architecture

This quickstart validates that M1 delivers a truly usable editor skeleton ready for subsequent milestone development.