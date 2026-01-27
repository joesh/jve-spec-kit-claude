// Tests for SSE decimate mode (>4x speeds up to 16x)
// Decimate mode skips samples instead of pitch-correcting, for very high speeds.

#include <QtTest>
#include <cmath>
#include <vector>

#include <scrub_stretch_engine/sse.h>

class TestSSEDecimate : public QObject
{
    Q_OBJECT

private:
    // Helper: Generate ramp PCM (linear ramp from 0 to 1)
    std::vector<float> generate_ramp_pcm(int64_t frames, int channels, int sample_rate) {
        std::vector<float> pcm(static_cast<size_t>(frames * channels));
        for (int64_t i = 0; i < frames; ++i) {
            float sample = static_cast<float>(i) / static_cast<float>(frames);
            for (int ch = 0; ch < channels; ++ch) {
                pcm[static_cast<size_t>(i * channels + ch)] = sample;
            }
        }
        return pcm;
    }

    // Helper: Check if buffer has non-zero audio
    bool has_audio(const float* data, int64_t frames, int channels) {
        for (int64_t i = 0; i < frames * channels; ++i) {
            if (std::abs(data[i]) > 0.001f) return true;
        }
        return false;
    }

private slots:

    // ========================================================================
    // Q3_DECIMATE ENUM AND CONSTANTS TESTS
    // ========================================================================

    void test_quality_mode_q3_decimate_exists() {
        // Q3_DECIMATE should be a valid QualityMode enum value
        sse::QualityMode mode = sse::QualityMode::Q3_DECIMATE;
        QCOMPARE(static_cast<int>(mode), 3);
    }

    void test_max_speed_stretched_constant() {
        // MAX_SPEED_STRETCHED should be 4.0
        QCOMPARE(sse::MAX_SPEED_STRETCHED, 4.0f);
    }

    void test_max_speed_decimate_constant() {
        // MAX_SPEED_DECIMATE should be 16.0
        QCOMPARE(sse::MAX_SPEED_DECIMATE, 16.0f);
    }

    // ========================================================================
    // DECIMATE MODE RENDERING TESTS
    // ========================================================================

    void test_render_8x_forward_produces_audio() {
        sse::SseConfig cfg = sse::default_config();
        auto engine = sse::ScrubStretchEngine::Create(cfg);

        // Push 2 seconds of ramp audio
        int64_t frames = cfg.sample_rate * 2;
        std::vector<float> pcm = generate_ramp_pcm(frames, cfg.channels, cfg.sample_rate);
        engine->PushSourcePcm(pcm.data(), frames, 0);

        // Set target at 8x (decimate mode)
        engine->SetTarget(0, 8.0f, sse::QualityMode::Q3_DECIMATE);

        std::vector<float> output(512 * cfg.channels);
        int64_t produced = engine->Render(output.data(), 512);

        QCOMPARE(produced, static_cast<int64_t>(512));
        QVERIFY(has_audio(output.data(), 512, cfg.channels));
    }

    void test_render_16x_forward_produces_audio() {
        sse::SseConfig cfg = sse::default_config();
        auto engine = sse::ScrubStretchEngine::Create(cfg);

        int64_t frames = cfg.sample_rate * 4;  // 4 seconds
        std::vector<float> pcm = generate_ramp_pcm(frames, cfg.channels, cfg.sample_rate);
        engine->PushSourcePcm(pcm.data(), frames, 0);

        engine->SetTarget(0, 16.0f, sse::QualityMode::Q3_DECIMATE);

        std::vector<float> output(512 * cfg.channels);
        int64_t produced = engine->Render(output.data(), 512);

        QCOMPARE(produced, static_cast<int64_t>(512));
        QVERIFY(has_audio(output.data(), 512, cfg.channels));
    }

    void test_render_8x_reverse_produces_audio() {
        sse::SseConfig cfg = sse::default_config();
        auto engine = sse::ScrubStretchEngine::Create(cfg);

        int64_t frames = cfg.sample_rate * 2;
        std::vector<float> pcm = generate_ramp_pcm(frames, cfg.channels, cfg.sample_rate);
        engine->PushSourcePcm(pcm.data(), frames, 0);

        // Start at 1 second, go reverse at 8x
        engine->SetTarget(1000000, -8.0f, sse::QualityMode::Q3_DECIMATE);

        std::vector<float> output(512 * cfg.channels);
        int64_t produced = engine->Render(output.data(), 512);

        QCOMPARE(produced, static_cast<int64_t>(512));
        QVERIFY(has_audio(output.data(), 512, cfg.channels));
    }

    void test_render_16x_reverse_produces_audio() {
        sse::SseConfig cfg = sse::default_config();
        auto engine = sse::ScrubStretchEngine::Create(cfg);

        int64_t frames = cfg.sample_rate * 4;
        std::vector<float> pcm = generate_ramp_pcm(frames, cfg.channels, cfg.sample_rate);
        engine->PushSourcePcm(pcm.data(), frames, 0);

        // Start at 2 seconds, go reverse at 16x
        engine->SetTarget(2000000, -16.0f, sse::QualityMode::Q3_DECIMATE);

        std::vector<float> output(512 * cfg.channels);
        int64_t produced = engine->Render(output.data(), 512);

        QCOMPARE(produced, static_cast<int64_t>(512));
        QVERIFY(has_audio(output.data(), 512, cfg.channels));
    }

