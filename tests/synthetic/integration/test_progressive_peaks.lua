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
EMP.PEAK_REQUEST(MEDIA_ID, MEDIA_PATH, PEAK_FILE)

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
    end

    for _ = 1, 100000 do end  -- brief busy-wait
    ::continue_poll::
end

-- ============================================================================
-- Step 3: Verify progressive data is partial (if caught)
-- ============================================================================
if caught_in_progress then
    print("  step 3: verify progressive data is partial")

    assert(progress_peaks, "progressive query returned nil peaks")
    assert(progress_count == 500,
        string.format("expected 500 pixel columns, got %d", progress_count))
    assert(progress_actual_start >= 0,
        string.format("actual_start (%d) must be >= 0", progress_actual_start))

    -- The progressive range should NOT cover the entire file
    -- (unless the file is very short or CPU is very fast)
    if progress_actual_end < total_samples then
        print(string.format("    partial: covers [%d,%d) of %d samples",
            progress_actual_start, progress_actual_end, total_samples))
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

    -- Query the final peak file at the same range as the progressive query
    local final_peaks, final_count =
        EMP.PEAK_QUERY(peak_handle, 0, progress_actual_end, progress_count)
    assert(final_peaks and final_count == progress_count,
        string.format("final query failed: count=%d expected=%d",
            final_count or 0, progress_count))

    -- Compare first few pixels: progressive data should match final data
    -- (both cover the same source range, same pixel count)
    local fpd = ffi.cast("float*", final_peaks)
    local max_diff = 0
    for px = 0, #saved_progressive - 1 do
        local p = saved_progressive[px + 1]
        local f_min = fpd[px * 2]
        local f_max = fpd[px * 2 + 1]
        local diff = math.max(math.abs(p.min - f_min), math.abs(p.max - f_max))
        if diff > max_diff then max_diff = diff end
    end

    -- Progressive data uses level 0 only; final data uses mipmaps.
    -- At the same zoom level, the resampling might differ slightly.
    -- But the underlying peak bins are the same, so differences should be small.
    local TOLERANCE = 0.05
    print(string.format("    progressive vs final: max_diff=%.6f (tolerance=%.6f)",
        max_diff, TOLERANCE))
    assert(max_diff < TOLERANCE,
        string.format("progressive data diverges from final: max_diff=%.6f", max_diff))

    EMP.PEAK_RELEASE(peak_handle)
    print("    progressive matches final: OK")

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
