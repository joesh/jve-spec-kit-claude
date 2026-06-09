-- T053 — edit_diff.classify contract (spec 023, FR-025).
--
-- Given a live read_timeline row, a stored edit_fingerprint (from last
-- sync), and the current JVE clip state, classify the change as:
--   "neither"        — both sides match the fingerprint (no work)
--   "resolve_only"   — Resolve diverged, JVE unchanged (safe to apply)
--   "jve_only"       — JVE diverged locally, Resolve unchanged (no-op)
--   "both"           — both sides diverged (conflict — needs user choice)
--
-- Pure data, no DB, no mocks. The fingerprint format is whatever
-- edit_diff.fingerprint() produces; the test only checks the
-- classification semantics, not the fingerprint byte string.
--
-- Non-trivial values per FR-022: trims expressed in TC frames, not
-- 0/0/0 identity that would hide a bug.

require("test_env")
local edit_diff = require("core.resolve_bridge.edit_diff")

local pass = 0
local fail = 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== edit_diff.classify Tests ===")

-- Baseline clip state captured at last sync: 100..300 source, 1000..1200
-- record, enabled. Fingerprint this exactly.
local function clip(opts)
    return {
        source_in     = opts.source_in     or 100,
        source_out    = opts.source_out    or 300,
        record_start  = opts.record_start  or 1000,
        record_dur    = opts.record_dur    or 200,
        enabled       = opts.enabled       == nil and true or opts.enabled,
    }
end

local baseline = clip{}
local baseline_fp = edit_diff.fingerprint(baseline)

-- ─── neither side changed ─────────────────────────────────────────────
do
    local result = edit_diff.classify(baseline, baseline_fp, baseline)
    check("neither: kind == 'neither'", result.kind == "neither")
end

-- ─── Resolve trimmed; JVE unchanged ──────────────────────────────────
do
    local live = clip{ source_out = 280 }  -- Resolve trimmed tail by 20f
    local result = edit_diff.classify(live, baseline_fp, baseline)
    check("resolve_only: kind", result.kind == "resolve_only")
    check("resolve_only: delta source_out",
        result.live.source_out == 280)
end

-- ─── JVE moved; Resolve unchanged ────────────────────────────────────
do
    local jve_current = clip{ record_start = 1100 }
    local result = edit_diff.classify(baseline, baseline_fp, jve_current)
    check("jve_only: kind", result.kind == "jve_only")
end

-- ─── both changed → conflict ─────────────────────────────────────────
do
    local live = clip{ source_in = 120 }
    local jve_current = clip{ record_start = 1100 }
    local result = edit_diff.classify(live, baseline_fp, jve_current)
    check("both: kind == 'both' (conflict)", result.kind == "both")
end

-- ─── fingerprint is deterministic across calls ───────────────────────
do
    local a = edit_diff.fingerprint(clip{})
    local b = edit_diff.fingerprint(clip{})
    check("fingerprint deterministic", a == b)
    local c = edit_diff.fingerprint(clip{ source_in = 101 })
    check("fingerprint distinguishes 1-frame diff", a ~= c)
end

-- ─── fingerprint covers enabled flag (mute via disable is a real edit)
do
    local a = edit_diff.fingerprint(clip{ enabled = true })
    local b = edit_diff.fingerprint(clip{ enabled = false })
    check("fingerprint distinguishes enabled", a ~= b)
end

-- ─── classify rejects missing fields (fail-fast) ─────────────────────
do
    local ok = pcall(edit_diff.classify, {}, baseline_fp, baseline)
    check("classify asserts on incomplete live row", not ok)
end

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
assert(fail == 0, "test_edit_diff.lua: failures present")
print("✅ test_edit_diff.lua passed")
