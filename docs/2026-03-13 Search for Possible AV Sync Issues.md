# Search for Possible A/V Sync Issues

**Date**: 2026-03-13
**Scope**: Full playback pipeline — PlaybackClock, AudioPump, PlaybackController, AOP, SSE, TMB audio path

---

## Architecture Summary

Epoch-based A/V sync: audio (AOP) is master clock, video (CVDisplayLink) follows via PLL steering 3%/tick toward audio-derived position. Three layers: **PlaybackClock** (epoch math), **AudioPump** (dedicated TMB->SSE->AOP thread), **PlaybackController** (CVDisplayLink ticks + PLL + frame delivery).

---

## Issues Found

### 1. CRITICAL: Reanchor Epoch Captured Before AOP Start (Play Start Offset)

**File**: `src/playback_controller.mm` — `prefillAudio()` lines 676-729

**Sequence**:
```
m_aop->Flush();                              // resets AOP playhead to 0
m_sse->Reset();
aop_playhead = m_aop->PlayheadTimeUS();      // capture epoch (~0)
m_clock.Reanchor(time_us, speed, aop_playhead);
// ... pre-fill ring buffer (10-100ms for slow codecs) ...
m_aop->Start();                              // AOP begins consuming NOW
m_clock.SetSinkBufferLatency(m_aop->SinkBufferUS());
```

**Bug**: Clock epoch captured BEFORE `Start()`. Pre-fill loop runs between Reanchor and Start (rendering up to 600ms into ring buffer). Once `Start()` fires, CoreAudio begins consuming pre-filled audio. But the clock's epoch references the pre-Start playhead value.

When pre-fill is slow (200ms due to slow decode), by the first `displayLinkTick` the AOP has consumed ~200ms of pre-filled audio. `CurrentTimeUS()` computes `elapsed = (current_aop_playhead - epoch) * speed` — this elapsed includes pre-fill rendering time as "audio consumed" time, making audio clock appear further ahead than reality. Video PLL chases phantom position.

**Symptom**: Video leads audio by pre-fill duration (~200ms) at play start. PLL corrects at ~0.03 * drift per tick at 60Hz -> ~100+ ticks (~1.7s) to converge.

**Amplified by shuttle**: Each shuttle tap calls `PLAY()` (not `SetSpeed()`), which runs the full Stop/prefillAudio/Start cycle. So this epoch race affects every shuttle tap, not just initial play.

---

### 2. LATENT: SetSpeed Flush Kills AOP, Never Restarts It

**File**: `src/playback_controller.mm` — `SetSpeed()` lines 1006-1013

**Currently unreachable**: `PLAYBACK.SET_SPEED` is bound in emp_bindings but never called from Lua. Shuttle uses `PLAY()` each time. However, the binding exists and could be called.

**Sequence**:
```cpp
m_aop->Flush();       // calls m_sink->stop() internally
m_sse->Reset();
m_audio_pump->ResetPushState();
m_fractional_frames = 0.0;
// Reanchor at new speed
int64_t new_epoch = m_aop->PlayheadTimeUS();
m_clock.Reanchor(current_time_us, signed_speed, new_epoch);
m_sse->SetTarget(current_time_us, signed_speed, ...);
// NOTE: no m_aop->Start() call anywhere
```

`Flush()` (aop.cpp line 265) calls `m_sink->stop()` + `m_io_device.close()`. After this the QAudioSink is stopped. AudioPump keeps running and calling `m_aop->WriteF32()` which fills the ring buffer, but CoreAudio never drains it because the sink is stopped. Nothing in the SetSpeed path restarts the AOP.

**Symptom**: If ever called, kills audio output permanently until next Play(). Total audio loss = total A/V desync.

---

### 3. MODERATE: Output Latency Measured Once, Not Remeasured on Device Change

**File**: `src/playback_controller.mm` — `MeasureOutputLatency()` lines 130-206, called from `ActivateAudio()`

