return [[
    PRAGMA foreign_keys = ON;

    CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        modified_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        settings TEXT DEFAULT '{}'
    );

    CREATE TABLE sequences (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        name TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'timeline',
        frame_rate REAL NOT NULL,
        audio_sample_rate INTEGER NOT NULL DEFAULT 48000,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        timecode_start_frame INTEGER NOT NULL DEFAULT 0,
        playhead_value INTEGER NOT NULL DEFAULT 0,
        selected_clip_ids TEXT,
        selected_edge_infos TEXT,
        viewport_start_value INTEGER NOT NULL DEFAULT 0,
        viewport_duration_frames_value INTEGER NOT NULL DEFAULT 240,
        mark_in_value INTEGER,
        mark_out_value INTEGER,
        current_sequence_number INTEGER,
        FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
    );

    CREATE TABLE tracks (
        id TEXT PRIMARY KEY,
        sequence_id TEXT NOT NULL,
        name TEXT NOT NULL,
        track_type TEXT NOT NULL,
        timebase_type TEXT NOT NULL,
        timebase_rate REAL NOT NULL,
        track_index INTEGER NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        locked INTEGER NOT NULL DEFAULT 0,
        muted INTEGER NOT NULL DEFAULT 0,
        soloed INTEGER NOT NULL DEFAULT 0,
        volume REAL NOT NULL DEFAULT 1.0,
        pan REAL NOT NULL DEFAULT 0.0,
        FOREIGN KEY (sequence_id) REFERENCES sequences(id) ON DELETE CASCADE,
        UNIQUE(sequence_id, track_type, track_index)
    );

    CREATE TABLE media (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        name TEXT,
        file_path TEXT,
        duration_value INTEGER NOT NULL,
        timebase_type TEXT NOT NULL,
        timebase_rate REAL NOT NULL,
        frame_rate REAL NOT NULL DEFAULT 0,
        width INTEGER,
        height INTEGER,
        audio_channels INTEGER,
        codec TEXT,
        created_at INTEGER,
        modified_at INTEGER,
        metadata TEXT,
        FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE
    );

    CREATE TABLE master_clips (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        media_id TEXT,
        name TEXT NOT NULL,
        clip_kind TEXT NOT NULL,
        duration_value INTEGER NOT NULL,
        source_in_value INTEGER NOT NULL DEFAULT 0,
        source_out_value INTEGER NOT NULL,
        timebase_type TEXT NOT NULL,
        timebase_rate REAL NOT NULL,
        created_at INTEGER,
        modified_at INTEGER,
        FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE,
        FOREIGN KEY (media_id) REFERENCES media(id) ON DELETE SET NULL
    );

    CREATE TABLE clips (
        id TEXT PRIMARY KEY,
        project_id TEXT,
        clip_kind TEXT NOT NULL DEFAULT 'timeline',
        name TEXT DEFAULT '',
        track_id TEXT,
        media_id TEXT,
        source_sequence_id TEXT,
        parent_clip_id TEXT,
        owner_sequence_id TEXT,
        start_value INTEGER NOT NULL,
        duration_value INTEGER NOT NULL,
        source_in_value INTEGER NOT NULL DEFAULT 0,
        source_out_value INTEGER NOT NULL,
        timebase_type TEXT NOT NULL,
        timebase_rate REAL NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        offline INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER,
        modified_at INTEGER,
        FOREIGN KEY (project_id) REFERENCES projects(id) ON DELETE CASCADE,
        FOREIGN KEY (track_id) REFERENCES tracks(id) ON DELETE CASCADE,
        FOREIGN KEY (media_id) REFERENCES media(id) ON DELETE SET NULL,
        FOREIGN KEY (source_sequence_id) REFERENCES sequences(id) ON DELETE SET NULL,
        FOREIGN KEY (parent_clip_id) REFERENCES clips(id) ON DELETE CASCADE,
        FOREIGN KEY (owner_sequence_id) REFERENCES sequences(id) ON DELETE CASCADE
    );

    CREATE TABLE properties (
        id TEXT PRIMARY KEY,
        clip_id TEXT NOT NULL,
        property_name TEXT NOT NULL,
        property_value TEXT NOT NULL,
        property_type TEXT NOT NULL,
        default_value TEXT NOT NULL,
        FOREIGN KEY (clip_id) REFERENCES clips(id) ON DELETE CASCADE
    );

    CREATE TABLE clip_links (
        link_group_id TEXT NOT NULL,
        clip_id TEXT NOT NULL,
        role TEXT NOT NULL,
        time_offset INTEGER NOT NULL DEFAULT 0,
        timebase_type TEXT NOT NULL,
        timebase_rate REAL NOT NULL,
        enabled INTEGER NOT NULL DEFAULT 1,
        PRIMARY KEY(link_group_id, clip_id),
        FOREIGN KEY (clip_id) REFERENCES clips(id) ON DELETE CASCADE
    );

    CREATE TABLE commands (
        id TEXT PRIMARY KEY,
        parent_id TEXT,
        parent_sequence_number INTEGER,
        sequence_number INTEGER UNIQUE NOT NULL,
        command_type TEXT NOT NULL,
        command_args TEXT,
        pre_hash TEXT,
        post_hash TEXT,
        timestamp INTEGER,
        playhead_value INTEGER DEFAULT 0,
        playhead_rate REAL DEFAULT 0,
        selected_clip_ids TEXT DEFAULT '[]',
        selected_edge_infos TEXT DEFAULT '[]',
        selected_gap_infos TEXT DEFAULT '[]',
        selected_clip_ids_pre TEXT DEFAULT '[]',
        selected_edge_infos_pre TEXT DEFAULT '[]',
        selected_gap_infos_pre TEXT DEFAULT '[]'
    );

    CREATE TABLE snapshots (
        id TEXT PRIMARY KEY,
        sequence_id TEXT NOT NULL,
        sequence_number INTEGER NOT NULL,
        clips_state TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        FOREIGN KEY (sequence_id) REFERENCES sequences(id) ON DELETE CASCADE
    );

    CREATE TABLE tag_namespaces (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL
    );

    INSERT OR IGNORE INTO tag_namespaces(id, display_name)
    VALUES('bin', 'Bins');

    CREATE TABLE tags (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        namespace_id TEXT NOT NULL,
        name TEXT NOT NULL,
        path TEXT NOT NULL,
        parent_id TEXT,
        sort_index INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
    );

    CREATE TABLE tag_assignments (
        tag_id TEXT NOT NULL,
        project_id TEXT NOT NULL,
        namespace_id TEXT NOT NULL,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        assigned_at INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(tag_id, entity_type, entity_id)
    );
]]
