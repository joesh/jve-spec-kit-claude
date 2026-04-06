# JVE Editing Commands Audit

Comparison of JVE's implemented commands against DaVinci Resolve (Edit page) and Adobe Premiere Pro core timeline editing operations. Audited 2026-04-05.

---

## Implemented

### Basic Editing
- **Insert** / **Overwrite** — standard 3-point edit
- **Cut** / **Copy** / **Paste** — mark-based and selection-based
- **Blade (Split)** — Cmd+B, split at playhead
- **LiftRange** / **ExtractRange** — mark-based lift and extract
- **DeleteClip** / **RippleDelete** / **RippleDeleteSelection**
- **InsertGap** — insert gap at playhead

### Trimming
- **TrimHead** / **TrimTail** — trim to playhead
- **ExtendEdit** — extend edge to playhead
- **RippleEdit** / **BatchRippleEdit** — drag-based ripple
- **Nudge** — move clip(s) by delta

### Selection
- **SelectAll** / **DeselectAll**
- **SelectClips** / **SelectEdges** / **SelectGaps** / **SelectRectangle**
- **SelectBrowserItems**

### Marks
- **SetMarkIn** / **SetMarkOut** / **ClearMarkIn** / **ClearMarkOut** / **ClearMarks**
- **MarkClipExtent** (X key) — mark to clip boundaries
- **GoToMarkIn** / **GoToMarkOut**

### Navigation & Playback
- **GoToNextEdit** / **GoToPrevEdit**
- **GoToStart** / **GoToEnd**
- **GoToTimecode** — TC dialog
- **MovePlayhead** / **SetPlayhead** / **StepFrame**
- **TogglePlay** / **ShuttleForward** / **ShuttleReverse** / **ShuttleStop** (with JKL slow-play)

### Clip Properties
- **SetClipProperty** — volume, name, etc.
- **ToggleClipEnabled** — enable/disable
- **LinkClips** / **UnlinkClips**
- **DuplicateClips** / **DuplicateMasterClip**
- **MatchFrame** — load source at playhead frame

### Track Management
- **AddTrack** / **SetTrackProperty** (mute, solo, locked, volume, pan) / **SetTrackHeights**

### Project & Media
- **NewProject** / **OpenProject** / **CreateSequence**
- **ImportMedia** / **ImportFCP7XML** / **ImportResolveProject**
- **NewBin** / **DeleteBin** / **RenameItem** / **RevealInFilesystem**
- **CreateSmartBin** / **UpdateSmartBin** / **DeleteSmartBin**
- **ShowRelinkDialog**

### UI / View
- **TimelineZoomIn** / **ZoomOut** / **ZoomFit**
- **ToggleSnapping** / **ToggleMaximizePanel** / **ToggleFullscreenView**
- **Find** / **FindNext** / **FindPrevious** / **FindReplace** / **Sift** (quick filter)
- **EditHistory** / **Undo** / **Redo**

---

## Missing

### Basic Editing — High Priority

| Command | R | P | Description |
|---|:---:|:---:|---|
| Replace Edit | Y | Y | Replace clip under playhead with source, matching around playhead position |
| Place on Top / Superimpose | Y | Y | Source to next available track above |
| Append to End | Y | Y | Add source after last clip on target track |
| Paste Insert | Y | Y | Paste at playhead with ripple (JVE paste is overwrite only) |
| Ripple Overwrite | Y | - | Overwrite + ripple the duration difference |

### Trimming — High Priority

| Command | R | P | Description |
|---|:---:|:---:|---|
| Roll Trim | Y | Y | Move edit point between adjacent clips, total duration unchanged |
| Slip | Y | Y | Shift source window, timeline position unchanged |
| Slide | Y | Y | Move clip, neighbors absorb the change |
| Dynamic Trim (JKL) | Y | - | Trim while playing — Resolve signature feature |
| Nudge Trim | Y | Y | Move selected *edit point* by N frames (distinct from clip nudge) |
| Join Through Edit | Y | - | Remove edit point between two clips from same source |
| Razor All Tracks | Y | Y | Blade across all tracks at playhead |

