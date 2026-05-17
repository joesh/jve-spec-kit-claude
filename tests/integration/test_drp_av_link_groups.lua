-- Integration test: DRP import builds correct V↔A clip_links groups
-- against the anamnesis-gold-timeline.drp fixture.
--
-- Domain expectations (derived from how Resolve renders this fixture):
--
--   * The V `13-053-001` shot at sequence_start = 111632 and the
--     A `13-053-001` chunk at 111626 belong to the same V↔A pair.
--     They must end up in one clip_links group.
--
--   * A parallel-track V duplicate of `13-053-001` at 111632 (a
--     colour/grade copy) is unlinked. It must NOT join the pair's
--     group, so Opt+Click on the linked V doesn't drag the duplicate
--     into the selection.
--
--   * The linked group must be scoped to ONE shot name. Adjacent
--     shots `13-053-001` and `13-055-001` were bladed from the same
--     parent take and therefore share their <LinkedItemSync> value,
--     but Resolve treats each shot name as its own independent V↔A
--     pair.
--
-- Runs via JVEEditor --test (qt_xml_parse C++ binding required by
-- drp_importer.parse_drp_file).

require("test_env")
local test_env = require("test_env")

print("=== test_drp_av_link_groups ===")

local DRP_PATH = test_env.resolve_repo_path(
    "tests/fixtures/resolve/anamnesis-gold-timeline.drp")
local TEST_DIR = "/tmp/jve/test_drp_av_link_groups"
local JVP_PATH = TEST_DIR .. "/anamnesis.jvp"

local f = io.open(DRP_PATH, "rb")
assert(f, "PRECONDITION: anamnesis fixture not at " .. DRP_PATH)
f:close()

os.execute("mkdir -p " .. TEST_DIR)
os.execute("rm -f " .. JVP_PATH .. "*")

local drp_importer = require("importers.drp_importer")
local database     = require("core.database")

assert(drp_importer.convert(DRP_PATH, JVP_PATH, function() end),
    "INTEGRATION: drp_importer.convert returned falsey")
assert(database.set_path(JVP_PATH),
    "INTEGRATION: database.set_path failed on imported jvp")

local conn = database.get_connection()

-- ----------------------------------------------------------------------
-- Locate the V `13-053-001` clip at sequence_start=111632 on the
-- GOLD-MASTER sequence. There are two such clips (one linked, one a
-- parallel-track duplicate) — distinguish them by track_index.
-- ----------------------------------------------------------------------

local function fetch_all(sql, params, columns)
    local stmt = conn:prepare(sql)
    if params then
        for i, v in ipairs(params) do
            stmt:bind_value(i, v)
        end
    end
    assert(stmt:exec(), "fetch_all: stmt:exec() failed for " .. sql)
    local rows = {}
    while stmt:next() do
        local r = {}
        for i, col in ipairs(columns) do
            r[col] = stmt:value(i - 1)
        end
        table.insert(rows, r)
    end
    stmt:finalize()
    return rows
end

local seq_rows = fetch_all(
    [[SELECT id FROM sequences
      WHERE name = '2026-03-28-anamnesis-GOLD-MASTER-CANDIDATE']],
    nil, {"id"})