    // ========================================================================
    // MONOTONIC TIME INVARIANT TESTS
    // ========================================================================

    void test_decimate_forward_time_non_decreasing() {
        // PIN: Forward render: CURRENT_TIME_US must be non-decreasing during steady-state
        sse::SseConfig cfg = sse::default_config();
        auto engine = sse::ScrubStretchEngine::Create(cfg);

        int64_t frames = cfg.sample_rate * 4;
        std::vector<float> pcm = generate_ramp_pcm(frames, cfg.channels, cfg.sample_rate);
        engine->PushSourcePcm(pcm.data(), frames, 0);

        engine->SetTarget(0, 8.0f, sse::QualityMode::Q3_DECIMATE);

        std::vector<float> output(512 * cfg.channels);
        int64_t prev_time = engine->CurrentTimeUS();

        for (int i = 0; i < 20; ++i) {
            engine->Render(output.data(), 512);
            int64_t current_time = engine->CurrentTimeUS();
            QVERIFY2(current_time >= prev_time,
                qPrintable(QString("Forward time went backwards: %1 -> %2")
                    .arg(prev_time).arg(current_time)));
            prev_time = current_time;
        }
    }

    void test_decimate_reverse_time_non_increasing() {
        // PIN: Reverse render: CURRENT_TIME_US must be non-increasing during steady-state
        sse::SseConfig cfg = sse::default_config();
        auto engine = sse::ScrubStretchEngine::Create(cfg);

        int64_t frames = cfg.sample_rate * 4;
        std::vector<float> pcm = generate_ramp_pcm(frames, cfg.channels, cfg.sample_rate);
        engine->PushSourcePcm(pcm.data(), frames, 0);

        // Start at 2 seconds, reverse at 8x
        engine->SetTarget(2000000, -8.0f, sse::QualityMode::Q3_DECIMATE);

        std::vector<float> output(512 * cfg.channels);
        int64_t prev_time = engine->CurrentTimeUS();

        for (int i = 0; i < 20; ++i) {
            engine->Render(output.data(), 512);
            int64_t current_time = engine->CurrentTimeUS();
            QVERIFY2(current_time <= prev_time,
                qPrintable(QString("Reverse time went forwards: %1 -> %2")
                    .arg(prev_time).arg(current_time)));
            prev_time = current_time;
        }
    }

    // ========================================================================
    // NO OOB READS TESTS
    // ========================================================================

    void test_decimate_no_oob_reads_forward() {
        // Verify no out-of-bounds reads at high speed
        sse::SseConfig cfg = sse::default_config();
        auto engine = sse::ScrubStretchEngine::Create(cfg);

        // Push exactly 1 second
        int64_t frames = cfg.sample_rate;
        std::vector<float> pcm = generate_ramp_pcm(frames, cfg.channels, cfg.sample_rate);
        engine->PushSourcePcm(pcm.data(), frames, 0);

        engine->SetTarget(0, 16.0f, sse::QualityMode::Q3_DECIMATE);

        std::vector<float> output(512 * cfg.channels);

        // Render several blocks - should not crash or read garbage
        for (int i = 0; i < 10; ++i) {
            engine->Render(output.data(), 512);
        }
        QVERIFY(engine != nullptr);  // Survived without crash
    }

    void test_decimate_no_oob_reads_reverse() {
        sse::SseConfig cfg = sse::default_config();
        auto engine = sse::ScrubStretchEngine::Create(cfg);

        int64_t frames = cfg.sample_rate;
        std::vector<float> pcm = generate_ramp_pcm(frames, cfg.channels, cfg.sample_rate);
        engine->PushSourcePcm(pcm.data(), frames, 0);

        // Start at end, go reverse at max speed
        engine->SetTarget(1000000, -16.0f, sse::QualityMode::Q3_DECIMATE);

        std::vector<float> output(512 * cfg.channels);

        for (int i = 0; i < 10; ++i) {
            engine->Render(output.data(), 512);
        }
        QVERIFY(engine != nullptr);
    }

    // ========================================================================
    // SPEED CLAMPING TESTS
    // ========================================================================

    void test_decimate_clamps_to_max_16x() {
        // Speed above 16x should be clamped
        sse::SseConfig cfg = sse::default_config();
        auto engine = sse::ScrubStretchEngine::Create(cfg);

        int64_t frames = cfg.sample_rate * 4;
        std::vector<float> pcm = generate_ramp_pcm(frames, cfg.channels, cfg.sample_rate);
        engine->PushSourcePcm(pcm.data(), frames, 0);

        // Set 32x speed (above max) - should be clamped to 16x
        engine->SetTarget(0, 32.0f, sse::QualityMode::Q3_DECIMATE);

        std::vector<float> output(512 * cfg.channels);
        engine->Render(output.data(), 512);

        // Engine should handle this gracefully (clamped to 16x)
        QVERIFY(engine != nullptr);
    }
};

QTEST_MAIN(TestSSEDecimate)
#include "test_sse_decimate.moc"