`MeasureOutputLatency()` queries CoreAudio default output device at `ActivateAudio` time. If user switches audio output mid-session (headphones -> speakers, USB DAC -> Bluetooth), latency changes but compensation does not update. Different devices have wildly different latencies (USB DAC: 5ms, Bluetooth: 150ms+).

**Symptom**: 150ms+ persistent A/V offset after switching audio outputs. Persists until next Play.

---

### 4. MODERATE: PLL Accumulator Clamp Prevents Video Catching Up to Audio

**File**: `src/playback_controller.mm` — `advancePosition()` line 1436

```cpp
m_fractional_frames = std::max(0.0, m_fractional_frames);
```

This prevents the accumulator from going negative, meaning PLL can only SLOW video (reduce accumulator), never ACCELERATE it. If audio gets ahead of video (negative drift), PLL tries to subtract from the accumulator but can't push it below 0. Video can never catch up to audio that's ahead of it.

**Symptom**: One-sided sync correction. Video-behind-audio drift persists; only video-ahead-of-audio drift self-corrects.

---

### 5. MINOR: Fractional Frame Loss on Speed Change

**File**: `src/playback_controller.mm` — `SetSpeed()` line 1009

```cpp
m_fractional_frames = 0.0;
```

Discards fractional video position. Minor for single speed changes, but repeated JKL shuttle taps accumulate lost fractions causing micro-stutter.

---

### 6. MINOR: Audio Pump Cache Warming Blocks Pump Thread

**File**: `src/playback_controller.mm` — `pumpLoop()` line 343

```cpp
m_tmb->GetMixedAudio(warm_start, warm_end);  // result discarded -- cache warming
```

Full decode+mix cycle to warm cache. For slow codecs, adds latency to each pump cycle, potentially starving AOP ring buffer if pump cycle takes longer than expected.

---

### 7. MODERATE: Boundary Auto-Stop Doesn't Stop AudioPump Immediately

**File**: `src/playback_controller.mm` — `displayLinkTick()` lines 1283-1296

When hitting a sequence boundary in non-shuttle mode:
```cpp
m_playing.store(false);           // stops video ticks
dispatch_async(main_queue, ^{     // async: stopDisplayLink + reportPosition
    stopDisplayLink();
    reportPosition(boundary_frame, true);
});
return;                           // exits tick — but AudioPump keeps running
```

AudioPump only stops in `Stop()` (line 855). The boundary auto-stop sets `m_playing=false` and dispatches cleanup async, but never calls `Stop()`. The AudioPump thread keeps running, continues writing to AOP, and CoreAudio keeps draining. Audio plays past the visual stop point until Lua's `_on_controller_position(frame, stopped=true)` callback fires and calls `engine:stop()` which calls `PLAYBACK.STOP()`.

**Symptom**: A few extra frames of audio (~50-100ms) play after video stops at boundary. Perceivable as a "tail" of audio on stop.

---

### 8. MODERATE: Dual Clock Divergence (Lua vs C++)

**File**: `src/lua/core/media/audio_playback.lua` lines 106-137 vs `src/playback_controller.mm` lines 103-128

Lua `audio_playback` has its own epoch-based clock (`M.media_anchor_us`, `M.aop_epoch_playhead_us`, `M.speed`) with **hardcoded** `OUTPUT_LATENCY_US = 150000`. C++ `PlaybackClock` measures actual device latency via `MeasureOutputLatency()` (CoreAudio query) + `SetSinkBufferLatency()`.

During Phase 3 C++ playback, the Lua clock is mostly dormant. But `audio_playback.stop()` calls `M.get_time_us()` to capture the "heard time" for park position (line 499). If the Lua clock's latency differs from C++ (which it will — C++ measures real values, Lua uses 150ms constant), the park-after-stop position diverges from what C++ was displaying.

**Symptom**: After stopping, the parked frame may differ by a few frames from where video appeared to stop. Subtle but visible if stopping during fast motion.

