# Audio Stack — Lessons Learned & Future Direction

**Authored:** 2026-06-23 (session that addressed the SSE flush race)
**Status:** Living doc — update as we learn more
**Scope:** Records the constraint we hit during the SSE flush-race fix, the three design options considered, why we shipped the hybrid, and what a from-scratch rewrite would actually look like.

---

## 1. The constraint we discovered

**QAudioSink on macOS cannot live on a non-main thread.** Specifically:

- The macOS backend (`QDarwinAudioSink`) creates internal child `QObject`s that expect the owner thread's affinity. Moving the sink to another thread surfaces: *"Cannot create children for a parent that is in a different thread. (Parent is QDarwinAudioSink … current thread is AudioThread)"*
- QAudioSink's pull mode is implemented as **push-with-timer** internally on macOS — a Qt timer drives `readData()` calls on the owner thread's event loop. **No event loop on the owner thread → no pulls.** Adds ~10 ms latency floor as a side effect.
- `QAudioSink` is not documented reentrant. Qt convention: absence of explicit reentrancy marking = assume main-thread-only.
- Failure mode when the sink is created on a thread without a Qt event loop: **one successful `readData()` then the stream stalls.** Matches our observed `aop_playhead > 0` (PLL releases audio-master) followed by zero further progress (PLL flails, video crawls).

