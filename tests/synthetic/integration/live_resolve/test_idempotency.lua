-- T026 — LIVE idempotency (spec 023, FR-005/FR-008/FR-021;
--          quickstart step 6; helper-protocol.md §testing-discipline:
--          "same state-changing id twice → Resolve state changed
--          exactly once, both responses identical").
--
-- Authors a 2-clip DRT in-test (drt_writer, the production writer),
-- imports it twice with the SAME change_token, and asserts:
--   1. Both responses are deep-identical — including
--      resolve_timeline_id: a ledger replay returns the SAME timeline
--      uid, while a broken ledger would re-import and mint a fresh
--      Timeline.GetUniqueId. This observable holds even when media
--      relink fails (empty mapping), so the test cannot pass vacuously.
--   2. The current-timeline item population is unchanged between the
--      two sends (read_identities count).
--   3. Teardown: delete_timeline removes the fixture timeline
--      (deleted=true); a SECOND delete with a FRESH token observes
--      deleted=false (idempotent-delete contract) — the fresh token is
--      required because a same-token re-send is answered from the
--      idempotency ledger, not by re-dispatching the verb.
--
-- ⚠ State-changing on the CURRENT Resolve project: run against the VM
-- test environment (memory: project_vm_test_environment), never
-- against a Resolve project anyone cares about. The test deletes the
-- timeline it creates.
--
-- Fixture media: tests/fixtures/media/A005_C052_0925BL_001.mp4 —
-- 24000/1001 fps, 108 frames, 640x360 h264, no TC track (origin 0).
-- The path is resolved relative to the repo root so the same test
-- works on host and on the VM guest tree.
--
-- Run via (absolute path — relative resolves bundle-relative):
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--       $PWD/tests/synthetic/integration/live_resolve/test_idempotency.lua

local test_env = require("test_env")
local fixture = require("synthetic.integration.live_resolve.live_fixture")
local drt_writer = require("exporters.drt_writer")

-- ── fixture payload (drt_writer input contract) ─────────────────────
local FPS = 24000 / 1001
local MEDIA_FRAMES = 108

-- Share path: the DRT is imported ON the guest, and the helper now
-- pre-imports media_paths into Resolve's pool — the path must exist
-- there AND be readable by Resolve (scp'd copies in the synced tree do
-- not survive sync-to-vm.sh).
local media_path = test_env.resolve_repo_path(
    "tests/fixtures/media/A005_C052_0925BL_001.mp4")

local payload = {
    project = { name = "JVE T026 idempotency", fps = FPS },
    media_refs = {
        {
            file_uuid       = "0b26aaaa-aaaa-4aaa-8aaa-00000000000a",
            file_path       = media_path,
            native_rate     = FPS,
            duration_frames = MEDIA_FRAMES,
            start_tc_frame  = 0,
            track_type      = "video",
        },
    },
    sequence = {
        name   = "JVE T026 idempotency",
        fps    = FPS,
        width  = 1920,
        height = 1080,
        tracks = {
            {
                type = "video",
                clips = {
                    -- Non-trivial windows: offset source-in, distinct
                    -- non-contiguous timeline positions.
                    {
                        id             = "0b26c0de-1111-4aaa-8aaa-000000000001",
                        media_uuid     = "0b26aaaa-aaaa-4aaa-8aaa-00000000000a",
                        source_in      = 17,
                        source_out     = 65,
                        sequence_start = 240,
                        duration       = 48,
                        enabled        = true,
                        name           = "t026 clip A",
                    },
                    {
                        id             = "0b26c0de-2222-4aaa-8aaa-000000000002",
                        media_uuid     = "0b26aaaa-aaaa-4aaa-8aaa-00000000000a",
                        source_in      = 41,
                        source_out     = 89,
                        sequence_start = 480,
                        duration       = 48,
                        enabled        = true,
                        name           = "t026 clip B",
                    },
                },
            },
        },
    },
}

local function deep_equal(a, b, path)
    path = path or "result"
    if type(a) ~= type(b) then
        return false, string.format("%s: type %s ~= %s",
            path, type(a), type(b))
    end
    if type(a) ~= "table" then
        if a ~= b then
            return false, string.format("%s: %s ~= %s",
                path, tostring(a), tostring(b))
        end
        return true
    end
    local keys = {}
    for k in pairs(a) do keys[k] = true end
    for k in pairs(b) do keys[k] = true end
    for k in pairs(keys) do
        local ok, why = deep_equal(a[k], b[k],
            path .. "." .. tostring(k))
        if not ok then return false, why end
    end
    return true
end

-- ── live run ─────────────────────────────────────────────────────────
local fix = fixture.start("/tmp/jve-live-idempotency.sock")
fixture.skip_unless_live(fix, "test_idempotency")

local drt_path = "/tmp/jve-t026-idempotency.drt"
os.remove(drt_path)
local authored = drt_writer.author_a005_compatible(drt_path, payload)
assert(type(authored) == "table" and type(authored.emit_order) == "table"
    and #authored.emit_order == 2,
    "T026: drt_writer must report emit_order for both clips")

local token = {
    project_id          = "t026-project",
    sequence_id         = "t026-sequence",
    mutation_generation = 1,
}
local import_args = {
    drt_path       = drt_path,
    media_paths    = { media_path },
    clip_positions = authored.emit_order,
    change_token   = token,
}

local first = fixture.expect_ok(
    fixture.request(fix, "import_timeline", import_args),
    "import #1")
assert(type(first.resolve_timeline_id) == "string"
    and first.resolve_timeline_id ~= "",
    "T026: import must return the imported timeline's uid")
print(string.format(
    "  import #1: timeline=%s mapped=%d unrelinked=%d unkeyed=%d",
    first.resolve_timeline_id, #first.mapping,
    #first.unrelinked, #first.unkeyed_resolve_items))

local ids_before = fixture.expect_ok(
    fixture.request(fix, "read_identities", {}),
    "read_identities after import #1")

local second = fixture.expect_ok(
    fixture.request(fix, "import_timeline", import_args),
    "import #2 (same change_token)")

-- The core FR-008 assertion: byte-for-byte identical result. A second
-- real import could not return the same resolve_timeline_id (fresh
-- GetUniqueId) nor the same resolve_item_ids.
local same, why = deep_equal(first, second)
assert(same, "T026: re-send with same change_token must return the "
    .. "identical response — " .. tostring(why))

local ids_after = fixture.expect_ok(
    fixture.request(fix, "read_identities", {}),
    "read_identities after import #2")
assert(#ids_after.items == #ids_before.items
    and ids_after.unkeyed_count == ids_before.unkeyed_count,
    string.format("T026: timeline population changed across an "
        .. "idempotent re-send (items %d→%d, unkeyed %d→%d)",
        #ids_before.items, #ids_after.items,
        ids_before.unkeyed_count, ids_after.unkeyed_count))
print(string.format(
    "  re-send: identical response, population stable "
    .. "(%d keyed, %d unkeyed)",
    #ids_after.items, ids_after.unkeyed_count))

-- ── teardown + idempotent-delete contract ────────────────────────────
local del1 = fixture.expect_ok(
    fixture.request(fix, "delete_timeline", {
        resolve_timeline_id = first.resolve_timeline_id,
        change_token        = token,
    }), "delete_timeline #1")
assert(del1.deleted == true,
    "T026 teardown: fixture timeline must delete (deleted=true)")

-- Fresh token forces real dispatch (same-token re-send would be
-- answered from the idempotency ledger with the cached deleted=true).
local del2 = fixture.expect_ok(
    fixture.request(fix, "delete_timeline", {
        resolve_timeline_id = first.resolve_timeline_id,
        change_token        = {
            project_id          = token.project_id,
            sequence_id         = token.sequence_id,
            mutation_generation = 2,
        },
    }), "delete_timeline #2 (fresh token)")
assert(del2.deleted == false,
    "T026: deleting an already-deleted timeline must observe "
    .. "deleted=false, got deleted=" .. tostring(del2.deleted))
print("  teardown: timeline deleted; re-delete observed deleted=false")

fixture.stop(fix)
print("✅ test_idempotency.lua passed")
