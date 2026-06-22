# Feature Specification: Five Timeline UX Improvements

**Feature Branch**: `025-five-timeline-ux`  
**Created**: 2026-06-17  
**Status**: Draft  
**Input**: User description: "Five timeline UX improvements: (1) FCP7-style through-edit detection and rendering — red inward-pointing triangle chevrons at cut points, right-click context menu 'Join Through Edit' / 'Join All Through Edits' commands; (2) ±nnn timecode offset entry — pressing + or - activates a red-bordered TC entry field prepopulated with the sign, Enter offsets the playhead; (3) JKL shuttle speed in quarter steps (0.25x increments) configurable via prefs, no settings UI yet; (4) bigger click zones for track header M and S buttons; (5) Option+click on M or S sets only that track to the toggled state and sets all other tracks to the opposite."

---

## User Scenarios & Testing *(mandatory)*

### Primary User Story

An editor working in the timeline needs sharper feedback about the edit structure, finer control over playback speed, and less frustration with small targets and all-or-nothing mute/solo toggling.

---

## FR-001: Through-Edit Detection and Rendering

### What Is a Through-Edit

A **through-edit** is a cut between two adjacent clips that is editorially invisible: both clips come from the same source and their source frames are contiguous, so playing across the cut is indistinguishable from an uncut clip. Through-edits arise from splitting, trimming, or importing. The editor needs to see them to decide whether to rejoin them.

### Visual Treatment

Two small red inward-pointing triangle chevrons appear at the cut point on every through-edit boundary:

- **Left chevron**: rightward-pointing triangle with its tip touching the cut line at the clip's right edge.
- **Right chevron**: leftward-pointing triangle with its tip touching the cut line at the clip’s left edge.

The chevrons are drawn in a named color constant `THROUGH_EDIT_MARKER` (red, exact value chosen at implementation time to read clearly against both audio and video clip body colors). They appear on both clips that form the pair — at the same pixel column where clip A ends and clip B begins.

### Scope

Through-edit detection and rendering applies to the **Record tab only** (the edit sequence). The Source tab displays a raw master clip and never shows through-edit markers.

### Detection Rule

Clips A and B form a through-edit when all three conditions hold:

1. Adjacent on the same track: `A` ends exactly where `B` begins (no gap).
2. Same source: both clips were drawn from the **same master sequence** — `clip.sequence_id`, the "source tape" resolved through `media_refs`→`media`. This is the field every ordinary media clip actually carries; a clip with no source sequence (gap / generator) never forms a through-edit. The per-clip layer selectors `master_layer_track_id` (video) / `master_audio_track_id` (audio) **refine** the match: they are normally `NULL` (the master's default layer), so two ordinary clips (both `NULL`) from one master sequence are the same source. Only a **different explicit** layer (multicam angle, split channel) breaks the match — so `NULL`==`NULL` is the same source, but two distinct non-`NULL` selectors are not. (These layer columns get renamed to `source_video_track_id` / `source_audio_track_id` by spec 021.)
3. Contiguous source frames: the left clip's `source_out` equals the right clip's `source_in`. (`source_out` is the exclusive one-past-last frame, so equality — not off-by-one — means contiguous; this matches how the blade/split commands cut.)

For audio clips with subframe precision, subframe continuity is also required when both values are present.

### Context Menu

Right-clicking an **edit point** (the cut line between two clips) is its own gesture, distinct from right-clicking a clip body: it shows an **edit menu** with the through-edit operations and does **not** select or act on either adjacent clip. (An edit-point right-click is detected first; only when the cursor is not on an edit point does the clip context menu appear.) The edit menu has:

- **Join Through Edit** — rejoins the right-clicked edit: deletes the right clip and extends the left clip to absorb it. Enabled only when the right-clicked edit is a through-edit **on an unlocked track**; shown but grayed out otherwise, with tooltip "Not a through-edit" (not a through-edit) or "Track is locked" (locked track).
- **Join All Through Edits** — rejoins every through-edit pair in the active sequence in one undoable operation. Pairs on locked tracks are skipped (their markers still render). The item is grayed out only when no joinable (unlocked) through-edit exists.

Both operations are **undoable**.

### Select-and-Delete

The conventional NLE way to remove a through-edit is to **select the edit and press Delete** (FCP7/Premiere). Selecting an edit point is a roll selection (both sides of one cut). When that selected cut is a through-edit, **Delete** (and Shift+Delete) runs `JoinThroughEdit` on the pair — one undoable join. A roll selection over a **genuine** cut (different source, or a real source-frame gap) is left untouched by Delete: there is nothing editorially invisible to remove. This routes through the `DeleteSelection` command's priority chain (after mark-range, before clip/gap delete), gated on the through-edit predicate so a non-through cut never reaches `JoinThroughEdit`'s assert.

### Join Behavior

Joining a through-edit extends the left clip’s out-point and duration to cover the right clip’s full range, then removes the right clip. The result is identical to what the original uncut clip would have been for that range. Link group membership is preserved on the surviving clip. Any `clip_markers` on the right clip are reassigned to the left clip **before** the right clip is deleted — otherwise the schema's `ON DELETE CASCADE` would discard them. (There are no per-clip keyframes in the model, so none are migrated.)

### Acceptance Scenarios

1. **Given** two adjacent clips from the same source with contiguous source frames, **When** the timeline renders, **Then** red chevrons appear at the cut point on both clips.
2. **Given** two adjacent clips from different sources, **When** the timeline renders, **Then** no chevrons appear at that cut.
3. **Given** two adjacent clips from the same source with a source gap (non-contiguous frames), **When** the timeline renders, **Then** no chevrons appear.
4. **Given** a through-edit exists, **When** the user right-clicks the edit point and chooses "Join Through Edit", **Then** the two clips merge into one, the chevrons disappear, and undo restores both clips.
5. **Given** multiple through-edits exist, **When** "Join All Through Edits" is chosen, **Then** all pairs are joined in a single undo step.
6. **Given** a non-through-edit cut point is right-clicked, **When** the edit menu opens, **Then** "Join Through Edit" is shown but grayed out.
7. **Given** a through-edit is selected (roll on the cut), **When** the user presses Delete, **Then** the pair is joined into one clip and undo restores both halves.
8. **Given** a genuine (non-through) cut is selected as a roll, **When** the user presses Delete, **Then** the clips are left untouched (no join).

### Edge Cases

- Three-way chain (clip B is the right member of one through-edit and the left member of another): "Join All Through Edits" collapses the entire chain.
- Through-edit on a locked track: the chevron marker still renders, but the "Join Through Edit" menu item is grayed out (tooltip "Track is locked") and "Join All Through Edits" skips the pair. There is no assert/crash — the existing `track_lock_guard` would refuse the write as a non-crashing no-op even if a join were somehow dispatched.
- Zero-duration clips cannot form a through-edit.

---

## FR-002: ±nnn Timecode Offset Entry

### Overview

Pressing `+` or `-` (main keyboard or numpad) activates the timecode entry field in offset mode. The field is pre-populated with the sign character. The user types an offset, then presses Enter. The activation commands (`IncrementTimecode`/`DecrementTimecode`/`GoToTimecode`) only stop playback and open the field (via signals); they perform no move themselves. On Enter the panel parses the field with `core.timecode_input` and dispatches the move through `timecode_entry.compute_action`: **if nothing is selected**, the playhead moves by that amount (`SetPlayhead`); **if clips or edits are selected**, the move delegates to the existing selection-aware `NudgeSelection` command (which routes edges→`BatchRippleEdit` and clips→`Nudge`, owning undo) — no clip/edit move logic is re-implemented. Pressing `=` activates the field pre-populated with `=` for direct absolute-timecode entry; Enter moves the playhead to that exact frame regardless of selection. This matches the standard NLE "nudge by typed amount / go to" gesture.

### Activation

- `+` or `Num+` → stops playback if running, then activates the entry field with `+` as the first character.
- `-` or `Num-` → stops playback if running, then activates the entry field with `-` as the first character.
- `=` → stops playback if running, then activates the entry field with `=` as the first character (absolute-TC mode).
- If the field is already active, pressing `+`/`-`/`=` replaces the prefix character (does not stack).

### Visual

Uses the TC text entry field at the Timeline upper-left. While in offset or GoTo mode the field gains a red border to indicate it is active for entry (distinct from the normal display state).

### Input Formats

- all the formats that the TC field currently accepts

### Commit and Cancel

- **Enter / Return**: parse the field, clamp the resulting frame to `[0, sequence_duration]`, do the move, exit the field.
- **Escape** or click outside: cancel without moving.
- Exiting restores the TC display.

### Keybindings

`+`, `Num+` → `IncrementTimecode`; `-`, `Num-` → `DecrementTimecode`; `=` → `GoToTimecode`. All three added to `default.jvekeys`.

Confirmed unbound: `default.jvekeys` has no bare `Plus`/`Minus`/`Equals` entries (only `Cmd+Plus`/`Cmd+Minus` for zoom, which do not conflict).

### Acceptance Scenarios

1. **Given** the timeline is focused, **When** `+` is pressed, **Then** the TC entry field appears with `+` and cursor ready for digits.
2. **Given** the TC field shows `+10` and no clips are selected, **When** Enter is pressed, **Then** the playhead moves forward 10 frames.
3. **Given** the TC field shows `+00:00:01:00` at 30 fps and no clips are selected, **When** Enter is pressed, **Then** the playhead moves forward 30 frames.
4. **Given** the TC field shows `-5` and no clips are selected, **When** Enter is pressed, **Then** the playhead moves backward 5 frames.
5. **Given** the TC field is active, **When** Escape is pressed, **Then** the field hides and the playhead does not move.
6. **Given** the playhead is at the last frame and `+100` is entered with no selection, **Then** the playhead clamps to the last frame without error.
7. **Given** playback is running, **When** `+` is pressed, **Then** playback stops and the TC field activates with `+`.
8. **Given** two clips are selected and the TC field shows `+10`, **When** Enter is pressed, **Then** both selected clips move forward 10 frames; playhead does not move.
9. **Given** the timeline is focused, **When** `=` is pressed, **Then** the TC entry field appears with `=` and cursor ready for digits; Enter navigates the playhead to the entered absolute timecode.

### Edge Cases

- Invalid input (non-numeric, malformed TC): field stays open for re-entry; no crash, no playhead move.
- Entry of bare `+`, `-`, or `=` with no digits then Enter: treated as zero offset / current TC (no-op).

---

## FR-003: JKL Shuttle Speed Quarter Steps

### Overview

The JKL shuttle speed ladder currently steps in powers of two (1×, 2×, 4×, 8×). It is replaced with a fixed algorithm: 0.25× increments from 1.0× to 2.0×, then powers of 2 up to a 32× ceiling (FCP7 convention). No configuration is needed.

### Speed Ladder Algorithm

- **1.0× – 2.0×**: steps of 0.25 (1.0, 1.25, 1.5, 1.75, 2.0)
- **Above 2.0×**: successive powers of 2 (4.0, 8.0, 16.0, 32.0)
- **32.0× is the ceiling**: holding the shuttle key at 32× stays at 32×. Above ~32× the video decoder + clip prefetch cannot keep the playhead's frame cached, so the picture starves (freezes/goes black) while audio and the position counter keep running on their own threads. The C++ `PlaybackController::SetSpeed` ceiling matches this value.

### Step Behavior

- Pressing L (forward) or J (reverse) while already playing in that direction advances one step up the ladder (faster).
- Pressing the opposite key retreats one step down.
- Pressing the opposite key at 1.0× stops playback.
- **Mid-play speed changes change speed in place.** Only the first press from a stopped transport is a cold-start play (clip prefetch + video pre-roll + audio device start); every subsequent ramp/unwind step reanchors at the live position via `SetSpeed` rather than re-entering the cold-start path. Re-entering it per keypress re-ran a blocking video pre-roll and an audio device flush/restart on each press, which under key-repeat starved the picture while audio continued.
- **A/V sync must remain bounded during a key-repeat ramp and recover to <0.10s drift_p50 (current-state) after a ramp back to 1.0×.** Lightweight `SetSpeed` skips the audio device restart, so the AOP ring + QAudioSink + CoreAudio buffer continue draining at the prior speed for ~75-150ms after each keypress. A single (anchor, epoch, speed) clock cannot represent the piecewise rate the device produces during the drain; without accounting for it, per-press offsets of ≈ latency × Δspeed accumulate across the ladder (~4.6s drift at the 32× rung). Architecture: `PlaybackClock` holds a rate **envelope** — a deque of `Segment{start_aop_us, start_media_us, speed}` indexed by *heard* aop — and `SetSpeed` lightweight calls `ScheduleSpeedChange(new_speed, aop_playhead)`, appending a segment that activates when `heard_aop = aop_playhead - output_latency` crosses the press moment. `Reanchor` stays the hard-reset primitive (cold start / direction flip / mix-flush / seek / shuttle→play cross). `advancePosition` reads `m_clock.ActiveSpeed(aop_playhead)` for the video frame stride so video tracks heard audio through each transition. Verified by `tests/synthetic/integration/test_playback_shuttle_ramp.lua` which asserts per-rung `drift_p95_s` bounds, `drift_p50_s < 0.10s` after ramp-down + settle (current-state recovery), and `gap_count == 0` end-to-end. Note: `drift_p95_s` is a percentile over the full diag ring (~50s history) so the unavoidable per-press transition spikes — bounded individually by `(NEW-OLD) × latency` — live there permanently after a high-speed ramp; `drift_p50_s` is the right metric for "is sync currently good."
- **Shuttle-mode video free-run above 2.0×.** SSE cannot sustain audio decimation at the high rungs of the ladder (4×/8×/16×/32×) — the `SSE scrub starved` path fires and the audio device runs dry. The pre-existing audio-master fallback pins video to the (frozen) audio clock until the device recovers, producing ~1s stalls between displayed frames at 32×. FCP7/Resolve/Premiere convention is to let video free-run at the user's requested speed at shuttle rungs while audio is allowed to scrub/gap; sync is a non-goal there by design. `PlaybackController::advancePosition` gates the mid-play audio-master engagement on `std::abs(intent_speed) > SHUTTLE_FREE_RUN_SPEED` (2.0×): in shuttle mode video runs on `m_speed` via the PLL block alone and any prior audio-master hold is force-released. On the speed-cross *back* into normal play (the J-rung that drops from >2× to ≤2×) the clock is re-anchored at `(current_video_frame, aop_playhead, intent_speed)` so accumulated shuttle-window drift doesn't show up as audio "racing forward" catch-up at 1×. The cold-start audio-master hold in `prefillAudioAtTime` is untouched — that's a brief CoreAudio spin-up gate, unrelated to the SSE-starve case.
- **Shuttle-mode video frame delivery (TMB consumer side).** At 32× the playhead consumes ~800 source frames/sec while the video decoder produces ~60–120 fps; the prefetcher already speed-scales its stride (`TimelineMediaBuffer::stride_for_clip` reads `m_playhead_speed`) so cached frames sit further than the normal `MAX_NEAREST_DISTANCE_BASE` (= `MAX_STRIDE`×2) nearest-fallback bound behind the racing playhead. Without aligning the consumer bound with the producer's policy, `GetVideoFrame(cache_only=true)` returned a non-null `clip_id` but a null `frame` for every tick during the shuttle hold; `deliverFrame` never called `setFrame`, the GPU surface kept displaying the last good image, and the picture froze for ~1s+ until the playhead slowed enough for a cached frame to land within `MAX_NEAREST_DISTANCE_BASE`. `TimelineMediaBuffer::GetVideoFrame` now scales `max_nearest_distance` with `m_playhead_speed`: at `speed_mag > SHUTTLE_FREE_RUN_SPEED` (2.0×, same threshold as the PlaybackController side) the cap is lifted to `INT64_MAX` and look-behind is enabled even for forward play (the decoder is by design behind the playhead at shuttle speed). Same-`clip_id` and `!offline` invariants preserved — wrong-clip or stale-after-seek frames still never surface. Verified by `test_playback_shuttle_ramp.lua` which asserts `cadence_p95_ms < 200` during the 32× hold (= ≥5fps display rate; pre-fix this was 1000+ms / one freeze per shuttle window).
- **RESOLVED 2026-06-21: shuttle catastrophic clip-transition freeze.** At 32× shuttle the playhead consumed `VIDEO_PREFETCH_MAX` (96) in ~120ms wall, but single-thread per-track decode (`claim_track_for_prefetch` serializes V1) couldn't keep up; the cursor walked stride-by-stride from a stale `video_buffer_end` while the playhead raced ahead, so `GetVideoFrame(cache_only=true)` returned no `clip_id` match for the playhead's current clip and `deliverFrame` never fired `setFrame` for ~5s of wall (588 ticks with `cadence=0`, then one outlier tick recording the catch-up wait as 12.9s `TickFlags::TRANSITION`). Three coupled changes resolve it:
  - **(i) `prefetch_worker` now invokes the canonical `discard_already_played_prefetch(target)` before `fill_prefetch(target)`.** This mirrors `audio_prefetch_worker` which already did. The canonical mutator (already in tree at `emp_timeline_media_buffer.cpp:1448`) snaps `video_buffer_end` to the playhead when the playhead has overtaken it in the travel direction — abandoning the stale region so the next fill starts where the user IS. No-op at normal play.
  - **(ii) Per-clip first-frame guarantee in `fill_prefetch`.** When the current clip has zero entries in `video_cache`, snap `decode_pos` to the clip's leading boundary (`sequence_start` for `direction > 0`, `sequence_end()-1` otherwise) regardless of stride. At extreme shuttle the stride can exceed clip length; this guarantees every clip surfaces ≥1 frame.
  - **(iii) Hardware-adaptive default pool.** `TimelineMediaBuffer::Create()` defaults to `clamp(hardware_concurrency()-2, MIN_POOL_THREADS, MAX_POOL_THREADS)`. `EMP.TMB_CREATE()` no-arg routes here from Lua. Reserves cores for main/UI/render; ceiling avoids FFmpeg shared-state contention past ~14 decode threads.
  - Graceful CPU degradation falls out of the existing `stride_for_clip` math (decode_ms vs effective_period): slower CPU → higher measured `decode_ms` → wider stride → choppier shuttle but no freeze. No thread-count term in stride (per-track decode is single-threaded by `claim_track_for_prefetch`).
  - **Measurement on anamnesis-gold-timeline.jvp at 32× shuttle, 30s wall hold:** cadence_max 12891 ms → 817 ms (16×), drift_p95 84 s → 1.1 s (75×), p50/p95/p99 essentially unchanged. The residual ≤800 ms tail is one deterministically-heavy ProRes clip's first-decode cost; further compression would need speculative pre-decode or lifting `claim_track_for_prefetch` — not pursued.
  - **Test:** `tests/synthetic/integration/test_playback_shuttle_gold_timeline.lua` (local-only; depends on Joe's `.jvp` + media). Gate: `cadence_max < 1000 ms` (human-perceptible "video frozen" threshold). Hold defaults to 4s wall; set to 30.0 to extend coverage into the heavy-clip tail. The picker from prior work is unit-test-enforced (`tests/synthetic/unit/test_tmb_warm_picker.cpp` 10/10 cases).
  - **(a) Speed-scaled Lua-provider horizon.** `PlaybackController::speedScaledLookahead()` / `speedScaledMargin()` multiply `PREFETCH_LOOKAHEAD` (150 frames @1×) and `PREFETCH_MARGIN` (120 @1×) by `|m_speed|`, keeping wall-time lead constant regardless of shuttle speed. Without this, at 32× the Lua provider doesn't even SUBMIT a `READER_WARM` job for the upcoming clip until the playhead is ~187ms away — far less than the ~1–3s a fresh file's first decode (open + VT init + first GOP) needs.
  - **(b) Proximity-priority `READER_WARM` picker.** `TimelineMediaBuffer::process_next_decode_prep_job` now picks the warm job whose `sequence_start` is closest to `m_playhead_frame` in the current `m_playhead_direction` (signed-distance comparison, with a fallback pass for the rare "all behind" case). `PreBufferJob` gained a `sequence_start` field that submission sites in `SetTrackClips`/`AddClips` populate from `ClipInfo::sequence_start`; a `JVE_ASSERT` fires if a `READER_WARM` job is submitted without it set (no silent fallback to LIFO). Without this, the LIFO picker over Lua's sequence-ordered insertions warms the FURTHEST clip first; the imminent clip waits at the queue tail behind dozens of far-future ones, and the single `prep_worker` thread (deliberately one — VT init can't be parallelized cleanly) grinds through them serially while the playhead crosses the boundary into the unwarmed clip.
  - (a) without (b) makes the freeze WORSE — verified live: it expands the warm queue to ~50 jobs at 32× while keeping LIFO, so the imminent clip is even more buried (9.8s vs 6.9s). (b) without (a) doesn't help because the imminent clip isn't submitted in time to warm at all.
  - **prep_worker count stays at 1** by deliberate design (parallel VT init is pathological and the cure must come from picking better, not parallelizing harder). The 1-thread-is-enough premise: at 32× shuttle clip boundaries cross every ~720ms wall; VT init ~264ms + first GOP ~200ms fits in 720ms with margin, ASSUMING the warm job submitted (a) and picked (b) is actually the upcoming clip. Both (a) and (b) are necessary for that assumption to hold.

### K+J / K+L (Slow Play)

The K-held slow-play behavior (K+J = 0.5× reverse, K+L = 0.5× forward) is unchanged.

### Acceptance Scenarios

1. **Given** playback is stopped, **When** L is pressed once, **Then** playback starts at 1.0× forward.
2. **Given** playback is at 1.0× forward, **When** L is pressed, **Then** speed becomes 1.25×.
3. **Given** playback is at 1.5× forward, **When** J is pressed twice, **Then** speed steps to 1.25×, then to 1.0×; pressing J once more stops playback.
4. **Given** playback is at 1.0× forward, **When** J is pressed, **Then** playback stops.
5. **Given** playback is at 2.0× forward, **When** L is pressed, **Then** speed becomes 4.0×.
6. **Given** playback is at 16.0× forward, **When** L is pressed, **Then** speed becomes 32.0×.
7. **Given** playback is at 32.0× forward, **When** L is pressed, **Then** speed stays 32.0× (the ceiling).

### Edge Cases

- K+J / K+L (0.5×) is outside the forward/reverse ladder; it does not interact with step-up/down behavior.

---

## FR-004: Larger M/S Button Click Zones

### Overview

The Mute (M) and Solo (S) buttons in the track header are currently too small to click reliably. Their click zone is expanded.

### Status: REVERTED (2026-06-21) — buttons left at their original compact size

The desired outcome was: M/S **look exactly the same** (small, compact) but have a
**larger click area** around them. Two implementations were tried and rejected:
- Widening the button → "didn't want them wider" (and it's the wrong axis: the
  buttons are stacked, so the hard miss is vertical).
- A QSS `margin` and then a transparent **halo** wrapper to enlarge the hit area
  without changing the look → the margin doesn't hit-test on a QPushButton, and
  the bare-`QWidget` halo didn't paint its region (graphic artifacts).
- Stretching the buttons to fill the header vertically → changed the look (Joe
  wanted them to look the same).

Per Joe, reverted to the original compact buttons. A correct "look identical,
bigger hit area" solution would need the halo wrapper done right (paint the halo
with the header background so it has no artifacts, and route its clicks to the
same toggle) — deferred unless revisited.

