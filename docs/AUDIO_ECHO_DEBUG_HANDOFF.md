# Audio Echo Bug - Debug Handoff

## Problem
JKL shuttle playback has audio echo/stutter - sounds like duplicated audio slightly behind video.

## What We Fixed (partially working)

### 1. Dual-Asset Architecture (DONE)
- `src/lua/ui/media_cache.lua` - NEW file
- Opens file TWICE: separate AVFormatContext for video vs audio
- Prevents seek conflicts that caused h264 decoder corruption

### 2. Resampler Reset (DONE)
- `src/editor_media_platform/src/impl/ffmpeg_resample.cpp` - added `reset()` method
- `src/editor_media_platform/src/emp_reader.cpp:301` - calls `resample_ctx.reset()` after seek
- Clears SwrContext FIFO to prevent old samples mixing with new

### 3. Duplicate PCM Push Prevention (DONE but echo persists)
- `src/lua/ui/audio_playback.lua` - only push to SSE when NEW data fetched
- Test: `tests/test_audio_no_duplicate_push.lua` - PASSES but real echo continues

## Likely Remaining Issue

SSE source buffer (`src/scrub_stretch_engine/sse.cpp:18-65`) accumulates chunks but `get_samples()` only returns the FIRST matching chunk for a time. If overlapping chunks exist, it doesn't deduplicate.

**Check `get_samples()` at line 44-65:**
- Iterates `m_chunks` and returns first match
- Multiple chunks covering same time = first one wins, but they still accumulate
- `trim()` only removes OLD data, not duplicates

## Next Steps

1. **Add deduplication to SSE::push_source** - Before adding new chunk, remove any existing chunks that overlap the new time range

2. **Or add overlap detection** - In `push_source()`, warn/assert if new chunk overlaps existing

3. **Debug logging** - Add logging in real app to see actual PUSH_PCM calls with timestamps

4. **Check playback_controller** - `set_media_time()` is called every video frame, which calls `SSE.SET_TARGET`. Verify this doesn't cause re-rendering of same audio.

## Key Files
- `src/lua/ui/media_cache.lua` - unified cache with dual assets
- `src/lua/ui/audio_playback.lua` - audio pump, PCM cache
- `src/lua/ui/playback_controller.lua` - JKL shuttle, calls media_cache.set_playhead()
- `src/scrub_stretch_engine/sse.cpp` - WSOLA time-stretch engine
- `tests/test_audio_no_duplicate_push.lua` - test for duplicate push bug

## Test Command
```bash
cd /Users/joe/Local/jve-spec-kit-claude
./tests/run_lua_tests_all.sh  # All 268 tests should pass
```
