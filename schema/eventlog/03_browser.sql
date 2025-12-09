CREATE TABLE IF NOT EXISTS browser_state (
  id INTEGER PRIMARY KEY CHECK (id=1),
  active_bin TEXT,
  tag_filter_json TEXT,
  selection_media_ids_json TEXT
);
