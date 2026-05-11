--- Integration test for the F-key (MatchFrame) source-load user flow.
--
-- Runs inside `./build/bin/JVEEditor --test`. Creates a project DB with
-- a record sequence + a master sequence (media at non-zero TC origin
-- like a typical camera-original file). Launches the full UI, then
-- programmatically does what F does: load the master into the source
-- viewer. Asserts what the user expects to see in the running editor.
--
-- This is a behavior test — names are user-visible concepts (what's
-- displayed, what tab is in the strip, what the monitors show), not
-- implementation details.

local ui = require("integration.ui_test_env")

print("=== test_015_f_key_source_load ===")

-- ── Custom DB seed: ui_test_env's helper only creates nested sequences;
-- we need a master with media_refs at non-zero TC origin to reproduce
-- the screenshot's failure conditions.
local saved_home = os.getenv("HOME")
local ffi = require("ffi")
ffi.cdef[[ int setenv(const char *name, const char *value, int overwrite); ]]
ffi.C.setenv("HOME", "/tmp/jve_test_home", 1)
os.execute("mkdir -p /tmp/jve_test_home/.jve")

local DB = "/tmp/jve/test_015_f_key.jvp"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")

local database = require("core.database")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
local TC_ORIGIN_24FPS = 1324752  -- 15:19:58:00 @ 24fps — camera-original

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at, settings)
    VALUES ('proj', 'F Key Test', 'resample', %d, %d,
            '{"last_open_sequence_id":"rec","open_sequence_ids":["rec"]}');

    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES
      ('rec', 'proj', 'Record', 'nested', 25, 1, 48000, 1920, 1080, 100, 0, 1500, %d, %d),
      ('msa', 'proj', 'A012',   'master', 24, 1,  NULL, 1920, 1080,   0, 0,  300, %d, %d),
      ('msb', 'proj', 'A037',   'master', 24, 1,  NULL, 1920, 1080,   0, 0,  300, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES
      ('rv1', 'rec', 'V1', 'VIDEO', 1, 1),
      ('ra1', 'rec', 'A1', 'AUDIO', 1, 1),
      ('av1', 'msa', 'V1', 'VIDEO', 1, 1),
      ('aa1', 'msa', 'A1', 'AUDIO', 1, 1),
      ('bv1', 'msb', 'V1', 'VIDEO', 1, 1);

    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_sample_rate, width, height,
        created_at, modified_at)
    VALUES
      ('ma', 'proj', 'A012', '/tmp/A012.mov', 1200, 24, 1, 48000, 1920, 1080, %d, %d),
      ('mb', 'proj', 'A037', '/tmp/A037.mov',  600, 24, 1, 48000, 1920, 1080, %d, %d);

    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        timeline_start_frame, duration_frames,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES
      ('mra_v', 'proj', 'msa', 'av1', 'ma', 0, 1200, %d, 1200, 1, 1.0, 0, %d, %d),
      ('mra_a', 'proj', 'msa', 'aa1', 'ma', 0, 1200, %d, 1200, 1, 1.0, 0, %d, %d),
      ('mrb_v', 'proj', 'msb', 'bv1', 'mb', 0,  600, 0,    600, 1, 1.0, 0, %d, %d);
]], now,now,                              -- projects (2)
    now,now, now,now, now,now,            -- 3 sequences (6)
    now,now, now,now,                     -- 2 media (4)
    TC_ORIGIN_24FPS, now,now,             -- mra_v (3)
    TC_ORIGIN_24FPS, now,now,             -- mra_a (3)
    now,now))                             -- mrb_v (2)

database.shutdown()

-- ── Launch the full UI against this DB ────────────────────────────────
ffi.C.setenv("JVE_PROJECT_PATH", DB, 1)
package.cpath = package.cpath .. ';' .. saved_home .. '/.luarocks/lib/lua/5.1/?.so'
package.path = package.path .. ';' .. saved_home .. '/.luarocks/share/lua/5.1/?.lua'
package.path = package.path .. ';' .. saved_home .. '/.luarocks/share/lua/5.1/?/init.lua'

local app = require("ui.layout")
assert(app and app.main_window, "layout.lua did not return main_window")
ui.pump(300)

local timeline_state = require("ui.timeline.timeline_state")
local timeline_panel = require("ui.timeline.timeline_panel")
local panel_manager  = require("ui.panel_manager")
local source_viewer  = require("ui.source_viewer")

-- ── Failure-collecting check (no early abort — see EVERYTHING broken) ──
local failures = {}
local function check(label, ok, detail)
    if ok then
        print(string.format("  PASS  %s", label))
    else
        print(string.format("  FAIL  %s — %s", label, detail or ""))
        table.insert(failures, label)
    end
end

-- ── Pre-F state ───────────────────────────────────────────────────────
print("-- pre-F: project just opened on record tab --")
check("active is record",
    timeline_state.get_active_sequence_id() == "rec",
    "got " .. tostring(timeline_state.get_active_sequence_id()))
check("displayed is record",
    timeline_state.get_displayed_tab_id() == "rec",
    "got " .. tostring(timeline_state.get_displayed_tab_id()))

