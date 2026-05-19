-- JVE Database Schema V11
-- Feature 018: Uniform Clip Source Timebase + Canonical-Clock Sub-Frame Primitives.
--   - clips.source_in_subframe / source_out_subframe (INTEGER, NULL for video, NOT NULL for audio)
--   - media_refs.audio_sample_rate (INTEGER, denormalized from media row)
--   - sequences.audio_sample_rate MUST be NULL on kind='master' (INV-7)
--   - projects.settings carries default_fps {num,den} and master_clock_hz (canonical 705600000 — flicks; immutable post-create per INV-6)
--   - INV-3 .. INV-7 triggers enforce subframe presence/bound + fps/clock single-writer
-- Feature 015: Source-in-Timeline — adds tracks.sync_mode column and patches table.
-- No backward compatibility with V10 or earlier (rule 2.15: re-import on schema change).

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
INSERT OR IGNORE INTO schema_version (version) VALUES (11);

CREATE TABLE IF NOT EXISTS projects (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL CHECK(length(name) > 0),
    created_at INTEGER NOT NULL,
    modified_at INTEGER NOT NULL,
    settings TEXT DEFAULT '{}',

    -- Per-Sequence Undo: global cursor for project-level commands.
    -- `global_undo_tip` is the sequence_number of the LEAF of the user's
    -- current branch on the global stack. Redo walks from cursor toward
    -- tip (descends through `parent_sequence_number`). When the user
    -- commits after undoing, both cursor and tip advance to the new
    -- command, orphaning the prior leaf — its branch remains in the DB
    -- (preserved for the future branch-picker UI) but is unreachable via
    -- Cmd+Shift+Z. Without this, an old undone DeleteSequence could
    -- resurface as a redo target on the user's current branch.
    global_undo_cursor INTEGER DEFAULT 0,
    global_undo_tip INTEGER DEFAULT 0,
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
    --   'sequence' — sequence's tracks hold clips (references to other sequences).
    -- Old values ('timeline','masterclip','compound','multicam') collapse into these.
    kind TEXT NOT NULL CHECK(kind IN ('master', 'sequence')),

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

    -- Undo/Redo State. `current_undo_tip` is the leaf of the user's
    -- current branch on this sequence's stack. Redo walks from
    -- current_sequence_number toward this tip via parent_sequence_number.
    -- New commits at non-tip positions orphan the prior leaf (still
    -- preserved in the commands tree, just unreachable via Cmd+Shift+Z).
    current_sequence_number INTEGER DEFAULT 0,
    current_undo_tip INTEGER DEFAULT 0,
    current_branch_path TEXT DEFAULT '',

    -- Mutation Generation (one bump per user-visible action; see pre-013 docs).
    mutation_generation INTEGER NOT NULL DEFAULT 0,

    -- 013: default video layer exposed when this sequence is referenced by a
    -- clip whose master_layer_track_id is NULL. Non-NULL whenever the sequence
    -- has at least one video track (default_video_layer_track_id must be non-NULL when video tracks exist — enforced at model layer + triggers).
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

    -- 015: per-track ripple sync mode. DB DEFAULT 'ripple' matches spec §3 domain default.
    -- Pre-015 tracks get 'ripple' from the schema.sql; migration T025 uses ALTER TABLE
    -- which also defaults to 'ripple' for any rows that predate the column.
    sync_mode TEXT NOT NULL DEFAULT 'ripple'
        CHECK (sync_mode IN ('off','ripple','cut')),

    -- 015 FR-038: record-track auto-select (Avid "track auto-select" /
    -- Premiere "track targeting"). Distinct from `enabled` (mix output)
    -- and from patch.enabled (per-channel routing). AND-gated with
    -- patch.enabled at edit time: a source channel participates in an
    -- edit iff (no patch row OR patch.enabled=1) AND record_track.autoselect=1.
    -- Domain default: on (1).
    autoselect INTEGER NOT NULL DEFAULT 1
        CHECK (autoselect IN (0,1)),

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
    sequence_start_frame INTEGER NOT NULL,
    duration_frames INTEGER NOT NULL CHECK(duration_frames > 0),

    -- 018 (V11): audio sample rate denormalized from media.audio_sample_rate at insert time.
    -- NULL allowed for video-only media_refs. Read by resolver (FR-008) per-emit; denorm
    -- avoids a media join in the hot path.
    audio_sample_rate INTEGER CHECK(audio_sample_rate IS NULL OR audio_sample_rate > 0),

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
    sequence_id TEXT NOT NULL REFERENCES sequences(id) ON DELETE CASCADE,

    -- Window into the source sequence's timebase.
    -- source_*_frame: integer frames in source sequence's fps.
    -- source_*_subframe (018, V11): integer ticks at project.master_clock_hz, in [0, ticks_per_frame).
    --   NULL on video clips; NOT NULL on audio clips. Enforced by INV-3 + INV-4.
    source_in_frame INTEGER NOT NULL,
    source_out_frame INTEGER NOT NULL,
    source_in_subframe INTEGER,
    source_out_subframe INTEGER,

    -- Where on this sequence's track the clip sits. sequence_start_frame and
    -- duration_frames are in the OWNER sequence's timebase; source_in/out are
    -- in the source sequence's timebase. The ratio between them is set by
    -- fps_mismatch_policy below. Neither timebase is carried on this row —
    -- callers dereference owner_sequence_id / sequence_id as needed.
    sequence_start_frame INTEGER NOT NULL,
    duration_frames INTEGER NOT NULL CHECK(duration_frames > 0),

    -- Per-clip video-layer override. Non-NULL = this clip exposes the named
    -- video track of its nested sequence. NULL = inherit nested sequence's
    -- default_video_layer_track_id. Rule 2.13: NULL is inherit, not fallback.
    master_layer_track_id TEXT REFERENCES tracks(id) ON DELETE SET NULL,

    -- Per-clip audio-track selector. NULL = composite (play all of the nested
    -- sequence's audio tracks together; FR-005). Non-NULL = expose exactly one
    -- of the nested sequence's audio tracks (FR-023/FR-024 — Expand/Collapse).
    -- Symmetric to master_layer_track_id but for audio. Non-NULL only
    -- on clips whose owner-side track is itself an audio track, and the
    -- referenced track must belong to sequence_id and have kind='audio'
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
CREATE INDEX IF NOT EXISTS idx_clips_sequence ON clips(sequence_id);
CREATE INDEX IF NOT EXISTS idx_clips_track_start ON clips(track_id, sequence_start_frame);

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
-- PATCHES (015 — per-sequence source-track → record-track routing)
-- ============================================================================

-- Patch routing is keyed by source_shape so different-shape sources (e.g. a
-- 2-ch stereo boom vs a 4-ch surround) on the same record sequence maintain
-- independent remembered maps. See specs/015-source-in-timeline/spec.md F2.
CREATE TABLE IF NOT EXISTS patches (
    id                  TEXT    PRIMARY KEY,
    sequence_id         TEXT    NOT NULL REFERENCES sequences(id) ON DELETE CASCADE,
    track_type          TEXT    NOT NULL CHECK (track_type IN ('VIDEO','AUDIO')),
    source_shape        INTEGER NOT NULL CHECK (source_shape > 0),
    source_track_index  INTEGER NOT NULL CHECK (source_track_index >= 0),
    record_track_index  INTEGER NOT NULL CHECK (record_track_index >= 0),
    enabled             INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0,1)),
    created_at          INTEGER NOT NULL DEFAULT 0,
    UNIQUE (sequence_id, track_type, source_shape, source_track_index)
);

