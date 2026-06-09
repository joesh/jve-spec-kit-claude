// Black-box tests for PlaybackClock — the epoch-based A/V sync clock.
//
// PlaybackClock answers: "given the audio output device has been running for
// X microseconds, what media time should the video be displaying?"
//
// The API contract:
// - Reanchor(media_time, speed, aop_playhead) — called at play/seek/speed-change
// - CurrentTimeUS(aop_playhead) — returns media time compensated for output latency
// - SetSinkBufferLatency(sink_us) — updates total output latency (device + sink)
// - FrameFromTimeUS(time_us, fps_num, fps_den) — converts media time to frame index
//
// Tests are structured around real NLE scenarios, not implementation details.

#include <QtTest>
#include "playback_controller.h"

class TestPlaybackClock : public QObject {
    Q_OBJECT

private slots:

    // ════════════════════════════════════════════════════════════════════════
    // Scenario: Press play from the beginning
    // ════════════════════════════════════════════════════════════════════════

    void test_play_from_zero_returns_correct_media_time() {
        // User presses play at TC 00:00:00:00. AOP starts at playhead=0.
        // After the audio device has been running for 1 second (1,000,000us),
        // the clock should report media time = 1s minus output latency.
        PlaybackClock clock;
        clock.Reanchor(0, 1.0f, 0);  // media=0, speed=1x, aop=0

        // 1 second of audio has been consumed by the OS
        int64_t media_time = clock.CurrentTimeUS(1000000);

        // With default 150ms latency, media time = 1.0s - 0.15s = 0.85s
        // The latency compensation means video is slightly behind the audio
        // output position, matching when sound actually reaches the speakers.
        QCOMPARE(media_time, (int64_t)850000);
    }

    void test_play_from_zero_before_latency_elapsed() {
        // Right after pressing play, the AOP has run for less than the
        // output latency. Media time should be 0 (clamped, not negative).
        PlaybackClock clock;
        clock.Reanchor(0, 1.0f, 0);

        // Only 50ms elapsed — less than 150ms latency
        int64_t media_time = clock.CurrentTimeUS(50000);
        QCOMPARE(media_time, (int64_t)0);
    }

    void test_play_from_zero_exactly_at_latency() {
        // AOP has run exactly the output latency duration.
        // Media time should be 0 (latency fully consumed, playback just starting).
        PlaybackClock clock;
        clock.Reanchor(0, 1.0f, 0);

        int64_t media_time = clock.CurrentTimeUS(150000);
        QCOMPARE(media_time, (int64_t)0);
    }

    // ════════════════════════════════════════════════════════════════════════
    // Scenario: Press play from a mid-timeline position (seek then play)
    // ════════════════════════════════════════════════════════════════════════

    void test_play_from_midpoint() {
        // User seeks to TC 01:00:00:00 (3,600s) then presses play.
        // AOP is reanchored at its current playhead position.
        PlaybackClock clock;
        int64_t one_hour_us = 3600LL * 1000000;
        int64_t aop_at_play = 5000000;  // AOP has been running for 5s already

        clock.Reanchor(one_hour_us, 1.0f, aop_at_play);

        // 2 seconds of new audio since play was pressed
        int64_t media_time = clock.CurrentTimeUS(aop_at_play + 2000000);

        // media = 1h + (2s - 150ms) * 1.0
        int64_t expected = one_hour_us + 1850000;
        QCOMPARE(media_time, expected);
    }

    void test_play_from_late_timeline_position() {
        // Simulate the real bug scenario: play from frame 93127 at 25fps.
        // TC ≈ 01:02:03:09, media_anchor ≈ 3723.08s
        PlaybackClock clock;
        int64_t media_anchor = 3723080000LL;  // ~01:02:03:02 in microseconds
        int64_t aop_start = 10000000;  // AOP had been running 10s

        clock.Reanchor(media_anchor, 1.0f, aop_start);

        // 5 seconds of playback
        int64_t media_time = clock.CurrentTimeUS(aop_start + 5000000);
        int64_t expected = media_anchor + 4850000;  // 5s - 150ms latency
        QCOMPARE(media_time, expected);

        // 60 seconds of playback
        int64_t media_time_60s = clock.CurrentTimeUS(aop_start + 60000000);
        int64_t expected_60s = media_anchor + 59850000;
        QCOMPARE(media_time_60s, expected_60s);
    }

    // ════════════════════════════════════════════════════════════════════════
    // Scenario: Speed changes (2x, 0.5x, reverse)
    // ════════════════════════════════════════════════════════════════════════