### Acceptance Scenarios

1. **Given** a track header is visible, **When** the user clicks the M button, **Then** the mute state toggles. (Original behavior — unchanged.)

---

## FR-005: Option+Click Exclusive Toggle (every header toggle)

### Overview

Option+clicking **any** track-header toggle button does two things in one
gesture:

1. The clicked button toggles (or cycles, for 3-state buttons) **just like
   a plain click would** — its new state depends on its own prior state.
2. Every other track of the same type (video tracks one population, audio
   another) gets that button set to the clicked track's **prior** state
   (the state it just left). All siblings land on the same value, exactly
   one step different from where the clicked button just went.

This applies to **every** boolean toggle in the track header — Mute (M),
Solo (S), Lock (🔒), and Waveform display (W) — **and** the 3-state Sync
mode cycle (Off / Ripple / Cut).

### Exact Semantics

Let `old` be the clicked button's state at the moment of the click, and
`new` be the state a plain click would produce:

- **Boolean buttons** (M, S, Lock, W): `new = not old`. Every other
  same-type track gets `old` (which equals `not new`).
- **Sync mode** (3-state cycle Off → Ripple → Cut → Off): `new` is the
  next state in the cycle. Every other same-type track gets `old` — the
  state one step earlier in the cycle.

The unified rule: **clicked goes to its NEW state; every other same-type
track gets clicked's OLD state.**

