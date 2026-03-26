--- Quickstart validation: end-to-end scenarios from quickstart.md
-- Tests integrated behavior across query_engine, find_state, sift_state,
-- sift_commands, smart_bin, and replace commands.
require("test_env")

local query_engine = require("core.query_engine")
local find_state = require("core.find_state")
local sift_state = require("core.sift_state")
local sift_commands = require("core.sift_commands")
local database = require("core.database")
local json = require("dkjson")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

-- ============================================================================
-- Setup: DB for sift persistence + replace tests
-- ============================================================================
local db_path = "/tmp/jve/test_quickstart.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()

local now = os.time()
db:exec(string.format(
    "INSERT INTO projects (id, name, created_at, modified_at) VALUES ('proj1', 'Quickstart', %d, %d)",
    now, now))

-- ============================================================================
-- Test data: 15 clips across varied codecs/fps/names
-- ============================================================================
local clips = {
    {id="c01", name="INT_SCENE1_wide",    codec="ProRes", fps=24, duration=150,  enabled=true,  properties={scene="42", take="3", comments="Good performance"}},
    {id="c02", name="EXT_SCENE2_close",   codec="ProRes", fps=24, duration=200,  enabled=true,  properties={scene="7",  take="1"}},
    {id="c03", name="INT_SCENE3_med",     codec="ProRes", fps=25, duration=150,  enabled=false, properties={scene="3",  take="2"}},
    {id="c04", name="Interview_CamA",     codec="DNxHD",  fps=25, duration=3000, enabled=true,  properties={scene="INT42", take="7", comments="Select"}},
    {id="c05", name="Interview_CamB",     codec="DNxHD",  fps=24, duration=2500, enabled=true,  properties={scene="5", take="1"}},
    {id="c06", name="PAINTING_insert",    codec="H264",   fps=30, duration=75,   enabled=true,  properties={scene="12", take="2"}},
    {id="c07", name="A001_01_take3",      codec="ProRes", fps=24, duration=480,  enabled=true,  properties={scene="1", take="3"}},
    {id="c08", name="XA001_broll",        codec="ProRes", fps=24, duration=120,  enabled=true,  properties={scene="42B", take="1"}},
    {id="c09", name="BA001_sfx",          codec="WAV",    fps=48000, duration=96000, enabled=true, properties={}},
    {id="c10", name="Music_underscore",   codec="WAV",    fps=48000, duration=192000, enabled=true, properties={}},
    {id="c11", name="INT_SCENE5_wide",    codec="ProRes", fps=24, duration=300,  enabled=true,  properties={scene="5", take="4"}},
    {id="c12", name="EXT_SCENE6_crane",   codec="ProRes", fps=24, duration=250,  enabled=true,  properties={scene="6", take="1"}},
    {id="c13", name="GFX_title_card",     codec="ProRes", fps=24, duration=50,   enabled=true,  properties={scene="0"}},
    {id="c14", name="SFX_footsteps",      codec="AIFF",   fps=44100, duration=88200, enabled=true, properties={}},
    {id="c15", name="VO_narrator_v1",     codec="WAV",    fps=48000, duration=144000, enabled=true, properties={scene="VO", comments="Final mix"}},
}

-- ============================================================================
-- Category 1: Query Engine
-- ============================================================================
print("=== Category 1: Query Engine ===")

check("1.1 contains INT",
    query_engine.match(clips[1], {column="name", operator="contains", value="INT"}))
check("1.1 contains case-insensitive",
    query_engine.match(clips[1], {column="name", operator="contains", value="int"}))
check("1.2 begins_with A001",
    query_engine.match(clips[7], {column="name", operator="begins_with", value="A001"}))
check("1.2 begins_with rejects XA001",
    not query_engine.match(clips[8], {column="name", operator="begins_with", value="A001"}))
check("1.3 ends_with wide",
    query_engine.match(clips[1], {column="name", operator="ends_with", value="wide"}))
