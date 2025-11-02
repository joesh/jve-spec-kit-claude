CREATE TABLE IF NOT EXISTS media (
  media_id TEXT PRIMARY KEY,
  uri TEXT,
  sha3 TEXT,
  duration INTEGER,
  time_base INTEGER,
  audio_layout TEXT,
  proxy_json TEXT,
  tags_json TEXT
);
CREATE INDEX IF NOT EXISTS idx_media_sha ON media(sha3);
