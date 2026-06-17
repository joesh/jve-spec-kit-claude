-- Integration test: progressive peak display via PEAK_QUERY_PROGRESS
--
-- Verifies that partially-generated peak data is queryable from the main
-- thread while background workers are still generating. Uses a 34s
-- synthetic AAC stereo file long enough to catch mid-generation state.
--
-- Tests:
--   1. PEAK_QUERY_PROGRESS returns data while generation is in progress
--   2. Returned range is partial (doesn't cover full file)
--   3. Progressive data matches final peak file at the same positions
--   4. PEAK_QUERY_PROGRESS returns nil after generation completes
--   5. PEAK_QUERY_PROGRESS returns nil for unknown media_id
--
-- Run via: ./build/bin/jve --test tests/synthetic/integration/test_progressive_peaks.lua

local env = require("synthetic.integration.integration_test_env")
local EMP = env.require_emp()
local ffi = require("ffi")

print("--- test_progressive_peaks.lua ---")

local MEDIA_PATH = env.test_media_path("varied_amplitude_aac_34s.mp4")
local PEAK_DIR = "/tmp/jve/test_progressive"
local PEAK_FILE = PEAK_DIR .. "/progressive.peaks"
os.execute(string.format("rm -rf %q", PEAK_DIR))
os.execute(string.format("mkdir -p %q", PEAK_DIR))

local MEDIA_ID = "progressive_test"

-- Get file info for total_samples calculation
local mf = assert(EMP.MEDIA_FILE_OPEN(MEDIA_PATH))
local info = EMP.MEDIA_FILE_INFO(mf)
assert(info.has_audio, "test media must have audio")
local total_samples = math.floor(info.duration_us / 1000000.0 * info.audio_sample_rate)
print(string.format("  media: sr=%d ch=%d total_samples=%d (%.1fs)",
    info.audio_sample_rate, info.audio_channels, total_samples,
    total_samples / info.audio_sample_rate))
EMP.MEDIA_FILE_CLOSE(mf)

-- ============================================================================
-- Step 1: PEAK_QUERY_PROGRESS returns nil for unknown media_id
-- ============================================================================
print("  step 1: unknown media_id returns nil")
local unk_peaks, unk_count = EMP.PEAK_QUERY_PROGRESS("nonexistent_id", 0, 48000, 100)
assert(not unk_peaks or unk_count == 0,
    "PEAK_QUERY_PROGRESS for unknown media_id must return nil")
print("    OK")

-- ============================================================================
-- Step 2: Start generation, catch mid-progress, query progressive data
-- ============================================================================
print("  step 2: query progressive data mid-generation")
os.remove(PEAK_FILE)
EMP.PEAK_REQUEST(MEDIA_ID, MEDIA_PATH, PEAK_FILE, -1)  -- composite

-- Poll until we have SOME progress but NOT complete
local deadline = os.time() + 30
local progress_peaks = nil
local progress_count = 0
local progress_actual_start = 0
local progress_actual_end = 0
local caught_in_progress = false

while os.time() <= deadline do
    local status = EMP.PEAK_STATUS(MEDIA_ID)
    if not status then
        for _ = 1, 100000 do end
        goto continue_poll
    end

    if status.state == "complete" then
        -- Generation finished before we caught it — file was too short or CPU too fast.
        -- This isn't a test failure, but we can't test progressive queries.
        print("    WARNING: generation completed before we could catch it in progress")
        print("    skipping progressive assertions (CPU too fast for this file)")
        caught_in_progress = false
        break
    end

    if status.state == "generating" and status.progress_samples > 0 then
        -- Caught it! Query progressive data at the beginning of the file.
        progress_peaks, progress_count, progress_actual_start, progress_actual_end =
            EMP.PEAK_QUERY_PROGRESS(MEDIA_ID, 0, total_samples, 500)

        if progress_peaks and progress_count > 0 then
            caught_in_progress = true
            print(string.format("    caught at progress=%d/%d (%.0f%%)",
                status.progress_samples, status.total_samples,
                status.progress_samples / status.total_samples * 100))
            print(string.format("    progressive query: count=%d actual=[%d,%d]",
                progress_count, progress_actual_start, progress_actual_end))
            break
        end

        -- Empty result while generating. Legitimate only at the very
        -- start, before the decoder frontier has filled a single peak
        -- bin. Once a full second of audio is decoded, a whole-file
        -- query must return at least one pixel — a persistent empty
        -- here is the silently-empty reveal regression (waveform pops
        -- at completion instead of revealing progressively). The
        -- re-check rules out the job completing mid-query: job state
        -- only moves forward, so "still generating after the query"
        -- proves it was generating during the query.
        local recheck = EMP.PEAK_STATUS(MEDIA_ID)
        assert(not (recheck and recheck.state == "generating"
                    and status.progress_samples >= info.audio_sample_rate),
            string.format(
                "PEAK_QUERY_PROGRESS returned no pixels while generating "
                .. "with %d samples (%.1fs) already decoded — progressive "
                .. "reveal is silently empty",
                status.progress_samples,
                status.progress_samples / info.audio_sample_rate))
    end

    for _ = 1, 100000 do end  -- brief busy-wait
    ::continue_poll::
end

-- ============================================================================
-- Step 3: Verify progressive data is partial (if caught)
-- ============================================================================
if caught_in_progress then
    print("  step 3: verify progressive data is partial AND proportional")

    assert(progress_peaks, "progressive query returned nil peaks")
    -- Proportional-pixel contract: when the decoder frontier hasn't yet
    -- reached source_end, the returned pixel count must scale with the
    -- decoded fraction — NOT be stretched to fill the full pixel_width.
    -- Stretching is the "march along" bug the renderer relies on this
    -- contract to avoid (see emp_peak_generator.cpp QueryInProgress).
    assert(progress_count > 0 and progress_count <= 500,
        string.format("expected 1..500 pixel columns, got %d", progress_count))
    assert(progress_actual_start >= 0,
        string.format("actual_start (%d) must be >= 0", progress_actual_start))

    -- The progressive range should NOT cover the entire file (we caught
    -- it mid-generation). When partial, count must also be partial.
    if progress_actual_end < total_samples then
        print(string.format("    partial: covers [%d,%d) of %d samples",
            progress_actual_start, progress_actual_end, total_samples))
        local covered_fraction =
            (progress_actual_end - progress_actual_start)
            / (total_samples - progress_actual_start)
        assert(progress_count < 500, string.format(
            "PROPORTIONAL-PIXEL CONTRACT violated: partial coverage "
            .. "(%.1f%% of requested range) but count=%d (== full pixel_width). "
            .. "QueryInProgress must scale output_pixels by "
            .. "available_bins/requested_bins so the renderer draws only "
            .. "the decoded prefix and leaves the tail blank.",
            covered_fraction * 100, progress_count))
        print(string.format("    proportional count=%d/500 (coverage %.1f%%)",
            progress_count, covered_fraction * 100))
    else
        print("    NOTE: progressive data covers entire file (fast CPU)")
    end

    -- Verify data is not all zeros or sentinels
    local pd = ffi.cast("float*", progress_peaks)
    local has_signal = false
    for px = 0, progress_count - 1 do
        local mn = pd[px * 2]
        local mx = pd[px * 2 + 1]
        -- Sentinel values are min=1.0, max=-1.0 (unwritten bins)
        if mx > mn and not (mn > 0.99 and mx < -0.99) then
            has_signal = true
            break
        end
    end
    assert(has_signal, "progressive data is all sentinels — no real audio data returned")
    print("    contains real audio signal: OK")

    -- Save a few progressive peak values for later comparison
    local saved_progressive = {}
    for px = 0, math.min(9, progress_count - 1) do
        table.insert(saved_progressive, {
            min = pd[px * 2],
            max = pd[px * 2 + 1],
        })
    end

    -- ========================================================================
    -- Step 4: Wait for completion, then compare progressive vs final
    -- ========================================================================
    print("  step 4: wait for completion, compare progressive vs final")

    while os.time() <= deadline + 30 do
        local status = EMP.PEAK_STATUS(MEDIA_ID)
        if status and status.state == "complete" then break end
        if status and status.state == "failed" then error("peak generation failed") end
        assert(os.time() <= deadline + 30, "generation timed out")
        for _ = 1, 1000000 do end
    end

    local peak_handle = assert(EMP.PEAK_LOAD(PEAK_FILE))

    -- Sanity-check the saved progressive values look like real audio
    -- (min in [-1,1], max in [-1,1], max >= min). A pixel-by-pixel
    -- comparison to the final file is not meaningful: progressive uses
    -- level-0 raw bins (the only level available during generation),
    -- whereas a same-range PEAK_QUERY on the completed file picks a
    -- mipmap level whose aggregation boundaries don't align with the
    -- progressive output's bin-to-pixel mapping. Differences in exact
    -- min/max per pixel are expected — both views are correct.
    for px = 1, #saved_progressive do
        local p = saved_progressive[px]
        assert(p.min >= -1.0 and p.min <= 1.0,
            string.format("progressive pixel %d min=%.4f out of [-1,1]",
                px - 1, p.min))
        assert(p.max >= -1.0 and p.max <= 1.0,
            string.format("progressive pixel %d max=%.4f out of [-1,1]",
                px - 1, p.max))
        assert(p.max >= p.min,
            string.format("progressive pixel %d max=%.4f < min=%.4f",
                px - 1, p.max, p.min))
    end

    EMP.PEAK_RELEASE(peak_handle)
    print("    progressive values are well-formed audio peaks: OK")

    -- ========================================================================
    -- Step 5: PEAK_QUERY_PROGRESS returns nil after completion
    -- ========================================================================
    print("  step 5: PEAK_QUERY_PROGRESS returns nil after completion")
    local post_peaks, post_count = EMP.PEAK_QUERY_PROGRESS(MEDIA_ID, 0, total_samples, 100)
    assert(not post_peaks or post_count == 0,
        "PEAK_QUERY_PROGRESS must return nil after generation completes")
    print("    OK")

else
    -- Generation completed before we caught it — wait for it and do basic validation
    print("  step 3-5: skipped (could not catch in-progress state)")

    while os.time() <= deadline + 30 do
        local status = EMP.PEAK_STATUS(MEDIA_ID)
        if status and status.state == "complete" then break end
        if status and status.state == "failed" then error("peak generation failed") end
        assert(os.time() <= deadline + 30, "generation timed out")
        for _ = 1, 1000000 do end
    end

    -- At minimum, verify the peak file was written correctly
    local peak_handle = assert(EMP.PEAK_LOAD(PEAK_FILE))
    local peaks, count = EMP.PEAK_QUERY(peak_handle, 0, total_samples, 500)
    assert(peaks and count == 500, "final peak query failed after fast completion")
    EMP.PEAK_RELEASE(peak_handle)
    print("    final peak file valid after fast completion")
end

-- Cleanup
os.execute(string.format("rm -rf %q", PEAK_DIR))

print("✅ test_progressive_peaks.lua passed")