---

### 9. MODERATE: PlaybackClock Torn Reads on Apple Silicon (ARM relaxed atomics)

**File**: `src/playback_controller.mm` — `Reanchor()` lines 97-101, `CurrentTimeUS()` lines 103-128

`Reanchor()` stores three atomics with `memory_order_relaxed`:
```cpp
m_media_anchor_us.store(media_time_us, memory_order_relaxed);
m_aop_epoch_us.store(aop_playhead_us, memory_order_relaxed);
m_speed.store(speed, memory_order_relaxed);
```

`CurrentTimeUS()` loads the same three with `memory_order_relaxed`. On ARM (Apple Silicon), relaxed stores have no ordering guarantees between each other. A concurrent reader (AudioPump thread or CVDisplayLink thread) can observe the NEW anchor with the OLD epoch, or vice versa.

**Worst case**: Seek from frame 1200 (50s at 24fps) to frame 0. Old anchor = 50000000us, new anchor = 0. Old epoch = some large value, new epoch = 0. If reader sees OLD anchor (50000000) with NEW epoch (0): `elapsed = playhead - 0`, `result = 50000000 + playhead * speed` — a massive forward jump. The teleport assert (delta >= 240 frames) would crash.

On x86 this is safe (TSO provides implicit release/acquire). On Apple Silicon (ARM), this is a genuine data race.

**Fix**: Use `memory_order_release` on the last store in `Reanchor()`, `memory_order_acquire` on the first load in `CurrentTimeUS()`. Or use a single `std::atomic<struct>` / seqlock.

---

### 10. MINOR: Double AOP Playhead Query Per Tick

**File**: `src/playback_controller.mm` — `advancePosition()` lines 1361-1439

The AOP playhead is queried twice per tick:
1. Line 1369: for audio-master stall detection (`buf`, `aop_playhead`, `audio_time_us`)
2. Line 1432: for PLL drift calculation (different `aop_playhead`, different `audio_time_us`)

Between these two reads, the AOP may have advanced (AudioPump pushing, CoreAudio draining). The stall detection and PLL use slightly different clock snapshots. In theory, stall detection could see `buf=0` (engaging audio-master) while PLL sees `buf>0` from a later read, though this path is unreachable since audio-master returns early.

More concerning: the PLL drift calculation at line 1432 uses a different playhead than the stall detection at line 1369. If stall detection decides NOT to engage audio-master (buf > 0), PLL runs with a newer playhead — inconsistent but harmless in practice (both are within ~15ms).

**Fix**: Query AOP playhead once at the top and pass it through.

---

### 11. MINOR: PlayBurst Doesn't Set Sink Buffer Latency

**File**: `src/playback_controller.mm` — `PlayBurst()` lines 1024-1082

`PlayBurst()` calls `m_aop->Start()` (line 1075) but never calls `m_clock.SetSinkBufferLatency(m_aop->SinkBufferUS())`. Since PlayBurst creates a fresh QAudioSink (via Flush→Start), the sink buffer may differ from the previous Start. Clock compensation is stale or default.

**Symptom**: Negligible for 40-60ms bursts. Only matters if PlayBurst is extended to longer durations.

---

### 12. MODERATE: FrameFromTimeUS / FrameTime::to_us() Asymmetric Rounding

**Files**: `src/playback_controller.mm` line 229 vs `src/editor_media_platform/include/editor_media_platform/emp_time.h` line 30

Two inverse conversions use different rounding:

```cpp
// FrameTime::to_us() — round-half-up
(frame * 1000000LL * rate.den + rate.num / 2) / rate.num

// PlaybackClock::FrameFromTimeUS() — floor (truncation)
(time_us * fps_num) / (1000000LL * fps_den)
```

For integer frame rates (24, 25, 30) these are consistent: frame→us→frame round-trips cleanly. But for non-integer rates like 23.976fps (24000/1001), `to_us()` rounds up by half a tick (~21us), and `FrameFromTimeUS()` truncates. The round-trip `FrameFromTimeUS(to_us(frame))` can return `frame - 1`.