CREATE INDEX IF NOT EXISTS idx_patches_sequence_id
    ON patches(sequence_id, track_type, source_shape);

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
-- media_refs/clips ownership constraints — schema-layer enforcement (rule 2.21 static verifiability)
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
WHEN (SELECT kind FROM sequences WHERE id = NEW.owner_sequence_id) != 'sequence'
BEGIN
    SELECT RAISE(ABORT, 'INV-2: clips.owner_sequence_id must reference a kind=''sequence'' sequence');
END;

DROP TRIGGER IF EXISTS trg_clips_owner_kind_update;
CREATE TRIGGER trg_clips_owner_kind_update
BEFORE UPDATE ON clips
WHEN (SELECT kind FROM sequences WHERE id = NEW.owner_sequence_id) != 'sequence'
BEGIN
    SELECT RAISE(ABORT, 'INV-2: clips.owner_sequence_id must reference a kind=''sequence'' sequence');
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
        SELECT (c.sequence_start_frame + c.duration_frames) FROM clips c
        WHERE c.track_id = NEW.track_id
          AND c.id != NEW.id
          AND c.sequence_start_frame < NEW.sequence_start_frame
        ORDER BY c.sequence_start_frame DESC LIMIT 1
    ), NEW.sequence_start_frame) > NEW.sequence_start_frame
        THEN RAISE(ABORT, 'VIDEO_OVERLAP: Clips cannot overlap on a video track')
    WHEN EXISTS (
        SELECT 1 FROM clips c
        WHERE c.track_id = NEW.track_id
          AND c.id != NEW.id
          AND c.sequence_start_frame >= NEW.sequence_start_frame
          AND c.sequence_start_frame < (NEW.sequence_start_frame + NEW.duration_frames)
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
        SELECT (c.sequence_start_frame + c.duration_frames) FROM clips c
        WHERE c.track_id = NEW.track_id
          AND c.id != NEW.id
          AND c.sequence_start_frame < NEW.sequence_start_frame
        ORDER BY c.sequence_start_frame DESC LIMIT 1
    ), NEW.sequence_start_frame) > NEW.sequence_start_frame
        THEN RAISE(ABORT, 'VIDEO_OVERLAP: Clips cannot overlap on a video track')
    WHEN EXISTS (
        SELECT 1 FROM clips c
        WHERE c.track_id = NEW.track_id
          AND c.id != NEW.id
          AND c.sequence_start_frame >= NEW.sequence_start_frame
          AND c.sequence_start_frame < (NEW.sequence_start_frame + NEW.duration_frames)
        LIMIT 1
    ) THEN RAISE(ABORT, 'VIDEO_OVERLAP: Clips cannot overlap on a video track')
    END;