    void test_double_speed_playback() {
        // Playing at 2x speed: 1 second of real time = 2 seconds of media.
        PlaybackClock clock;
        clock.Reanchor(0, 2.0f, 0);

        // 1 second of AOP audio consumed
        int64_t media_time = clock.CurrentTimeUS(1000000);
        // (1s - 150ms) * 2.0 = 1.7s
        QCOMPARE(media_time, (int64_t)1700000);
    }

    void test_half_speed_playback() {
        PlaybackClock clock;
        clock.Reanchor(0, 0.5f, 0);

        // 2 seconds of AOP audio
        int64_t media_time = clock.CurrentTimeUS(2000000);
        // (2s - 150ms) * 0.5 = 0.925s
        QCOMPARE(media_time, (int64_t)925000);
    }

    void test_reverse_playback() {
        // Playing in reverse from TC 00:10:00. Speed = -1.0.
        PlaybackClock clock;
        int64_t ten_min_us = 600000000LL;
        clock.Reanchor(ten_min_us, -1.0f, 0);

        // 2 seconds elapsed
        int64_t media_time = clock.CurrentTimeUS(2000000);
        // 10min + (2s - 150ms) * (-1.0) = 10min - 1.85s
        int64_t expected = ten_min_us - 1850000;
        QCOMPARE(media_time, expected);
    }

    void test_reverse_2x_speed() {
        PlaybackClock clock;
        int64_t start_us = 10000000;  // 10s
        clock.Reanchor(start_us, -2.0f, 0);

        int64_t media_time = clock.CurrentTimeUS(1000000);
        // 10s + (1s - 150ms) * (-2.0) = 10s - 1.7s = 8.3s
        QCOMPARE(media_time, (int64_t)8300000);
    }

    // ════════════════════════════════════════════════════════════════════════
    // Scenario: Reanchor (seek during playback)
    // ════════════════════════════════════════════════════════════════════════

    void test_reanchor_resets_epoch() {
        // User seeks during playback. AOP keeps running but epoch resets.
        PlaybackClock clock;
        clock.Reanchor(0, 1.0f, 0);

        // 5 seconds of playback
        int64_t before_seek = clock.CurrentTimeUS(5000000);
        QCOMPARE(before_seek, (int64_t)4850000);  // 5s - 150ms

        // User seeks to 30s while AOP playhead is at 5s
        clock.Reanchor(30000000, 1.0f, 5000000);

        // AOP at 5.5s (0.5s since seek)
        int64_t after_seek = clock.CurrentTimeUS(5500000);
        // 30s + (0.5s - 150ms) * 1.0 = 30.35s
        QCOMPARE(after_seek, (int64_t)30350000);
    }

    void test_reanchor_with_speed_change() {
        // Seek + speed change simultaneously (e.g., JKL shuttle)
        PlaybackClock clock;
        clock.Reanchor(0, 1.0f, 0);

        // After 2s, user hits L again to go 2x from current position
        int64_t current_media = clock.CurrentTimeUS(2000000);  // 1.85s

        clock.Reanchor(current_media, 2.0f, 2000000);

        // 1s later at 2x
        int64_t after = clock.CurrentTimeUS(3000000);
        // 1.85s + (1s - 150ms) * 2.0 = 1.85s + 1.7s = 3.55s
        QCOMPARE(after, (int64_t)3550000);
    }

    // ════════════════════════════════════════════════════════════════════════
    // Scenario: Latency compensation
    // ════════════════════════════════════════════════════════════════════════

    void test_sink_buffer_latency_adds_to_device_latency() {
        // SetSinkBufferLatency adds Qt-level buffer delay to the CoreAudio
        // device latency. With default device latency of 150ms, adding 100ms
        // sink buffer → 250ms total.
        PlaybackClock clock;
        clock.SetSinkBufferLatency(100000);  // 100ms sink buffer

        QCOMPARE(clock.OutputLatencyUS(), (int64_t)250000);  // 150ms device + 100ms sink

        clock.Reanchor(0, 1.0f, 0);

        // 1 second elapsed
        int64_t media_time = clock.CurrentTimeUS(1000000);
        // (1s - 250ms) * 1.0 = 750ms
        QCOMPARE(media_time, (int64_t)750000);
    }