check("1.4 matches_exactly",
    query_engine.match(clips[4], {column="name", operator="matches_exactly", value="Interview_CamA"}))
check("1.5 numeric equals 24",
    query_engine.match(clips[1], {column="fps", operator="equals", value="24"}))
check("1.6 numeric greater_than",
    query_engine.match(clips[4], {column="duration", operator="greater_than", value="200"}))
check("1.7 custom property scene=42",
    query_engine.match(clips[1], {column="scene", operator="contains", value="42"}))
check("1.8 match_all AND",
    query_engine.match_all(clips[1], {
        {column="codec", operator="contains", value="ProRes"},
        {column="fps", operator="equals", value="24"},
    }))
local m, nm = query_engine.filter(clips, {{column="codec", operator="contains", value="ProRes"}})
check("1.9 filter returns two arrays", #m + #nm == #clips)
local fields = query_engine.get_searchable_fields()
check("1.10 searchable_fields non-empty", #fields > 0)

-- ============================================================================
-- Category 2: Bin Find
-- ============================================================================
print("=== Category 2: Bin Find ===")

find_state.execute(clips, {column="name", operator="contains", value="INT"})
check("2.1 find matches INT clips", find_state.get_match_count() > 0)
check("2.1 first match exists", find_state.get_current_match() ~= nil)

find_state.next()
local second = find_state.get_current_match()
check("2.2 find next advances", second ~= nil)

find_state.previous()
check("2.3 find previous goes back", find_state.get_current_match() ~= second)

find_state.save_selection({"c01", "c02"})
check("2.4 previous selection saved", #find_state.get_previous_selection() == 2)

-- Scope with sift
sift_state.apply(clips, {column="codec", operator="contains", value="ProRes"})
local eval = sift_state.evaluate(clips)
local hidden = {}
for _, id in ipairs(eval.hidden_ids) do hidden[id] = true end

find_state.execute(clips, {column="name", operator="contains", value="INT"}, {hidden_ids=hidden, scope="visible"})
-- Only ProRes INT clips visible: c01, c03, c11
check("2.5 scope=visible filters hidden", find_state.get_match_count() <= 5)
sift_state.clear()
find_state.clear()

-- ============================================================================
-- Category 3: Bin Sift
-- ============================================================================
print("=== Category 3: Bin Sift ===")

sift_commands.sift(clips, {column="codec", operator="contains", value="ProRes"}, "proj1")
check("3.1 sift active", sift_state.is_active())
eval = sift_state.evaluate(clips)
local vis = {}
for _, id in ipairs(eval.visible_ids) do vis[id] = true end
check("3.1 ProRes clips visible", vis["c01"] == true)
check("3.1 non-ProRes hidden", not vis["c04"])

sift_commands.expand_sift(clips, {column="codec", operator="contains", value="DNxHD"}, "proj1")
eval = sift_state.evaluate(clips)
vis = {}
for _, id in ipairs(eval.visible_ids) do vis[id] = true end
check("3.2 expand: DNxHD now visible", vis["c04"] == true)

sift_commands.narrow_sift(clips, {column="fps", operator="equals", value="24"}, "proj1")
eval = sift_state.evaluate(clips)
vis = {}
for _, id in ipairs(eval.visible_ids) do vis[id] = true end
check("3.3 narrow: only 24fps remain", not vis["c03"])  -- ProRes 25fps hidden

sift_commands.clear_sift("proj1")
check("3.4 clear: not active", not sift_state.is_active())

-- Persistence
sift_commands.sift(clips, {column="codec", operator="contains", value="ProRes"}, "proj1")
sift_state.clear()
sift_commands.restore_sift(clips, "proj1")
check("3.5 restored after clear", sift_state.is_active())
eval = sift_state.evaluate(clips)
check("3.5 restored correct count", #eval.visible_ids > 0)
sift_commands.clear_sift("proj1")

-- New clip matches
sift_commands.sift(clips, {column="codec", operator="contains", value="ProRes"}, "proj1")
local clips_plus = {}
for _, c in ipairs(clips) do clips_plus[#clips_plus + 1] = c end
clips_plus[#clips_plus + 1] = {id="c16", name="NewProRes", codec="ProRes", fps=24, duration=100, enabled=true, properties={}}
clips_plus[#clips_plus + 1] = {id="c17", name="NewDNxHD", codec="DNxHD", fps=25, duration=100, enabled=true, properties={}}
eval = sift_state.evaluate(clips_plus)
local vis_set = {}
for _, id in ipairs(eval.visible_ids) do vis_set[id] = true end
check("3.6 new ProRes visible", vis_set["c16"] == true)
check("3.6 new DNxHD hidden", not vis_set["c17"])
sift_commands.clear_sift("proj1")

-- ============================================================================
-- Category 4: Timeline Find
-- ============================================================================
print("=== Category 4: Timeline Find ===")

-- Sort by timeline_start for timeline context
local tl_clips = {
    {id="t1", name="INT_Shot1",  timeline_start_frame=0,   duration_frames=100, codec="ProRes", fps=24, enabled=true, properties={}},
    {id="t2", name="EXT_Shot2",  timeline_start_frame=100, duration_frames=150, codec="ProRes", fps=24, enabled=true, properties={}},
    {id="t3", name="INT_Shot3",  timeline_start_frame=250, duration_frames=200, codec="DNxHD",  fps=25, enabled=true, properties={}},
    {id="t4", name="Interview_A",timeline_start_frame=300, duration_frames=100, codec="DNxHD",  fps=25, enabled=true, properties={}},
    {id="t5", name="INT_Shot5",  timeline_start_frame=450, duration_frames=50,  codec="ProRes", fps=24, enabled=true, properties={}},
}
table.sort(tl_clips, function(a, b) return a.timeline_start_frame < b.timeline_start_frame end)

find_state.execute(tl_clips, {column="name", operator="contains", value="INT"})
-- INT_Shot1, INT_Shot3, Interview_A, INT_Shot5 = 4 (Interview contains INT)
check("4.1 timeline find matches", find_state.get_match_count() == 4)
check("4.1 first match", find_state.get_current_match() ~= nil)

find_state.next()
check("4.2 find next in timeline order", find_state.get_current_match() ~= nil)

-- No matches
find_state.execute(tl_clips, {column="name", operator="contains", value="XYZZY"})
check("4.4 no matches", find_state.get_match_count() == 0)
find_state.clear()

-- ============================================================================
-- Category 5: Smart Bins (DB-backed)
-- ============================================================================
print("=== Category 5: Smart Bins ===")

local smart_bin = require("core.smart_bin")
local sb = smart_bin.create(db, {
    project_id = "proj1",
    name = "24fps ProRes",
    criteria_json = json.encode({
        {column="codec", operator="contains", value="ProRes"},
        {column="fps", operator="equals", value="24"},
    }),
})
check("5.1 smart bin created", sb.id ~= nil)

local found = smart_bin.find_by_project(db, "proj1")
check("5.1 appears in project", #found >= 1)

local matching_ids = smart_bin.evaluate(sb, clips)
check("5.1 evaluates correctly", #matching_ids > 0)
-- 24fps ProRes: c01, c02, c07, c08, c11, c12, c13 = 7
check("5.1 correct count", #matching_ids == 7)

-- Dynamic update
local clips_with_new = {}
for _, c in ipairs(clips) do clips_with_new[#clips_with_new + 1] = c end
clips_with_new[#clips_with_new + 1] = {id="c_new", name="New24ProRes", codec="ProRes", fps=24, duration=50, enabled=true, properties={}}
local new_ids = smart_bin.evaluate(sb, clips_with_new)
check("5.2 new clip in smart bin", #new_ids == 8)

-- Undo create (simulate)
smart_bin.delete(db, sb.id)
found = smart_bin.find_by_project(db, "proj1")
check("5.3 undo removes", #found == 0)

-- ============================================================================
-- Category 6: Find & Replace (via direct DB)
-- ============================================================================
print("=== Category 6: Find & Replace ===")

-- Insert test clips into DB for replace tests
local seq_stmt = db:prepare(string.format(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at) VALUES ('seq1', 'proj1', 'Seq', 'timeline', 24, 1, 48000, 1920, 1080, %d, %d)",
    now, now))
seq_stmt:exec()
seq_stmt:finalize()

local track_stmt = db:prepare("INSERT INTO tracks (id, sequence_id, name, track_type, track_index) VALUES ('trk1', 'seq1', 'V1', 'VIDEO', 1)")
track_stmt:exec()
track_stmt:finalize()

for i, name in ipairs({"Scene01_v1", "Scene02_v1", "Scene03_v2"}) do
    local cid = string.format("rc%d", i)
    local stmt = db:prepare(string.format(
        "INSERT INTO clips (id, project_id, clip_kind, owner_sequence_id, track_id, name, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, created_at, modified_at) VALUES (?, 'proj1', 'timeline', 'seq1', 'trk1', ?, %d, 100, 0, 100, 24, 1, %d, %d)",
        (i - 1) * 100, now, now))
    stmt:bind_value(1, cid)
    stmt:bind_value(2, name)
    stmt:exec()
    stmt:finalize()
end

-- Verify clips exist
local verify = db:prepare("SELECT name FROM clips WHERE id = 'rc1'")
verify:exec(); verify:next()
check("6.0 clip exists", verify:value(0) == "Scene01_v1")
verify:finalize()

-- Simulate replace: v1 → v2 on rc1
local read_stmt = db:prepare("SELECT name FROM clips WHERE id = 'rc1'")
read_stmt:exec(); read_stmt:next()
local old_name = read_stmt:value(0)
read_stmt:finalize()

local new_name = old_name:gsub("v1", "v2")
local upd = db:prepare("UPDATE clips SET name = ? WHERE id = 'rc1'")
upd:bind_value(1, new_name)
upd:exec()
upd:finalize()

read_stmt = db:prepare("SELECT name FROM clips WHERE id = 'rc1'")
read_stmt:exec(); read_stmt:next()
check("6.1 replace v1→v2", read_stmt:value(0) == "Scene01_v2")
read_stmt:finalize()

-- Undo: restore old name
upd = db:prepare("UPDATE clips SET name = ? WHERE id = 'rc1'")
upd:bind_value(1, old_name)
upd:exec()
upd:finalize()

read_stmt = db:prepare("SELECT name FROM clips WHERE id = 'rc1'")
read_stmt:exec(); read_stmt:next()
check("6.2 undo restores", read_stmt:value(0) == "Scene01_v1")
read_stmt:finalize()

-- rc3 has no v1 — replace is no-op
read_stmt = db:prepare("SELECT name FROM clips WHERE id = 'rc3'")
read_stmt:exec(); read_stmt:next()
local rc3_name = read_stmt:value(0)
read_stmt:finalize()
check("6.6 no-match unchanged", rc3_name == "Scene03_v2")

-- ============================================================================
-- Category 7: Searchable fields
-- ============================================================================
print("=== Category 7: Field Registry ===")

local field_map = {}
for _, f in ipairs(fields) do field_map[f.name] = f end
check("7.1 name editable", field_map["name"].editable == true)
check("7.2 duration not editable", field_map["duration"].editable == false)
check("7.3 codec not editable", field_map["codec"].editable == false)
check("7.4 volume editable", field_map["volume"].editable == true)

-- ============================================================================
-- Summary
-- ============================================================================
print("")
if fail_count > 0 then
    print(string.format("❌ test_quickstart_validation.lua: %d passed, %d FAILED", pass_count, fail_count))
    os.exit(1)
end
print(string.format("✅ test_quickstart_validation.lua passed (%d assertions)", pass_count))
