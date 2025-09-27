# Data Model: Video Editor M1 Foundation

## Core Entities

### Project
**Purpose**: Top-level container for all editing session data
**Fields**:
- `id` (UUID): Unique project identifier
- `name` (string): User-visible project name
- `created_at` (timestamp): Project creation time
- `modified_at` (timestamp): Last modification time
- `settings` (JSON): Project-wide preferences and configuration

**Relationships**: One-to-many with Sequences
**Validation Rules**: Name must be non-empty, timestamps must be valid
**State Transitions**: Created → Modified → Saved

### Sequence
**Purpose**: Timeline container with tracks and clips, defines canvas/composition settings
**Fields**:
- `id` (UUID): Unique sequence identifier
- `project_id` (UUID): Foreign key to Project
- `name` (string): User-visible sequence name
- `frame_rate` (real): Frames per second (e.g., 23.976, 24, 29.97, 30, 59.94, 60)
- `width` (integer): Canvas width in pixels (e.g., 1920, 3840)
- `height` (integer): Canvas height in pixels (e.g., 1080, 2160)
- `timecode_start` (integer): Starting timecode in ticks

**Relationships**: 
- Belongs to Project
- One-to-many with Tracks
**Validation Rules**: Frame rate must be positive, canvas resolution must be valid (width > 0, height > 0)
**State Transitions**: Created → Populated → Modified
**Derived Properties**: 
- `duration` (calculated): Total sequence duration from rightmost clip position
- `aspect_ratio` (calculated): width / height ratio

### Track
**Purpose**: Container for clips with video/audio designation
**Fields**:
- `id` (UUID): Unique track identifier
- `sequence_id` (UUID): Foreign key to Sequence
- `name` (string): User-visible track name (e.g., "Video 1", "Dialogue", "Music")
- `track_type` (enum): VIDEO or AUDIO
- `track_index` (integer): Display order (V1, V2, A1, A2, etc.)
- `enabled` (boolean): Track enabled/disabled state
- `locked` (boolean): Track locked state for editing

**Relationships**: 
- Belongs to Sequence
- One-to-many with Clips
**Validation Rules**: Track index must be unique per sequence+type
**State Transitions**: Created → Configured → Populated

### Clip
**Purpose**: Media reference with timeline position and properties
**Fields**:
- `id` (UUID): Unique clip identifier
- `track_id` (UUID): Foreign key to Track
- `media_id` (UUID): Reference to source media
- `start_time` (integer): Timeline start position in ticks
- `duration` (integer): Clip duration in ticks
- `source_in` (integer): Source media in-point in ticks
- `source_out` (integer): Source media out-point in ticks
- `enabled` (boolean): Clip enabled/disabled state

**Relationships**: 
- Belongs to Track
- References Media
- One-to-many with Properties
**Validation Rules**: Duration > 0, source_out > source_in, no overlaps on track
**State Transitions**: Created → Positioned → Modified

### Media
**Purpose**: Source media file reference and metadata
**Fields**:
- `id` (UUID): Unique media identifier
- `file_path` (string): Path to source media file
- `file_name` (string): Original filename
- `duration` (integer): Media duration in ticks
- `frame_rate` (real): Source frame rate
- `metadata` (JSON): Technical metadata (codec, resolution, etc.)

**Relationships**: One-to-many with Clips
**Validation Rules**: File path must exist, duration > 0
**State Transitions**: Imported → Analyzed → Referenced

### Property
**Purpose**: Clip instance setting with validation and undo
**Fields**:
- `id` (UUID): Unique property identifier
- `clip_id` (UUID): Foreign key to Clip
- `property_name` (string): Property identifier (speed, opacity, etc.)
- `property_value` (JSON): Current value
- `property_type` (enum): STRING, NUMBER, BOOLEAN, COLOR, etc.
- `default_value` (JSON): Schema default value

**Relationships**: Belongs to Clip
**Validation Rules**: Value must match type constraints
**State Transitions**: Created → Modified → Validated

### Command
**Purpose**: Logged editing operation for deterministic replay
**Fields**:
- `id` (UUID): Unique command identifier
- `parent_id` (UUID): Parent command for grouping
- `sequence_number` (integer): Execution order
- `command_type` (string): Operation type (split, ripple_delete, etc.)
- `command_args` (JSON): Operation parameters
- `pre_hash` (string): State hash before command
- `post_hash` (string): State hash after command
- `timestamp` (timestamp): Execution time

**Relationships**: Self-referencing for undo/redo chains
**Validation Rules**: Sequence number must be unique and incremental
**State Transitions**: Created → Executed → Logged

### Snapshot
**Purpose**: Periodic state checkpoint for fast project loading
**Fields**:
- `id` (UUID): Unique snapshot identifier
- `command_id` (UUID): Last command included in snapshot
- `snapshot_data` (BLOB): Compressed state data
- `created_at` (timestamp): Snapshot creation time

**Relationships**: References Command for replay boundary
**Validation Rules**: Snapshot data must be valid compressed format
**State Transitions**: Created → Compressed → Stored

## Relationships Diagram

```
Project (1) ─── (N) Sequence (1) ─── (N) Track (1) ─── (N) Clip
                                                           │
                                                           │ (N)
                                                           ▼
                                                       Property
                                     
Media (1) ─── (N) Clip

Command ─── (1) Snapshot
   │
   └── (self-reference for undo chains)
```

## Validation Rules Summary

1. **Temporal Integrity**: No clip overlaps on same track, all times >= 0
2. **Reference Integrity**: All foreign keys must exist
3. **Command Determinism**: Command replay must produce identical post_hash
4. **Data Types**: All JSON fields must validate against schemas
5. **Uniqueness**: IDs must be unique, track indices unique per sequence

## Performance Considerations

- **Indexing**: B-tree indices on all foreign keys and timestamp fields
- **Query Optimization**: Materialized views for timeline rendering
- **Batch Operations**: Commands grouped in transactions for consistency
- **Lazy Loading**: Media metadata loaded on-demand for large projects