assert(#seq_rows == 1, string.format(
    "expected exactly one GOLD-MASTER sequence, got %d", #seq_rows))
local gold_seq_id = seq_rows[1].id

local v_clip_rows = fetch_all([[
    SELECT c.id, c.track_id, t.track_index
    FROM clips c
    JOIN tracks t ON t.id = c.track_id
    WHERE c.owner_sequence_id = ?
      AND c.name = '13-053-001'
      AND c.sequence_start_frame = 111632
      AND t.track_type = 'VIDEO'
    ORDER BY t.track_index
]], { gold_seq_id }, {"id", "track_id", "track_index"})

assert(#v_clip_rows == 2, string.format(
    "fixture invariant: expected 2 V `13-053-001` clips at start=111632, got %d",
    #v_clip_rows))

-- The linked V is the lower track_index (V1 in Resolve image), the
-- parallel duplicate is the higher (V4). Don't hard-code which is
-- which — distinguish by clip_links presence at the end.
local v_clip_a, v_clip_b = v_clip_rows[1], v_clip_rows[2]

local a_clip_rows = fetch_all([[
    SELECT c.id, c.track_id, t.track_index
    FROM clips c
    JOIN tracks t ON t.id = c.track_id
    WHERE c.owner_sequence_id = ?
      AND c.name = '13-053-001'
      AND c.sequence_start_frame = 111626
      AND t.track_type = 'AUDIO'
    ORDER BY t.track_index
]], { gold_seq_id }, {"id", "track_id", "track_index"})

assert(#a_clip_rows >= 1, string.format(
    "fixture invariant: expected ≥1 A `13-053-001` clip at start=111626, got %d",
    #a_clip_rows))

-- ----------------------------------------------------------------------
-- Assertion 1: exactly one of the two V clips is in a clip_links group.
-- ----------------------------------------------------------------------

local function get_link_group_id(clip_id)
    local rows = fetch_all(
        "SELECT link_group_id FROM clip_links WHERE clip_id = ?",
        { clip_id }, {"link_group_id"})
    if #rows == 0 then return nil end
    assert(#rows == 1, string.format(
        "clip %s in %d link groups (expected 0 or 1)", clip_id, #rows))
    return rows[1].link_group_id
end

local v_a_group = get_link_group_id(v_clip_a.id)
local v_b_group = get_link_group_id(v_clip_b.id)

assert(not (v_a_group and v_b_group), string.format(
    "BUG: both V `13-053-001` duplicates at start=111632 are in link groups\n" ..
    "  V_a clip=%s track_index=%d group=%s\n" ..
    "  V_b clip=%s track_index=%d group=%s\n" ..
    "Only the V with <LinkedItemSync> should be linked; the parallel\n" ..
    "duplicate must be unlinked.",
    v_clip_a.id, v_clip_a.track_index, tostring(v_a_group),
    v_clip_b.id, v_clip_b.track_index, tostring(v_b_group)))

assert(v_a_group or v_b_group,
    "neither V `13-053-001` is in a link group — the linked V is missing")

local linked_v = v_a_group and v_clip_a or v_clip_b
local linked_v_group = v_a_group or v_b_group
local unlinked_v = v_a_group and v_clip_b or v_clip_a

print(string.format(
    "  ✓ Exactly one V `13-053-001` at start=111632 is in a link group\n" ..
    "    linked V on track_index=%d, parallel duplicate on track_index=%d",
    linked_v.track_index, unlinked_v.track_index))

-- ----------------------------------------------------------------------
-- Assertion 2: the linked V's group also contains an A `13-053-001`.
-- ----------------------------------------------------------------------

local group_members = fetch_all([[
    SELECT cl.clip_id, cl.role, c.name, c.sequence_start_frame, t.track_type, t.track_index
    FROM clip_links cl
    JOIN clips  c ON c.id  = cl.clip_id
    JOIN tracks t ON t.id  = c.track_id
    WHERE cl.link_group_id = ?
    ORDER BY t.track_type, t.track_index
]], { linked_v_group },
    {"clip_id", "role", "name", "sequence_start_frame", "track_type", "track_index"})

local has_video = false
local has_audio = false
for _, m in ipairs(group_members) do
    if m.track_type == "VIDEO" then has_video = true end
    if m.track_type == "AUDIO" then has_audio = true end
end

if not has_audio then
    print("--- linked group members ---")
    for _, m in ipairs(group_members) do
        print(string.format(
            "  %s/%d %s start=%d clip_id=%s",
            m.track_type, m.track_index, m.name,
            m.sequence_start_frame, m.clip_id))
    end
end

assert(has_video and has_audio, string.format(
    "BUG: link group %s contains only %s%s — the V↔A pair from\n" ..
    "<LinkedItemSync>-2021</LinkedItemSync> on the V `13-053-001` clip at\n" ..
    "111632 and the A `13-053-001` clip at 111626 must end up in the\n" ..
    "same group.",
    linked_v_group,
    has_video and "video" or "",
    has_audio and "audio" or ""))

-- ----------------------------------------------------------------------
-- Assertion 3: the link group is scoped to the `13-053-001` shot —
-- it must NOT absorb the adjacent `13-055-001` segments that share
-- the same parent-take ID via <LinkedItemSync>. Resolve renders each
-- shot name as its own V↔A pair.
-- ----------------------------------------------------------------------

local member_names = {}
for _, m in ipairs(group_members) do
    member_names[m.name] = (member_names[m.name] or 0) + 1
end
local distinct_names = 0
for _ in pairs(member_names) do distinct_names = distinct_names + 1 end

if distinct_names ~= 1 then
    print("--- linked group members (multi-name) ---")
    for _, m in ipairs(group_members) do
        print(string.format(
            "  %s/%d %s start=%d", m.track_type, m.track_index,
            m.name, m.sequence_start_frame))
    end
end

assert(distinct_names == 1, string.format(
    "BUG: link group %s spans %d shot names (expected 1).\n" ..
    "Adjacent shots from the same take share LinkedItemSync but must\n" ..
    "form independent V↔A pairs per shot name. Members: %d total.",
    linked_v_group, distinct_names, #group_members))
assert(member_names["13-053-001"] == #group_members, string.format(
    "expected all %d members to be `13-053-001`; got: %s",
    #group_members, (function()
        local s = {}
        for n, c in pairs(member_names) do
            table.insert(s, string.format("%s=%d", n, c))
        end
        return table.concat(s, ", ")
    end)()))
print(string.format(
    "  ✓ Link group is shot-pair scoped: %d members, all `13-053-001`",
    #group_members))

-- ----------------------------------------------------------------------
-- Assertion 4: the unlinked V duplicate is NOT in any group.
-- ----------------------------------------------------------------------

local unlinked_group = get_link_group_id(unlinked_v.id)
assert(unlinked_group == nil, string.format(
    "parallel-track V duplicate (track_index=%d, clip=%s) is in link\n" ..
    "group %s. It has no <LinkedItemSync> in the DRP and should be\n" ..
    "unlinked.",
    unlinked_v.track_index, unlinked_v.id, tostring(unlinked_group)))

print("  ✓ Linked V and A `13-053-001` share a clip_links group")
print("  ✓ Parallel V duplicate is not in any link group")

-- Cleanup.
os.remove(JVP_PATH)
os.remove(JVP_PATH .. "-shm")
os.remove(JVP_PATH .. "-wal")

print("✅ test_drp_av_link_groups passed")