END;

-- ============================================================================
-- 018 INVARIANT TRIGGERS — sub-frame primitives + fps/clock single-writer
-- ============================================================================
-- INV-3: clips subframe presence by clip kind (FR-001)
--   VIDEO clips MUST have NULL subframes.
--   AUDIO clips MUST have non-NULL subframes.
-- INV-4: clips subframe bound (FR-002)
--   0 <= source_*_subframe < master_clock_hz * source_seq.fps_den / source_seq.fps_num.
-- INV-5: sequences.fps_num/den single-writer (FR-031)
--   UPDATE rejected unless db_session_flags has '_conform_sequence_in_progress' row.
-- INV-6: projects.settings.master_clock_hz immutable post-create (FR-028)
--   UPDATE OF settings that changes master_clock_hz is unconditionally
--   rejected. The canonical clock (705,600,000 — flicks) exactly
--   represents every supported audio rate and frame rate, so no command
--   has any reason to change it. INSERT (project create) sets the
--   canonical value once and never again.
-- INV-7: sequences.audio_sample_rate must be NULL on kind='master' (FR-004)
--
-- Session-flag pattern: SQLite non-TEMP triggers cannot reference temp.*,
-- so the flag table is a permanent table (db_session_flags). Commands INSERT
-- the flag row inside their transaction and DELETE before COMMIT. On rollback
-- the flag row goes with the transaction — defense-in-depth.

CREATE TABLE IF NOT EXISTS db_session_flags (
    name TEXT PRIMARY KEY
);

-- ---------- INV-3 — subframe presence by clip kind ----------

DROP TRIGGER IF EXISTS trg_clips_subframe_kind_insert;
CREATE TRIGGER trg_clips_subframe_kind_insert
BEFORE INSERT ON clips
BEGIN
    SELECT CASE
        WHEN (SELECT track_type FROM tracks WHERE id = NEW.track_id) = 'VIDEO'
             AND (NEW.source_in_subframe IS NOT NULL OR NEW.source_out_subframe IS NOT NULL)
        THEN RAISE(ABORT, 'INV-3: video clip must have NULL source_in_subframe and source_out_subframe')
        WHEN (SELECT track_type FROM tracks WHERE id = NEW.track_id) = 'AUDIO'
             AND (NEW.source_in_subframe IS NULL OR NEW.source_out_subframe IS NULL)
        THEN RAISE(ABORT, 'INV-3: audio clip must have non-NULL source_in_subframe and source_out_subframe')
    END;
END;

