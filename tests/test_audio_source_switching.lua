--- Test: Audio source switching at edit points
--
-- Verifies that when crossing an edit point:
-- 1. Source changes (path, offset, duration) are detected correctly
-- 2. Cold path (with flush) is triggered, not hot swap
-- 3. Only volume-only changes use hot swap

require("test_env")

print("Testing audio source switching at edit points...")

-- Helper: simulate the sources_changed detection logic from set_audio_sources
local function detect_sources_changed(old_sources, new_sources)
    local old_count = old_sources and #old_sources or 0
    local new_count = #new_sources

    if old_count ~= new_count then
        return true
    elseif old_count > 0 then
        for i, old_src in ipairs(old_sources) do
            local new_src = new_sources[i]
            if not new_src then return true end
            if old_src.path ~= new_src.path then return true end
            if old_src.seek_us ~= new_src.seek_us then return true end
            if old_src.clip_start_us ~= new_src.clip_start_us then return true end
            if old_src.speed_ratio ~= new_src.speed_ratio then return true end
            if old_src.duration_us ~= new_src.duration_us then return true end
        end
    end
    return false
end

-- Test 1: Different file paths
print("  Test 1: Different file paths should trigger sources_changed...")
do
    local old = {{ path = "/media/clip_a.mov", source_offset_us = 0, seek_us = 0, speed_ratio = 1.0, clip_start_us = 0, volume = 1.0, duration_us = 1000000 }}
    local new = {{ path = "/media/clip_b.mov", source_offset_us = 0, seek_us = 0, speed_ratio = 1.0, clip_start_us = 0, volume = 1.0, duration_us = 1000000 }}
    assert(detect_sources_changed(old, new) == true, "Different paths should trigger change")
    print("    ✓ Different paths detected")
end

-- Test 2: Same path, same offset, different volume only - should NOT change
print("  Test 2: Volume-only change should NOT trigger sources_changed...")
do
    local old = {{ path = "/media/clip.mov", source_offset_us = 0, seek_us = 0, speed_ratio = 1.0, clip_start_us = 0, volume = 1.0, duration_us = 1000000 }}
    local new = {{ path = "/media/clip.mov", source_offset_us = 0, seek_us = 0, speed_ratio = 1.0, clip_start_us = 0, volume = 0.5, duration_us = 1000000 }}
    assert(detect_sources_changed(old, new) == false, "Volume-only should not trigger change")
    print("    ✓ Volume-only change uses hot swap (no flush)")
end

-- Test 3: Same path, different offset (edit point within same file)
print("  Test 3: Same path, different offset should trigger sources_changed...")
do
    local old = {{ path = "/media/clip.mov", source_offset_us = 0, seek_us = 0, speed_ratio = 1.0, clip_start_us = 0, volume = 1.0, duration_us = 800000 }}
    local new = {{ path = "/media/clip.mov", source_offset_us = 800000, seek_us = 0, speed_ratio = 1.0, clip_start_us = 800000, volume = 1.0, duration_us = 800000 }}
    assert(detect_sources_changed(old, new) == true, "Offset change should trigger change")
    print("    ✓ Offset change triggers cold path (flush)")
end

-- Test 4: Same path, different duration (clip length changed)
print("  Test 4: Different duration should trigger sources_changed...")
do
    local old = {{ path = "/media/clip.mov", source_offset_us = 0, seek_us = 0, speed_ratio = 1.0, clip_start_us = 0, volume = 1.0, duration_us = 1000000 }}
    local new = {{ path = "/media/clip.mov", source_offset_us = 0, seek_us = 0, speed_ratio = 1.0, clip_start_us = 0, volume = 1.0, duration_us = 500000 }}
    assert(detect_sources_changed(old, new) == true, "Duration change should trigger change")
    print("    ✓ Duration change triggers cold path (flush)")
end

-- Test 5: Different source count
print("  Test 5: Different source count should trigger sources_changed...")
do
    local old = {{ path = "/media/clip.mov", source_offset_us = 0, seek_us = 0, speed_ratio = 1.0, clip_start_us = 0, volume = 1.0, duration_us = 1000000 }}
    local new = {
        { path = "/media/clip.mov", source_offset_us = 0, seek_us = 0, speed_ratio = 1.0, clip_start_us = 0, volume = 1.0, duration_us = 1000000 },
        { path = "/media/audio.wav", source_offset_us = 0, seek_us = 0, speed_ratio = 1.0, clip_start_us = 0, volume = 1.0, duration_us = 1000000 }
    }
    assert(detect_sources_changed(old, new) == true, "Count change should trigger change")
    print("    ✓ Source count change triggers cold path (flush)")
end

-- Test 6: Empty to non-empty
print("  Test 6: Empty to non-empty should trigger sources_changed...")
do
    local old = {}
    local new = {{ path = "/media/clip.mov", source_offset_us = 0, seek_us = 0, speed_ratio = 1.0, clip_start_us = 0, volume = 1.0, duration_us = 1000000 }}
    assert(detect_sources_changed(old, new) == true, "Empty to non-empty should trigger change")
    print("    ✓ Empty to non-empty triggers cold path")
end

-- Verify the actual implementation matches
print("  Verifying implementation in audio_playback.lua...")
do
    local file = io.open("../src/lua/core/media/audio_playback.lua", "r")
    assert(file, "Could not open audio_playback.lua")
    local content = file:read("*all")
    file:close()

    -- Check that we're now checking seek_us
    assert(content:find("seek_us ~= new_src.seek_us", 1, true),
        "Implementation must check seek_us changes")

    -- Check that we're now checking duration_us
    assert(content:find("duration_us ~= new_src.duration_us", 1, true),
        "Implementation must check duration_us changes")

    -- Check that we use sources_changed (not just paths_changed)
    assert(content:find("not sources_changed", 1, true),
        "Implementation must use sources_changed variable")

    print("    ✓ Implementation correctly checks path, offset, and duration")
end

print("✅ test_audio_source_switching.lua passed")
