-- Regression: FCP7 XML importer must create clip_links rows connecting V and
-- A clips when the source XML declares them linked via <link><linkclipref>.
--
-- Domain behavior (per FCP7 XMEML format):
--   Every <clipitem> that is part of a V+A linked pair contains one <link>
--   block per sibling in the group. Each <link> holds a <linkclipref> whose
--   text is the id attribute of the linked <clipitem>. The entire group is
--   symmetric: V references A and A references V.
--
--   After import, V and A clips that share a link group in the source XML
--   must appear in the same clip_links group in the JVE database.
--
--   An unlinked <clipitem> (no <link> children) must NOT have a clip_links row.

require("test_env")

local database  = require("core.database")
local fcp7      = require("importers.fcp7_xml_importer")

print("=== test_fcp7_linked_item_sync.lua ===")

local TEST_DB = "/tmp/jve/test_fcp7_linked_item_sync.db"
os.remove(TEST_DB)
database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))

db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'Test', 'resample', 0, 0);
]])
db:exec([[INSERT OR IGNORE INTO tag_namespaces(id, display_name) VALUES('bin', 'Bins');]])

-- ─────────────────────────────────────────────────────────────────────
-- Synthetic parsed_result with two linked clips (V+A) and one unlinked
-- video clip, all in a single sequence.
--
-- FCP7 link canonical key = sorted minimum of all <linkclipref> IDs in the
-- link block. Here: V clip "vid-1" links to ["vid-1", "aud-1"]; canonical
-- min = "aud-1". A clip "aud-1" links to ["aud-1", "vid-1"]; same min.
-- Unlinked clip "vid-2" has no <link> children → linked_item_sync = nil.
-- ─────────────────────────────────────────────────────────────────────
-- TC metadata (start_tc_value=0 frames, start_tc_rate=25fps, audio at 48kHz).
-- Pre-set so ensure_media can pass it to Media.create, avoiding EMP dependency
-- in pure-Lua tests (Sequence.ensure_master asserts TC is non-nil for video).
local TC_METADATA = '{"start_tc_value":0,"start_tc_rate":25,"start_tc_audio_samples":0,"start_tc_audio_rate":48000}'

local function make_clip(id, name, media_key, lis, start)
    return {
        original_id      = id,
        name             = name,
        start_value      = start or 0,
        duration         = 25,
        source_in        = 0,
        source_out       = 25,
        frame_rate       = 25.0,
        enabled          = true,
        linked_item_sync = lis,     -- nil for unlinked clips
        file_id          = media_key,
        media_key        = media_key,
        media = {
            id                = media_key,
            key               = media_key,
            path              = "/test/" .. name,
            name              = name,
            duration          = 25,
            frame_rate        = 25.0,
            width             = 1920,
            height            = 1080,
            audio_channels    = 2,
            audio_sample_rate = 48000,
            metadata          = TC_METADATA,
        },
    }
end

local LINK_KEY = "aud-1"   -- sorted minimum of {"vid-1", "aud-1"}

local parsed = {
    success  = true,
    sequences = {
        {
            original_id       = "seq-1",
            name              = "Test Seq",
            frame_rate        = 25.0,
            width             = 1920,
            height            = 1080,
            audio_sample_rate = 48000,
            media_files       = {},
            video_tracks = {
                {
                    type    = "VIDEO",
                    index   = 1,
                    enabled = true,
                    locked  = false,
                    clips   = {
                        make_clip("vid-1", "clip.mov",     "media-a", LINK_KEY,   0),
                        make_clip("vid-2", "unlinked.mov", "media-b", nil,        50),
                    },
                },
            },
            audio_tracks = {
                {
                    type    = "AUDIO",
                    index   = 1,
                    enabled = true,
                    locked  = false,
                    clips   = {
                        make_clip("aud-1", "clip.mov", "media-a", LINK_KEY),
                    },
                },
            },
        },
    },
    media_files = {},
}

local result = fcp7.create_entities(parsed, db, "proj")
assert(result and result.success, "create_entities failed: " .. tostring(result and result.error))

-- ─────────────────────────────────────────────────────────────────────
-- Domain assertion: the V+A linked pair must appear in the same
-- clip_links group; the unlinked clip must have no clip_links row.
-- ─────────────────────────────────────────────────────────────────────

-- Find the DB clip id for "vid-1" and "aud-1" via clip_id_map.
-- clip_key format: sequence_key :: track_key :: original_id
-- (see create_clip_set in fcp7_xml_importer.lua)
local clip_id_map = result.clip_id_map or {}

-- Collect clip ids for all linked clips (vid-1 and aud-1).
-- We don't know the exact composite key, so scan the map for entries
-- whose suffix matches the original clip id.
local linked_clip_ids = {}
local unlinked_clip_ids = {}
for key, cid in pairs(clip_id_map) do
    if key:find("::vid%-1$") or key:find("::aud%-1$") then
        table.insert(linked_clip_ids, cid)
    elseif key:find("::vid%-2$") then
        table.insert(unlinked_clip_ids, cid)
    end
end

assert(#linked_clip_ids == 2,
    "expected 2 linked clip ids (vid-1 and aud-1), got " .. #linked_clip_ids)
assert(#unlinked_clip_ids == 1,
    "expected 1 unlinked clip id (vid-2), got " .. #unlinked_clip_ids)

-- Verify that both linked clips share the same link_group_id.
local function get_link_group(clip_id)
    local stmt = db:prepare("SELECT link_group_id FROM clip_links WHERE clip_id = ?")
    assert(stmt, "prepare failed")
    stmt:bind_value(1, clip_id)
    local grp = nil
    if stmt:exec() and stmt:next() then
        grp = stmt:value(0)
    end
    stmt:finalize()
    return grp
end

local grp_a = get_link_group(linked_clip_ids[1])
local grp_b = get_link_group(linked_clip_ids[2])

assert(grp_a ~= nil,
    "linked clip 1 must have a clip_links row (link_group_id was nil)")
assert(grp_b ~= nil,
    "linked clip 2 must have a clip_links row (link_group_id was nil)")
assert(grp_a == grp_b,
    "linked V and A clips must share the same link_group_id")
print("  ✓ V and A clips share link_group_id: " .. grp_a)

-- Verify the unlinked clip has no clip_links row.
local grp_unlinked = get_link_group(unlinked_clip_ids[1])
assert(grp_unlinked == nil,
    "unlinked clip must have no clip_links row (got link_group_id=" .. tostring(grp_unlinked) .. ")")
print("  ✓ unlinked clip has no clip_links row")

print("\n✅ test_fcp7_linked_item_sync.lua passed")
