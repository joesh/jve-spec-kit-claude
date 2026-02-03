require("test_env")

local database = require("core.database")
local ClipLink = require("models.clip_link")

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

local function expect_error(label, fn)
    local ok, err = pcall(fn)
    if not ok then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL (expected error): " .. label)
    end
    return err
end

print("\n=== ClipLink Model Tests ===")

local db_path = "/tmp/jve/test_clip_link_model.db"
os.remove(db_path)

assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

-- Seed: project + sequence + track + 4 clips
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq', 'timeline', 24000, 1001, 48000,
        1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk_v', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk_a', 'seq1', 'A1', 'AUDIO', 2, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels,
        codec, metadata, created_at, modified_at)
    VALUES ('med1', 'proj1', 'media.mov', '/tmp/media.mov', 1000,
        24000, 1001, 1920, 1080, 2, 'prores', '{}', %d, %d);
]], now, now, now, now, now, now))

-- 4 clips: video pair (v1, a1) and separate pair (v2, a2)
for _, c in ipairs({
    {"clip_v1", "trk_v", 0,   100},
    {"clip_a1", "trk_a", 0,   100},
    {"clip_v2", "trk_v", 100, 50},
    {"clip_a2", "trk_a", 100, 50},
}) do
    db:exec(string.format([[
        INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id,
            timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
            fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
        VALUES ('%s', 'proj1', 'timeline', '%s', '%s', 'med1',
            %d, %d, 0, %d, 24000, 1001, 1, 0, %d, %d);
    ]], c[1], c[1], c[2], c[3], c[4], c[4], now, now))
end

-- Helper: count rows in clip_links
local function count_links(filter_col, filter_val)
    local sql
    if filter_col then
        sql = string.format("SELECT count(*) FROM clip_links WHERE %s = ?", filter_col)
    else
        sql = "SELECT count(*) FROM clip_links"
    end
    local stmt = db:prepare(sql)
    assert(stmt)
    if filter_val then stmt:bind_value(1, filter_val) end
    assert(stmt:exec())
    stmt:next()
    local n = stmt:value(0)
    stmt:finalize()
    return n
end

-- ═══════════════════════════════════════════════════════════════
-- 1. create_link_group
-- ═══════════════════════════════════════════════════════════════

print("\n--- create_link_group: 2-clip video/audio pair ---")
local group1_id
do
    local clips = {
        { clip_id = "clip_v1", role = "video", time_offset = 0 },
        { clip_id = "clip_a1", role = "audio", time_offset = 0 },
    }
    local id, err = ClipLink.create_link_group(clips, db)
    check("returns link_group_id", id ~= nil)
    check("no error", err == nil)
    check("2 rows inserted", count_links("link_group_id", id) == 2)
    group1_id = id
end

print("--- create_link_group: <2 clips returns nil ---")
do
    local id, err = ClipLink.create_link_group({{ clip_id = "clip_v2", role = "video" }}, db)
    check("nil for 1 clip", id == nil)
    check("error message present", err and err:find("2 clips") ~= nil)
end

print("--- create_link_group: nil clips returns nil ---")
do
    local id, err = ClipLink.create_link_group(nil, db)
    check("nil for nil input", id == nil)
end

print("--- create_link_group: empty table returns nil ---")
do
    local id, err = ClipLink.create_link_group({}, db)
    check("nil for empty", id == nil)
end

-- ═══════════════════════════════════════════════════════════════
-- 2. get_link_group
-- ═══════════════════════════════════════════════════════════════