### Selection — Medium Priority

| Command | R | P | Description |
|---|:---:|:---:|---|
| Select All Forward on Track | Y | Y | Select clip + everything to its right |
| Select All Backward on Track | Y | Y | Select clip + everything to its left |
| Select All Forward All Tracks | Y | Y | Everything right of playhead, all tracks |
| Select All Backward All Tracks | Y | Y | Everything left of playhead, all tracks |
| Select Clips at Playhead | Y | - | All clips intersecting playhead |
| Select In to Out | Y | Y | All clips within mark range |
| Linked Selection toggle | Y | Y | Global: selecting video auto-selects linked audio |

### Navigation — Medium Priority

| Command | R | P | Description |
|---|:---:|:---:|---|
| Next/Prev Gap | Y | Y | Jump to next gap on targeted track |
| Next/Prev Marker | Y | Y | Jump to markers (markers not yet implemented) |
| Play Around (preroll/postroll) | Y | Y | Play around current position with configurable pre/post |
| Scroll to Playhead | Y | Y | Center view on playhead |

### Marks — Low Priority

| Command | R | P | Description |
|---|:---:|:---:|---|
| Mark Selection | Y | Y | Set in/out to span of selected clips |
| Mark to End / Mark from Start | Y | - | Quick mark from playhead to boundary |
| Add/Modify/Delete Marker | Y | Y | Timeline and clip markers — whole subsystem missing |

### Speed / Retiming — Future

| Command | R | P | Description |
|---|:---:|:---:|---|
| Change Clip Speed | Y | Y | Constant speed percentage |
| Freeze Frame | Y | Y | Hold one frame |
| Reverse Clip | Y | Y | Play backward |
| Speed Ramp / Time Remap | Y | Y | Variable speed with keyframes |
| Fit to Fill | Y | Y | Auto-speed to fill marked duration |

### Compound / Multicam — Future

| Command | R | P | Description |
|---|:---:|:---:|---|
| Nest / Compound Clip | Y | Y | Collapse clips into container (IS-a refactor enables this) |
| Multicam Create | Y | Y | Synced multi-angle group |
| Multicam Cut | Y | Y | Live-switch angles during playback |
| Group / Ungroup | Y | Y | Move/delete as unit (distinct from link) |

### Track Management — Gaps

| Command | R | P | Description |
|---|:---:|:---:|---|
| Delete Track | Y | Y | Remove track + all clips |
| Track Patching / Targeting | Y | Y | Route source V1/A1 to timeline tracks |
| Auto-Select per track | Y | - | Which tracks participate in razor/select-all |
| Move Track Up/Down | Y | Y | Reorder |
| Rename Track | Y | Y | Label |

### Clipboard — Gaps

| Command | R | P | Description |
|---|:---:|:---:|---|
| Paste Attributes | Y | Y | Apply effects/properties from one clip to another |
| Remove Attributes | Y | - | Strip attributes |
| Copy Timecode | Y | - | Copy playhead TC to system clipboard |

### View — Minor Gaps

| Command | R | P | Description |
|---|:---:|:---:|---|
| Zoom to In/Out | Y | - | Zoom to marked region |
| Show Audio Waveforms toggle | Y | Y | Waveform display in clips |
| Show Thumbnails toggle | Y | Y | Filmstrip in video clips |
| Proxy Toggle | Y | Y | Switch proxy/full-res |

---

## Priority Tiers

**Tier 1 — Core editing gaps** (most editors would expect these):
Roll Trim, Slip, Slide, Select Forward/Backward, Replace Edit, Append to End, Paste Insert, Linked Selection toggle, Track Patching/Auto-Select

**Tier 2 — Power features** (serious editors need these):
Dynamic Trim, Markers, Join Through Edit, Speed Change, Freeze Frame, Play Around, Select In-to-Out

**Tier 3 — Advanced** (differentiators):
Compound Clips, Multicam, Speed Ramp, Paste Attributes, Razor All Tracks
