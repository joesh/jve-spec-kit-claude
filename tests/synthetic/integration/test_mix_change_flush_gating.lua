-- Integration: a solo/mute change during playback drops the stale already-mixed
-- PCM tail downstream of TMB (the "flush") — EXCEPT when a solo is active and
-- only a mute toggled, where solo trumps mute so the audible output is unchanged
-- and flushing would click for nothing.
--
-- Domain rules under test (stated by the user):
--   * No solo active, mute toggled        → output changes  → flush
--   * Solo active, mute toggled (any trk)  → output same     → NO flush
--   * Solo toggled (always)                → audible set chgs → flush
--
-- The flush itself lives in C++ (PlaybackController::FlushAudioForMixChange);
-- here we observe whether the engine *decides* to flush by counting calls to
-- the engine's flush method. The gating decision and the real solo query
-- (_any_audio_track_soloed, reads the DB) are exercised for real.

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

require("test_env")
local database       = require("core.database")
local PlaybackEngine = require("core.playback.playback_engine")

print("=== test_mix_change_flush_gating.lua ===")

local DB = "/tmp/jve/test_mix_change_flush_gating.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('proj','P','resample',%d,%d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
        VALUES ('seq','proj','S','sequence',24,1,48000,1920,1080,%d,%d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, volume, pan, muted, soloed)
        VALUES ('a1','seq','A1','AUDIO',1,1,1.0,0.0,0,0),
               ('a2','seq','A2','AUDIO',2,1,1.0,0.0,0,0);
]], now, now, now, now))

local Sequence = require("models.sequence")
local seq = Sequence.load("seq")
assert(seq, "sequence must load")

-- Real engine; only the audio-mix refresh and the downstream flush are stubbed
-- (their bodies need a live audio session / C++ controller). Everything the
-- gating decision reads is real.
local engine = PlaybackEngine.new("record", {
    on_show_frame = function() end, on_show_gap = function() end,
    on_set_rotation = function() end, on_set_par = function() end,
    on_position_changed = function() end,
})
engine.loaded_sequence_id = "seq"
engine.sequence = seq

local flush_calls = 0
engine._refresh_audio_mix = function() end
engine._flush_audio_pipeline_for_mix_change = function() flush_calls = flush_calls + 1 end

local function set_track(id, col, on)
    db:exec(string.format("UPDATE tracks SET %s=%d WHERE id='%s'", col, on and 1 or 0, id))
end

-- ── (1) No solo, mute toggled → flush ────────────────────────────────
print("-- (1) no solo + mute toggle → flush --")
set_track("a1", "muted", true)
engine:_on_track_preference_changed_signal("a1", "muted", true, false)
assert(flush_calls == 1, "mute change with no solo active must flush, got " .. flush_calls)
print("  PASS")

-- ── (2) Solo active, mute toggled → NO flush (solo trumps mute) ───────
print("-- (2) solo active + mute toggle → no flush --")
set_track("a2", "soloed", true)
engine:_on_track_preference_changed_signal("a1", "muted", false, true)
assert(flush_calls == 1, "mute change while a solo is active must NOT flush, got " .. flush_calls)
print("  PASS")

-- ── (3) Solo toggled → flush (audible set changed) ───────────────────
print("-- (3) solo toggle → flush --")
engine:_on_track_preference_changed_signal("a2", "soloed", true, false)
assert(flush_calls == 2, "solo change must always flush, got " .. flush_calls)
print("  PASS")

-- ── (4) Removing the last solo, then mute toggles again → flush ──────
print("-- (4) solo cleared, mute toggle → flush again --")
set_track("a2", "soloed", false)
engine:_on_track_preference_changed_signal("a1", "muted", true, false)
assert(flush_calls == 3, "with no solo active, mute must flush again, got " .. flush_calls)
print("  PASS")

print("\nPASS test_mix_change_flush_gating.lua")
