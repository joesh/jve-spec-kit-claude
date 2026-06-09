-- master_clock_hz canonical value (705,600,000 — flicks) MUST exactly
-- divide every supported audio rate and frame rate. This is what justifies
-- removing SetProjectMasterClock: with flicks-canonical, no user-facing
-- knob is needed because every rate lands on an exact integer.
--
-- Pre-bump (master_clock_hz=192000): 44.1k, 88.2k, 176.4k fail because
-- 192000/44100 = 4.3537… (non-integer). Subframe ticks ↔ samples for
-- those rates rounds. Bound stays < ½ tick per single round-trip so
-- subframe values within INV-4 don't drift in practice, but cumulative
-- arithmetic at the tick layer is structurally lossy.
--
-- Post-bump: every supported rate divides 705,600,000 exactly. INV-9
-- below is a structural property that, if it ever fails, means a new
-- rate has been added that flicks doesn't cover and the canonical clock
-- must be reconsidered.

require("test_env")
local Project = require("models.project")

-- INV-9 (informal): default master_clock_hz must exactly divide every
-- supported audio rate (flicks/sample integer) and every supported frame
-- rate (flicks/frame integer for any fps_num/fps_den combination we ship).
local SUPPORTED_AUDIO_RATES = {
    8000, 11025, 16000, 22050, 24000, 32000,
    44100, 48000, 88200, 96000, 176400, 192000,
}

-- Supported frame rates as (num, den) pairs. Integer rates have den=1;
-- broadcast NTSC rates use the 1001 denominator family.
local SUPPORTED_FRAME_RATES = {
    {num = 24,    den = 1},
    {num = 25,    den = 1},
    {num = 30,    den = 1},
    {num = 48,    den = 1},
    {num = 50,    den = 1},
    {num = 60,    den = 1},
    {num = 100,   den = 1},
    {num = 120,   den = 1},
    {num = 24000, den = 1001},  -- 23.976
    {num = 30000, den = 1001},  -- 29.97
    {num = 48000, den = 1001},  -- 47.952
    {num = 60000, den = 1001},  -- 59.94
    {num = 120000,den = 1001},  -- 119.88
}

-- Bootstrap a default project and read back the canonical mch.
-- Project.create with no settings uses the default JSON, which is the
-- canonical value under test here.
local database = require("core.database")
local DB = "/tmp/jve/test_master_clock_canonical_flicks.db"
os.remove(DB); assert(database.init(DB))

local proj = Project.create("test", { fps_mismatch_policy = "passthrough" })
assert(proj:save(), "test setup: project save failed")
local mch = proj:get_master_clock_hz()
assert(type(mch) == "number" and mch > 0, "test setup: mch must be positive int")

print(string.format("\n=== canonical master_clock_hz = %d ===", mch))

-- For every audio rate: mch / rate must be exact integer.
print("-- audio rates: flicks / sample is integer --")
for _, rate in ipairs(SUPPORTED_AUDIO_RATES) do
    local q = mch / rate
    assert(q == math.floor(q), string.format(
        "INV-9 audio: mch=%d does not divide rate=%d cleanly "
        .. "(quotient=%.6f). Canonical clock must exactly represent every "
        .. "supported audio rate so subframe arithmetic is lossless.",
        mch, rate, q))
    print(string.format("  ok %6d Hz → %d flicks/sample", rate, q))
end

-- For every fps (num, den): mch * den / num must be exact integer.
print("-- frame rates: flicks / frame is integer --")
for _, fr in ipairs(SUPPORTED_FRAME_RATES) do
    local num, den = fr.num, fr.den
    local product = mch * den
    assert(product % num == 0, string.format(
        "INV-9 fps: mch=%d does not divide cleanly for fps=%d/%d "
        .. "(mch*den=%d, %% num=%d). Canonical clock must exactly represent "
        .. "every supported frame rate so ticks_per_frame is integer.",
        mch, num, den, product, product % num))
    print(string.format("  ok %5d/%-4d → %d flicks/frame", num, den, product / num))
end

print("✅ test_master_clock_canonical_flicks.lua passed")
