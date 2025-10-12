-- JVE Editor Database Schema v1.0.0
-- Constitutional requirement: Single-file (.jve) project persistence
-- All times stored as integer ticks for deterministic arithmetic

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;

-- Schema version tracking for migrations
CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER PRIMARY KEY,
    applied_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

INSERT OR IGNORE INTO schema_version (version) VALUES (1);

-- Projects table: Top-level container for all editing session data
CREATE TABLE IF NOT EXISTS projects (
    id TEXT PRIMARY KEY,                    -- UUID
    name TEXT NOT NULL CHECK(length(name) > 0),
    created_at INTEGER NOT NULL,            -- Unix timestamp
    modified_at INTEGER NOT NULL,           -- Unix timestamp  
    settings TEXT DEFAULT '{}',             -- JSON configuration
    
    CONSTRAINT valid_timestamps CHECK(created_at <= modified_at)
);

-- Sequences table: Timeline containers with canvas settings
CREATE TABLE IF NOT EXISTS sequences (
    id TEXT PRIMARY KEY,                    -- UUID
    project_id TEXT NOT NULL,
    name TEXT NOT NULL CHECK(length(name) > 0),
    frame_rate REAL NOT NULL CHECK(frame_rate > 0),
    width INTEGER NOT NULL CHECK(width > 0),
    height INTEGER NOT NULL CHECK(height > 0),
    timecode_start INTEGER NOT NULL DEFAULT 0 CHECK(timecode_start >= 0),
    playhead_time INTEGER NOT NULL DEFAULT 0 CHECK(playhead_time >= 0),  -- Current playhead position in ms
    selected_clip_ids TEXT,                                                -- JSON array of selected clip IDs
    current_sequence_number INTEGER,                                       -- Current position in undo tree (NULL = at HEAD)

    FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
);

-- Tracks table: Containers for clips with video/audio designation
CREATE TABLE IF NOT EXISTS tracks (
    id TEXT PRIMARY KEY,                    -- UUID
    sequence_id TEXT NOT NULL,
    name TEXT NOT NULL CHECK(length(name) > 0),
    track_type TEXT NOT NULL CHECK(track_type IN ('VIDEO', 'AUDIO')),
    track_index INTEGER NOT NULL,           -- Display order (V1=1, V2=2, A1=1, A2=2)
    enabled BOOLEAN NOT NULL DEFAULT 1,
    locked BOOLEAN NOT NULL DEFAULT 0,
    muted BOOLEAN NOT NULL DEFAULT 0,
    soloed BOOLEAN NOT NULL DEFAULT 0,
    volume REAL NOT NULL DEFAULT 1.0 CHECK(volume >= 0.0 AND volume <= 2.0),
    pan REAL NOT NULL DEFAULT 0.0 CHECK(pan >= -1.0 AND pan <= 1.0),
    
    FOREIGN KEY (sequence_id) REFERENCES sequences(id) ON DELETE CASCADE,
    
    -- Ensure unique track indices per sequence and type
    UNIQUE(sequence_id, track_type, track_index)
);

-- Media table: Source media file references and metadata
CREATE TABLE IF NOT EXISTS media (
    id TEXT PRIMARY KEY,                    -- UUID
    project_id TEXT NOT NULL,               -- Project ownership
    name TEXT NOT NULL,                     -- Display name (can be renamed)
    file_path TEXT NOT NULL,                -- Absolute path to source file
    duration INTEGER NOT NULL CHECK(duration > 0),  -- Duration in milliseconds
    frame_rate REAL NOT NULL CHECK(frame_rate >= 0),  -- 0 for audio-only files
    width INTEGER DEFAULT 0,                -- Video width (0 for audio-only)
    height INTEGER DEFAULT 0,               -- Video height (0 for audio-only)
    audio_channels INTEGER DEFAULT 0,       -- Number of audio channels (0 for video-only)
    codec TEXT DEFAULT '',                  -- Primary codec (e.g., "h264", "aac")
    created_at INTEGER NOT NULL,            -- Unix timestamp
    modified_at INTEGER NOT NULL,           -- Unix timestamp
    metadata TEXT DEFAULT '{}',             -- Additional JSON metadata (bitrate, color space, etc.)

    -- File path should be unique per project (handled at application level)
    UNIQUE(file_path),
    FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
);

