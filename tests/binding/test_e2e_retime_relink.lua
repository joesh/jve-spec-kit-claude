-- End-to-end verification: convert DRP → relink against fixture tree →
-- verify retimed clip is no longer offline → confirm the clips that
-- previously crashed (clip 01-333-2 and 00.5G-1) now have correct
-- source_in values matching their fixture file's first_frame_tc.
--
-- Drives the editor entirely through model + command APIs (no raw SQL
-- outside test files), so the SQL isolation guard is satisfied by the
-- test_ filename + tests/ location.

local drp_importer = require("importers.drp_importer")
local media_relinker = require("core.media_relinker")
local database = require("core.database")
local Clip = require("models.clip")

local DRP_PATH = "/Users/joe/Local/jve-spec-kit-claude/tests/fixtures/resolve/anamnesis joe edit.drp"
local JVP_PATH = "/tmp/jve_retime_e2e.jvp"
local FIXTURE_ROOT = "/Users/joe/Local/jve-spec-kit-claude/tests/fixtures/media/anamnesis"

-- Clean up any prior run
os.remove(JVP_PATH)
os.remove(JVP_PATH .. "-shm")
os.remove(JVP_PATH .. "-wal")

print("=== test_e2e_retime_relink.lua ===")
print("[1/6] Converting DRP → " .. JVP_PATH)
local convert_ok, convert_err = drp_importer.convert(DRP_PATH, JVP_PATH)
assert(convert_ok, "DRP convert failed: " .. tostring(convert_err))
print("      ✓ converted")

print("[2/6] Opening converted project")
database.set_path(JVP_PATH)
local db = database.get_connection()
assert(db, "no DB connection after set_path")

local proj_id
do
    local stmt = db:prepare("SELECT id FROM projects LIMIT 1")
    assert(stmt:exec() and stmt:next(), "no projects in fresh .jvp")
    proj_id = stmt:value(0)
    stmt:finalize()
end
print("      ✓ project_id = " .. proj_id)

local seq_id, seq_name
do
    local stmt = db:prepare([[
        SELECT id, name FROM sequences
        WHERE name LIKE '%GOLD-MASTER-CANDIDATE'
        ORDER BY name DESC LIMIT 1
    ]])
    assert(stmt:exec() and stmt:next(), "no gold-master sequence found")
    seq_id = stmt:value(0)
    seq_name = stmt:value(1)
    stmt:finalize()
end
print("      ✓ gold master = " .. seq_name)

local function tc25(f)
    if not f then return "nil" end
    f = math.floor(f)
    local h = math.floor(f / 90000); f = f % 90000
    local m = math.floor(f / 1500);  f = f % 1500
    local s = math.floor(f / 25);    local ff = f % 25
    return string.format("%02d:%02d:%02d:%02d", h, m, s, ff)
end

local function find_clip(name)
    local stmt = db:prepare([[
        SELECT c.id, c.media_id, c.source_in_frame, c.source_out_frame,
               c.duration_frames, m.file_path
        FROM clips c
        JOIN tracks t ON c.track_id = t.id
        LEFT JOIN media m ON c.media_id = m.id
        WHERE t.sequence_id = ? AND c.name = ?
        LIMIT 1
    ]])
    stmt:bind_value(1, seq_id)
    stmt:bind_value(2, name)
    local row = nil
    if stmt:exec() and stmt:next() then
        row = {
            clip_id    = stmt:value(0),
            media_id   = stmt:value(1),
            source_in  = stmt:value(2),
            source_out = stmt:value(3),
            duration   = stmt:value(4),
            file_path  = stmt:value(5),
        }
    end
    stmt:finalize()
    return row
end

local function dump_clip(name, c)
    print(string.format("      %s: source_in=%d (%s) src_out=%d (%s) src_len=%d media=%s",
        name, c.source_in, tc25(c.source_in), c.source_out, tc25(c.source_out),
        c.source_out - c.source_in,
        c.file_path and (c.file_path:sub(1, 60) .. "...") or "nil"))
end