local pre_tabs = timeline_panel.get_open_tab_ids()
check("strip has exactly one tab (record)",
    #pre_tabs == 1 and pre_tabs[1] == "rec",
    "got tabs=[" .. table.concat(pre_tabs, ",") .. "]")

local tl_monitor = panel_manager.get_sequence_monitor("timeline_monitor")
check("timeline_monitor loaded with active record",
    tl_monitor.sequence_id == "rec",
    "got " .. tostring(tl_monitor.sequence_id))

-- ── Simulate F (MatchFrame): load master into the source viewer ───────
print("-- F pressed: source_viewer.load_master_clip(master) --")
source_viewer.load_master_clip("msa")
ui.pump(300)

-- ── Post-F assertions ────────────────────────────────────────────────
print("-- post-F: source tab open, displayed swapped --")
check("displayed is now master (FR-005 displayed-only swap)",
    timeline_state.get_displayed_tab_id() == "msa",
    "got " .. tostring(timeline_state.get_displayed_tab_id()))
check("active is STILL record (FR-005 — source tab is not active)",
    timeline_state.get_active_sequence_id() == "rec",
    "got " .. tostring(timeline_state.get_active_sequence_id()))

local post_tabs = timeline_panel.get_open_tab_ids()
check("strip has exactly two tabs: record + source",
    #post_tabs == 2,
    "got " .. #post_tabs .. " tabs: [" .. table.concat(post_tabs, ",") .. "]")

local has_record_tab, has_master_tab = false, false
for _, id in ipairs(post_tabs) do
    if id == "rec" then has_record_tab = true end
    if id == "msa" then has_master_tab = true end
end
check("strip contains the record tab", has_record_tab, "")
check("strip contains the master/source tab", has_master_tab, "")

-- The timeline view must show master content — virtual clips synthesized from media_refs.
local view_clips = timeline_state.get_clips()
local virtuals = 0
for _, c in ipairs(view_clips) do if c.is_master_virtual then virtuals = virtuals + 1 end end
check("timeline view shows 2 virtual clips (V + A media_refs)",
    virtuals == 2,
    string.format("got %d virtual / %d total", virtuals, #view_clips))

-- Critical user-visible fix from the screenshot: viewport must intersect content.
local vs = timeline_state.get_viewport_start_time()
local vd = timeline_state.get_viewport_duration()
local ve = vs + vd
local intersects = false
for _, c in ipairs(view_clips) do
    if not c.is_gap then
        local cs, ce = c.timeline_start, c.timeline_start + c.duration
        if cs and ce and cs < ve and ce > vs then intersects = true end
    end
end
check("timeline view viewport intersects master content (content visible)",
    intersects,
    string.format("viewport=[%d,%d) clip starts at %d", vs, ve,
        view_clips[1] and view_clips[1].timeline_start or -1))

-- The two monitors must NOT both show source content.
check("timeline_monitor STAYS on active record (does NOT mirror source)",
    tl_monitor.sequence_id == "rec",
    "got " .. tostring(tl_monitor.sequence_id))

local src_monitor = panel_manager.get_sequence_monitor("source_monitor")
check("source_monitor loaded with the master",
    src_monitor.sequence_id == "msa",
    "got " .. tostring(src_monitor.sequence_id))

-- Record's persisted state must not be corrupted by source-tab visit.
local Sequence = require("models.sequence")
local rec_after = Sequence.load("rec")
check("record's persisted playhead unchanged (no corruption)",
    rec_after.playhead_position == 100,
    "got " .. tostring(rec_after.playhead_position))
check("record's persisted playhead is sane (< 1M frames)",
    rec_after.playhead_position < 1000000,
    "got " .. tostring(rec_after.playhead_position))

-- ── Second F: load a DIFFERENT master into the source viewer.
-- This exercises the master→master transition where sequence_monitor
-- saves the prior master's playhead before swapping. TSO showed a
-- FOREIGN KEY constraint failure in this path.
print("-- second F: load master B into source viewer --")
local ok2, err2 = pcall(source_viewer.load_master_clip, "msb")
ui.pump(300)
check("loading a second master does not crash (no FK constraint failure)",
    ok2,
    string.format("error: %s", tostring(err2)))

-- After the swap, only ONE source tab should be in the strip (FR-001).
local post2_tabs = timeline_panel.get_open_tab_ids()
local has_msa, has_msb = false, false
for _, id in ipairs(post2_tabs) do
    if id == "msa" then has_msa = true end
    if id == "msb" then has_msb = true end
end
check("after second F, only the new master tab exists (FR-001 singleton)",
    has_msb and not has_msa,
    string.format("tabs=[%s] (has_msa=%s has_msb=%s)",
        table.concat(post2_tabs, ","), tostring(has_msa), tostring(has_msb)))
check("after second F, displayed is the new master",
    timeline_state.get_displayed_tab_id() == "msb",
    "got " .. tostring(timeline_state.get_displayed_tab_id()))

-- ── Report ────────────────────────────────────────────────────────────
print("")
if #failures == 0 then
    print("✅ test_015_f_key_source_load passed")
else
    print(string.format("❌ test_015_f_key_source_load FAILED — %d behavior(s) broken:", #failures))
    for _, f in ipairs(failures) do print("    - " .. f) end
    os.exit(1)
end
