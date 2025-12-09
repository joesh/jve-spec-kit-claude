CREATE TABLE IF NOT EXISTS ui_state (
  id INTEGER PRIMARY KEY CHECK (id=1),
  active_seq TEXT,
  playhead_time INTEGER,
  last_panel TEXT
);