-- Clips table: Media references with timeline position and properties
CREATE TABLE IF NOT EXISTS clips (
    id TEXT PRIMARY KEY,                    -- UUID
    track_id TEXT,                          -- NULL when clip not yet on timeline
    media_id TEXT,                          -- NULL for generated clips (bars, tone, etc.)
    start_time INTEGER NOT NULL CHECK(start_time >= 0),
    duration INTEGER NOT NULL CHECK(duration > 0),
    source_in INTEGER NOT NULL DEFAULT 0 CHECK(source_in >= 0),
    source_out INTEGER NOT NULL CHECK(source_out > source_in),
    enabled BOOLEAN NOT NULL DEFAULT 1,
    
    FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE,
    FOREIGN KEY (media_id) REFERENCES media(id) ON DELETE SET NULL
);

-- Properties table: Clip instance settings with validation and undo
CREATE TABLE IF NOT EXISTS properties (
    id TEXT PRIMARY KEY,                    -- UUID
    clip_id TEXT NOT NULL,
    property_name TEXT NOT NULL,            -- speed, opacity, position_x, etc.
    property_value TEXT NOT NULL,           -- JSON value
    property_type TEXT NOT NULL CHECK(property_type IN ('STRING', 'NUMBER', 'BOOLEAN', 'COLOR', 'ENUM')),
    default_value TEXT NOT NULL,            -- JSON default value

    FOREIGN KEY (clip_id) REFERENCES clips(id) ON DELETE CASCADE,

    -- One property value per clip per property name
    UNIQUE(clip_id, property_name)
);

-- Clip Links table: A/V sync relationships between clips
-- A link group represents clips that move/trim together (e.g., 1 video + 2 audio channels)
CREATE TABLE IF NOT EXISTS clip_links (
    link_group_id TEXT NOT NULL,            -- Shared ID for all clips in the link group
    clip_id TEXT NOT NULL,                  -- Clip that is part of this link group
    role TEXT NOT NULL CHECK(role IN ('VIDEO', 'AUDIO_LEFT', 'AUDIO_RIGHT', 'AUDIO_MONO', 'AUDIO_CUSTOM')),
    time_offset INTEGER NOT NULL DEFAULT 0, -- Time offset from link anchor point (for dual-system sound)
    enabled BOOLEAN NOT NULL DEFAULT 1,     -- Temporarily disable link without breaking it

    PRIMARY KEY (link_group_id, clip_id),
    FOREIGN KEY (clip_id) REFERENCES clips(id) ON DELETE CASCADE
);

-- Index for finding all clips in a link group
CREATE INDEX IF NOT EXISTS idx_clip_links_group ON clip_links(link_group_id);
-- Index for finding the link group of a specific clip
CREATE INDEX IF NOT EXISTS idx_clip_links_clip ON clip_links(clip_id);

-- Commands table: Logged editing operations for deterministic replay
CREATE TABLE IF NOT EXISTS commands (
    id TEXT PRIMARY KEY,                    -- UUID
    parent_id TEXT,                         -- For command grouping/batching
    parent_sequence_number INTEGER,         -- For undo tree: which command this was executed after
    sequence_number INTEGER NOT NULL,       -- Execution order within project
    command_type TEXT NOT NULL,             -- split_clip, ripple_delete, etc.
    command_args TEXT NOT NULL,             -- JSON parameters
    pre_hash TEXT NOT NULL,                 -- State hash before command
    post_hash TEXT NOT NULL,                -- State hash after command
    timestamp INTEGER NOT NULL,             -- Unix timestamp
    playhead_time INTEGER NOT NULL DEFAULT 0,  -- Playhead position after this command (for undo/redo)
    selected_clip_ids TEXT,                     -- JSON array of selected clip IDs after this command

    FOREIGN KEY (parent_id) REFERENCES commands(id) ON DELETE SET NULL,

    -- Ensure sequence numbers are unique and incremental per project
    -- (Project association handled through application logic)
    UNIQUE(sequence_number)
);

-- Snapshots table: Periodic state checkpoints for fast project loading and event replay
CREATE TABLE IF NOT EXISTS snapshots (
    id TEXT PRIMARY KEY,                    -- UUID
    sequence_id TEXT NOT NULL,              -- Which sequence this snapshot belongs to
    sequence_number INTEGER NOT NULL,       -- Last command sequence number included in this snapshot
    clips_state TEXT NOT NULL,              -- JSON array of all clips at this point in time
    created_at INTEGER NOT NULL,            -- Unix timestamp

    FOREIGN KEY (sequence_id) REFERENCES sequences(id) ON DELETE CASCADE,

    -- Only keep one snapshot per sequence (latest wins)
    UNIQUE(sequence_id)
);