DROP TRIGGER IF EXISTS trg_clips_subframe_kind_update;
CREATE TRIGGER trg_clips_subframe_kind_update
BEFORE UPDATE OF source_in_subframe, source_out_subframe, track_id ON clips
BEGIN
    SELECT CASE
        WHEN (SELECT track_type FROM tracks WHERE id = NEW.track_id) = 'VIDEO'
             AND (NEW.source_in_subframe IS NOT NULL OR NEW.source_out_subframe IS NOT NULL)
        THEN RAISE(ABORT, 'INV-3: video clip must have NULL source_in_subframe and source_out_subframe')
        WHEN (SELECT track_type FROM tracks WHERE id = NEW.track_id) = 'AUDIO'
             AND (NEW.source_in_subframe IS NULL OR NEW.source_out_subframe IS NULL)
        THEN RAISE(ABORT, 'INV-3: audio clip must have non-NULL source_in_subframe and source_out_subframe')
    END;
END;

-- ---------- INV-4 — subframe bound ----------
-- ticks_per_frame = master_clock_hz * source_seq.fps_den / source_seq.fps_num.
-- master_clock_hz pulled from projects.settings JSON via json_extract.
-- SQLite JSON1 is compiled into the lsqlite3 build used by JVE.

DROP TRIGGER IF EXISTS trg_clips_subframe_bound_insert;
CREATE TRIGGER trg_clips_subframe_bound_insert
BEFORE INSERT ON clips
WHEN NEW.source_in_subframe IS NOT NULL OR NEW.source_out_subframe IS NOT NULL
BEGIN
    SELECT CASE
        WHEN NEW.source_in_subframe < 0
        THEN RAISE(ABORT, 'INV-4: source_in_subframe must be >= 0')
        WHEN NEW.source_out_subframe < 0
        THEN RAISE(ABORT, 'INV-4: source_out_subframe must be >= 0')
        WHEN NEW.source_in_subframe >= (
            (SELECT json_extract(p.settings, '$.master_clock_hz')
               FROM projects p WHERE p.id = NEW.project_id) *
            (SELECT s.fps_denominator FROM sequences s WHERE s.id = NEW.sequence_id) /
            (SELECT s.fps_numerator   FROM sequences s WHERE s.id = NEW.sequence_id)
        )
        THEN RAISE(ABORT, 'INV-4: source_in_subframe >= ticks_per_frame')
        WHEN NEW.source_out_subframe >= (
            (SELECT json_extract(p.settings, '$.master_clock_hz')
               FROM projects p WHERE p.id = NEW.project_id) *
            (SELECT s.fps_denominator FROM sequences s WHERE s.id = NEW.sequence_id) /
            (SELECT s.fps_numerator   FROM sequences s WHERE s.id = NEW.sequence_id)
        )
        THEN RAISE(ABORT, 'INV-4: source_out_subframe >= ticks_per_frame')
    END;
END;

DROP TRIGGER IF EXISTS trg_clips_subframe_bound_update;
CREATE TRIGGER trg_clips_subframe_bound_update
BEFORE UPDATE OF source_in_subframe, source_out_subframe, sequence_id ON clips
WHEN NEW.source_in_subframe IS NOT NULL OR NEW.source_out_subframe IS NOT NULL
BEGIN
    SELECT CASE
        WHEN NEW.source_in_subframe < 0
        THEN RAISE(ABORT, 'INV-4: source_in_subframe must be >= 0')
        WHEN NEW.source_out_subframe < 0
        THEN RAISE(ABORT, 'INV-4: source_out_subframe must be >= 0')
        WHEN NEW.source_in_subframe >= (
            (SELECT json_extract(p.settings, '$.master_clock_hz')
               FROM projects p WHERE p.id = NEW.project_id) *
            (SELECT s.fps_denominator FROM sequences s WHERE s.id = NEW.sequence_id) /
            (SELECT s.fps_numerator   FROM sequences s WHERE s.id = NEW.sequence_id)
        )
        THEN RAISE(ABORT, 'INV-4: source_in_subframe >= ticks_per_frame')
        WHEN NEW.source_out_subframe >= (
            (SELECT json_extract(p.settings, '$.master_clock_hz')
               FROM projects p WHERE p.id = NEW.project_id) *
            (SELECT s.fps_denominator FROM sequences s WHERE s.id = NEW.sequence_id) /
            (SELECT s.fps_numerator   FROM sequences s WHERE s.id = NEW.sequence_id)
        )
        THEN RAISE(ABORT, 'INV-4: source_out_subframe >= ticks_per_frame')
    END;
END;

-- ---------- INV-5 — sequences.fps_num/den single-writer ----------
-- Allowed only when temp table _conform_sequence_in_progress exists
-- (ConformSequence creates it inside its transaction).