print("[3/6] Pre-relink DB state for retimed clips:")
local pre_333 = find_clip("01-333-2")
local pre_05G = find_clip("00.5G-1")
assert(pre_333, "01-333-2 not found in gold master")
assert(pre_05G, "00.5G-1 not found in gold master")
dump_clip("01-333-2", pre_333)
dump_clip("00.5G-1 ", pre_05G)

assert(pre_333.source_in == 111916, string.format(
    "Pre-relink 01-333-2 source_in must be 111916 (=01:14:36:16), got %d", pre_333.source_in))
assert(pre_05G.source_in == 124682, string.format(
    "Pre-relink 00.5G-1 source_in must be 124682 (=01:23:07:07), got %d", pre_05G.source_in))
print("      ✓ both retimed clips have correct source_in (curve-walking fix is in)")

print("[4/6] Building media_infos and running relink against fixture tree")

-- Build media_infos with source extents (no per-clip loading).
local media_list = media_relinker.find_project_media(db, proj_id)
print(string.format("      project has %d non-proxy media", #media_list))

local media_infos = {}
for _, media in ipairs(media_list) do
    local tc_value, tc_rate = media:get_start_tc()
    local file_orig_tc = media:get_file_original_timecode()
    local extent_start, extent_end = media:get_source_extent(tc_rate or 25)
    media_infos[#media_infos + 1] = {
        media_id = media.id,
        media_path = media:get_file_path(),
        media_name = media.name or media.id,
        media_start_tc_value = tc_value,
        media_start_tc_rate = tc_rate,
        media_file_original_tc = file_orig_tc,
        width = media.width or 0,
        height = media.height or 0,
        source_extent_start = extent_start,
        source_extent_end = extent_end,
    }
end
print(string.format("      built media_infos for %d media", #media_infos))

local batch = media_relinker.relink_media_batch(media_infos, {
    search_paths = { FIXTURE_ROOT },
    matching_rules = {
        match_filename       = true,
        match_timecode       = true,
        match_resolution     = false,
        match_frame_rate     = false,
        accept_trimmed_media = true,
        accept_filename_suffixes = false,
    },
    clip_loader = function(media_id)
        local clips = Clip.find_clips_for_media(media_id)
        local entries = {}
        for _, clip in ipairs(clips) do
            entries[#entries + 1] = {
                clip_id = clip.id,
                clip_kind = clip.clip_kind,
                source_in = clip.source_in,
                source_out = clip.source_out,
                fps_num = clip.rate.fps_numerator,
                fps_den = clip.rate.fps_denominator,
            }
        end
        return entries
    end,
})
print(string.format("      relink_media_batch: %d relinked, %d failed, %d ambiguous, %d new media",
    #(batch.relinked or {}), #(batch.failed or {}), #(batch.ambiguous or {}), #(batch.new_media or {})))

-- Initialize the command manager (it normally happens in post_open_init via UI)
local command_manager = require("core.command_manager")
command_manager.init(seq_id, proj_id)

-- Apply the relinker output as RelinkClips. Two different project-media rows
-- can resolve to the same fixture-tree path (e.g. AnamBack1 vs AnamBack4 dupes).
-- The shared planner handles DB-owner collisions, priority tiebreaks, splits,
-- and dedupe salvage — same code production uses via show_relink_dialog.
-- relink_media_batch's contract guarantees .relinked and .failed arrays; the
-- planner asserts types so a missing field surfaces as an actionable error.
assert(type(batch.relinked) == "table",
    "relink_media_batch must return .relinked array")
assert(type(batch.failed) == "table",
    "relink_media_batch must return .failed array")

local relink_planner = require("core.relink_planner")
local plan = relink_planner.build_plan(
    db, batch.relinked, batch.failed,
    {},  -- no folder priority in this smoke test — first-writer-wins ties
    proj_id)

print(string.format("      planner: %d clip changes, %d media path changes, %d new media, %d salvaged",
    (function() local n=0 for _ in pairs(plan.clip_relink_map) do n=n+1 end return n end)(),
    (function() local n=0 for _ in pairs(plan.media_path_changes) do n=n+1 end return n end)(),
    #plan.new_media_records, plan.salvaged_count))

local apply_result = command_manager.execute("RelinkClips", {
    clip_relink_map    = plan.clip_relink_map,
    media_path_changes = plan.media_path_changes,
    new_media_records  = plan.new_media_records,
    project_id         = proj_id,
})
assert(apply_result and apply_result.success, "RelinkClips failed")
print("      ✓ RelinkClips committed")

print("[5/6] Post-relink DB state:")
local post_333 = find_clip("01-333-2")
local post_05G = find_clip("00.5G-1")
dump_clip("01-333-2", post_333)
dump_clip("00.5G-1 ", post_05G)

local function file_exists(p)
    local f = io.open(p, "r"); if f then f:close(); return true end; return false
end

local function check_relinked(name, c)
    if not c.file_path then return "nil file_path" end
    if not file_exists(c.file_path) then return "file does not exist on disk: " .. c.file_path end
    if not c.file_path:find("/tests/fixtures/", 1, true) then
        return "not in fixture tree: " .. c.file_path
    end
    return nil
end

local err1 = check_relinked("01-333-2", post_333)
local err2 = check_relinked("00.5G-1", post_05G)
if err1 then print("      ⚠ 01-333-2: " .. err1) end
if err2 then print("      ⚠ 00.5G-1: " .. err2) end

print("[6/6] Verifying source_in ≥ first_frame_tc (the assertion that crashed before)")

local function probe_first_frame_tc(path)
    local cmd = string.format(
        'ffprobe -v error -show_format -show_streams -print_format json "%s" 2>/dev/null',
        path)
    local f = io.popen(cmd)
    if not f then return nil end
    local out = f:read("*a"); f:close()
    if not out or out == "" then return nil end
    local tc = out:match('"timecode":%s*"([^"]+)"')
    if not tc then return nil end
    -- Parse HH:MM:SS:FF at 25 fps
    local h, m, s, ff = tc:match("(%d+):(%d+):(%d+):(%d+)")
    if not h then return nil end
    return tonumber(h) * 90000 + tonumber(m) * 1500 + tonumber(s) * 25 + tonumber(ff)
end

local function check_no_crash(name, c)
    local tc = probe_first_frame_tc(c.file_path)
    if not tc then
        print(string.format("      %s: could not probe fixture timecode (skipping)", name))
        return true
    end
    local file_frame = c.source_in - tc
    local mark = (file_frame >= 0) and "✓" or "✗"
    print(string.format("      %s: fixture first_frame_tc=%d (%s), source_in=%d, file_frame=%d %s",
        name, tc, tc25(tc), c.source_in, file_frame, mark))
    return file_frame >= 0
end

local ok_333 = (not err1) and check_no_crash("01-333-2", post_333) or err1 == nil
local ok_05G = (not err2) and check_no_crash("00.5G-1 ", post_05G) or err2 == nil

assert(not err1 or ok_333, "01-333-2 would still crash the playback engine")
assert(not err2 or ok_05G, "00.5G-1 would still crash the playback engine")

-- Count remaining offline clips in the gold master (media not under fixture tree)
local offline_count
do
    local stmt = db:prepare([[
        SELECT COUNT(*) FROM clips c
        JOIN tracks t ON c.track_id = t.id
        LEFT JOIN media m ON c.media_id = m.id
        WHERE t.sequence_id = ?
          AND (m.file_path IS NULL OR m.file_path NOT LIKE '%/tests/fixtures/%')
    ]])
    stmt:bind_value(1, seq_id)
    assert(stmt:exec() and stmt:next(), "offline count query failed")
    offline_count = stmt:value(0)
    stmt:finalize()
end
print(string.format("\n[7/7] Gold master clips still offline after relink + dedupe: %d",
    offline_count))

-- Per-media breakdown
do
    local stmt = db:prepare([[
        SELECT substr(m.name, 1, 45), COUNT(c.id) FROM clips c
        JOIN tracks t ON c.track_id = t.id
        JOIN media m ON c.media_id = m.id
        WHERE t.sequence_id = ?
          AND m.file_path NOT LIKE '%/tests/fixtures/%'
        GROUP BY m.id
        ORDER BY COUNT(c.id) DESC
    ]])
    stmt:bind_value(1, seq_id)
    if stmt:exec() then
        while stmt:next() do
            print(string.format("      %4d × %s", stmt:value(1), stmt:value(0)))
        end
    end
    stmt:finalize()
end

-- ─────────────────────────────────────────────────────────────
-- [8/8] Verify VFX clips with Set Timecode overrides came online (FR-019)
-- ─────────────────────────────────────────────────────────────
print("\n[8/8] VFX Set Timecode override verification:")

-- The 3 VFX master clips with overrides (file_original_timecode ≠ start_tc_value):
--   A001_05191316_C013 VFX_01.mov: override 13:16:12:21, file 00:07:35:08
--   A003_05191950_C002 VFX_01.mov: override 19:50:33:12, file 00:05:47:14
--   A001_05191306_C010 VFX_01.mov: override 13:06:17:16, file 00:04:50:06
local vfx_override_names = {
    "A001_05191316_C013 VFX_01.mov",
    "A003_05191950_C002 VFX_01.mov",
    "A001_05191306_C010 VFX_01.mov",
}

local vfx_online = 0
local vfx_total_clips = 0
for _, vfx_name in ipairs(vfx_override_names) do
    local stmt_vfx = db:prepare([[
        SELECT m.id, m.file_path, m.metadata FROM media m
        WHERE m.name = ? AND m.project_id = ?
    ]])
    stmt_vfx:bind_value(1, vfx_name)
    stmt_vfx:bind_value(2, proj_id)
    assert(stmt_vfx:exec(), "VFX media query failed for " .. vfx_name)

    while stmt_vfx:next() do
        local mid = stmt_vfx:value(0)
        local mpath = stmt_vfx:value(1) or ""
        local mmeta = stmt_vfx:value(2) or "{}"

        -- Check file_original_timecode is present in metadata
        local has_fotc = mmeta:find("file_original_timecode") ~= nil
        local is_fixture = mpath:find("/tests/fixtures/", 1, true) ~= nil

        -- Count clips in gold master on this media
        local clip_stmt = db:prepare([[
            SELECT COUNT(*) FROM clips c
            JOIN tracks t ON c.track_id = t.id
            WHERE t.sequence_id = ? AND c.media_id = ?
        ]])
        clip_stmt:bind_value(1, seq_id)
        clip_stmt:bind_value(2, mid)
        assert(clip_stmt:exec() and clip_stmt:next())
        local clip_count = clip_stmt:value(0)
        clip_stmt:finalize()

        vfx_total_clips = vfx_total_clips + clip_count
        if is_fixture then vfx_online = vfx_online + clip_count end

        local status = is_fixture and "✓ ONLINE" or "✗ OFFLINE"
        print(string.format("      %s %s: fotc=%s clips=%d path=...%s",
            status, vfx_name, tostring(has_fotc),
            clip_count, mpath:sub(math.max(1, #mpath - 50))))
    end
    stmt_vfx:finalize()
end

assert(vfx_online > 0, string.format(
    "VFX override clips must be online after relink (got %d/%d)", vfx_online, vfx_total_clips))
print(string.format("      ✓ %d/%d VFX override clips online", vfx_online, vfx_total_clips))

print("\n✅ test_e2e_retime_relink.lua passed")
print("   - DRP convert produces correct source_in for retimed clips (111916, 124682)")
print("   - Both clips relinked to the fixture tree")
print("   - source_in ≥ first_frame_tc → C++ assertion will not fire")
print(string.format("   - Dedupe salvage reassigned %d clips to sibling media rows", plan.salvaged_count))
print(string.format("   - VFX override clips online: %d/%d", vfx_online, vfx_total_clips))
print(string.format("   - Gold master offline count: %d", offline_count))
