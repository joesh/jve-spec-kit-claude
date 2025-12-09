CREATE TABLE IF NOT EXISTS tl_clips (
  seq_id TEXT,
  clip_id TEXT PRIMARY KEY,
  media_id TEXT,
  track TEXT,
  t_in INTEGER,
  t_out INTEGER,
  src_in INTEGER,
  src_out INTEGER,
  enable INTEGER,
  attrs_json TEXT
);
CREATE INDEX IF NOT EXISTS idx_tl_seq_track ON tl_clips(seq_id, track, t_in, t_out);

CREATE TABLE IF NOT EXISTS tl_markers (
  seq_id TEXT,
  marker_id TEXT PRIMARY KEY,
  t INTEGER,
  color TEXT,
  name TEXT
);