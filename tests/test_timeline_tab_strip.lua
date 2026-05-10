#!/usr/bin/env luajit

-- Phase 1 of 015 refactor — TimelineTabStrip holder.
--
-- Domain: the strip holds tabs and two pointers (DisplayedTab, ActiveRecordTab).
-- Per spec FR-003/004/005:
--   - clicking a Record tab updates BOTH pointers
--   - clicking the Source tab updates ONLY DisplayedTab
--   - SourceTab is a singleton, always first when open
--   - SourceTab is NEVER the ActiveRecordTab

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local TimelineTabStrip = require("ui.timeline.timeline_tab_strip")

print("=== test_timeline_tab_strip.lua ===")

-- ── DB setup ──────────────────────────────────────────────────────────────
local DB = "/tmp/jve/test_timeline_tab_strip.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', %d, %d)
]], now, now))
-- Three sequences: rec1, rec2 (record tabs), src (source-side master).
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('rec1', 'proj', 'Rec 1', 'nested', 24, 1, 48000, 1920, 1080, 0, 0, 300, %d, %d),
           ('rec2', 'proj', 'Rec 2', 'nested', 24, 1, 48000, 1920, 1080, 0, 0, 300, %d, %d),
           ('src',  'proj', 'Src',   'master', 24, 1, 48000, 1920, 1080, 0, 0, 300, %d, %d),
           ('src2', 'proj', 'Src2',  'master', 24, 1, 48000, 1920, 1080, 0, 0, 300, %d, %d)
]], now, now, now, now, now, now, now, now))

