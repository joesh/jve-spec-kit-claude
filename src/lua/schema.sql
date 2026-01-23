-- JVE Database Schema V5.0
-- "Scorched Earth" - Frame-Accurate, Rational Timebase
-- No backward compatibility with legacy schemas.

PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;

-- ============================================================================
-- META & CONFIG
-- ============================================================================

CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER PRIMARY KEY,
    applied_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
INSERT OR IGNORE INTO schema_version (version) VALUES (5);

CREATE TABLE IF NOT EXISTS projects (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL CHECK(length(name) > 0),
    created_at INTEGER NOT NULL,
    modified_at INTEGER NOT NULL,
    settings TEXT DEFAULT '{}'
);

-- ============================================================================
-- MEDIA POOL
-- ============================================================================

CREATE TABLE IF NOT EXISTS media (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    file_path TEXT NOT NULL UNIQUE,
    
    -- Duration in its native timebase
    duration_frames INTEGER NOT NULL CHECK(duration_frames > 0),
    
    -- Native Timebase (e.g. 24/1 for video, 48000/1 for audio)
    fps_numerator INTEGER NOT NULL CHECK(fps_numerator > 0),
    fps_denominator INTEGER NOT NULL CHECK(fps_denominator > 0),
    
    -- Metadata
    width INTEGER DEFAULT 0,
    height INTEGER DEFAULT 0,
    audio_channels INTEGER DEFAULT 0,
    codec TEXT DEFAULT '',
    metadata TEXT DEFAULT '{}', -- JSON
    
    created_at INTEGER NOT NULL,
    modified_at INTEGER NOT NULL
);

-- ============================================================================
-- TIMELINE STRUCTURE
-- ============================================================================

