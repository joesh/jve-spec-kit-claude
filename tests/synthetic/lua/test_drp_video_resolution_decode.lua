require("test_env")

-- =============================================================================
-- DRP import — BtVideoInfo <Geometry> resolution decode (spec 026 gap #4,
-- FR-011). The DRP carries each video clip's INTRINSIC pixel dimensions in the
-- plaintext Geometry Fusion-fields blob ("Resolution" field, type 0x000c,
-- payload = two BE int64 = width, height). The importer never parsed it, so
-- media.width/height held the PROJECT resolution instead — and the DRT writer
-- then stamped every video item with A005's borrowed Geometry. decode_bt_video
-- _resolution must read the real per-clip dimensions.
--
-- DOMAIN: the committed A005 reference template's Geometry decodes to 640×360
-- (A005 is a 640×360 proxy — verified first-hand, NOT the 1920×1080 project).
-- Golden dims are the literal BE int64 bytes Resolve wrote.
--
-- Run: cd tests && luajit test_harness.lua synthetic/lua/test_drp_video_resolution_decode.lua
-- =============================================================================

local drp_binary = require("importers.drp_binary")
local path_utils = require("core.path_utils")

local function read(p)
    local h = assert(io.open(p, "r"), "cannot open " .. p)
    local s = h:read("*a"); h:close(); return s
end

local xml = read(path_utils.resolve_repo_root()
    .. "/src/lua/exporters/drt_canonical/full_reference_mp_video_clip_a005.xml")
local geometry = assert(xml:match("<Geometry>([0-9a-f]+)</Geometry>"),
    "no <Geometry> blob in the A005 video template")

local w, h = drp_binary.decode_bt_video_resolution(geometry)
assert(w == 640, string.format("Geometry width: got %s, want 640", tostring(w)))
assert(h == 360, string.format("Geometry height: got %s, want 360", tostring(h)))

print("✅ test_drp_video_resolution_decode.lua passed")
