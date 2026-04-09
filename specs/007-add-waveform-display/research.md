# Research: Waveform Display

## 1. Peak File Format

**Decision**: Binary file with header + mipmapped min/max float32 data, 256 samples/peak base resolution.

**Rationale**: Industry standard (Audacity 256:1, Ardour 256:1). 256 samples/peak gives ~187 peaks/sec at 48kHz — sufficient detail at max zoom while keeping files small. A 5-minute stereo 48kHz file produces ~56KB at base level, ~75KB with all 4 mipmap levels.

**Alternatives considered**:
- SQLite storage: rejected — binary is simpler, mmap-friendly, no query overhead
- JSON/text: rejected — too large, too slow to parse
- 512 samples/peak: rejected — too coarse at high zoom
- 128 samples/peak: rejected — diminishing visual returns, 2x file size

## 2. Peak File Identity & Naming

**Decision**: Peak files named by media_id (UUID from clips table) with `.peaks` extension. Header contains source file mtime for staleness detection.

**Rationale**: media_id is stable across relinks (same master clip keeps same ID). Using path hash would break on relink. Using file content hash would require hashing the entire file (expensive for large media).

**Alternatives considered**:
- Path hash: rejected — breaks on file move/relink
- Content hash (SHA256): rejected — requires full file read, too slow for multi-GB files
- Incrementing integer: rejected — not stable across sessions

## 3. Peak File Header Format

**Decision**: Fixed 64-byte header:
- Magic bytes: "JVPK" (4 bytes)
- Version: uint32 (4 bytes) — currently 1
- Source mtime: int64 (8 bytes) — for staleness detection
- Sample rate: uint32 (4 bytes) — source sample rate
- Channels: uint16 (2 bytes) — source channel count
- Base samples per peak: uint32 (4 bytes) — 256
- Mipmap levels: uint16 (2 bytes) — 4
- Total bins per level: uint64[4] (32 bytes) — bin count at each level
- Reserved: 4 bytes padding

**Rationale**: Fixed-size header enables mmap with known data offset. Version field allows future format changes (add RMS, change resolution) without breaking existing caches.

## 4. Mipmap Level Selection

**Decision**: Pick the coarsest level where `samples_per_peak / samples_per_pixel <= 1.0`. This ensures at least 1 bin per pixel (no interpolation gaps). If zoomed in beyond base level, use base level with interpolation.

**Rationale**: Standard approach (Ardour, Audacity). Avoids aliasing from decimation while minimizing data read.

## 5. Rendering Approach

**Decision**: Batch QPainter command — single `addWaveform()` call from Lua passes peak array to C++, which draws all vertical lines in one QPainter pass.

**Rationale**: Current `addLine()` approach would require ~1920 individual Lua→C++ calls per clip per audio track. Each call creates a DrawCommand struct, pushes to vector, parses color string. Batch primitive eliminates this overhead entirely.

**Alternatives considered**:
- Individual addLine() calls: rejected — too many Lua→C++ transitions, DrawCommand vector bloat
- QImage buffer: rejected — adds complexity, QPainter vertical lines are fast enough
- OpenGL: rejected — overkill for timeline, no GPU rendering in timeline currently

## 6. Waveform Color

**Decision**: Derive from clip_audio color by darkening 40%. For disabled clips, derive from clip_audio_disabled color.

**Rationale**: Pro Tools, Logic, Reaper all derive waveform color from clip color. 40% darker provides sufficient contrast against the clip body while remaining visible.

## 7. Background Peak Generation

**Decision**: Dedicated C++ thread per peak generation job. Uses existing EMP Reader to decode audio sequentially. Emits progress via atomic counter (samples completed). Lua polls progress on timeline repaint to update progressive display.

**Rationale**: Separate from TMB reader pool (which serves playback). Sequential decode is optimal for peak gen — no seeking, just walk forward through the file. Atomic progress counter avoids mutex contention.

**Alternatives considered**:
- TMB GetTrackAudio: rejected — playback-oriented, involves reader pool locks, wrong abstraction
- Lua coroutine: rejected — would block main thread
- Multiple worker threads per file: rejected — sequential decode is already I/O-bound

## 8. File Watch Integration

**Decision**: Hook into existing `media_status._on_file_changed()` callback. When a watched media file changes, invalidate its peak cache and trigger regeneration.

**Rationale**: `media_status.lua` already watches all project media files via `QFileSystemWatcher`. Adding peak invalidation to the existing callback is the natural extension point — no new watch infrastructure needed.

## 9. Cache Lifecycle

**Decision**: Peak files retained while media is reachable from any undo stack path. Orphaned peaks cleaned up on project close or undo history truncation. Cleanup scans `<project>.jvp-cache/peaks/` and deletes files whose media_id has no corresponding record in the DB and no undo reference.

**Rationale**: User requirement — undo must be able to restore clips with their waveforms intact. Cleaning on close is safe (undo stack is discarded) and avoids runtime complexity.

## 10. Monitor Waveform

**Decision**: Source and sequence monitors display a waveform strip across the bottom. Shares same peak data/cache as timeline waveforms. Lower priority — implement after timeline waveform works.

**Rationale**: User requirement. Reuses all peak infrastructure; only the rendering location and coordinate mapping differ.