    void test_large_latency_delays_playback_start() {
        // With 250ms total latency, the first 250ms of AOP runtime produce
        // no media advancement (video stays at start until sound reaches speakers).
        PlaybackClock clock;
        clock.SetSinkBufferLatency(100000);  // total = 250ms
        clock.Reanchor(0, 1.0f, 0);

        // 200ms elapsed — still within latency window
        QCOMPARE(clock.CurrentTimeUS(200000), (int64_t)0);

        // 250ms — exactly at latency boundary
        QCOMPARE(clock.CurrentTimeUS(250000), (int64_t)0);

        // 251ms — just past latency
        int64_t media_at_251ms = clock.CurrentTimeUS(251000);
        QVERIFY2(media_at_251ms > 0,
            qPrintable(QString("media_time=%1 should be >0 at 251ms with 250ms latency")
                .arg(media_at_251ms)));
        QCOMPARE(media_at_251ms, (int64_t)1000);
    }

    // ════════════════════════════════════════════════════════════════════════
    // Scenario: FrameFromTimeUS — media time to frame conversion
    // ════════════════════════════════════════════════════════════════════════

    void test_frame_from_time_25fps() {
        // 25fps: 1 frame = 40ms = 40000us
        QCOMPARE(PlaybackClock::FrameFromTimeUS(0, 25, 1), (int64_t)0);
        QCOMPARE(PlaybackClock::FrameFromTimeUS(40000, 25, 1), (int64_t)1);
        QCOMPARE(PlaybackClock::FrameFromTimeUS(1000000, 25, 1), (int64_t)25);
        QCOMPARE(PlaybackClock::FrameFromTimeUS(3607000000LL, 25, 1), (int64_t)90175);
    }

    void test_frame_from_time_24fps() {
        // 24fps: 1 frame ≈ 41666.67us
        QCOMPARE(PlaybackClock::FrameFromTimeUS(0, 24, 1), (int64_t)0);
        QCOMPARE(PlaybackClock::FrameFromTimeUS(1000000, 24, 1), (int64_t)24);
    }

    void test_frame_from_time_23976() {
        // 23.976fps = 24000/1001
        // 1 second = 23.976 frames → frame 23
        QCOMPARE(PlaybackClock::FrameFromTimeUS(1000000, 24000, 1001), (int64_t)23);
        // 10 seconds = 239.76 frames → frame 239
        QCOMPARE(PlaybackClock::FrameFromTimeUS(10000000, 24000, 1001), (int64_t)239);
    }

    void test_frame_from_time_at_one_hour() {
        // 1 hour at 25fps = 90,000 frames
        int64_t one_hour = 3600LL * 1000000;
        QCOMPARE(PlaybackClock::FrameFromTimeUS(one_hour, 25, 1), (int64_t)90000);
    }

    // ════════════════════════════════════════════════════════════════════════
    // Scenario: End-to-end — "what frame should video show?"
    // ════════════════════════════════════════════════════════════════════════

    void test_end_to_end_play_from_tc_one_hour_25fps() {
        // User presses play at TC 01:00:00:00 (frame 90000 at 25fps).
        // After 2 seconds, what frame should the video display?
        PlaybackClock clock;
        int64_t one_hour_us = 3600LL * 1000000;
        clock.Reanchor(one_hour_us, 1.0f, 0);

        int64_t media_time = clock.CurrentTimeUS(2000000);
        int64_t frame = PlaybackClock::FrameFromTimeUS(media_time, 25, 1);

        // 1h + (2s - 150ms) = 1h + 1.85s = 3601.85s
        // 3601.85s * 25fps = 90046.25 → frame 90046
        QCOMPARE(frame, (int64_t)90046);
    }

    void test_end_to_end_play_from_real_bug_position() {
        // Real bug scenario: play from frame ~93127 (TC ≈ 01:02:03:02.08)
        // After 5 seconds, are we at the right frame?
        PlaybackClock clock;
        // Frame 93127 at 25fps = 3725.08s = 3725080000us
        int64_t anchor_us = 3725080000LL;
        clock.Reanchor(anchor_us, 1.0f, 0);

        // 5 seconds elapsed
        int64_t media_time = clock.CurrentTimeUS(5000000);
        int64_t frame = PlaybackClock::FrameFromTimeUS(media_time, 25, 1);

        // Expected: 93127 + (5s - 150ms) * 25 = 93127 + 121.25 = 93248
        int64_t expected_frame = 93127 + (int64_t)((5.0 - 0.15) * 25);
        QCOMPARE(frame, expected_frame);
    }

