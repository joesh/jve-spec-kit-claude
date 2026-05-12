#!/usr/bin/env luajit

-- Phase 1 of 015 refactor — TimelineTab object.
--
-- Domain: a TimelineTab is a thin handle: (id, kind, sequence_id) +
-- listener pub/sub. All displayed state (marks, viewport, playhead, scroll)
-- lives on the sequence row. Tab getters pull lazily so model mutations
-- propagate without explicit cache sync (MVC pull).
-- Selection and drag are global on timeline_state, not per-tab.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local Sequence = require("models.sequence")
local TimelineTab = require("ui.timeline.timeline_tab")

print("=== test_timeline_tab.lua ===")

-- ── DB setup ──────────────────────────────────────────────────────────────
local DB = "/tmp/jve/test_timeline_tab.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', %d, %d)
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('seqA', 'proj', 'A', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0, 300, %d, %d),
           ('seqB', 'proj', 'B', 'sequence', 30, 1, 48000, 1920, 1080, 0, 0, 300, %d, %d)
]], now, now, now, now))

-- ── 1. construction ───────────────────────────────────────────────────────
local tab = TimelineTab.new("record", "seqA")
assert(tab.kind == "record", "kind preserved")
assert(tab.sequence_id == "seqA", "sequence_id preserved")
assert(type(tab.id) == "string" and #tab.id > 0, "id auto-generated")
print("✓ construction")

-- ── 2. construction error paths ───────────────────────────────────────────
local ok, err = pcall(TimelineTab.new, "invalid", "seqA")
assert(not ok and err:find("kind must be"), "rejects bad kind")

ok, err = pcall(TimelineTab.new, "record", nil)
assert(not ok and err:find("sequence_id required"), "rejects missing sequence_id")

ok, err = pcall(TimelineTab.new, "record", "")
assert(not ok and err:find("sequence_id required"), "rejects empty sequence_id")

ok, err = pcall(TimelineTab.new, "record", "ghost")
assert(not ok and err:find("ghost"), "rejects unknown sequence_id")
print("✓ construction error paths")

-- ── 3. get_marks pulls fresh from sequence row (MVC) ──────────────────────
local marks = tab:get_marks()
assert(marks.in_frame == nil and marks.out_frame == nil, "fresh seq has no marks")

-- Mutate the sequence's marks externally via Sequence model.
local seq = Sequence.load("seqA")
seq:set_in(48)
seq:set_out(120)
seq:save()

local marks2 = tab:get_marks()
assert(marks2.in_frame == 48, string.format("mark_in pulled fresh (got %s)", tostring(marks2.in_frame)))
assert(marks2.out_frame ~= nil, "mark_out pulled fresh after external write")
print("✓ get_marks pulls fresh from sequence row")

-- get_marks asserts when the sequence is deleted out from under the tab.
db:exec("DELETE FROM sequences WHERE id='seqB'")
local orphan_seq = "seqB"
ok = pcall(function() return TimelineTab.new("record", orphan_seq) end)
assert(not ok, "construction against deleted sequence asserts")
print("✓ construction asserts on deleted sequence")

-- ── 4. listener pub/sub ───────────────────────────────────────────────────
-- Restore seqB so we can exercise reload notifications.
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('seqB', 'proj', 'B', 'sequence', 30, 1, 48000, 1920, 1080, 0, 0, 300, %d, %d)
]], now, now))

local notify_count = 0
local lid = tab:add_listener(function() notify_count = notify_count + 1 end)
tab:reload("seqB")
assert(notify_count == 1, "reload notifies subscribers")

tab:remove_listener(lid)
tab:reload("seqA")
assert(notify_count == 1, "remove_listener stops notifications")
print("✓ listener pub/sub")

-- ── 5. reload preserves identity and listener subscriptions ───────────────
local source_tab = TimelineTab.new("source", "seqA")
local original_id = source_tab.id
local rcount = 0
source_tab:add_listener(function() rcount = rcount + 1 end)

source_tab:reload("seqB")
assert(source_tab.id == original_id, "reload preserves tab id")
assert(source_tab.sequence_id == "seqB", "reload changes sequence_id")
assert(rcount == 1, "reload notifies subscribed listeners (listener survives reload)")

-- reload asserts on missing sequence
ok, err = pcall(function() source_tab:reload("ghost") end)
assert(not ok and err:find("ghost"), "reload asserts on missing sequence")
print("✓ reload preserves id + listeners + asserts on missing sequence")

-- ── 6. serialize / deserialize round trip ─────────────────────────────────
-- Serialization captures (id, kind, sequence_id) — per-tab display state
-- (viewport, playhead, scroll, marks) lives on the sequence row and is
-- restored via Sequence model, not via tab serialization.
local s = source_tab:serialize()
assert(s.id == source_tab.id, "serialize emits id")
assert(s.kind == "source", "serialize emits kind")
assert(s.sequence_id == "seqB", "serialize emits sequence_id")
-- Per-tab display state must NOT appear in serialization (source-of-truth
-- belongs to sequence row).
assert(s.viewport == nil and s.playhead_position == nil and s.scroll == nil,
    "serialize does not duplicate sequence-row state")

local restored = TimelineTab.deserialize(s)
assert(restored.id == source_tab.id, "deserialize preserves id")
assert(restored.kind == source_tab.kind, "deserialize preserves kind")
assert(restored.sequence_id == source_tab.sequence_id, "deserialize preserves sequence_id")
print("✓ serialize/deserialize round trip")

-- deserialize asserts on every required field
ok, err = pcall(TimelineTab.deserialize, { kind = "record", sequence_id = "seqA" })
assert(not ok and err:find("id required"), "deserialize rejects missing id")

ok, err = pcall(TimelineTab.deserialize, { id = "x", sequence_id = "seqA" })
assert(not ok and err:find("kind must be"), "deserialize rejects missing kind")

ok, err = pcall(TimelineTab.deserialize, { id = "x", kind = "record" })
assert(not ok and err:find("sequence_id required"), "deserialize rejects missing sequence_id")

ok, err = pcall(TimelineTab.deserialize, { id = "x", kind = "record", sequence_id = "ghost" })
assert(not ok and err:find("ghost"), "deserialize asserts on dangling sequence reference")
print("✓ deserialize asserts on every required field + dangling sequence ref")

print("✅ test_timeline_tab.lua passed")