**Impact path**: In `advancePosition()` audio-master mode (lines 1397-1420), the video frame is derived from audio clock time via `FrameFromTimeUS(audio_time_us)`. The audio clock is anchored using `FrameTime::to_us()` in `prefillAudio()`. If the rounding mismatch causes a 1-frame shortfall, video systematically displays the previous frame — a permanent 1-frame (~41ms at 23.976) audio-video offset whenever audio-master mode engages.

**Symptom**: At 23.976fps, video may lag audio by exactly 1 frame (~41ms) during audio-master mode (empty AOP buffer, e.g. initial frames or after stall). Self-corrects when PLL re-engages but recurs each time audio-master activates.

---

### 13. MODERATE: execute_mix_range Multi-Track Audio Misalignment

**File**: `src/editor_media_platform/src/emp_timeline_media_buffer.cpp` — `execute_mix_range()` lines 1445-1504

When mixing multiple audio tracks, the mixing loop accumulates each track's PCM into the output buffer starting at sample index 0:

```cpp
for (size_t i = 0; i < track_results.size(); ++i) {
    auto& pcm = track_results[i];
    // ... volume scaling ...
    for (int s = 0; s < sample_count; ++s) {
        output[s] += pcm_data[s] * volume;  // always starts at index 0
    }
}
```

Each track's `GetTrackAudio()` returns PCM for the requested `[start_time_us, end_time_us)` range. But if Track 1 has a clip covering the full range while Track 2 has a clip that starts mid-range, `GetTrackAudio()` for Track 2 returns a shorter PCM buffer starting from its clip's beginning. This shorter buffer is added starting at sample 0, misaligning it with Track 1's audio.

**Symptom**: When two audio tracks have clips starting at different timeline positions and both are audible within the same mix window, the later-starting track's audio is shifted earlier in time by the gap between the two clips' start positions. The offset equals the distance between the request start and the second clip's start. In practice this manifests as a brief audio timing glitch at clip boundaries where tracks overlap — likely a few milliseconds to tens of milliseconds depending on mix chunk size (200ms chunks from mix_thread_loop).

---

## Summary

| # | Issue | Severity | Symptom |
|---|-------|----------|---------|
| 1 | Reanchor epoch captured before AOP Start | Critical | Video leads audio by ~200ms at play start, slowly converges over ~1.7s |
| 2 | SetSpeed Flush kills AOP, never restarts (latent) | Latent | If ever called: total audio loss after speed change |
| 9 | PlaybackClock torn reads on ARM (relaxed atomics) | Moderate | Transient clock jump on seek → teleport assert crash |
| 3 | Output latency not remeasured on device switch | Moderate | 150ms+ persistent offset after switching audio outputs |
| 4 | PLL clamp prevents video catching up to audio | Moderate | Video-behind-audio drift never self-corrects |
| 7 | Boundary auto-stop doesn't stop AudioPump | Moderate | ~50-100ms audio tail after visual stop at boundary |
| 8 | Dual clock divergence (Lua 150ms vs C++ measured) | Moderate | Park position after stop may differ by a few frames |
| 5 | Fractional frame loss on speed change | Minor | Micro-stutter on repeated JKL taps |
| 6 | Cache warming blocks pump thread | Minor | Intermittent audio stutter with slow codecs |
| 12 | FrameFromTimeUS / to_us() asymmetric rounding | Moderate | 1-frame (41ms) video lag at 23.976fps during audio-master mode |
| 13 | execute_mix_range multi-track misalignment | Moderate | Audio timing glitch when tracks have clips at different start positions |
| 10 | Double AOP playhead query per tick | Minor | Inconsistent stall detection vs PLL (harmless) |
| 11 | PlayBurst missing sink buffer latency | Minor | Negligible for short bursts |