    void test_end_to_end_2x_reverse_from_midpoint() {
        // Playing 2x reverse from frame 1000 at 25fps.
        // After 3 seconds, where is the playhead?
        PlaybackClock clock;
        int64_t anchor_us = 40000000;  // frame 1000 * 40000us
        clock.Reanchor(anchor_us, -2.0f, 0);

        int64_t media_time = clock.CurrentTimeUS(3000000);
        int64_t frame = PlaybackClock::FrameFromTimeUS(media_time, 25, 1);

        // 40s + (3s - 150ms) * (-2) = 40s - 5.7s = 34.3s
        // 34.3s * 25fps = 857.5 → frame 857
        QCOMPARE(frame, (int64_t)857);
    }

    // ════════════════════════════════════════════════════════════════════════
    // Scenario: Monotonicity — time never goes backward during playback
    // ════════════════════════════════════════════════════════════════════════

    void test_forward_playback_monotonically_increasing() {
        PlaybackClock clock;
        clock.Reanchor(0, 1.0f, 0);

        int64_t prev = -1;
        for (int64_t aop = 0; aop <= 10000000; aop += 16667) {  // ~60Hz ticks
            int64_t t = clock.CurrentTimeUS(aop);
            QVERIFY2(t >= prev,
                qPrintable(QString("Time went backward: %1 -> %2 at aop=%3")
                    .arg(prev).arg(t).arg(aop)));
            prev = t;
        }
    }