print("\n--- get_link_group: returns all members ---")
do
    local members = ClipLink.get_link_group("clip_v1", db)
    check("returns table", type(members) == "table")
    check("2 members", members and #members == 2)
    -- Ordered by role: audio before video
    if members and #members == 2 then
        check("first member is audio (sorted by role)", members[1].role == "audio")
        check("second member is video", members[2].role == "video")
        check("audio clip_id correct", members[1].clip_id == "clip_a1")
        check("video clip_id correct", members[2].clip_id == "clip_v1")
        check("enabled is boolean true", members[1].enabled == true)
        check("time_offset is 0", members[1].time_offset == 0)
    end
end

print("--- get_link_group: unlinked clip returns nil ---")
do
    local members = ClipLink.get_link_group("clip_v2", db)
    check("unlinked clip returns nil", members == nil)
end

print("--- get_link_group: nonexistent clip returns nil ---")
do
    local members = ClipLink.get_link_group("nonexistent", db)
    check("nonexistent returns nil", members == nil)
end

-- ═══════════════════════════════════════════════════════════════
-- 3. get_link_group_id
-- ═══════════════════════════════════════════════════════════════

print("\n--- get_link_group_id: linked clip ---")
do
    local gid = ClipLink.get_link_group_id("clip_v1", db)
    check("returns group id", gid == group1_id)
end

print("--- get_link_group_id: unlinked clip ---")
do
    local gid = ClipLink.get_link_group_id("clip_v2", db)
    check("unlinked returns nil", gid == nil)
end

-- ═══════════════════════════════════════════════════════════════
-- 4. is_linked
-- ═══════════════════════════════════════════════════════════════

print("\n--- is_linked: true for linked clip ---")
do
    check("clip_v1 is linked", ClipLink.is_linked("clip_v1", db) == true)
    check("clip_a1 is linked", ClipLink.is_linked("clip_a1", db) == true)
end

print("--- is_linked: false for unlinked clip ---")
do
    check("clip_v2 not linked", ClipLink.is_linked("clip_v2", db) == false)
    check("nonexistent not linked", ClipLink.is_linked("nonexistent", db) == false)
end

-- ═══════════════════════════════════════════════════════════════
-- 5. disable_link / enable_link
-- ═══════════════════════════════════════════════════════════════

print("\n--- disable_link: sets enabled=0 ---")
do
    local ok = ClipLink.disable_link("clip_v1", db)
    check("disable returns truthy", ok)

    local members = ClipLink.get_link_group("clip_v1", db)
    local v1_member
    for _, m in ipairs(members or {}) do
        if m.clip_id == "clip_v1" then v1_member = m end
    end
    check("clip_v1 enabled=false after disable", v1_member and v1_member.enabled == false)
    -- Other member unaffected
    local a1_member
    for _, m in ipairs(members or {}) do
        if m.clip_id == "clip_a1" then a1_member = m end
    end
    check("clip_a1 still enabled", a1_member and a1_member.enabled == true)
end

print("--- enable_link: sets enabled=1 ---")
do
    local ok = ClipLink.enable_link("clip_v1", db)
    check("enable returns truthy", ok)

    local members = ClipLink.get_link_group("clip_v1", db)
    local v1_member
    for _, m in ipairs(members or {}) do
        if m.clip_id == "clip_v1" then v1_member = m end
    end
    check("clip_v1 enabled=true after re-enable", v1_member and v1_member.enabled == true)
end

print("--- disable_link: unlinked clip is no-op ---")
do
    local ok = ClipLink.disable_link("clip_v2", db)
    -- SQLite UPDATE on 0 rows still succeeds
    check("disable unlinked returns truthy", ok)
end

-- ═══════════════════════════════════════════════════════════════
-- 6. unlink_clip — auto-dissolve when <=1 member
-- ═══════════════════════════════════════════════════════════════

print("\n--- unlink_clip: removing from 2-member group dissolves group ---")
do
    -- group1 has clip_v1 + clip_a1
    local ok = ClipLink.unlink_clip("clip_v1", db)
    check("unlink returns true", ok == true)
    check("clip_v1 no longer linked", ClipLink.is_linked("clip_v1", db) == false)
    -- With only 1 member left, group should auto-dissolve
    check("clip_a1 also unlinked (group dissolved)", ClipLink.is_linked("clip_a1", db) == false)
    check("no rows remain for group1", count_links("link_group_id", group1_id) == 0)
end

print("--- unlink_clip: already-unlinked clip is no-op ---")
do
    local ok = ClipLink.unlink_clip("clip_v1", db)
    check("unlink already-unlinked returns true", ok == true)
end

-- ═══════════════════════════════════════════════════════════════
-- 7. unlink_clip with 3-member group (doesn't dissolve)
-- ═══════════════════════════════════════════════════════════════

print("\n--- unlink_clip: 3-member group keeps 2 after unlink ---")
local group2_id
do
    -- Create a 3-clip group
    local clips = {
        { clip_id = "clip_v1", role = "video" },
        { clip_id = "clip_a1", role = "audio" },
        { clip_id = "clip_v2", role = "video" },
    }
    group2_id = ClipLink.create_link_group(clips, db)
    check("3-member group created", group2_id ~= nil)

    local ok = ClipLink.unlink_clip("clip_v2", db)
    check("unlink returns true", ok == true)
    check("clip_v2 unlinked", ClipLink.is_linked("clip_v2", db) == false)
    -- 2 members remain — group survives
    check("clip_v1 still linked", ClipLink.is_linked("clip_v1", db) == true)
    check("clip_a1 still linked", ClipLink.is_linked("clip_a1", db) == true)
    check("2 rows remain", count_links("link_group_id", group2_id) == 2)
end

-- Clean up for link_two_clips tests
ClipLink.unlink_clip("clip_v1", db)

-- ═══════════════════════════════════════════════════════════════
-- 8. link_two_clips — convenience wrapper
-- ═══════════════════════════════════════════════════════════════

print("\n--- link_two_clips: creates new group ---")
local link2_gid
do
    local gid = ClipLink.link_two_clips(
        { id = "clip_v1", role = "video" },
        { id = "clip_a1", role = "audio" }
    )
    check("link_two_clips returns group id", gid ~= nil)
    check("both clips linked", ClipLink.is_linked("clip_v1", db) and ClipLink.is_linked("clip_a1", db))
    link2_gid = gid
end

print("--- link_two_clips: adds to existing group ---")
do
    local gid = ClipLink.link_two_clips(
        { id = "clip_v1", role = "video" },
        { id = "clip_v2", role = "video" }
    )
    check("returns same group id", gid == link2_gid)
    check("3 members now", count_links("link_group_id", link2_gid) == 3)
end

print("--- link_two_clips: accepts clip_id field ---")
do
    -- Fully clean up all clips from prior section (3-member group)
    ClipLink.unlink_clip("clip_v1", db)
    ClipLink.unlink_clip("clip_a1", db)
    ClipLink.unlink_clip("clip_v2", db)
    local gid = ClipLink.link_two_clips(
        { clip_id = "clip_v1", role = "video" },
        { clip_id = "clip_a1", role = "audio" }
    )
    check("clip_id field accepted", gid ~= nil)
    ClipLink.unlink_clip("clip_v1", db)
end

print("--- link_two_clips: error paths ---")
do
    expect_error("nil left clip asserts", function()
        ClipLink.link_two_clips(nil, { id = "clip_a1" })
    end)

    expect_error("nil right clip asserts", function()
        ClipLink.link_two_clips({ id = "clip_v1" }, nil)
    end)

    expect_error("missing id in left asserts", function()
        ClipLink.link_two_clips({ role = "video" }, { id = "clip_a1" })
    end)
end

print("--- link_two_clips: right clip already in different group asserts ---")
do
    -- Ensure all clips are unlinked before creating two separate groups
    ClipLink.unlink_clip("clip_v1", db)
    ClipLink.unlink_clip("clip_a1", db)
    ClipLink.unlink_clip("clip_v2", db)
    ClipLink.unlink_clip("clip_a2", db)

    ClipLink.create_link_group({
        { clip_id = "clip_v1", role = "video" },
        { clip_id = "clip_a1", role = "audio" },
    }, db)
    ClipLink.create_link_group({
        { clip_id = "clip_v2", role = "video" },
        { clip_id = "clip_a2", role = "audio" },
    }, db)

    expect_error("cross-group link asserts", function()
        ClipLink.link_two_clips(
            { id = "clip_v1", role = "video" },
            { id = "clip_a2", role = "audio" }
        )
    end)

    -- Cleanup
    ClipLink.unlink_clip("clip_v1", db)
    ClipLink.unlink_clip("clip_v2", db)
end

-- ═══════════════════════════════════════════════════════════════
-- 9. calculate_anchor_time — returns MIN(timeline_start_frame) across linked clips
-- ═══════════════════════════════════════════════════════════════

print("\n--- calculate_anchor_time: queries MIN start across linked clips ---")
do
    -- Create a fresh group
    local gid = ClipLink.create_link_group({
        { clip_id = "clip_v1", role = "video" },   -- timeline_start_frame = 0
        { clip_id = "clip_v2", role = "video" },   -- timeline_start_frame = 100
    }, db)

    local anchor = ClipLink.calculate_anchor_time(gid, db)
    -- MIN(0, 100) = 0
    check("calculate_anchor_time returns min start frame", anchor == 0)

    ClipLink.unlink_clip("clip_v1", db)
end

-- ═══════════════════════════════════════════════════════════════
-- Summary
-- ═══════════════════════════════════════════════════════════════

print(string.format("\n%d passed, %d failed", pass_count, fail_count))

if fail_count > 0 then
    os.exit(1)
else
    print("✅ test_clip_link_model.lua passed")
end