DROP TRIGGER IF EXISTS trg_sequences_fps_guard;
-- INV-5 trigger fires only on ACTUAL change. SQLite's BEFORE UPDATE OF col
-- fires whenever the column appears in the SET clause regardless of value,
-- so callers writing a row-image with unchanged fps would trigger spurious
-- aborts. Comparing NEW vs OLD makes the trigger value-driven, matching the
-- intent (FR-031 forbids *mutation*, not *no-op rewrite*).
CREATE TRIGGER trg_sequences_fps_guard
BEFORE UPDATE OF fps_numerator, fps_denominator ON sequences
WHEN NOT EXISTS (SELECT 1 FROM db_session_flags
                  WHERE name = '_conform_sequence_in_progress')
  AND (NEW.fps_numerator IS NOT OLD.fps_numerator
       OR NEW.fps_denominator IS NOT OLD.fps_denominator)
BEGIN
    SELECT RAISE(ABORT,
        'INV-5: sequences.fps_num/den mutable only via ConformSequence');
END;

-- ---------- INV-6 — projects.settings.master_clock_hz immutable post-create ----------
-- The canonical master clock (705,600,000 — flicks) exactly represents
-- every supported audio rate and frame rate, so no user-facing reason to
-- change it exists. The previous SetProjectMasterClock command is gone;
-- the trigger now unconditionally rejects any UPDATE that changes the
-- master_clock_hz value within settings. Other settings keys may still be
-- UPDATEd freely. INSERT (project create) is not blocked — it sets the
-- canonical value once and never again.

DROP TRIGGER IF EXISTS trg_projects_master_clock_guard;
CREATE TRIGGER trg_projects_master_clock_guard
BEFORE UPDATE OF settings ON projects
WHEN json_extract(NEW.settings, '$.master_clock_hz')
     IS NOT json_extract(OLD.settings, '$.master_clock_hz')
BEGIN
    SELECT RAISE(ABORT,
        'INV-6: projects.settings.master_clock_hz is immutable post-create (canonical value is 705600000 flicks)');
END;

-- ---------- INV-7 — master.audio_sample_rate must be NULL ----------

-- ---------- INV-8 — audio media_refs MUST carry audio_sample_rate ----------
-- 018 V5: schema-layer enforcement of FR-008 prerequisite. The resolver
-- reads media_refs.audio_sample_rate per-emit; NULL on an AUDIO row is a
-- writer bug that must be caught at insert time, not silently coerced.

DROP TRIGGER IF EXISTS trg_media_refs_audio_rate_required_insert;
CREATE TRIGGER trg_media_refs_audio_rate_required_insert
BEFORE INSERT ON media_refs
WHEN (SELECT track_type FROM tracks WHERE id = NEW.track_id) = 'AUDIO'
     AND NEW.audio_sample_rate IS NULL
BEGIN
    SELECT RAISE(ABORT,
        'INV-8: AUDIO media_ref must have non-NULL audio_sample_rate');
END;

DROP TRIGGER IF EXISTS trg_media_refs_audio_rate_required_update;
CREATE TRIGGER trg_media_refs_audio_rate_required_update
BEFORE UPDATE OF audio_sample_rate, track_id ON media_refs
WHEN (SELECT track_type FROM tracks WHERE id = NEW.track_id) = 'AUDIO'
     AND NEW.audio_sample_rate IS NULL
BEGIN
    SELECT RAISE(ABORT,
        'INV-8: AUDIO media_ref must have non-NULL audio_sample_rate');
END;

DROP TRIGGER IF EXISTS trg_sequences_master_audio_rate_null_insert;
CREATE TRIGGER trg_sequences_master_audio_rate_null_insert
BEFORE INSERT ON sequences
WHEN NEW.kind = 'master' AND NEW.audio_sample_rate IS NOT NULL
BEGIN
    SELECT RAISE(ABORT,
        'INV-7: sequences.audio_sample_rate must be NULL for kind=''master''');
END;

DROP TRIGGER IF EXISTS trg_sequences_master_audio_rate_null_update;
CREATE TRIGGER trg_sequences_master_audio_rate_null_update
BEFORE UPDATE OF kind, audio_sample_rate ON sequences
WHEN NEW.kind = 'master' AND NEW.audio_sample_rate IS NOT NULL
BEGIN
    SELECT RAISE(ABORT,
        'INV-7: sequences.audio_sample_rate must be NULL for kind=''master''');
END;