-- ── 1. empty strip ────────────────────────────────────────────────────────
local strip = TimelineTabStrip.new()
assert(#strip.tabs == 0, "fresh strip empty")
assert(strip:get_displayed() == nil, "no displayed tab")
assert(strip:get_active_record() == nil, "no active record")
assert(strip:get_source_tab() == nil, "no source tab")
print("✓ empty strip")

-- ── 2. open record tab is idempotent on same sequence ─────────────────────
local r1 = strip:open_record_tab("rec1")
local r1_again = strip:open_record_tab("rec1")
assert(r1 == r1_again, "open_record_tab returns existing tab on same seq")
assert(#strip.tabs == 1, "no duplicate tab created")

local r2 = strip:open_record_tab("rec2")
assert(r2 ~= r1, "different seq → different tab")
assert(#strip.tabs == 2, "two record tabs in strip")
print("✓ open_record_tab idempotent + multiple")

-- ── 3. switch_active_record updates BOTH pointers (FR-004) ────────────────
strip:switch_active_record(r1)
assert(strip:get_active_record() == r1, "active = r1")
assert(strip:get_displayed() == r1, "displayed = r1 (auto)")

strip:switch_active_record(r2)
assert(strip:get_active_record() == r2, "active = r2")
assert(strip:get_displayed() == r2, "displayed = r2")
print("✓ switch_active_record updates both pointers")

-- ── 4. SourceTab singleton, always first (F1) ─────────────────────────────
local s = strip:open_source_tab("src")
assert(strip:get_source_tab() == s, "source tab tracked")
assert(strip.tabs[1] == s, "source tab inserted at index 1 (first)")
assert(#strip.tabs == 3, "strip now has 3 tabs")

-- Opening source again with a different seq RELOADS the same tab object.
local s_after_reload = strip:open_source_tab("src2")
assert(s_after_reload == s, "open_source_tab is singleton: same object after reload")
assert(s.sequence_id == "src2", "reloaded sequence_id updated")
assert(strip.tabs[1] == s, "still first")
assert(#strip.tabs == 3, "still 3 tabs (no duplicate)")
print("✓ SourceTab singleton + always first + reload preserves object identity")

-- ── 5. switch_displayed to source updates ONLY displayed (FR-005) ────────
strip:switch_active_record(r2)  -- baseline: active=r2 displayed=r2
strip:switch_displayed(s)
assert(strip:get_displayed() == s, "displayed = source")
assert(strip:get_active_record() == r2, "active UNCHANGED on source-tab click (FR-005)")
print("✓ switch_displayed to source preserves active pointer")

-- ── 6. switch_active_record refuses source tab (FR-003) ──────────────────
local ok, err = pcall(function() strip:switch_active_record(s) end)
assert(not ok and err:find("must pass a record tab"),
    "switch_active_record asserts on source tab")
print("✓ switch_active_record refuses source tab")

-- ── 7. close source tab; displayed falls back to active record ───────────
-- State: tabs=[src,r1,r2], displayed=src, active=r2
strip:close_source_tab()
assert(strip:get_source_tab() == nil, "source tab gone")
assert(#strip.tabs == 2, "two record tabs remain")
assert(strip:get_displayed() == r2, "displayed fell back to active record")
assert(strip:get_active_record() == r2, "active unchanged")

-- close_source_tab when none open → asserts
ok, err = pcall(function() strip:close_source_tab() end)
assert(not ok and err:find("no source tab open"), "double-close asserts")
print("✓ close_source_tab + displayed fallback")

-- ── 8. close record tab; pointer recovery ────────────────────────────────
-- State: tabs=[r1,r2], displayed=r2, active=r2
strip:close_record_tab(r2)
assert(#strip.tabs == 1, "one record tab remains")
assert(strip:get_active_record() == r1, "active fell back to r1")
assert(strip:get_displayed() == r1, "displayed fell back to r1")

-- close last record tab; both pointers go nil (no source tab to fall back to)
strip:close_record_tab(r1)
assert(#strip.tabs == 0, "strip empty")
assert(strip:get_active_record() == nil, "active = nil")
assert(strip:get_displayed() == nil, "displayed = nil")
print("✓ close_record_tab pointer recovery")

-- ── 9. close record tab with source tab present → displayed → source ────
strip = TimelineTabStrip.new()
local rec = strip:open_record_tab("rec1")
local src_tab = strip:open_source_tab("src")
strip:switch_active_record(rec)
-- displayed=rec, active=rec, source tab present
strip:close_record_tab(rec)
assert(strip:get_active_record() == nil, "active = nil after closing only record")
assert(strip:get_displayed() == src_tab, "displayed falls back to source tab")
print("✓ close last record with source open → displayed → source")

-- ── 10. switch_displayed asserts on tab not in strip ────────────────────
local stranger = require("ui.timeline.timeline_tab").new("record", "rec1")
ok, err = pcall(function() strip:switch_displayed(stranger) end)
assert(not ok and err:find("not in strip"), "switch_displayed asserts on stranger")

ok, err = pcall(function() strip:close_record_tab(stranger) end)
assert(not ok and err:find("not in strip"), "close_record_tab asserts on stranger")
print("✓ pointer/close ops assert on tabs not in strip")

-- ── 11. listener notification ────────────────────────────────────────────
strip = TimelineTabStrip.new()
local notify_count = 0
local lid = strip:add_listener(function() notify_count = notify_count + 1 end)
strip:open_record_tab("rec1"); assert(notify_count == 1, "open notifies")
strip:open_record_tab("rec2"); assert(notify_count == 2, "open notifies")
strip:switch_active_record(strip.tabs[1]); assert(notify_count == 3, "switch notifies")
strip:remove_listener(lid)
strip:open_record_tab("rec1") -- idempotent, no extra
local before = notify_count
strip:open_source_tab("src")
assert(notify_count == before, "remove_listener stops notifications")
print("✓ listener subscription")

-- ── 12. serialize / deserialize round trip ───────────────────────────────
strip = TimelineTabStrip.new()
local source = strip:open_source_tab("src")
local rec_a = strip:open_record_tab("rec1")
strip:open_record_tab("rec2")  -- third tab, no var needed (just exercises multi-record persistence)
strip:switch_active_record(rec_a)  -- displayed=rec_a active=rec_a
strip:switch_displayed(source)     -- displayed=source active=rec_a (FR-005)

local serialized = strip:serialize()
local restored = TimelineTabStrip.deserialize(serialized)
assert(#restored.tabs == 3, "tab count preserved")
assert(restored.tabs[1].kind == "source", "source tab still first")
assert(restored:get_source_tab() ~= nil, "source tab tracked after deserialize")

-- Pointer round-trip by id, not object identity.
assert(restored:get_displayed().id == source.id, "displayed pointer restored")
assert(restored:get_active_record().id == rec_a.id, "active pointer restored")

-- Tab identity (id, kind, sequence_id) survives. Per-tab DISPLAY state
-- (viewport, playhead, scroll) lives on the sequence row and is NOT
-- duplicated through tab serialization — verified by the tab unit test.
local restored_rec_a
for _, t in ipairs(restored.tabs) do
    if t.id == rec_a.id then restored_rec_a = t; break end
end
assert(restored_rec_a, "rec_a tab found in restored strip")
assert(restored_rec_a.kind == "record" and restored_rec_a.sequence_id == "rec1",
    "tab identity preserved across serialize/deserialize")
print("✓ serialize/deserialize round trip preserves tabs + pointers + identity")

-- deserialize asserts on dangling pointer
local bad = strip:serialize()
bad.displayed_tab_id = "nonexistent-id"
ok, err = pcall(function() return TimelineTabStrip.deserialize(bad) end)
assert(not ok and err:find("nonexistent-id", 1, true), "dangling displayed_tab_id asserts")
print("✓ deserialize asserts on dangling pointer")

print("✅ test_timeline_tab_strip.lua passed")