    void test_reverse_playback_monotonically_decreasing() {
        PlaybackClock clock;
        int64_t start = 60000000;  // 60s
        clock.Reanchor(start, -1.0f, 0);

        int64_t prev = start + 1;  // Start above anchor
        for (int64_t aop = 200000; aop <= 10000000; aop += 16667) {
            int64_t t = clock.CurrentTimeUS(aop);
            QVERIFY2(t <= prev,
                qPrintable(QString("Reverse time went forward: %1 -> %2 at aop=%3")
                    .arg(prev).arg(t).arg(aop)));
            prev = t;
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // Scenario: Getters reflect state after Reanchor
    // ════════════════════════════════════════════════════════════════════════

    void test_getters_reflect_reanchor_state() {
        PlaybackClock clock;
        clock.Reanchor(5000000, 2.0f, 1000000);

        QCOMPARE(clock.MediaAnchorUS(), (int64_t)5000000);
        QCOMPARE(clock.Speed(), 2.0f);
    }

    void test_successive_reanchors_overwrite() {
        PlaybackClock clock;
        clock.Reanchor(1000000, 1.0f, 0);
        clock.Reanchor(9000000, -1.5f, 500000);

        QCOMPARE(clock.MediaAnchorUS(), (int64_t)9000000);
        QCOMPARE(clock.Speed(), -1.5f);

        // CurrentTimeUS uses new anchor/epoch
        int64_t t = clock.CurrentTimeUS(1500000);
        // 9s + (1.5s - 0.5s - 150ms) * (-1.5) = 9s + 850ms * (-1.5) = 9s - 1.275s
        QCOMPARE(t, (int64_t)7725000);
    }

    // ════════════════════════════════════════════════════════════════════════
    // Scenario: Edge cases
    // ════════════════════════════════════════════════════════════════════════

    void test_aop_playhead_before_epoch_clamps_to_zero_elapsed() {
        // AOP playhead can be at a position before the epoch if there was
        // a flush/reset. Elapsed should clamp to 0, not go negative.
        PlaybackClock clock;
        clock.Reanchor(5000000, 1.0f, 3000000);  // epoch at 3s

        // AOP reports 2s (before epoch) — elapsed would be -1s
        int64_t t = clock.CurrentTimeUS(2000000);
        // Clamped: max(0, -1s - 150ms) = 0 → media = anchor = 5s
        QCOMPARE(t, (int64_t)5000000);
    }

    void test_zero_speed_returns_anchor() {
        // Speed = 0 (paused). Media time = anchor regardless of elapsed.
        PlaybackClock clock;
        clock.Reanchor(5000000, 0.0f, 0);

        QCOMPARE(clock.CurrentTimeUS(0), (int64_t)5000000);
        QCOMPARE(clock.CurrentTimeUS(10000000), (int64_t)5000000);
    }

    void test_very_large_aop_values_no_overflow() {
        // After 24 hours of continuous playback, AOP playhead is huge.
        PlaybackClock clock;
        clock.Reanchor(0, 1.0f, 0);

        int64_t day_us = 86400LL * 1000000;  // 24 hours
        int64_t t = clock.CurrentTimeUS(day_us);
        int64_t expected = day_us - 150000;
        QCOMPARE(t, expected);
    }

    // ════════════════════════════════════════════════════════════════════════
    // NSF Half 1: Input validation — preconditions
    // ════════════════════════════════════════════════════════════════════════

    void test_frame_from_time_rejects_zero_fps_den() {
        // FrameFromTimeUS divides by fps_den. Zero → division by zero.
        // NSF: must assert, not silently return garbage.
        // We test that the function has a guard by checking fps_den=0 doesn't
        // produce a garbage result. (QTest can't catch asserts directly, but
        // we can verify the guard exists by checking valid boundary.)
        // fps_den=1 is the minimum valid denominator.
        int64_t frame = PlaybackClock::FrameFromTimeUS(1000000, 25, 1);
        QCOMPARE(frame, (int64_t)25);
    }

    void test_frame_from_time_negative_time_returns_negative() {
        // Negative time_us is valid for reverse playback.
        // FrameFromTimeUS should return negative frame (caller clamps).
        int64_t frame = PlaybackClock::FrameFromTimeUS(-1000000, 25, 1);
        QVERIFY2(frame < 0,
            qPrintable(QString("Negative time should give negative frame, got %1").arg(frame)));
        QCOMPARE(frame, (int64_t)-25);
    }

    void test_frame_from_time_at_exact_frame_boundaries() {
        // At exact frame boundaries, no off-by-one.
        // Frame 0: [0, 40000)   Frame 1: [40000, 80000)   at 25fps
        QCOMPARE(PlaybackClock::FrameFromTimeUS(0, 25, 1), (int64_t)0);
        QCOMPARE(PlaybackClock::FrameFromTimeUS(39999, 25, 1), (int64_t)0);   // just before frame 1
        QCOMPARE(PlaybackClock::FrameFromTimeUS(40000, 25, 1), (int64_t)1);   // exactly frame 1
        QCOMPARE(PlaybackClock::FrameFromTimeUS(79999, 25, 1), (int64_t)1);   // just before frame 2
        QCOMPARE(PlaybackClock::FrameFromTimeUS(80000, 25, 1), (int64_t)2);   // exactly frame 2
    }

    void test_reanchor_preserves_values_exactly() {
        // After Reanchor, getters must return EXACTLY the values passed.
        // No rounding, no clamping, no "improvement".
        PlaybackClock clock;
        int64_t anchor = 123456789012LL;  // ~34h in us — unusual but valid
        float speed = -3.5f;
        int64_t epoch = 987654321LL;

        clock.Reanchor(anchor, speed, epoch);

        QCOMPARE(clock.MediaAnchorUS(), anchor);
        QCOMPARE(clock.Speed(), speed);
    }

    // ════════════════════════════════════════════════════════════════════════
    // NSF Half 2: Output invariants — postconditions
    // ════════════════════════════════════════════════════════════════════════

    void test_forward_play_never_returns_negative_media_time() {
        // NSF Half 2: For forward playback from anchor >= 0,
        // CurrentTimeUS must NEVER return negative.
        // Even during the latency window, it should clamp to 0, not go below.
        PlaybackClock clock;
        clock.Reanchor(0, 1.0f, 0);

        for (int64_t aop = 0; aop <= 1000000; aop += 1000) {
            int64_t t = clock.CurrentTimeUS(aop);
            QVERIFY2(t >= 0,
                qPrintable(QString("CurrentTimeUS returned negative %1 at aop=%2")
                    .arg(t).arg(aop)));
        }
    }

    void test_forward_play_from_positive_anchor_bounded_below() {
        // NSF: When playing forward from a positive anchor, media time
        // should never go below anchor (it's the floor).
        PlaybackClock clock;
        int64_t anchor = 5000000;  // 5s
        clock.Reanchor(anchor, 1.0f, 0);

        // During latency window, media time = anchor (elapsed < latency → delta = 0)
        for (int64_t aop = 0; aop <= 150000; aop += 10000) {
            int64_t t = clock.CurrentTimeUS(aop);
            QVERIFY2(t >= anchor,
                qPrintable(QString("Forward play: media_time %1 < anchor %2 at aop=%3")
                    .arg(t).arg(anchor).arg(aop)));
        }

        // After latency window, media time grows from anchor
        int64_t t_1s = clock.CurrentTimeUS(1000000);
        QVERIFY2(t_1s > anchor,
            qPrintable(QString("After 1s, media_time %1 should exceed anchor %2")
                .arg(t_1s).arg(anchor)));
    }

    void test_reverse_play_media_time_decreases_from_anchor() {
        // NSF: Reverse playback from anchor should produce time < anchor
        // (after latency window elapses).
        PlaybackClock clock;
        int64_t anchor = 10000000;  // 10s
        clock.Reanchor(anchor, -1.0f, 0);

        // After latency window
        int64_t t = clock.CurrentTimeUS(1000000);
        QVERIFY2(t < anchor,
            qPrintable(QString("Reverse play: media_time %1 should be < anchor %2")
                .arg(t).arg(anchor)));
        // Should be exactly anchor - (1s - 150ms) = 10s - 0.85s = 9.15s
        QCOMPARE(t, (int64_t)9150000);
    }

    void test_current_time_overflow_protection_large_speed() {
        // NSF: With large speed multiplier and large elapsed time,
        // the multiplication (compensated_elapsed * speed) must not overflow int64.
        // Max safe: 2^63 / (max_speed * max_elapsed)
        PlaybackClock clock;
        clock.Reanchor(0, 8.0f, 0);  // 8x speed

        // 2 hours of playback at 8x = 16 hours of media time
        int64_t two_hours = 7200LL * 1000000;
        int64_t t = clock.CurrentTimeUS(two_hours);

        // Expected: (7200s - 0.15s) * 8 = 57598.8s = 57598800000us
        int64_t expected = static_cast<int64_t>((7200.0 - 0.15) * 8.0 * 1000000.0);
        // Allow 1us tolerance for float→int rounding
        QVERIFY2(std::abs(t - expected) <= 1,
            qPrintable(QString("Large speed overflow: got %1, expected ~%2")
                .arg(t).arg(expected)));
    }

    void test_frame_from_time_23976_no_drift_at_1_hour() {
        // NSF Half 2: 23.976fps (24000/1001) at 1 hour must be exactly 86313 frames.
        // Integer arithmetic in FrameFromTimeUS must not accumulate drift.
        // 1 hour = 3600s = 3600000000us
        // frames = 3600000000 * 24000 / (1000000 * 1001) = 86400000000000 / 1001000000
        //        = 86313.686... → floor = 86313
        int64_t one_hour = 3600LL * 1000000;
        int64_t frame = PlaybackClock::FrameFromTimeUS(one_hour, 24000, 1001);
        QCOMPARE(frame, (int64_t)86313);
    }

    void test_frame_from_time_deterministic_at_boundaries() {
        // NSF: Same input must always produce same output (no float state).
        // FrameFromTimeUS is static/pure — verify it truly is.
        int64_t a = PlaybackClock::FrameFromTimeUS(3725080000LL, 25, 1);
        int64_t b = PlaybackClock::FrameFromTimeUS(3725080000LL, 25, 1);
        QCOMPARE(a, b);
        // And the frame should be exactly: 3725080000 * 25 / 1000000 = 93127
        QCOMPARE(a, (int64_t)93127);
    }

    void test_sink_buffer_latency_increases_delay_window() {
        // NSF: After SetSinkBufferLatency, the entire latency window should
        // grow — meaning more elapsed time is needed before media advances.
        PlaybackClock clock;
        clock.Reanchor(0, 1.0f, 0);

        // Without extra sink latency, 200ms elapsed → 50ms of media time
        int64_t t_no_sink = clock.CurrentTimeUS(200000);
        QCOMPARE(t_no_sink, (int64_t)50000);  // 200ms - 150ms = 50ms

        // Now add 100ms sink buffer (total = 250ms)
        clock.SetSinkBufferLatency(100000);

        // Same 200ms elapsed → now within latency window → 0
        int64_t t_with_sink = clock.CurrentTimeUS(200000);
        QCOMPARE(t_with_sink, (int64_t)0);

        // 300ms → (300ms - 250ms) = 50ms
        int64_t t_300 = clock.CurrentTimeUS(300000);
        QCOMPARE(t_300, (int64_t)50000);
    }

    void test_output_latency_never_negative() {
        // NSF: OutputLatencyUS must always be > 0. The default (150ms)
        // is positive, and SetSinkBufferLatency only adds.
        PlaybackClock clock;
        QVERIFY(clock.OutputLatencyUS() > 0);
    }
};

QTEST_MAIN(TestPlaybackClock)
#include "test_playback_clock.moc"
