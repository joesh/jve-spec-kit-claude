-- Feature 027 T018: D1 initial schema.
--
-- Five tables (per data-model.md §Tier 1):
--   installs                    — one row per app installation
--   reports                     — one row per submitted bug report
--   clusters                    — dedup key (signature) → count + gh_issue_url
--   report_idempotency          — X-Report-Local-Id replay guard (TTL 7d)
--   install_register_attempts   — per-IP-hash + hour register rate counter
--
-- No `nonce_hash` — the `nonce` is stored raw because the HMAC protocol
-- needs the secret value to verify each subsequent request (a hash
-- would be one-way and useless for verification). Compromise mitigated
-- by per-install revocation (installs.status = 'suspended').
--
-- Joe regenerates the database when schema changes (no down-migration
-- needed; the dataset is small enough that re-collecting from active
-- installs is faster than authoring rollback DDL).

CREATE TABLE installs (
  install_id          TEXT PRIMARY KEY NOT NULL,
  nonce               TEXT NOT NULL,
  first_seen          INTEGER NOT NULL,
  last_launched       INTEGER NOT NULL,
  jve_sha             TEXT NOT NULL,
  platform            TEXT NOT NULL,
  os_version          TEXT,
  arch                TEXT NOT NULL,
  country             TEXT,
  timezone            TEXT,
  cpu_model           TEXT,
  cpu_cores_physical  INTEGER,
  cpu_cores_logical   INTEGER,
  cpu_perf_cores      INTEGER,
  cpu_eff_cores       INTEGER,
  system_memory_mb    INTEGER,
  gpu_vendor          TEXT,
  gpu_model           TEXT,
  gpu_memory_mb       INTEGER,
  gpu_api             TEXT,
  unified_memory      INTEGER NOT NULL DEFAULT 0,
  reports_count       INTEGER NOT NULL DEFAULT 0,
  status              TEXT NOT NULL DEFAULT 'active' CHECK(status IN ('active', 'suspended'))
);

CREATE INDEX idx_installs_last_launched ON installs(last_launched);
CREATE INDEX idx_installs_country       ON installs(country);
CREATE INDEX idx_installs_jve_sha       ON installs(jve_sha);

CREATE TABLE clusters (
  id            TEXT PRIMARY KEY NOT NULL,
  signature     TEXT UNIQUE NOT NULL,
  first_seen    INTEGER NOT NULL,
  count         INTEGER NOT NULL DEFAULT 1,
  gh_issue_url  TEXT
);

CREATE INDEX idx_clusters_count ON clusters(count DESC);

-- reports references clusters, so clusters must exist first.
CREATE TABLE reports (
  id              TEXT PRIMARY KEY NOT NULL,
  install_id      TEXT NOT NULL REFERENCES installs(install_id),
  ts              INTEGER NOT NULL,
  jve_sha         TEXT NOT NULL,
  schema_version  TEXT NOT NULL,
  signature       TEXT NOT NULL,
  last_cmd        TEXT,
  last_err        TEXT,
  user_title      TEXT NOT NULL CHECK(length(user_title) > 0),
  user_desc       TEXT,
  capture_type    TEXT NOT NULL CHECK(capture_type IN ('user_submitted', 'automatic')),
  text_only       INTEGER NOT NULL DEFAULT 0 CHECK(text_only IN (0, 1)),
  r2_key          TEXT NOT NULL,
  cluster_id      TEXT NOT NULL REFERENCES clusters(id)
);

CREATE INDEX idx_reports_install_ts  ON reports(install_id, ts);
CREATE INDEX idx_reports_cluster     ON reports(cluster_id);
CREATE INDEX idx_reports_signature   ON reports(signature);
CREATE INDEX idx_reports_jve_sha     ON reports(jve_sha);

CREATE TABLE report_idempotency (
  install_id    TEXT NOT NULL,
  local_id      TEXT NOT NULL,
  report_id     TEXT NOT NULL,
  created_at    INTEGER NOT NULL,
  PRIMARY KEY (install_id, local_id)
);

CREATE INDEX idx_report_idempotency_created ON report_idempotency(created_at);

CREATE TABLE install_register_attempts (
  ip_hash       TEXT NOT NULL,
  window_start  INTEGER NOT NULL,
  attempt_count INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (ip_hash, window_start)
);

CREATE INDEX idx_register_attempts_window ON install_register_attempts(window_start);
