"""
Playback smokes against the live editor: cadence + monotonicity + seek
+ A/V drift + audio-underrun.

Hits the actual user surface — real OS key events into a foregrounded
JVE — to verify the engine plays at the sequence's wall-clock rate,
advances monotonically across the play window, lands a typed-frame
seek inside a reasonable latency budget, and keeps audio in sync with
video without underruns.

Replaces ``tests/synthetic/integration/test_playback_av_sync.lua``
whose headless harness measured the diag-ring book-keeping rather than
wall-clock behaviour. The A/V drift + underrun reads use new
``debug_helpers.audio_*`` accessors over ``AOP.AUDIBLE_US`` /
``AOP.HAD_UNDERRUN`` / ``AOP.CLEAR_UNDERRUN``.

Run:
    python3 -m unittest tests.live.cases.test_playback_advances_wall_clock -v
"""

import time
import unittest

from tests.live.runner.case import JVESmokeCase

PLAY_SECONDS = 5.0
# Tolerance: ≥ 90 % of expected. Catches the cadence cliff Joe just
# reported (≈ 0.2 × baseline) with a generous margin for OS jitter,
# audio-device warm-up, and AppKit scheduling hiccups.
MIN_ADVANCE_RATIO = 0.90
# Sample mid-window to verify monotonicity. Four samples around the
# play arc are enough to catch a backwards jump without bloating the
# wall-clock budget.
MID_SAMPLES = 4
# Seek latency budget. The headless test used 500 ms for the
# decode + display round-trip; the typed-frame UI path adds a few
# keystrokes' worth of cost on top, so allow 1.0 s end-to-end.
SEEK_LATENCY_BUDGET_S = 1.0


def _engine_pos_lua() -> str:
    return ("return require('core.playback.transport')"
            ".engine_for_target():get_position()")