Worked examples:

| Property | Clicked old | Clicked new | Siblings end at |
|----------|-------------|-------------|------------------|
| M        | un-muted    | muted       | un-muted (= "mute only me") |
| M        | muted       | un-muted    | muted (= "everyone except me") |
| S        | un-soloed   | soloed      | un-soloed (= "solo only me") |
| Lock     | unlocked    | locked      | unlocked (= "lock only me") |
| W        | hidden      | shown       | hidden (= "show only me") |
| Sync     | Off         | Ripple      | Off |
| Sync     | Ripple      | Cut         | Ripple |
| Sync     | Cut         | Off         | Cut |

Video and audio populations are independent: Option+click on a video
track affects only video tracks. The waveform-display gesture is
audio-only (W exists only on audio rows).

A locked track is protected against M/S/W/Sync isolation — Option+click
on those buttons on a locked clicked track is a graceful no-op. The
**Lock** gesture itself is always allowed (you can Option+click Lock on
a locked track to walk back through the cycle).

### Non-Undoable

Consistent with the plain single-track toggles, this operation is not on
the undo stack.

### Acceptance Scenarios

1. **Given** three audio tracks all un-muted, **When** Option+click M on A2, **Then** A2 is muted=true; A1 and A3 are muted=false ("mute only A2").
2. **Given** three audio tracks all muted, **When** Option+click M on A2, **Then** A2 is muted=false; A1 and A3 are muted=true ("everyone except A2 muted").
3. **Given** three audio tracks all un-soloed, **When** Option+click S on A1, **Then** A1 is soloed=true; A2 and A3 are soloed=false.
4. **Given** mixed video and audio tracks, **When** Option+click M on a video track, **Then** only other video tracks are affected; audio mute states are unchanged.
5. **Given** three audio tracks with W shown on A1 and A3 and hidden on A2, **When** Option+click W on A2, **Then** A2's W is shown and A1/A3's W is hidden ("show waveform only on A2").
6. **Given** three video tracks with sync_mode all Off, **When** Option+click Sync on V1, **Then** V1 cycles to Ripple and V2/V3 stay/go to Off.
7. **Given** three video tracks with sync_mode all Ripple, **When** Option+click Sync on V1, **Then** V1 cycles to Cut and V2/V3 go to Ripple.
8. **Given** only one track exists, **When** Option+click M, **Then** the lone track's M toggles (no siblings to set).
9. **Given** a plain click (no Option key), **When** any header toggle is clicked, **Then** only that track's button changes — siblings untouched.

