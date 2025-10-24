#!/usr/bin/env bash

set -euo pipefail

PROJECT_PATH="${1:-/tmp/canonical.jvp}"
SCHEMA_FILE="$(dirname "$0")/../src/core/persistence/schema.sql"

if [[ ! -f "$SCHEMA_FILE" ]]; then
  echo "Schema file not found: $SCHEMA_FILE" >&2
  exit 1
fi

mkdir -p "$(dirname "$PROJECT_PATH")"
rm -f "$PROJECT_PATH"

sqlite3 "$PROJECT_PATH" < "$SCHEMA_FILE"

sqlite3 "$PROJECT_PATH" <<'SQL'
DELETE FROM commands;
DELETE FROM clips;
DELETE FROM media;
DELETE FROM tracks;
DELETE FROM sequences;
DELETE FROM projects;

INSERT INTO projects (id, name, created_at, modified_at, settings)
VALUES ('default_project', 'Canonical Ripple Project', strftime('%s','now'), strftime('%s','now'), '{}');

INSERT INTO sequences (id, project_id, name, frame_rate, width, height, timecode_start, playhead_time, selected_clip_ids, selected_edge_infos)
VALUES ('default_sequence', 'default_project', 'Sequence 1', 30.0, 1920, 1080, 0, 0, '[]', '[]');

INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES
    ('video1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0),
    ('video2', 'default_sequence', 'V2', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0);

INSERT INTO media (id, project_id, name, file_path, duration, frame_rate, width, height, audio_channels, codec, created_at, modified_at)
VALUES
    ('media_v2_clip', 'default_project', 'Clip A', '/tmp/clip_a.mov', 8000, 30.0, 1920, 1080, 2, 'prores', strftime('%s','now'), strftime('%s','now')),
    ('media_v1_clip', 'default_project', 'Clip B', '/tmp/clip_b.mov', 10000, 30.0, 1920, 1080, 2, 'prores', strftime('%s','now'), strftime('%s','now'));

INSERT INTO clips (id, track_id, media_id, start_time, duration, source_in, source_out, enabled)
VALUES
    ('clip_v2_a', 'video2', 'media_v2_clip', 0, 5000, 0, 5000, 1),
    ('clip_v1_b', 'video1', 'media_v1_clip', 3000, 5000, 0, 5000, 1);
SQL

echo "Canonical ripple project written to $PROJECT_PATH"