class TestPlaybackSmokes(JVESmokeCase):
    """Live-editor playback contract: advance, monotonicity, seek."""

    def _fps(self, seq_id: str) -> float:
        fps_num = self.eval_int(
            f"return require('models.sequence').load('{seq_id}').frame_rate.fps_numerator")
        fps_den = self.eval_int(
            f"return require('models.sequence').load('{seq_id}').frame_rate.fps_denominator")
        assert fps_num > 0 and fps_den > 0, (
            f"sequence {seq_id} frame_rate.fps_numerator/fps_denominator unpopulated "
            f"({fps_num}/{fps_den}) — fixture broken or schema regression")
        return fps_num / fps_den

    def test_play_advances_at_wall_clock_rate_and_stays_monotonic(self) -> None:
        # Densest variant biases the play arc into the heaviest GPU
        # compositor load on the fixture. A regression that throttles
        # the real-time advance path tends to manifest under concurrent
        # video tracks (multi-source decode + blend) before it shows on
        # a lone clip — running this against the first armed clip on
        # gold misses that surface.
        clip = self.densest_armed_video_clip(
            min_frames=int(PLAY_SECONDS * 60) + 60)

        # Park inside the clip body so the play arc stays inside one clip
        # (no clip-transition cost confounding the cadence measurement)
        # and the engine has frames to serve.
        self.move_playhead_to(clip.seq_start + 1)

        fps = self._fps(clip.rec_seq)
        expected_frames = int(round(fps * PLAY_SECONDS))
        min_frames = int(round(expected_frames * MIN_ADVANCE_RATIO))

        engine_lua = _engine_pos_lua()
        start_pos = self.eval_int(engine_lua)

        self.key("Space", expect_command=False)
        samples = [start_pos]
        sample_interval = PLAY_SECONDS / (MID_SAMPLES + 1)
        for _ in range(MID_SAMPLES):
            time.sleep(sample_interval)
            samples.append(self.eval_int(engine_lua))
        time.sleep(sample_interval)
        self.key("Space", expect_command=False)

        end_pos = self.eval_int(engine_lua)
        samples.append(end_pos)
        advanced = end_pos - start_pos

        self.assertGreaterEqual(advanced, min_frames, (
            f"engine advanced {advanced} frames in {PLAY_SECONDS}s at "
            f"{fps:.3f} fps; expected ≥ {min_frames} "
            f"(≥{MIN_ADVANCE_RATIO * 100:.0f}% of {expected_frames}). "
            f"Cadence cliff — something is throttling the real-time "
            f"advance path. Suspect main/pump handshake overhead, "
            f"audio-device contention, or a synchronous stall in the "
            f"tick loop."))

        prev = samples[0]
        for i, pos in enumerate(samples[1:], start=1):
            self.assertGreaterEqual(pos, prev, (
                f"engine moved backwards at sample {i}: {pos} < {prev} "
                f"(samples={samples}). Backward advance is never legal "
                f"during forward play — decoder re-route or playhead "
                f"signal cycle."))
            prev = pos

    def test_av_drift_stays_bounded_and_no_underruns_during_play(self) -> None:
        clip = self.first_armed_video_clip(
            min_frames=int(PLAY_SECONDS * 60) + 60)

        self.move_playhead_to(clip.seq_start + 1)
        fps = self._fps(clip.rec_seq)
        engine_lua = _engine_pos_lua()
        audio_lua = ("return require('core.debug_helpers')"
                     ".audio_audible_us()")
        underrun_lua = ("return require('core.debug_helpers')"
                        ".audio_had_underrun()")
        clear_underrun_lua = ("require('core.debug_helpers')"
                              ".audio_clear_underrun()")
        has_audio_lua = ("return require('core.debug_helpers')"
                         ".has_audio_session()")

        self.key("Space", expect_command=False)
        # Warm-up window: cold-start AAC decode + SSE fill + AOP buffer
        # under-runs on the first 500ms. Audio session is lazily opened
        # by playback_engine on first audio-bearing render, so the
        # session check must happen AFTER Space (a pre-Space check
        # would skip every test, since aop only exists once play
        # begins). Clear the sticky underrun flag after warmup.
        time.sleep(0.5)
        if not self.eval_bool(has_audio_lua):
            self.key("Space", expect_command=False)
            self.skipTest("no audio session opened after 0.5s of play — "
                          "fixture's play range has no audio clips, or "
                          "engine declined to open AOP for the parked "
                          "clip (not an A/V sync regression)")
        self.eval(clear_underrun_lua)

        start_frame = self.eval_int(engine_lua)
        samples = []
        # Sample evenly across the remaining play window so a drift
        # spike anywhere in the arc is caught.
        for _ in range(MID_SAMPLES + 1):
            time.sleep((PLAY_SECONDS - 0.5) / (MID_SAMPLES + 1))
            samples.append({
                "video_frame": self.eval_int(engine_lua),
                "audio_us": self.eval_int(audio_lua),
            })
        self.key("Space", expect_command=False)

        # Drift is RELATIVE to the first post-warmup sample. Qt doesn't
        # expose CoreAudio HAL latency, so the absolute audio↔video
        # offset is irreducible; what matters is whether that offset
        # stays stable during play.
        baseline_offset_us = None
        peak_drift_us = 0
        peak_idx = -1
        for i, s in enumerate(samples):
            video_time_us = (s["video_frame"] - start_frame) * 1_000_000 / fps
            raw_offset = s["audio_us"] - video_time_us
            if baseline_offset_us is None:
                baseline_offset_us = raw_offset
                continue
            drift = abs(raw_offset - baseline_offset_us)
            if drift > peak_drift_us:
                peak_drift_us = drift
                peak_idx = i

        # 150 ms peak drift ceiling matches the headless suite. Real
        # CVDisplayLink production hits ~10-30 ms; the budget tolerates
        # one-shot transition glitches without flagging the harness.
        MAX_DRIFT_US = 150_000
        self.assertLess(peak_drift_us, MAX_DRIFT_US, (
            f"A/V drift peaked at {peak_drift_us / 1000:.1f}ms "
            f"(limit {MAX_DRIFT_US / 1000:.0f}ms) at sample {peak_idx} "
            f"of {len(samples)}. Audio and video clocks diverged "
            f"mid-play — suspect decoder lag, audio reseek glitch, "
            f"or a one-shot offline transition."))

        self.assertFalse(self.eval_bool(underrun_lua), (
            "AOP reported an underrun during the post-warmup play "
            "arc. Pump starved the audio device — likely cause: "
            "decoder couldn't keep up, or the pump-pause handshake "
            "blocked audio fill."))

    def test_seek_to_typed_frame_lands_within_latency_budget(self) -> None:
        clip = self.first_armed_video_clip(min_frames=120)

        start_frame = clip.seq_start + 1
        target_frame = clip.seq_start + 80

        self.move_playhead_to(start_frame)
        engine_lua = _engine_pos_lua()
        seeded = self.eval_int(engine_lua)
        self.assertEqual(start_frame, seeded, (
            f"seed precondition: typed-frame seek to {start_frame} left "
            f"engine at {seeded} — engine-sync path is broken before "
            f"the latency measurement even begins"))

        t0 = time.monotonic()
        self.move_playhead_to(target_frame)
        landed = self.eval_int(engine_lua)
        latency_s = time.monotonic() - t0

        self.assertEqual(target_frame, landed, (
            f"seek target: engine at {landed}, expected {target_frame}. "
            f"Typed-frame UI path didn't deliver the frame to the "
            f"displayed engine."))

        self.assertLess(latency_s, SEEK_LATENCY_BUDGET_S, (
            f"seek latency: {latency_s * 1000:.0f}ms exceeds "
            f"{SEEK_LATENCY_BUDGET_S * 1000:.0f}ms budget. "
            f"Decode + display round-trip stalled, or the typed-frame "
            f"UI path lost a keystroke and waited on a timeout."))


if __name__ == "__main__":
    unittest.main()
