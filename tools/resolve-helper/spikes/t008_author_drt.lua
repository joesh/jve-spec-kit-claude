--- T008 spike — author a DRT carrying known sentinels in EVERY candidate
--- identity field so a single Resolve import + read-back round-trip
--- answers which field(s) survive byte-clean (FR-002).
---
--- Candidate fields encoded per-clip:
---   • Sm2Ti*Clip.DbId    — `JVE_DBID_<n>` (writer's current default)
---   • <Name>              — `JVE_NAME_<n>` (visible on the Resolve item)
---   • <LinkedItemSync>    — `JVE_LIS_<n>`  (NOT emitted by writer today —
---                                          probe reports "writer-stubbed"
---                                          until the writer plumbs it)
---
--- Marker (Sm2TiItemLockableBlob) carrier is NOT in this first variant —
--- its blob encoding is more invasive. Adding it is the follow-up if
--- none of the three above survive.
---
--- Run from repo root:
---   luajit tools/resolve-helper/spikes/t008_author_drt.lua [/tmp/jve/t008_identity.drt]
---
--- Then drive Resolve: File → Import → Timeline → pick the .drt.
--- Then probe: python3 tools/resolve-helper/spikes/t008_probe.py

package.path = package.path
    .. ";" .. (debug.getinfo(1, "S").source:sub(2):gsub("/[^/]+$", "")
        .. "/../../../src/lua/?.lua")

local writer = require("exporters.drt_writer")

local OUT = arg[1] or "/tmp/jve/t008_identity.drt"
os.execute("mkdir -p /tmp/jve")

-- 24 fps so frame math is integer-clean (no NTSC noise during the spike).
local FR = 24.0
local function sentinel(carrier, n)
    return string.format("JVE_%s_%d", carrier, n)
end

local MEDIA = {
    {
        file_uuid       = "11111111-1111-4111-8111-111111111111",
        file_path       = "/tmp/jve/t008_a.mov",
        duration_frames = 720,
        start_tc_frame  = 0,
    },
    {
        file_uuid       = "22222222-2222-4222-8222-222222222222",
        file_path       = "/tmp/jve/t008_b.mov",
        duration_frames = 720,
        start_tc_frame  = 86400,
    },
    {
        file_uuid       = "33333333-3333-4333-8333-333333333333",
        file_path       = "/tmp/jve/t008_c.mov",
        duration_frames = 720,
        start_tc_frame  = 0,
    },
}

local CLIPS = {}
for i = 1, 3 do
    CLIPS[i] = {
        id              = sentinel("DBID", i),
        media_uuid      = MEDIA[i].file_uuid,
        sequence_start  = (i - 1) * 240,
        duration        = 240,
        source_in       = MEDIA[i].start_tc_frame + 24 * i,
        name            = sentinel("NAME", i),
        -- Reserved sentinel for the LinkedItemSync carrier. The writer
        -- doesn't emit <LinkedItemSync> today; the probe will report
        -- LIS as "writer-stubbed" so Joe knows the absence is intentional,
        -- not an import-side loss. If DbId/Name both fail to round-trip,
        -- next iteration plumbs this into `drt_writer.build_clip_xml`.
        linked_item_sync = sentinel("LIS", i),
    }
end

local PAYLOAD = {
    project = { name = "JVE_T008_identity_spike", fps = FR },
    media_refs = MEDIA,
    sequences = {
        {
            name           = "JVE_T008_seq",
            fps            = FR,
            start_tc_frame = 0,
            tracks = { { type = "video", clips = CLIPS } },
        },
    },
}

local result = writer.author(OUT, PAYLOAD)

print(string.format("Authored: %s", result.path))
print(string.format("Stage tree: %s", result.stage))
print()
print("Per-clip sentinels (probe checks each carrier round-trips byte-clean):")
print()
print("  N | DBID            | NAME            | LIS")
print("  --+-----------------+-----------------+----------------")
for i, c in ipairs(CLIPS) do
    print(string.format("  %d | %-15s | %-15s | %s (writer-stubbed)",
        i, c.id, c.name, c.linked_item_sync))
end
print()
print("Next:")
print("  1. In Resolve: File > Import > Timeline... > pick " .. OUT)
print("  2. Then:       python3 tools/resolve-helper/spikes/t008_probe.py "
    .. "JVE_T008_identity_spike")
