-- JVE Database Schema V9
-- Feature 013: Timeline placements as nested sequence references.
-- Three-table model (sequences, media_refs, clips) + sparse override tables.
-- No backward compatibility with V8 or earlier (FR-018).

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
INSERT OR IGNORE INTO schema_version (version) VALUES (9);

CREATE TABLE IF NOT EXISTS projects (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL CHECK(length(name) > 0),
    created_at INTEGER NOT NULL,
    modified_at INTEGER NOT NULL,
    settings TEXT DEFAULT '{}',

    -- Per-Sequence Undo: global cursor for project-level commands
    global_undo_cursor INTEGER DEFAULT 0,
    global_branch_path TEXT DEFAULT '',

    -- FR-015: project-level default for how the resolver treats a clip whose
    -- referenced sequence's fps differs from its containing sequence's fps.
    -- Per-sequence and per-clip fps_mismatch_policy columns can override.
    fps_mismatch_policy TEXT NOT NULL
        CHECK(fps_mismatch_policy IN ('resample', 'passthrough'))
);

-- ============================================================================
-- MEDIA POOL
-- ============================================================================

CREATE TABLE IF NOT EXISTS media (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    file_path TEXT NOT NULL UNIQUE,
    file_uuid TEXT,  -- DRP master clip UUID (MediaRef DbId) for cross-volume dedup

    -- Duration in its native timebase
    duration_frames INTEGER NOT NULL CHECK(duration_frames > 0),

    -- Native Timebase (e.g. 24/1 for video, 48000/1 for audio)
    fps_numerator INTEGER NOT NULL CHECK(fps_numerator > 0),
    fps_denominator INTEGER NOT NULL CHECK(fps_denominator > 0),

    -- Audio sample rate (e.g. 48000, 44100). 0 = no audio or unknown.
    audio_sample_rate INTEGER DEFAULT 0,

    -- Metadata
    width INTEGER DEFAULT 0,
    height INTEGER DEFAULT 0,
    rotation INTEGER DEFAULT 0, -- 0, 90, 180, 270 from display matrix
    audio_channels INTEGER DEFAULT 0,
    codec TEXT DEFAULT '',
    is_still INTEGER NOT NULL DEFAULT 0 CHECK(is_still IN (0, 1)),
    metadata TEXT DEFAULT '{}', -- JSON
    offline_note TEXT,

    created_at INTEGER NOT NULL,
    modified_at INTEGER NOT NULL
);

