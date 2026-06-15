require("test_env")

-- =============================================================================
-- DRT writer — Sm2TiVideoClip shape assertions on the synthesized output.
--
-- The writer used to borrow the entire Sm2TiVideoClip block verbatim from
-- a Resolve-authored template. After option D (regenerate from payload —
-- see phase0-findings §K3c), the writer synthesizes each clip; this test
-- guards the byte shapes that have to match what Resolve actually writes
-- (otherwise Resolve refuses or drops the clip on import).
--
-- DOMAIN contract (phase0-findings §K3c, dissected from
-- resolve_authored_single_clip.drp):
--   • <Start>            = clip.sequence_start (absolute project-epoch)
--   • <MediaRef>         = clip.media_uuid
--   • <MediaStartTime>   = bare "0" for integer media.start_tc_frame
--   • <MediaFrameRate>   = 16 hex chars LE-double(media.native_rate) +
--                          16 zero hex chars
--   • <MediaTimemapBA>   = "02" + 16 hex chars BE-double(
--                            (media.duration_frames - 1) / media.native_rate )
--   • BtThumnail @DbId   = freshly minted UUID, NOT a fixed constant
-- =============================================================================

local writer  = require("exporters.drt_writer")
local fixture = require("synthetic.helpers.drt_spike_fixture")

local function check(cond, msg)
    assert(cond, "Sm2TiVideoClip shape FAILED: " .. tostring(msg))
end

-- Pinned expected bytes for an A005-at-23.976 clip of 108 timeline
-- frames. The fixture builds exactly that payload; if anyone changes
-- fixture.A005_DURATION_FRAMES or .A005_NATIVE_RATE these expectations
-- become invalid (which is correct — the spec is per-config).
-- MediaFrameRate provenance: unzip resolve_authored_single_clip.drp →
-- SeqContainer/<dbid>.xml (it is the media's native-rate encoding, the
-- same in .drp and .drt). MediaTimemapBA provenance is the .drt 9-byte
-- form — see its block below.
local PINNED_MEDIA_FRAME_RATE = "872211b5dcf937400000000000000000"
-- 9-byte 0x02 forward form: type tag + be(d), where d = 107/23.976.
-- This is the shape a Resolve-authored **.drt** uses for a forward
-- un-retimed clip (retime-test.drt; see feedback_drt_drp_follow_fixtures).
-- The 41-byte `02|be(d)|0×8|be(d+1/24000)|0×8|be(d)` long form is a
-- **.drp**-only encoding (resolve_authored_single_clip.drp). Since this
-- writer authors a .drt, the 9-byte form is correct. A live import
-- experiment (test_drt_mtba_short_vs_long_render.lua, 2026-06-14)
-- confirmed the 9-byte form renders identically to the 41-byte form
-- (record_duration=24, kind=media), disproving the earlier 2026-05-31
-- "short form refuses to render" claim. The 9-byte form is also
-- rate-general — no epsilon constant, works at any native rate.
local PINNED_MEDIA_TIMEMAP_BA = "024011d9e60f04c756"
local PINNED_CURRENT_SELECTOR_IDX = "1083179008"

local payload = fixture.build_a005_payload()
local clip  = payload.sequence.tracks[1].clips[1]
local media = payload.media_refs[1]

local OUT = fixture.out_path("test_drt_writer_ti_video_clip_shape")
os.remove(OUT)
writer.author_a005_compatible(OUT, payload)

local seq_xml = fixture.unzip_member(OUT, "SeqContainer/*.xml")

-- Isolate the Sm2TiVideoClip subtree so substring assertions can't pass
-- on unrelated content elsewhere in the archive. UUIDs contain hyphens
-- which Lua patterns interpret as quantifiers; find the open tag by
-- plain-substring then scan forward to the close tag.
local open_tag = string.format('<Sm2TiVideoClip DbId="%s">', clip.id)
local open_lo, open_hi = seq_xml:find(open_tag, 1, true)
check(open_lo, "no " .. open_tag .. " found in SeqContainer/*.xml")
local close_lo = seq_xml:find("</Sm2TiVideoClip>", open_hi, true)
check(close_lo, "Sm2TiVideoClip element not properly closed for clip "
    .. clip.id)