-- Indices for performance optimization
CREATE INDEX IF NOT EXISTS idx_sequences_project ON sequences(project_id);
CREATE INDEX IF NOT EXISTS idx_tracks_sequence ON tracks(sequence_id);
CREATE INDEX IF NOT EXISTS idx_clips_track ON clips(track_id);
CREATE INDEX IF NOT EXISTS idx_clips_media ON clips(media_id);
CREATE INDEX IF NOT EXISTS idx_properties_clip ON properties(clip_id);
CREATE INDEX IF NOT EXISTS idx_commands_sequence ON commands(sequence_number);
CREATE INDEX IF NOT EXISTS idx_commands_parent_sequence ON commands(parent_sequence_number);
CREATE INDEX IF NOT EXISTS idx_commands_timestamp ON commands(timestamp);
CREATE INDEX IF NOT EXISTS idx_snapshots_sequence ON snapshots(sequence_id);
CREATE INDEX IF NOT EXISTS idx_snapshots_sequence_number ON snapshots(sequence_number);

-- Triggers for maintaining data integrity and timestamps

-- Update project modified_at when any related data changes
CREATE TRIGGER IF NOT EXISTS update_project_modified_sequences
AFTER INSERT ON sequences
BEGIN
    UPDATE projects SET modified_at = strftime('%s', 'now') 
    WHERE id = NEW.project_id;
END;

CREATE TRIGGER IF NOT EXISTS update_project_modified_clips
AFTER INSERT ON clips
BEGIN
    UPDATE projects SET modified_at = strftime('%s', 'now')
    WHERE id = (
        SELECT p.id FROM projects p
        JOIN sequences s ON p.id = s.project_id
        JOIN tracks t ON s.id = t.sequence_id
        WHERE t.id = NEW.track_id
    );
END;

-- Prevent overlapping clips on the same track (business rule enforcement)
CREATE TRIGGER IF NOT EXISTS prevent_clip_overlap
BEFORE INSERT ON clips
BEGIN
    SELECT CASE
        WHEN EXISTS (
            SELECT 1 FROM clips 
            WHERE track_id = NEW.track_id 
            AND id != NEW.id
            AND NOT (
                NEW.start_time >= (start_time + duration) OR
                (NEW.start_time + NEW.duration) <= start_time
            )
        )
        THEN RAISE(ABORT, 'CLIP_OVERLAP_FORBIDDEN: Clips cannot overlap on the same track')
    END;
END;

-- Constitutional compliance views for debugging and validation

-- View: Project summary with statistics
CREATE VIEW IF NOT EXISTS project_summary AS
SELECT 
    p.id,
    p.name,
    p.created_at,
    p.modified_at,
    COUNT(DISTINCT s.id) as sequence_count,
    COUNT(DISTINCT m.id) as media_count,
    COUNT(DISTINCT c.id) as clip_count,
    (SELECT COUNT(*) FROM commands) as command_count
FROM projects p
LEFT JOIN sequences s ON p.id = s.project_id
LEFT JOIN media m ON 1=1  -- All media belongs to project context
LEFT JOIN tracks t ON s.id = t.sequence_id
LEFT JOIN clips c ON t.id = c.track_id
GROUP BY p.id;

-- View: Timeline integrity check for debugging
CREATE VIEW IF NOT EXISTS timeline_integrity AS
SELECT 
    t.id as track_id,
    t.track_type,
    t.track_index,
    c.id as clip_id,
    c.start_time,
    c.duration,
    c.start_time + c.duration as end_time,
    -- Check for gaps and overlaps
    LAG(c.start_time + c.duration) OVER (
        PARTITION BY t.id ORDER BY c.start_time
    ) as prev_end_time
FROM tracks t
JOIN clips c ON t.id = c.track_id
ORDER BY t.sequence_id, t.track_type, t.track_index, c.start_time;

-- View: Command replay validation
CREATE VIEW IF NOT EXISTS command_replay_status AS
SELECT 
    c.id,
    c.sequence_number,
    c.command_type,
    c.pre_hash,
    c.post_hash,
    c.timestamp,
    -- Verify hash chain continuity
    LAG(c.post_hash) OVER (ORDER BY c.sequence_number) as expected_pre_hash,
    CASE 
        WHEN LAG(c.post_hash) OVER (ORDER BY c.sequence_number) = c.pre_hash 
        THEN 'VALID'
        WHEN c.sequence_number = 1 THEN 'INITIAL'
        ELSE 'HASH_MISMATCH'
    END as hash_status
FROM commands c
ORDER BY c.sequence_number;