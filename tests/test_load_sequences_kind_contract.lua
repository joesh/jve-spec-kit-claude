#!/usr/bin/env luajit

-- Regression for project_browser ↔ load_sequences kind-name contract.
--
-- Bug history: project_browser.lua filtered with `sequence.kind == "timeline"`
-- while load_sequences returns rows whose kind is "sequence" (the only
-- non-master value the schema's CHECK constraint allows). The result was
-- that every user-created sequence was silently filtered out of the
-- browser tree — gold timeline included.
--
-- This test pins the contract from the DB side: load_sequences MUST
-- return non-master sequences with kind == "sequence" (not "timeline",
-- not nil). The matching browser filter currently accepts whatever
-- load_sequences returns; if either side drifts, this test fails.

require("test_env")
local database = require("core.database")

local DB = "/tmp/jve/test_load_sequences_kind_contract.db"

print("=== test_load_sequences_kind_contract.lua ===")

os.remove(DB); os.execute("mkdir -p /tmp/jve")
assert(database.init(DB), "schema.sql init failed")
local db = database.get_connection()

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('p', 'p', 'passthrough', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        created_at, modified_at)
    VALUES
      ('m1', 'p', 'master-one', 'master',   24, 1, 48000, 1920, 1080, %d, %d),
      ('s1', 'p', 'gold',       'sequence', 24, 1, 48000, 1920, 1080, %d, %d),
      ('s2', 'p', 'silver',     'sequence', 24, 1, 48000, 1920, 1080, %d, %d);
]], now, now, now, now, now, now, now, now)))

local rows = database.load_sequences("p")
assert(type(rows) == "table",
    "load_sequences must return a table; got " .. type(rows))
assert(#rows == 2, string.format(
    "load_sequences must return only kind='sequence' rows (2 expected); got %d",
    #rows))

-- Every returned row must carry kind == "sequence". The browser's
-- consumer must filter on (or trust) this exact string — see project
-- _browser.lua collection of timeline_sequences. Any other value (nil,
-- "timeline", "master") breaks the browser tree.
local seen_names = {}
for _, r in ipairs(rows) do
    assert(r.kind == "sequence", string.format(
        "load_sequences returned row with kind=%q on id=%s; "
        .. "browser display contract requires kind=='sequence'",
        tostring(r.kind), tostring(r.id)))
    seen_names[r.name] = true
end
assert(seen_names["gold"], "load_sequences must include 'gold' sequence")
assert(seen_names["silver"], "load_sequences must include 'silver' sequence")
assert(not seen_names["master-one"],
    "load_sequences must exclude kind='master' rows (they're listed via load_master_clips)")

print("\nâœ… test_load_sequences_kind_contract.lua passed")