CREATE TABLE IF NOT EXISTS sequences (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    kind TEXT NOT NULL DEFAULT 'timeline', -- 'timeline', 'compound', 'multicam'
    
    -- Sequence Video Timebase (The Master Clock)
    fps_numerator INTEGER NOT NULL CHECK(fps_numerator > 0),
    fps_denominator INTEGER NOT NULL CHECK(fps_denominator > 0),
    
    -- Sequence Audio Rate (Sample Rate, e.g. 48000)
    audio_rate INTEGER NOT NULL CHECK(audio_rate > 0),
    
    -- Dimensions
    width INTEGER NOT NULL,
    height INTEGER NOT NULL,
    
    -- State (Rational Frames)
    view_start_frame INTEGER NOT NULL DEFAULT 0,
    view_duration_frames INTEGER NOT NULL DEFAULT 240,
    playhead_frame INTEGER NOT NULL DEFAULT 0,
    
    -- Marks (Optional, Nullable)
    mark_in_frame INTEGER,
    mark_out_frame INTEGER,
    
    -- Selection State (JSON)
    selected_clip_ids TEXT DEFAULT '[]',
    selected_edge_infos TEXT DEFAULT '[]',
    selected_gap_infos TEXT DEFAULT '[]',
    
    -- Undo/Redo State
    current_sequence_number INTEGER DEFAULT 0,
    
    created_at INTEGER NOT NULL,
    modified_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS tracks (
    id TEXT PRIMARY KEY,
    sequence_id TEXT NOT NULL REFERENCES sequences(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    track_type TEXT NOT NULL CHECK(track_type IN ('VIDEO', 'AUDIO')),
    track_index INTEGER NOT NULL, -- 1-based index per type
    
    -- State
    enabled BOOLEAN NOT NULL DEFAULT 1,
    locked BOOLEAN NOT NULL DEFAULT 0,
    muted BOOLEAN NOT NULL DEFAULT 0,
    soloed BOOLEAN NOT NULL DEFAULT 0,
    
    -- Audio Mixer State (ignored for Video)
    volume REAL NOT NULL DEFAULT 1.0,
    pan REAL NOT NULL DEFAULT 0.0,
    
    UNIQUE(sequence_id, track_type, track_index)
);

CREATE TABLE IF NOT EXISTS clips (
    id TEXT PRIMARY KEY,
    project_id TEXT REFERENCES projects(id) ON DELETE CASCADE, -- Ownership
    
    -- Structural Fields (Restored)
    clip_kind TEXT NOT NULL DEFAULT 'timeline', -- 'master', 'timeline'
    source_sequence_id TEXT, -- For nested/compound clips
    parent_clip_id TEXT REFERENCES clips(id) ON DELETE CASCADE, -- For master->timeline relationship
    owner_sequence_id TEXT REFERENCES sequences(id) ON DELETE CASCADE, -- Direct ownership shortcut
    
    -- Container Relationship
    track_id TEXT REFERENCES tracks(id) ON DELETE CASCADE,
    
    -- Source Relationship
    media_id TEXT REFERENCES media(id) ON DELETE SET NULL,
    
    -- Naming
    name TEXT DEFAULT '',
    
    -- Position on Timeline (Rational Ticks)
    -- Units depend on Track Type (Video Frames vs Audio Samples)
    timeline_start_frame INTEGER NOT NULL,
    duration_frames INTEGER NOT NULL CHECK(duration_frames > 0),
    
    -- Source Selection (Rational Ticks)
    source_in_frame INTEGER NOT NULL DEFAULT 0,
    source_out_frame INTEGER NOT NULL, -- Must be >= source_in + duration
    
    -- The Timebase of THESE ticks (Self-describing)
    -- For Video Clips: Matches Sequence FPS (usually)
    -- For Audio Clips: Matches Audio Sample Rate (e.g. 48000/1)
    fps_numerator INTEGER NOT NULL CHECK(fps_numerator > 0),
    fps_denominator INTEGER NOT NULL CHECK(fps_denominator > 0),
    
    -- State
    enabled BOOLEAN NOT NULL DEFAULT 1,
    offline BOOLEAN NOT NULL DEFAULT 0,
    
    created_at INTEGER NOT NULL,
    modified_at INTEGER NOT NULL
);

-- Clip Links: A/V sync relationships between clips
-- Manages linked clip groups for synchronized editing operations
CREATE TABLE IF NOT EXISTS clip_links (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    link_group_id TEXT NOT NULL,
    clip_id TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
    role TEXT NOT NULL DEFAULT 'video', -- 'video', 'audio'
    time_offset INTEGER NOT NULL DEFAULT 0, -- Offset in frames from group anchor
    enabled BOOLEAN NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_clip_links_group ON clip_links(link_group_id);
CREATE INDEX IF NOT EXISTS idx_clip_links_clip ON clip_links(clip_id);

-- ============================================================================
-- UI & AUXILIARY
-- ============================================================================

-- Persistent Layouts (Track Heights)
CREATE TABLE IF NOT EXISTS sequence_track_layouts (
    sequence_id TEXT PRIMARY KEY REFERENCES sequences(id) ON DELETE CASCADE,
    track_heights_json TEXT NOT NULL, -- JSON {track_id: height}
    updated_at INTEGER NOT NULL
);

-- Command History (Event Sourcing)
CREATE TABLE IF NOT EXISTS commands (
    id TEXT PRIMARY KEY,
    parent_id TEXT, -- For batch command relationships
    sequence_number INTEGER NOT NULL UNIQUE,
    command_type TEXT NOT NULL,
    command_args TEXT NOT NULL, -- JSON
    parent_sequence_number INTEGER, -- For Undo Tree
    undo_group_id INTEGER, -- For Emacs-style undo grouping
    pre_hash TEXT,
    post_hash TEXT,
    timestamp INTEGER NOT NULL,

    -- Snapshot State (for fast restores)
    playhead_value REAL,
    playhead_rate REAL,

    selected_clip_ids TEXT,
    selected_edge_infos TEXT,
    selected_gap_infos TEXT,

    selected_clip_ids_pre TEXT,
    selected_edge_infos_pre TEXT,
    selected_gap_infos_pre TEXT
);

-- ============================================================================
-- TAGS & BINS
-- ============================================================================

CREATE TABLE IF NOT EXISTS tag_namespaces (
    id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS tags (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    namespace_id TEXT NOT NULL REFERENCES tag_namespaces(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    path TEXT NOT NULL,
    parent_id TEXT REFERENCES tags(id) ON DELETE CASCADE,
    sort_index INTEGER DEFAULT 0
);

CREATE TABLE IF NOT EXISTS tag_assignments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    tag_id TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    namespace_id TEXT NOT NULL REFERENCES tag_namespaces(id) ON DELETE CASCADE,
    entity_type TEXT NOT NULL, -- 'master_clip', 'media'
    entity_id TEXT NOT NULL,
    UNIQUE(tag_id, entity_type, entity_id)
);

-- ============================================================================
-- INDEXES (performance-critical)
-- ============================================================================

-- Used by overlap-prevention triggers and timeline queries.
CREATE INDEX IF NOT EXISTS idx_clips_track_id ON clips(track_id);
CREATE INDEX IF NOT EXISTS idx_clips_track_start ON clips(track_id, timeline_start_frame);

-- ============================================================================
-- TRIGGERS
-- ============================================================================

-- Basic timestamp updates
CREATE TRIGGER IF NOT EXISTS trg_projects_update
AFTER UPDATE ON projects
BEGIN
    UPDATE projects SET modified_at = strftime('%s', 'now') WHERE id = NEW.id;
END;

CREATE TRIGGER IF NOT EXISTS trg_sequences_update
AFTER UPDATE ON sequences
BEGIN
    UPDATE projects SET modified_at = strftime('%s', 'now') WHERE id = NEW.project_id;
END;

-- Overlap Prevention (Video Only)
-- Audio allows overlapping layers (mix), Video usually does not (overwrite/composite).
-- For V5, we enforce NO OVERLAP on Video Tracks at the DB level using timebase-aware comparison.

DROP TRIGGER IF EXISTS trg_prevent_video_overlap_insert;
CREATE TRIGGER trg_prevent_video_overlap_insert
BEFORE INSERT ON clips
WHEN EXISTS (
    SELECT 1 FROM tracks WHERE id = NEW.track_id AND track_type = 'VIDEO'
)
BEGIN
    SELECT CASE
    WHEN EXISTS (
        SELECT 1 FROM clips c
        WHERE c.track_id = NEW.track_id
          AND c.id != NEW.id
          AND (
            (
              (CAST(NEW.timeline_start_frame AS REAL) * NEW.fps_denominator / NEW.fps_numerator) <
              (CAST(c.timeline_start_frame AS REAL) * c.fps_denominator / c.fps_numerator + CAST(c.duration_frames AS REAL) * c.fps_denominator / c.fps_numerator) - 0.000001
            ) AND
            (
              (CAST(NEW.timeline_start_frame AS REAL) * NEW.fps_denominator / NEW.fps_numerator + CAST(NEW.duration_frames AS REAL) * NEW.fps_denominator / NEW.fps_numerator) >
              (CAST(c.timeline_start_frame AS REAL) * c.fps_denominator / c.fps_numerator) + 0.000001
            )
          )
    ) THEN RAISE(ABORT, 'VIDEO_OVERLAP: Clips cannot overlap on a video track')
    END;
END;

DROP TRIGGER IF EXISTS trg_prevent_video_overlap_update;
CREATE TRIGGER trg_prevent_video_overlap_update
BEFORE UPDATE ON clips
WHEN EXISTS (
    SELECT 1 FROM tracks WHERE id = NEW.track_id AND track_type = 'VIDEO'
)
BEGIN
    SELECT CASE
    WHEN EXISTS (
        SELECT 1 FROM clips c
        WHERE c.track_id = NEW.track_id
          AND c.id != NEW.id
          AND (
            (
              (CAST(NEW.timeline_start_frame AS REAL) * NEW.fps_denominator / NEW.fps_numerator) <
              (CAST(c.timeline_start_frame AS REAL) * c.fps_denominator / c.fps_numerator + CAST(c.duration_frames AS REAL) * c.fps_denominator / c.fps_numerator) - 0.000001
            ) AND
            (
              (CAST(NEW.timeline_start_frame AS REAL) * NEW.fps_denominator / NEW.fps_numerator + CAST(NEW.duration_frames AS REAL) * NEW.fps_denominator / NEW.fps_numerator) >
              (CAST(c.timeline_start_frame AS REAL) * c.fps_denominator / c.fps_numerator) + 0.000001
            )
          )
    ) THEN RAISE(ABORT, 'VIDEO_OVERLAP: Clips cannot overlap on a video track')
    END;
END;
