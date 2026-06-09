-- Regression: DRP parse_master_clip_element attaches enough data to
-- distinguish a synced video pool item from an unsynced one, and to
-- resolve which BtAudioInfo DbIds this pool item references.
--
-- Domain behavior:
--   - Every Sm2Mp{Video,Audio}Clip carries >= 1 <BtAudioInfo DbId="…"/>
--     child under EmbeddedAudioVec (and the audio clip's own body).
--     These are the audio-stream IDs other pool items link to.
--   - Every Sm2MpVideoClip carries an <AudioSource> tag whose value is
--     AUDIO_SOURCE_EMBEDDED (unsynced, plays video's own audio) or
--     AUDIO_SOURCE_CUSTOM (synced, plays an external WAV's audio).
--   - The Sm2MpVideoClip's FieldsBlob — once decompressed — contains
--     MediaRef UUIDs that point at BtAudioInfo DbIds. The ordered list
--     is the pool-level mapping from virtual-audio-track index to the
--     audio source that feeds it. For unsynced, all refs land on the
--     video's own embedded BtAudioInfo. For synced, refs split between
--     the external WAV's BtAudioInfo and the video's own embedded.
--
-- This test exercises parse_master_clip_element on synthetic elements
-- (no qt_xml_parse dependency), asserting the attached fields:
--   clip.audio_source          ∈ {"AUDIO_SOURCE_EMBEDDED","AUDIO_SOURCE_CUSTOM"}
--   clip.own_bt_audio_info_ids  — DbIds of BtAudioInfo children this
--                                 pool item *owns* (used to build the
--                                 reverse index elsewhere).
--   clip.audio_refs            — ordered list of BtAudioInfo DbIds this
--                                 pool item *references* (from the
--                                 decompressed FieldsBlob). Video only;
--                                 nil for audio.

require("test_env")

-- Stub qt_zstd_decompress with the CLI so parse_master_clip_element can
-- actually decompress the FieldsBlob on a pure-Lua test runner.
if type(qt_zstd_decompress) ~= "function" then
    _G.qt_zstd_decompress = function(frame)
        if type(frame) ~= "string" or #frame == 0 then
            return nil, "zstd: empty input"
        end
        local ti, to = os.tmpname(), os.tmpname()
        local fh = assert(io.open(ti, "wb")); fh:write(frame); fh:close()
        local rc = os.execute(string.format(
            "zstd -d -q -f -o %q %q 2>/dev/null", to, ti))
        os.remove(ti)
        if rc ~= 0 and rc ~= true then os.remove(to); return nil, "zstd" end
        local ofh = assert(io.open(to, "rb"))
        local out = ofh:read("*a"); ofh:close(); os.remove(to)
        return out
    end
end

local drp = require("importers.drp_importer")

print("=== test_drp_synced_clip_pool_link.lua ===")

-- ─────────────────────────────────────────────────────────────────────
-- Element-tree helpers matching qt_xml_parse's output shape.
-- ─────────────────────────────────────────────────────────────────────
local function elem(tag, attrs, children_or_text)
    local e = { tag = tag, attrs = attrs or {}, children = {} }
    if type(children_or_text) == "string" then
        e.text = children_or_text
    elseif type(children_or_text) == "table" then
        e.children = children_or_text
    end
    return e
end
local function text(tag, t) return elem(tag, {}, t) end

-- Real FieldsBlob hex from the synced-clip example DRP.
local SYNCED_FB =
    "00000002000001ec81" ..
    "28b52ffd606e090d0f00369a4f3c30ada639200d97bfebaa6ff411469440681c513de70b81f" ..
    "87a4586ae22fa95dd67fd476b87de75ad1808a0316e7fab51f987833ec260b55760247ba748" ..
    "00370037000b6247455f911a33271dad7094e5c805ccf400bf52c7f8740e8703164ef432d24" ..
    "bcb860595140455e542251f675595e772251fe740086408d8400244870d86c680865342c349" ..
    "a109235f942b11321fba6904c890095148b12743352e3294e44696d8e720e7357f53621fccb" ..
    "ea22a43330e220942b1e2c26fdeb294f42d7519a993a52b5f054b47436e5c8a36f0cc66558f" ..
    "5a514fe7d575be5693d6ce4facc78e9d6ed6ead1a4fb7965a07d21243831a0c54bdf965a6dd" ..
    "bb66ddbb66d17cf984ea894eac78e1fb5d517ebbe59cdca11dbb95a59932cf6aab556330c15" ..
    "55600269a01813225484c840e1ca971202887194060f2ed5e4a13832309315412090020966e" ..
    "8a61ed04981f4b300008d041cc1d0ec86a12eecdf708b40c44c6037d27f1bbebff0fd3fc409" ..
    "63201fc4b882332413a461d04af762821c90be66c6ebcb82d29823cac804e554500621381788" ..
    "ca702410f5c0e1b8d594d561b3bbe39ef84a4e0044abd5656823fae61d6efaa7e285268ac586" ..
    "db8d0c5118cebbc3c6700d2748c4513cb355e4803dd7bbe1994b48f07eb8db00da017a218b66c60c"
local UNSYNCED_FB =
    "0000000200000147" .. "81" ..
    "28b52ffd604701e5090046533e39606dd21cc014b44d44004ba4142e6480190660a1e1876d7" ..
    "bab6f934b2c409218a4daa3d9461010fd4bc62eb6ce80ce0e8d388e0b234bc8de293b002900" ..
    "29001306f844c973016fa1e7936780d230a7c94844320c161940380828aa591c9766a1a8eaa" ..
    "2715c5acb205019c0618487101280e84044e91051404401477739af106aba5890d6ca33198f" ..
    "4c090911253e6ca82015d999753b473278ddc4ba1b2b4eee862419d31613637b31c1b6dac0a" ..
    "32b41d2900a1d2af064d4a0d042f6fad15af18dd6082d5e7875b39b0f521cefbdf7de7b134b" ..
    "15e863674877c1ce4d8dd2c36923b10e2834ab0a62c4ac76ac5aa6d44b2ce6b4594e3bae011" ..
    "900d22b46e7456c01e9c031903d6998828bb5cab266f3d0c0a7e4ef3cbdd5181e4f5f263210" ..
    "9b8edbad77780d37802013fc3c83b759111c8673d6a6a3baebf6"

-- Ground truth BtAudioInfo DbIds from the example DRP.
local SYNC_VID_BTAI   = "5c14f5ac-cbc5-454c-a348-fce0ae1f9691"   -- video's own
local WAV_BTAI        = "580b74c0-67a8-4b4e-8005-c02df71eccc2"   -- synced WAV's
local UNSYNC_VID_BTAI = "20350790-a79b-4500-9d81-3542b29762c1"

-- ─────────────────────────────────────────────────────────────────────
-- Synthetic Sm2MpVideoClip — synced
-- ─────────────────────────────────────────────────────────────────────
local synced_video = elem("Sm2MpVideoClip", { DbId = "sync-vid-dbid" }, {
    text("FieldsBlob", SYNCED_FB),
    text("Name", "A008_05211408_C011.mov"),
    text("AudioSource", "AUDIO_SOURCE_CUSTOM"),
    elem("EmbeddedAudioVec", {}, {
        elem("Element", {}, {
            elem("BtAudioInfo", { DbId = SYNC_VID_BTAI }, {}),
        }),
    }),
})

local mc_synced = drp._parse_master_clip_element(synced_video, "folder-sync")
assert(mc_synced, "parse returned nil for synced video")
assert(mc_synced.audio_source == "AUDIO_SOURCE_CUSTOM",
    "synced: audio_source = " .. tostring(mc_synced.audio_source))
assert(type(mc_synced.own_bt_audio_info_ids) == "table"
    and mc_synced.own_bt_audio_info_ids[1] == SYNC_VID_BTAI,
    "synced: own_bt_audio_info_ids must list the video's BtAudioInfo DbId")
assert(type(mc_synced.audio_refs) == "table",
    "synced: audio_refs must be a table")
local refs_set = {}
for _, u in ipairs(mc_synced.audio_refs) do refs_set[u] = (refs_set[u] or 0) + 1 end
assert(refs_set[WAV_BTAI], "synced audio_refs must include external WAV BtAudioInfo")
assert(refs_set[SYNC_VID_BTAI], "synced audio_refs must include own embedded BtAudioInfo")
assert(refs_set[WAV_BTAI] > refs_set[SYNC_VID_BTAI],
    "synced: external WAV should be referenced more than embedded")
print(string.format("  ✓ synced video: %d refs (%d WAV + %d embedded), audio_source=CUSTOM",
    #mc_synced.audio_refs, refs_set[WAV_BTAI], refs_set[SYNC_VID_BTAI]))

-- ─────────────────────────────────────────────────────────────────────
-- Synthetic Sm2MpVideoClip — unsynced
-- ─────────────────────────────────────────────────────────────────────
local unsynced_video = elem("Sm2MpVideoClip", { DbId = "unsync-vid-dbid" }, {
    text("FieldsBlob", UNSYNCED_FB),
    text("Name", "A009_unsynced.mov"),
    text("AudioSource", "AUDIO_SOURCE_EMBEDDED"),
    elem("EmbeddedAudioVec", {}, {
        elem("Element", {}, {
            elem("BtAudioInfo", { DbId = UNSYNC_VID_BTAI }, {}),
        }),
    }),
})
local mc_unsynced = drp._parse_master_clip_element(unsynced_video, "folder-sync")
assert(mc_unsynced.audio_source == "AUDIO_SOURCE_EMBEDDED",
    "unsynced: audio_source = " .. tostring(mc_unsynced.audio_source))
local u_refs = {}
for _, u in ipairs(mc_unsynced.audio_refs) do u_refs[u] = true end
assert(u_refs[UNSYNC_VID_BTAI] and not u_refs[WAV_BTAI],
    "unsynced audio_refs should reference only the video's own embedded BtAudioInfo")
print(string.format("  ✓ unsynced video: %d refs (all to own embedded), audio_source=EMBEDDED",
    #mc_unsynced.audio_refs))

-- ─────────────────────────────────────────────────────────────────────
-- Synthetic Sm2MpAudioClip — plain audio pool item (S064-T002.WAV)
-- Audio pool items have no AudioSource / audio_refs; they only expose
-- their own BtAudioInfo DbId so the reverse-index lookup works.
-- ─────────────────────────────────────────────────────────────────────
local WAV_POOL_BTAI = "580b74c0-67a8-4b4e-8005-c02df71eccc2"
local audio_pool = elem("Sm2MpAudioClip", { DbId = "wav-pool-dbid" }, {
    text("FieldsBlob", ""),  -- FieldsBlob optional for this assertion
    text("Name", "S064-T002.WAV"),
    elem("EmbeddedAudioVec", {}, {
        elem("Element", {}, {
            elem("BtAudioInfo", { DbId = WAV_POOL_BTAI }, {}),
        }),
    }),
})
local mc_audio = drp._parse_master_clip_element(audio_pool, "folder-sync")
assert(mc_audio.audio_source == nil,
    "audio pool item must not have audio_source (only videos do)")
assert(mc_audio.audio_refs == nil,
    "audio pool item must not have audio_refs (only videos do)")
assert(mc_audio.own_bt_audio_info_ids and mc_audio.own_bt_audio_info_ids[1] == WAV_POOL_BTAI,
    "audio pool: own_bt_audio_info_ids must list the WAV's BtAudioInfo DbId")
print("  ✓ audio pool item: own_bt_audio_info_ids populated; no audio_source/audio_refs")

-- ─────────────────────────────────────────────────────────────────────
-- End-to-end linkage: given these three pool items, a caller can build
-- btai_dbid → pool_item and resolve each synced video's audio_refs to
-- the external Sm2MpAudioClip. This is the minimum data stage 3 needs.
-- ─────────────────────────────────────────────────────────────────────
local btai_index = {}
for _, mc in ipairs({ mc_synced, mc_unsynced, mc_audio }) do
    for _, id in ipairs(mc.own_bt_audio_info_ids or {}) do
        btai_index[id] = mc
    end
end

local linked_audio_pool_items = {}
for _, ref in ipairs(mc_synced.audio_refs or {}) do
    local owner = btai_index[ref]
    if owner and owner ~= mc_synced then
        linked_audio_pool_items[owner.id] = true
    end
end
assert(linked_audio_pool_items["wav-pool-dbid"],
    "resolving synced video's audio_refs must land on the WAV pool item")
print("  ✓ synced video's audio_refs resolve to the external audio pool item")

print("\n✅ test_drp_synced_clip_pool_link.lua passed")