### Edge Cases

- Option+click M, S, W, or Sync on a locked clicked track: graceful no-op (early return, not a crash).
- Option+click on a single-track population: behaves as a plain toggle.
- Waveform-display gesture on a non-audio track: asserts (W only exists on audio rows).

---

## Key Entities

- **Through-edit pair**: two adjacent clips satisfying the detection rule (same source, contiguous source range). Identified at render time; not persisted.
- **TC offset entry**: transient UI state (active/inactive, current text). Not persisted.
- **Track preference (muted/soloed)**: per-track boolean persisted in the project. Modified by both single-track and exclusive-toggle operations.

---

## Clarifications

### Session 2026-06-18

- Q: When `+`/`-` is entered with clips selected, does the offset move the selected clips or the playhead? → A: Moves selected clips (Option A); playhead moves only when nothing is selected. `=` always moves playhead to absolute timecode regardless of selection.
- Q: When right-clicking in a through-edit chain, which pair does "Join Through Edit" act on? → A: The right-click target is the edit point (cut line), not a clip body — the edit uniquely identifies the pair. "Delete right clip, extend left" always applies; no special-casing needed.

- Q: When pressing the opposite direction key while shuttling forward, does retreat stop at 1× or continue decelerating below 1× in the original direction? → A: Stops at 1× (Option A — like Resolve/FCP7). Pressing the opposite key at 1× stops playback; speeds below 1× are only reached by pressing the same-direction key from stopped.
- Q: What happens if `+` or `-` is pressed while playback is running? → A: Stop playback first, then activate the TC entry field.
- Q: Should through-edit chevrons appear on the Source tab (master clip view) or Record tab only? → A: Record tab only.

---

## Review & Acceptance Checklist

### Content Quality
- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user/editor workflow value
- [x] All mandatory sections completed

### Requirement Completeness
- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Scope clearly bounded (five discrete, independently testable features)
- [x] Dependencies identified: FR-005 requires modifier state at button-click time

---

## Execution Status

- [x] User description parsed
- [x] Key concepts extracted
- [x] Ambiguities marked
- [x] User scenarios defined
- [x] Requirements generated
- [x] Entities identified
- [x] Review checklist passed
