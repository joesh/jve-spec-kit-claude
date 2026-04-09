# Data Model: Waveform Display

## Entities

### PeakFile (binary on disk)

**Location**: `<project>.jvp-cache/peaks/<media_id>.peaks`

**Header** (64 bytes, fixed):

| Field | Type | Bytes | Description |
|-------|------|-------|-------------|
| magic | char[4] | 4 | "JVPK" |
| version | uint32 | 4 | Format version (1) |
| source_mtime | int64 | 8 | Media file mtime at generation time |
| sample_rate | uint32 | 4 | Source audio sample rate |
| channels | uint16 | 2 | Source channel count |
| base_spp | uint32 | 4 | Base samples-per-peak (256) |
| num_levels | uint16 | 2 | Mipmap level count (4) |
| bins_per_level | uint64[4] | 32 | Bin count at each mipmap level |
| reserved | uint8[4] | 4 | Padding (zero) |

**Data** (after header):

Per channel, per mipmap level, contiguous:
```
Level 0: [min0, max0, min1, max1, ...] × channels   (256 spp)
Level 1: [min0, max0, min1, max1, ...] × channels   (512 spp)
Level 2: [min0, max0, min1, max1, ...] × channels   (1024 spp)
Level 3: [min0, max0, min1, max1, ...] × channels   (2048 spp)
```

Each min/max is float32. Layout: all channels interleaved within each level (ch0_min, ch0_max, ch1_min, ch1_max per bin).

**Size estimate**: 5-min stereo 48kHz file:
- Total samples: 5 × 60 × 48000 = 14,400,000
- Level 0 bins: 56,250 × 2 channels × 8 bytes = 900,000 bytes
- Level 1-3: ~450KB total (each level halves)
- Total: ~1.4MB header+data

### PeakGenerationJob (in-memory, C++)

| Field | Type | Description |
|-------|------|-------------|
| media_id | string | UUID of media file being processed |
| media_path | string | Filesystem path to source audio |
| output_path | string | Path to `.peaks` file being written |
| state | enum | Queued, Running, Complete, Failed |
| progress_samples | atomic<int64> | Samples processed so far |
| total_samples | int64 | Total samples in source file |
| cancel_flag | atomic<bool> | Set true to abort |

### PeakCache (in-memory, Lua side)

| Field | Type | Description |
|-------|------|-------------|
| cache | table | media_id → PeakHandle mapping |
| pending | table | media_id → generation job state |

**PeakHandle** (per loaded peak file):

| Field | Type | Description |
|-------|------|-------------|
| media_id | string | UUID key |
| mmap_ptr | lightuserdata | Pointer to mmap'd peak file data |
| header | table | Parsed header fields |
| ready_bins | integer | Bins available (for progressive display) |

## State Transitions

### Peak Generation Lifecycle

```
[No peak file] → QUEUED → RUNNING → COMPLETE
                              ↓
                           FAILED (decode error, disk full)
                              ↓
                        [No waveform shown]

COMPLETE + media mtime changed → STALE → QUEUED (regenerate)
COMPLETE + media removed from undo stack → ORPHANED → DELETED (on project close)
```

## Relationships

- PeakFile ← 1:1 → media (via media_id)
- PeakFile ← 1:many → clips (all clips with same media_id share one PeakFile)
- PeakGenerationJob ← 1:1 → PeakFile (one job produces one file)
- PeakCache ← 1:many → PeakHandle (one cache holds all loaded peaks)
- Track.waveform_enabled ← per-track toggle state (in-memory, persisted in track_heights_json or similar)

## Validation Rules

- Peak file magic MUST be "JVPK" — reject on mismatch (corrupt/wrong file)
- Peak file version MUST be supported — reject and regenerate on version mismatch
- source_mtime MUST match current media file mtime — regenerate on mismatch
- channels MUST be > 0
- base_spp MUST be 256 (current version)
- bins_per_level[0] MUST equal ceil(total_samples / base_spp)
- Each subsequent level MUST equal ceil(previous_level / 2)