Sources:
- [Qt forum: How to stream audio to QAudioSink in a separate thread](https://forum.qt.io/topic/133711/how-to-stream-audio-to-qaudiosink-in-a-separate-thread)
- [Qt forum: QAudioSink potential bug (macOS timer-driven ring buffer)](https://forum.qt.io/topic/140465/qt-6-x-qaudiosink-potential-bug/21)
- [QAudioSink class docs](https://doc.qt.io/qt-6/qaudiosink.html)

**The 33-min lesson:** before any plan that hands a Qt object to a non-main thread, web-search `<QtClass> thread affinity <platform>` and `<QtClass> reentrant`. Two minutes of search would have killed option (a) before any code was written. See `feedback_search_qt_threading_before_committing.md`.

---

## 2. The problem we are solving

**SSE (ScrubStretchEngine) flush race during mid-play state changes.**

Today, mute/solo and `SetSpeed` direction-flip call `prefillAudioAtTime` on **main**, which calls `m_sse->Reset(...)`, `m_sse->SetTarget(...)`, and pushes prefill PCM. Simultaneously the **AudioPump thread** is calling `m_sse->Render(...)` / `m_sse->CurrentTimeUS()` / `m_sse->PushSourcePcm(...)` in its render cycle. SSE has no internal locking (mutex-less pimpl). The two threads racing on its mutable state surfaces as occasional SIGSEGV in `test_mix_change_keeps_playing` (the originally-flaky test that triggered this work).

**Goal:** one thread touches SSE during any given window. Specifically during mid-play state changes, the pump must not be in `Render` while main is in `Reset`.

---

## 3. The three options

### Option (a) — Pump owns SSE *and* QAudioSink end-to-end

Pump thread is the sole owner of both SSE and AOP/QAudioSink. Main signals the pump via `RequestFlush(time, dir, speed)`; pump's loop services it at the top of the next cycle (calls `prefillAudioAtTime` on the pump thread); pump continues into normal render.

**Why we tried it:** cleanest contract — one thread owns everything audio-related, asserts catch any future violations, no handoff dance.

**Why it failed:** QAudioSink-on-non-main-thread constraint above. Even with AOP's sink lazily created on the pump thread, the sink completed one `readData()` then stalled because the pump has no Qt event loop, so its internal timer never fired again.

**Cost spent:** ~33 min implementing before behavioral testing revealed the issue. Cost would have been 2 min of web search.

### Option 2 — Pump-pause with main-side flush

Pump signals "paused" at a flag, main does SSE work (and AOP work, which already lives on main), pump resumes.

**Negatives previously discussed:**
- Pause flag is convention only — no runtime enforcement; silent corruption if a future edit calls SSE outside the pause window.
- Two writers to `m_audio_master_position` / dry / healthy counters (main during flush, pump during play) without atomics → torn reads from DisplayLink reader.
- Sleep-poll on a bool → CPU-tight-spin or coarse latency.
- Resume race: main signals done, pump wakes mid-cycle and reads stale SSE state.
- Testing: how do you prove the discipline holds?

### Option 2′ — **Hybrid** (what we shipped)

Option 2's pump-pause + the runtime contracts built during (a).

| Concern with plain option 2 | Hybrid fix |
|---|---|
| Pause flag is convention only | SSE `assert_owner_thread()` at every public method → loud crash on violation |
| Torn reads on audio-master state | Atomic<bool>/atomic<int> for `m_audio_master_position` + dry/healthy counters |
| Sleep-poll vs latency tradeoff | `condition_variable wait_for` — wakes on signal, no polling |
| Resume race | Owner-thread handoff IS the synchronization: pump can't touch SSE until `SetOwnerThread(pump_tid)` lands |
| Untestable discipline | Asserts ARE the test; any wrong-thread call crashes in dev |

**Flow:**

Cold-start (`Play`): main calls `prefillAudioAtTime` (AOP.Start + SSE Reset/SetTarget/prefill), THEN `pump->Start(...)`. Pump claims SSE owner in its first cycle.

Mid-play flush (mute/solo/SetSpeed direction-flip):
1. Main: `pump->RequestFlush(time, dir, speed)` — sets pending under mutex, notifies pump.
2. Pump at top of next cycle: `m_sse->ClearOwnerThread()`, signals "released" CV, blocks on "resume" CV.
3. Main: `SetOwnerThread(main_tid)` → SSE work (`Reset` + `SetTarget` + push prefill PCM) AND AOP work (`Flush` + `Start`) — all on main, all assertions pass.
4. Main: `ClearOwnerThread()`, signals "resume" CV.
5. Pump: re-claims `SetOwnerThread(pump_tid)`, resumes normal cycle.

**Pieces kept from (a) implementation:**
- SSE owner-thread atomic + assert (`sse.h` / `sse.cpp`) — highest-value piece, encodes contract as runtime invariant.
- Atomicized `m_audio_master_position` / dry / healthy counters (`playback_controller.h`).
- `AudioPump::RequestFlush` + condition_variable plumbing (handler now triggers main-side handoff, not pump-side work).

**Pieces reverted from (a):**
- `AOP::init()` deferred-sink-creation → restore init-time sink on main.
- Lua `acquire_for` AOP.START removal → restore.
- `Play()`'s `StartWithInitialFlush` → revert to `prefillAudio` on main + `pump->Start`.
- `SetSpeed` / `FlushAudioForMixChange` flush-handler-on-pump → handler runs on MAIN.

---

## 4. From-scratch design (the architecturally-correct end state)

**Stop using QAudioSink. Drive CoreAudio AudioUnit (or AVAudioEngine) directly.**

```
Producer thread          Lock-free SPSC ring         CoreAudio RT callback
  pulls TMB                 (f32 interleaved,           runs on Core Audio's
  runs SSE                   power-of-2, atomic           own RT-priority thread,
  fills ring                 read/write indices)          NOT a Qt thread
       │                          │                            │
       │                          ▼                            ▼
       │                  ┌───────────────┐            ┌────────────────┐
       │                  │ State snapshot│            │ HW timestamp   │
       └─────────────────▶│ ptr (atomic)  │◀───────────│ → authoritative│
        publishes new      │ immutable per │             │ clock for video│
        snapshot on        │ version       │             └────────────────┘
        mute/solo/speed    └───────────────┘
```

**What disappears:**

| Today / hybrid | From scratch |
|---|---|
| `audio_output_platform` QAudioSink wrapper | Thin AudioUnit/AVAudioEngine wrapper (no thread-affinity worries) |
| `AudioPump` class + flush condvars + exit ritual | Producer thread is a plain loop filling the ring |
| SSE owner-thread atomic + assert | SSE only ever on producer; no other thread to defend against |
| Mid-play flush handshake | Atomic ptr-swap of immutable state snapshot |
| PLL (`m_audio_master_position`, drift, healthy/dry, fractional-frames guard) | Likely deletable — CoreAudio gives HW timestamps. **Caveat:** screen-refresh clock vs audio-device clock can still drift; a smaller PLL or rate-matching may still be needed; verify before committing to deletion. |
| Cold-start vs mid-play distinction | Same code path: publish snapshot, drain + refill |
| `JVE_LOG_EVENT(Ticks, …)` cycle steps 0–7 | Producer loop is ~20 lines |

**What stays the same:** TMB (pre-decoded source buffer), SSE math, Lua command layer.

**Why snapshot beats handshake:** Immutable + versioned. Producer reads at cycle start, works through with a consistent view, sees next version next cycle. No half-state ever observable. No locks. No condvars. Same pattern Pro Tools / Reaper / Resolve use.

---

## 5. Honest cost of from-scratch

I had to be pushed twice to write this section without bias. The list:

**Things I underestimated initially:**

1. **AudioUnit wrapper is 500–800 LOC, not 150.** Format negotiation (rate/channels/interleaved-vs-planar), device-change listener (`AudioObjectAddPropertyListener` for plug/unplug), `AudioConverter` when device rate ≠ source rate, sleep/wake/lock detection + restart, underrun policy. All in `.mm` for the C/Obj-C++ glue.

2. **Lock-free ring is 100 LOC done carefully** but the bugs are 1-frame glitches in production, hard to repro in tests. Either pull a vetted dep (choc/farbot — friction) or write + adversarially test our own.

3. **State-snapshot pattern is architecturally invasive.** Every mid-play state change (mute, solo, volume, pan, speed, direction, marks, edits, splits, deletes) has to be sorted into "snapshot field" vs "command queue entry." Plus the implementation of either `std::atomic<shared_ptr<T>>` (perf gotchas), hazard pointers, or double-buffer-with-version. 200–400 LOC across modules.

4. **Test harness rewrite.** Today's integration tests poke `PLAYBACK.TICK` to drive the clock manually. CoreAudio HW timestamps can't be driven manually. Either build a test seam (more abstraction) or tests run against real audio (CI flake; headless mode is already broken with QAudioSink, would still be broken with AudioUnit unless we have a synth-clock seam). 1–2 days of test fixup minimum.

5. **DisplayLink ↔ audio-clock drift.** PLL exists for a reason; "delete the PLL" may be wrong. Need to measure before committing.

6. **"Delete 800 LOC" is misleading** — deleted code has callers (DisplayLink, tests, Lua, diag ring). Touching 1500 more lines is realistic; tail of "oh that test assumed X" for weeks after.

7. **CoreAudio depth.** I've read about it; haven't shipped on it. AudioUnit format negotiation is famously fussy. Plug/unplug semantics, sample-rate-change-mid-playback, the property listener event order — each "I'll just plug it in" hides a 2-hour rabbit hole.

8. **RT-safety audit.** Producer is non-RT (relief — SSE allocation is fine), but the render callback IS RT and cannot block/allocate/lock. Ring read + snapshot read must be RT-safe. Audit-required, not free.

**Honest schedule:**

| Scenario | Time | Probability |
|---|---|---|
| Optimistic — no platform surprises, tests adapt cleanly, PLL truly deletable | 3 days | ~15% |
| Realistic — some surprises, test harness needs a seam, small PLL stays | 1.5–2 weeks | ~55% |
| Pessimistic — AudioUnit negotiation pain, sample-rate conversion eats latency budget, audio glitches need empirical debugging, fixed-point clock-mapping bug hunt | 3–4 weeks | ~30% |

**Risks specific to "from scratch":**
- **Cross-platform door closes** — if JVE ever wants Linux/Windows, CoreAudio-direct means writing the equivalent. QAudioSink was meant to be that abstraction; it's broken on macOS, but the need doesn't disappear.
- **Audio dropouts are user-visible and viscerally bad.** Today's path has been tuned by walking into failure modes; new path re-walks them.
- **My calibration on this kind of call is bad right now** — see: today. Widen intervals.
- **The "greenfield erases bug categories" framing is seductive.** Existing bugs are paid-for. New code has its own bug taxonomy we will meet.

---

## 6. Decision shipped (2026-06-23)

**Ship the hybrid.** Reasons in priority order:
1. ~30 min of remaining work vs 1.5–4 weeks.
2. Unblocks the original `test_mix_change_keeps_playing` flake + the inspector PR.
3. SSE owner-thread asserts permanently encode the threading contract — survives any future hybrid → from-scratch transition.
4. Atomicized audio-master state is correct under both designs.

**Future direction (not scheduled):** When audio path becomes a roadmap priority (perf work, new device support, lower latency requirements, or accumulated tax from the current stack), do the CoreAudio rewrite as a deliberate spec, not an in-line refactor. Estimate 1.5–4 weeks per section 5.

**What to NOT do in the meantime:** further bolt-ons to the QAudioSink/AudioPump/PLL stack beyond bug fixes. Each addition is debt to be unwound during the eventual rewrite.

---

## 7. Things to verify if/when from-scratch happens

- Measure CVDisplayLink vs CoreAudio HW timestamp drift over 10-min play sessions — does PLL stay deletable?
- Confirm AVAudioEngine vs raw AudioUnit tradeoff (AVAudioEngine is friendlier; check whether its scheduling latency is acceptable).
- Audit all SSE call sites for RT-safety assumptions that may change under the new threading.
- Decide snapshot vs command-queue for each mid-play state change ahead of implementation.
- Build the test-clock seam BEFORE deleting the manual-tick harness.
- Re-check QAudioSource (capture) usage — if present, can't fully extract Qt audio module.