local ti_clip = seq_xml:sub(open_lo, close_lo + #"</Sm2TiVideoClip>" - 1)

local function expect_inside(needle, hint)
    check(fixture.plain_count(ti_clip, needle) == 1, string.format(
        "expected %s inside Sm2TiVideoClip subtree. Hint: %s",
        needle, hint))
end

-- Payload-derived expectations:
expect_inside(
    string.format('<Sm2TiVideoClip DbId="%s">', clip.id),
    "FR-011b: clip.id is the identity carrier")
expect_inside(
    string.format("<Name>%s</Name>", clip.name),
    "<Name> comes from clip.name")
expect_inside(
    string.format("<Start>%d</Start>", clip.sequence_start),
    "<Start> = clip.sequence_start (absolute project-epoch frames; "
    .. "sequence.lua:1007)")
expect_inside(
    string.format("<Duration>%d</Duration>", clip.duration),
    "<Duration> from clip.duration")
expect_inside(
    string.format("<MediaRef>%s</MediaRef>", media.file_uuid),
    "<MediaRef> = media.file_uuid (round-trips with Sm2MpVideoClip@DbId)")
expect_inside(
    string.format("<MediaFilePath>%s</MediaFilePath>", media.file_path),
    "<MediaFilePath> from media.file_path")
expect_inside(
    "<MediaStartTime>0</MediaStartTime>",
    "Resolve writes bare \"0\" for integer media.start_tc_frame, not "
    .. "\"0.000000000\" — Resolve refuses the latter")

-- MediaFrameRate must equal the bytes Resolve writes — pinned from
-- resolve_authored_single_clip.drp, not recomputed by the writer's encoder.
expect_inside(
    "<MediaFrameRate>" .. PINNED_MEDIA_FRAME_RATE .. "</MediaFrameRate>",
    "MediaFrameRate must match Resolve's bytes for A005-at-23.976 "
    .. "(NOT seq.fps=24 — cross-rate semantics, phase0-findings §K3c). "
    .. "Computing expected via the writer's own encoder would pass "
    .. "even under reversed endianness; pinned literal does not.")

-- MediaTimemapBA must equal Resolve's bytes for a 108-frame A005 clip:
-- `02` (1-byte type tag) + BE-double(107/23.976) = `024011d9e60f04c756`.
-- A 10-byte 0x0240 header (an earlier incorrect synthesis) would fail
-- against this pinned literal.
expect_inside(
    "<MediaTimemapBA>" .. PINNED_MEDIA_TIMEMAP_BA .. "</MediaTimemapBA>",
    "MediaTimemapBA must match the .drt forward 9-byte form for "
    .. "108-frame A005-at-23.976 (02|be(107/23.976)). The .drt fixture "
    .. "uses this form; a live import experiment confirmed it renders "
    .. "identically to the .drp 41-byte long form (2026-06-14).")
expect_inside(
    "<CurrentSelectorIdx>" .. PINNED_CURRENT_SELECTOR_IDX
        .. "</CurrentSelectorIdx>",
    "CurrentSelectorIdx is an opaque magic value Resolve writes; "
    .. "emitting \"0\" correlated with the clip not rendering")

-- BtThumnail @DbId must be freshly minted per export. Capture it and
-- assert it's a valid UUID and NOT the reference template's value.
local LEAK_THUMB_DBID = "c2b31a93-3697-4d07-9ce7-65ac0f86e7a9"
local thumb_dbid = ti_clip:match('<BtThumnail DbId="([^"]+)"')
check(thumb_dbid, "<BtThumnail DbId=...> not found inside Sm2TiVideoClip")
check(thumb_dbid:match("^%x+%-%x+%-%x+%-%x+%-%x+$"),
    "BtThumnail DbId not a UUID: " .. thumb_dbid)
check(thumb_dbid ~= LEAK_THUMB_DBID,
    "BtThumnail DbId leaked template value " .. LEAK_THUMB_DBID
    .. " — must be freshly minted per export to avoid cross-archive "
    .. "collision in the same Resolve instance")

-- <Flags> carries the item's enabled state: 0 = enabled, bit 2 set =
-- disabled (live-probed 2026-06-10: exporting a timeline whose second
-- item was SetClipEnabled(False) flips exactly <Flags>0</Flags> →
-- <Flags>2</Flags> on that item; the DRP importer reads the same bit
-- at drp_importer.lua's Flags%4 check). Without this, a JVE user's
-- disabled clip arrives in Resolve enabled — and the first
-- SyncEditsFromResolve then classifies the discrepancy resolve_only
-- and silently re-enables the JVE clip.
expect_inside("<Flags>0</Flags>",
    "enabled clip must carry <Flags>0</Flags>")

local function author_disabled_variant()
    local p2 = fixture.build_a005_payload()
    for _, track in ipairs(p2.sequence.tracks) do
        for _, c in ipairs(track.clips) do
            c.enabled = false
        end
    end
    local out2 = fixture.out_path(
        "test_drt_writer_ti_video_clip_shape_disabled")
    os.remove(out2)
    writer.author_a005_compatible(out2, p2)
    local xml2 = fixture.unzip_member(out2, "SeqContainer/*.xml")
    local v_clip = p2.sequence.tracks[1].clips[1]
    local lo, hi = xml2:find(
        string.format('<Sm2TiVideoClip DbId="%s">', v_clip.id), 1, true)
    check(lo, "disabled variant: Sm2TiVideoClip not found")
    local close = xml2:find("</Sm2TiVideoClip>", hi, true)
    check(close, "disabled variant: Sm2TiVideoClip not closed")
    local subtree = xml2:sub(lo, close)
    check(fixture.plain_count(subtree, "<Flags>2</Flags>") == 1,
        "disabled clip must carry <Flags>2</Flags> in its "
        .. "Sm2TiVideoClip (got: "
        .. tostring(subtree:match("<Flags>[^<]*</Flags>")) .. ")")
    os.remove(out2)
end
author_disabled_variant()

os.remove(OUT)

print("✅ test_drt_writer_ti_video_clip_shape.lua passed")
