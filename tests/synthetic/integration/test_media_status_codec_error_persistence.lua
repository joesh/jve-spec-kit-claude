-- Integration: a codec-level media error must survive directory churn.
--
-- Domain rule: "this file fails to decode" is established by a decoder
-- (TMB during playback, or the background codec probe). A directory
-- change event re-checks only EXISTENCE (can the file be opened?), and
-- existence cannot refute a codec verdict: the file was present when it
-- failed to decode. So:
--   • codec error (Unsupported / DecodeFailed) + file still exists
--       → verdict KEPT through dir events
--   • file disappears → FileNotFound replaces any verdict
--   • file reappears → online (existence transitions stay watcher-owned)
--
-- The bug this pins (found 2026-06-10): every dir event re-probed all
-- watched paths with an io.open existence check and unconditionally
-- replaced the cached status — flipping a TMB-reported DecodeFailed
-- back to online. Worse, persisting the error status writes the project
-- DB, whose WAL lives in the same directory as media for /tmp-style
-- projects — the persist's own dir event erased the status it was
-- persisting (self-stomp within ~1s; the CODEC UNAVAIL timeline label
-- flickered away).
--
-- Real path: real files in a scratch dir, the real QFileSystemWatcher
-- wiring (watch installed by media_status.register), real dir events
-- from os.remove / file creation. A sibling file's removal is the
-- positive control proving the watcher fired for this directory before
-- we assert the codec verdict survived the same event.

local ienv = require("synthetic.integration.integration_test_env")

print("=== test_media_status_codec_error_persistence.lua ===")

require("test_env")
local media_status = require("core.media.media_status")

local wait_until = ienv.wait_until

local DIR    = "/tmp/jve/codec_persist_test"
local KEEPER = DIR .. "/keeper.mp4"
local GONER  = DIR .. "/goner.mp4"

local function write_file(path)
    local f = assert(io.open(path, "w"), "cannot create " .. path)
    f:write("bytes irrelevant - existence checks only io.open")
    f:close()
end

os.execute("mkdir -p " .. DIR)
write_file(KEEPER)
write_file(GONER)

media_status.clear()

-- Register both paths: probes (online) and installs the real dir watch.
local st_keeper = media_status.register(KEEPER)
local st_goner  = media_status.register(GONER)
assert(st_keeper.offline == false, "setup: keeper must probe online")
assert(st_goner.offline == false,  "setup: goner must probe online")

-- ── (A) codec verdict survives a dir event ───────────────────────────
print("\n-- (A) DecodeFailed survives sibling-file dir churn --")
do
    -- TMB reports a decode failure for keeper (file present, codec bad).
    media_status.update_from_tmb(KEEPER, true, "DecodeFailed")
    assert(media_status.get(KEEPER).offline == true
        and media_status.get(KEEPER).error_code == "DecodeFailed",
        "setup: TMB update must land in the cache")

    -- Real dir event: remove the sibling. The watcher re-probes every
    -- registered path in the dir, so goner flipping to FileNotFound
    -- proves the same event stream that threatens keeper has fired.
    os.remove(GONER)
    wait_until(function()
        return media_status.get(GONER).offline == true
    end, 15, "goner flip to offline after real dir event")
    assert(media_status.get(GONER).error_code == "FileNotFound",
        "goner must be FileNotFound after removal; got "
        .. tostring(media_status.get(GONER).error_code))

    -- REGRESSION CHECK: keeper's codec verdict must have survived the
    -- same dir event — io.open success cannot refute DecodeFailed.
    local k = media_status.get(KEEPER)
    assert(k.offline == true and k.error_code == "DecodeFailed",
        string.format("keeper's DecodeFailed must survive the dir event; "
            .. "got offline=%s error_code=%s",
            tostring(k.offline), tostring(k.error_code)))
    print("  PASS codec verdict survived dir churn")
end

-- ── (B) existence transitions still watcher-owned ────────────────────
print("\n-- (B) disappearance replaces the verdict; reappearance clears it --")
do
    -- Keeper disappears: FileNotFound is more fundamental than the codec
    -- verdict and must replace it.
    os.remove(KEEPER)
    wait_until(function()
        return media_status.get(KEEPER).error_code == "FileNotFound"
    end, 15, "keeper flip to FileNotFound after removal")

    -- Keeper reappears: fresh existence → online until a decoder says
    -- otherwise (the old verdict was superseded by FileNotFound).
    write_file(KEEPER)
    wait_until(function()
        return media_status.get(KEEPER).offline == false
    end, 15, "keeper flip to online after recreation")
    assert(media_status.get(KEEPER).error_code == nil,
        "recreated keeper must carry no error_code; got "
        .. tostring(media_status.get(KEEPER).error_code))
    print("  PASS existence transitions still flow through the watcher")
end

media_status.unregister(KEEPER)
media_status.unregister(GONER)
media_status.clear()
os.remove(KEEPER)
os.execute("rmdir " .. DIR)

print("\nPASS test_media_status_codec_error_persistence.lua")