-- ============================================================================
-- SEQUENCES (three-table model's spine)
-- ============================================================================

CREATE TABLE IF NOT EXISTS sequences (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    name TEXT NOT NULL,

    -- Structural kind. Exactly two values after 013:
    --   'master' — sequence's tracks hold media_refs (direct file references).
    --   'nested' — sequence's tracks hold clips (references to other sequences).
    -- Old values ('timeline','masterclip','compound','multicam') collapse into these.
    kind TEXT NOT NULL CHECK(kind IN ('master', 'nested')),

    -- Sequence Video Timebase (The Master Clock)
    fps_numerator INTEGER NOT NULL CHECK(fps_numerator > 0),
    fps_denominator INTEGER NOT NULL CHECK(fps_denominator > 0),

    -- Sequence Audio Sample Rate (e.g. 48000). NULL is permitted ONLY for
    -- masters whose source media has no audio (audio-less video files);
    -- such masters never emit audio media_refs and never get audio clips
    -- referencing them, so the rate is genuinely unrepresentable. For all
    -- other sequences (every nested edit + any master with audio media),
    -- the rate is required and must be positive.
    audio_sample_rate INTEGER CHECK(audio_sample_rate IS NULL OR audio_sample_rate > 0),

    -- Dimensions. NULL is permitted ONLY for masters whose source media
    -- has no video (audio-only files); such masters never emit video
    -- media_refs and never get clips referencing them as a video source.
    -- Every other sequence (every nested edit + any master with video
    -- media) requires positive integer width/height.
    width INTEGER CHECK(width IS NULL OR width > 0),
    height INTEGER CHECK(height IS NULL OR height > 0),

    -- Timeline Start Timecode (display offset, does not affect internal coords)
    start_timecode_frame INTEGER NOT NULL DEFAULT 0,

    -- State (Rational Frames)
    view_start_frame INTEGER NOT NULL DEFAULT 0,
    view_duration_frames INTEGER NOT NULL DEFAULT 240,
    playhead_frame INTEGER NOT NULL DEFAULT 0,
    video_scroll_offset INTEGER NOT NULL DEFAULT 0,
    audio_scroll_offset INTEGER NOT NULL DEFAULT 0,
    video_audio_split_ratio REAL NOT NULL DEFAULT 0.5,

    -- Marks
    mark_in_frame INTEGER,
    mark_out_frame INTEGER,

    -- Selection State (JSON)
    selected_clip_ids TEXT DEFAULT '[]',
    selected_edge_infos TEXT DEFAULT '[]',
    selected_gap_infos TEXT DEFAULT '[]',

    -- Undo/Redo State
    current_sequence_number INTEGER DEFAULT 0,
    current_branch_path TEXT DEFAULT '',

    -- Mutation Generation (one bump per user-visible action; see pre-013 docs).
    mutation_generation INTEGER NOT NULL DEFAULT 0,

    -- 013: default video layer exposed when this sequence is referenced by a
    -- clip whose master_layer_track_id is NULL. Non-NULL whenever the sequence
    -- has at least one video track (INV-8, enforced at model layer + triggers).
    default_video_layer_track_id TEXT REFERENCES tracks(id) ON DELETE SET NULL,

    -- 013: FR-017 — user-modifiable start TCs.
    video_start_tc_frame INTEGER,
    audio_start_tc_samples INTEGER,

    -- 013: FR-015 — per-sequence fps-mismatch policy override.
    -- NULL = inherit project-level default.
    fps_mismatch_policy TEXT
        CHECK(fps_mismatch_policy IS NULL OR fps_mismatch_policy IN ('resample','passthrough')),

    created_at INTEGER NOT NULL,
    modified_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS tracks (
    id TEXT PRIMARY KEY,
    sequence_id TEXT NOT NULL REFERENCES sequences(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    track_type TEXT NOT NULL CHECK(track_type IN ('VIDEO', 'AUDIO')),
    track_index INTEGER NOT NULL,

    enabled BOOLEAN NOT NULL DEFAULT 1,
    locked BOOLEAN NOT NULL DEFAULT 0,
    muted BOOLEAN NOT NULL DEFAULT 0,
    soloed BOOLEAN NOT NULL DEFAULT 0,

    volume REAL NOT NULL DEFAULT 1.0,
    pan REAL NOT NULL DEFAULT 0.0,

    UNIQUE(sequence_id, track_type, track_index)
);

-- ============================================================================
-- MEDIA REFS (013 — rows inside master sequences, direct file references)
-- ============================================================================

CREATE TABLE IF NOT EXISTS media_refs (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

    -- Containment: which master sequence and which track.
    owner_sequence_id TEXT NOT NULL REFERENCES sequences(id) ON DELETE CASCADE,
    track_id TEXT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,

    -- What file is referenced and which portion of it.
    media_id TEXT NOT NULL REFERENCES media(id) ON DELETE SET NULL,
    source_in_frame INTEGER NOT NULL,
    source_out_frame INTEGER NOT NULL,

    -- Where on the master's track this portion sits.
    timeline_start_frame INTEGER NOT NULL,
    duration_frames INTEGER NOT NULL CHECK(duration_frames > 0),

    -- Source timebase is the referenced media's (media.fps_numerator/denominator);
    -- not carried on this row to avoid denormalization.

    -- State (explicit on INSERT; no column defaults — rule 2.13).
    enabled INTEGER NOT NULL,
    volume REAL NOT NULL,
    mark_in_frame INTEGER,
    mark_out_frame INTEGER,
    playhead_frame INTEGER NOT NULL,

    created_at INTEGER NOT NULL,
    modified_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_media_refs_owner_sequence ON media_refs(owner_sequence_id);
CREATE INDEX IF NOT EXISTS idx_media_refs_track ON media_refs(track_id);
CREATE INDEX IF NOT EXISTS idx_media_refs_media ON media_refs(media_id);

-- ============================================================================
-- CLIPS (013 — rows inside non-master sequences, references to other sequences)
-- ============================================================================

CREATE TABLE IF NOT EXISTS clips (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,

    -- Containment: which non-master sequence and which track.
    owner_sequence_id TEXT NOT NULL REFERENCES sequences(id) ON DELETE CASCADE,
    track_id TEXT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,

    -- What sequence this clip references (any kind). Replaces the pre-013
    -- master_clip_id column with clearer semantics.
    nested_sequence_id TEXT NOT NULL REFERENCES sequences(id) ON DELETE CASCADE,

    -- Window into the nested sequence's timebase.
    source_in_frame INTEGER NOT NULL,
    source_out_frame INTEGER NOT NULL,

    -- Where on this sequence's track the clip sits. timeline_start_frame and
    -- duration_frames are in the OWNER sequence's timebase; source_in/out are
    -- in the NESTED sequence's timebase. The ratio between them is set by
    -- fps_mismatch_policy below. Neither timebase is carried on this row —
    -- callers dereference owner_sequence_id / nested_sequence_id as needed.
    timeline_start_frame INTEGER NOT NULL,
    duration_frames INTEGER NOT NULL CHECK(duration_frames > 0),

    -- Per-clip video-layer override. Non-NULL = this clip exposes the named
    -- video track of its nested sequence. NULL = inherit nested sequence's
    -- default_video_layer_track_id. Rule 2.13: NULL is inherit, not fallback.
    master_layer_track_id TEXT REFERENCES tracks(id) ON DELETE SET NULL,

    -- Per-clip audio-track selector. NULL = composite (play all of the nested
    -- sequence's audio tracks together; FR-005). Non-NULL = expose exactly one
    -- of the nested sequence's audio tracks (FR-023/FR-024 — Expand/Collapse).
    -- Symmetric to master_layer_track_id but for audio. INV-9: non-NULL only
    -- on clips whose owner-side track is itself an audio track, and the
    -- referenced track must belong to nested_sequence_id and have kind='audio'
    -- (model-layer asserts; FK takes care of dangling-on-delete).
    master_audio_track_id TEXT REFERENCES tracks(id) ON DELETE SET NULL,

    -- Per-clip fps-mismatch policy. NOT NULL — set at Insert time from the
    -- effective project/sequence default (or explicit arg). duration_frames
    -- above was computed under THIS policy at write time; changing the
    -- policy is a structural mutation that re-computes duration and ripples
    -- downstream (SetFpsMismatchPolicy, T064).
    fps_mismatch_policy TEXT NOT NULL
        CHECK(fps_mismatch_policy IN ('resample','passthrough')),

    -- State (explicit on INSERT; no column defaults — rule 2.13).
    name TEXT NOT NULL,
    enabled INTEGER NOT NULL,
    volume REAL NOT NULL,
    mark_in_frame INTEGER,
    mark_out_frame INTEGER,
    playhead_frame INTEGER NOT NULL,

    created_at INTEGER NOT NULL,
    modified_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_clips_owner_sequence ON clips(owner_sequence_id);
CREATE INDEX IF NOT EXISTS idx_clips_track ON clips(track_id);
CREATE INDEX IF NOT EXISTS idx_clips_nested_sequence ON clips(nested_sequence_id);
CREATE INDEX IF NOT EXISTS idx_clips_track_start ON clips(track_id, timeline_start_frame);

-- ============================================================================
-- CLIP LINKS (V+A sync — scope narrowed to clips only, media_refs don't link)
-- ============================================================================

CREATE TABLE IF NOT EXISTS clip_links (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    link_group_id TEXT NOT NULL,
    clip_id TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
    role TEXT NOT NULL DEFAULT 'video',
    time_offset INTEGER NOT NULL DEFAULT 0,
    enabled BOOLEAN NOT NULL DEFAULT 1
);

CREATE INDEX IF NOT EXISTS idx_clip_links_group ON clip_links(link_group_id);
CREATE INDEX IF NOT EXISTS idx_clip_links_clip ON clip_links(clip_id);

-- ============================================================================
-- OVERRIDE STATE (sparse — row exists only when explicitly set)
-- ============================================================================

-- Master-level per-channel state. Absent row = default (enabled, unity gain)
-- applied by the resolver. Rule 2.13: materialized rows carry explicit values.
CREATE TABLE IF NOT EXISTS media_refs_channel_state (
    owner_sequence_id TEXT NOT NULL REFERENCES sequences(id) ON DELETE CASCADE,
    channel_index INTEGER NOT NULL,
    enabled INTEGER NOT NULL,
    default_gain_db REAL NOT NULL,
    PRIMARY KEY (owner_sequence_id, channel_index)
);

-- Per-clip channel override. Absent row = inherit nested sequence's state
-- (which in turn may come from media_refs_channel_state at a leaf master).
-- Rule 2.13: no column defaults.
CREATE TABLE IF NOT EXISTS clip_channel_override (
    clip_id TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
    channel_index INTEGER NOT NULL,
    enabled INTEGER NOT NULL,
    gain_db REAL NOT NULL,
    PRIMARY KEY (clip_id, channel_index)
);

CREATE INDEX IF NOT EXISTS idx_clip_channel_override_clip ON clip_channel_override(clip_id);

-- ============================================================================
-- CLIP PROPERTIES / SNAPSHOTS / LAYOUTS / COMMANDS (unchanged from V8)
-- ============================================================================

CREATE TABLE IF NOT EXISTS properties (
    id TEXT PRIMARY KEY,
    clip_id TEXT NOT NULL,
    property_name TEXT NOT NULL,
    property_value TEXT,
    property_type TEXT DEFAULT 'string',
    default_value TEXT,
    UNIQUE(clip_id, property_name)
);

CREATE INDEX IF NOT EXISTS idx_properties_clip_id ON properties(clip_id);

CREATE TABLE IF NOT EXISTS snapshots (
    id TEXT PRIMARY KEY,
    sequence_id TEXT NOT NULL,
    sequence_number INTEGER NOT NULL,
    clips_state TEXT NOT NULL,
    created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS sequence_track_layouts (
    sequence_id TEXT PRIMARY KEY REFERENCES sequences(id) ON DELETE CASCADE,
    track_heights_json TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS commands (
    id TEXT PRIMARY KEY,
    parent_id TEXT,
    sequence_number INTEGER NOT NULL UNIQUE,
    command_type TEXT NOT NULL,
    command_args TEXT NOT NULL,
    parent_sequence_number INTEGER,
    undo_group_id INTEGER,
    pre_hash TEXT,
    post_hash TEXT,
    timestamp INTEGER NOT NULL,

    playhead_value REAL,
    playhead_rate REAL,
    playhead_value_post REAL,
    playhead_rate_post REAL,

    selected_clip_ids TEXT,
    selected_edge_infos TEXT,
    selected_gap_infos TEXT,

    selected_clip_ids_pre TEXT,
    selected_edge_infos_pre TEXT,
    selected_gap_infos_pre TEXT,

    sequence_id TEXT
);

-- ============================================================================
-- TAGS & BINS (unchanged from V8)
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
    entity_type TEXT NOT NULL,
    entity_id TEXT NOT NULL,
    UNIQUE(tag_id, entity_type, entity_id)
);

CREATE TABLE IF NOT EXISTS smart_bins (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    name TEXT NOT NULL CHECK(length(name) > 0),
    scope_bin_id TEXT REFERENCES tags(id) ON DELETE SET NULL,
    criteria_json TEXT NOT NULL DEFAULT '[]',
    created_at INTEGER NOT NULL,
    modified_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_smart_bins_project ON smart_bins(project_id);

-- ============================================================================
-- TIMESTAMP TRIGGERS (unchanged from V8)
-- ============================================================================

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

-- ============================================================================
-- INV-1 / INV-2 — schema-layer enforcement (rule 2.21 static verifiability)
-- ============================================================================
-- SQLite doesn't allow subqueries in CHECK constraints; triggers are the
-- schema-layer path to express "owner_sequence_id must reference a sequence
-- of the right kind." Model-layer asserts in models/media_ref.lua and
-- models/clip.lua are defense-in-depth.

DROP TRIGGER IF EXISTS trg_media_refs_owner_kind_insert;
CREATE TRIGGER trg_media_refs_owner_kind_insert
BEFORE INSERT ON media_refs
WHEN (SELECT kind FROM sequences WHERE id = NEW.owner_sequence_id) != 'master'
BEGIN
    SELECT RAISE(ABORT, 'INV-1: media_refs.owner_sequence_id must reference a kind=master sequence');
END;

DROP TRIGGER IF EXISTS trg_media_refs_owner_kind_update;
CREATE TRIGGER trg_media_refs_owner_kind_update
BEFORE UPDATE ON media_refs
WHEN (SELECT kind FROM sequences WHERE id = NEW.owner_sequence_id) != 'master'
BEGIN
    SELECT RAISE(ABORT, 'INV-1: media_refs.owner_sequence_id must reference a kind=master sequence');
END;

DROP TRIGGER IF EXISTS trg_clips_owner_kind_insert;
CREATE TRIGGER trg_clips_owner_kind_insert
BEFORE INSERT ON clips
WHEN (SELECT kind FROM sequences WHERE id = NEW.owner_sequence_id) != 'nested'
BEGIN
    SELECT RAISE(ABORT, 'INV-2: clips.owner_sequence_id must reference a kind=nested sequence');
END;

DROP TRIGGER IF EXISTS trg_clips_owner_kind_update;
CREATE TRIGGER trg_clips_owner_kind_update
BEFORE UPDATE ON clips
WHEN (SELECT kind FROM sequences WHERE id = NEW.owner_sequence_id) != 'nested'
BEGIN
    SELECT RAISE(ABORT, 'INV-2: clips.owner_sequence_id must reference a kind=nested sequence');
END;

-- ============================================================================
-- VIDEO TRACK OVERLAP PREVENTION (unchanged from V8 — uses track_id + start +
-- duration, all still present on clips)
-- ============================================================================

DROP TRIGGER IF EXISTS trg_prevent_video_overlap_insert;
CREATE TRIGGER trg_prevent_video_overlap_insert
BEFORE INSERT ON clips
WHEN EXISTS (
    SELECT 1 FROM tracks WHERE id = NEW.track_id AND track_type = 'VIDEO'
)
BEGIN
    SELECT CASE
    WHEN coalesce((
        SELECT (c.timeline_start_frame + c.duration_frames) FROM clips c
        WHERE c.track_id = NEW.track_id
          AND c.id != NEW.id
          AND c.timeline_start_frame < NEW.timeline_start_frame
        ORDER BY c.timeline_start_frame DESC LIMIT 1
    ), NEW.timeline_start_frame) > NEW.timeline_start_frame
        THEN RAISE(ABORT, 'VIDEO_OVERLAP: Clips cannot overlap on a video track')
    WHEN EXISTS (
        SELECT 1 FROM clips c
        WHERE c.track_id = NEW.track_id
          AND c.id != NEW.id
          AND c.timeline_start_frame >= NEW.timeline_start_frame
          AND c.timeline_start_frame < (NEW.timeline_start_frame + NEW.duration_frames)
        LIMIT 1
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
    WHEN coalesce((
        SELECT (c.timeline_start_frame + c.duration_frames) FROM clips c
        WHERE c.track_id = NEW.track_id
          AND c.id != NEW.id
          AND c.timeline_start_frame < NEW.timeline_start_frame
        ORDER BY c.timeline_start_frame DESC LIMIT 1
    ), NEW.timeline_start_frame) > NEW.timeline_start_frame
        THEN RAISE(ABORT, 'VIDEO_OVERLAP: Clips cannot overlap on a video track')
    WHEN EXISTS (
        SELECT 1 FROM clips c
        WHERE c.track_id = NEW.track_id
          AND c.id != NEW.id
          AND c.timeline_start_frame >= NEW.timeline_start_frame
          AND c.timeline_start_frame < (NEW.timeline_start_frame + NEW.duration_frames)
        LIMIT 1
    ) THEN RAISE(ABORT, 'VIDEO_OVERLAP: Clips cannot overlap on a video track')
    END;
END;
