// Tests for SSE pitch preservation (WSOLA time-stretch).
//
// DOMAIN BEHAVIOR (NLE convention, FCP/Resolve/Premiere): when you play a clip
// faster or slower inside the pitch-corrected speed band, the *content plays at a
// different rate but the PITCH does not change* — a 440 Hz tone stays 440 Hz at
// 2x, not 880 Hz ("chipmunk"). That is the whole point of time-stretch vs. the
// naive resample (varispeed) that shifts pitch with speed.
//
// These tests feed a pure sine and measure its fundamental frequency from the
// rendered output. They make NO reference to how the engine achieves this; they
// assert only the audible outcome: fundamental frequency is preserved across the
// Q1 (1x-4x) and Q2 (<0.25x slomo) pitch-corrected bands.
//
// A varispeed engine FAILS these: at 2x the measured fundamental is ~2x the
// source. That contrast is what makes the test able to catch the regression.

#include <QtTest>
#include <cmath>
#include <vector>

#include <scrub_stretch_engine/sse.h>

class TestSSEPitch : public QObject
{
    Q_OBJECT

private:
    static constexpr float PI = 3.14159265358979f;

    // Generate a pure sine tone, interleaved across `channels`.
    std::vector<float> generate_sine(double freq_hz, int64_t frames, int channels,
                                     int sample_rate, float amp = 0.5f) {
        std::vector<float> pcm(static_cast<size_t>(frames * channels));
        for (int64_t i = 0; i < frames; ++i) {
            float s = amp * std::sin(2.0 * PI * freq_hz * (double)i / (double)sample_rate);
            for (int c = 0; c < channels; ++c) {
                pcm[static_cast<size_t>(i * channels + c)] = s;
            }
        }
        return pcm;
    }

    // Estimate fundamental frequency of a mono signal by counting sign changes
    // (zero crossings). For a clean tone, freq = (crossings / 2) / duration.
    // Samples near zero are ignored so amplitude modulation from overlap-add
    // does not inject spurious crossings.
    double measure_freq_zcr(const std::vector<float>& mono, int sample_rate) {
        const float eps = 0.02f;
        int crossings = 0;
        int last_sign = 0;
        int counted = 0;
        for (float x : mono) {
            if (std::abs(x) < eps) continue;
            int sign = (x > 0.0f) ? 1 : -1;
            if (last_sign != 0 && sign != last_sign) crossings++;
            last_sign = sign;
            counted++;
        }
        if (counted == 0) return 0.0;
        double duration = (double)mono.size() / (double)sample_rate;
        return (crossings / 2.0) / duration;
    }

    // Render `blocks` of 512 frames at the given target, return channel-0 output
    // with the first `skip_blocks` discarded (window ramp-up / startup transient).
    std::vector<float> render_mono(sse::ScrubStretchEngine* engine, int channels,
                                   int blocks, int skip_blocks) {
        std::vector<float> out;
        std::vector<float> block(512 * channels);
        for (int b = 0; b < blocks; ++b) {
            engine->Render(block.data(), 512);
            if (b < skip_blocks) continue;
            for (int i = 0; i < 512; ++i) out.push_back(block[i * channels]);
        }
        return out;
    }

private slots:

    // 2x forward in Q1 must preserve pitch: a 440 Hz tone stays ~440 Hz, NOT 880.
    void test_q1_2x_preserves_pitch() {
        sse::SseConfig cfg = sse::default_config();
        auto engine = sse::ScrubStretchEngine::Create(cfg);

        const double tone = 440.0;
        int64_t frames = cfg.sample_rate * 20;  // 20s source headroom for 2x
        auto pcm = generate_sine(tone, frames, cfg.channels, cfg.sample_rate);
        engine->PushSourcePcm(pcm.data(), frames, 0);

        engine->SetTarget(0, 2.0f, sse::QualityMode::Q1);
        auto mono = render_mono(engine.get(), cfg.channels, 200, 4);

        double f = measure_freq_zcr(mono, cfg.sample_rate);
        QVERIFY2(std::abs(f - tone) < 60.0,
            qPrintable(QString("2x Q1 fundamental %1 Hz; expected ~%2 Hz (pitch must "
                "not scale with speed). Varispeed would read ~880.").arg(f).arg(tone)));
    }

    // 3x forward in Q1 must also preserve pitch.
    void test_q1_3x_preserves_pitch() {
        sse::SseConfig cfg = sse::default_config();
        auto engine = sse::ScrubStretchEngine::Create(cfg);

        const double tone = 440.0;
        int64_t frames = cfg.sample_rate * 30;
        auto pcm = generate_sine(tone, frames, cfg.channels, cfg.sample_rate);
        engine->PushSourcePcm(pcm.data(), frames, 0);

        engine->SetTarget(0, 3.0f, sse::QualityMode::Q1);
        auto mono = render_mono(engine.get(), cfg.channels, 200, 4);

        double f = measure_freq_zcr(mono, cfg.sample_rate);
        QVERIFY2(std::abs(f - tone) < 70.0,
            qPrintable(QString("3x Q1 fundamental %1 Hz; expected ~%2 Hz").arg(f).arg(tone)));
    }

    // 1.5x — the case Joe hears chipmunking at (1.25-1.5x). Must preserve pitch.
    void test_q1_1_5x_preserves_pitch() {
        sse::SseConfig cfg = sse::default_config();
        auto engine = sse::ScrubStretchEngine::Create(cfg);

        const double tone = 440.0;
        int64_t frames = cfg.sample_rate * 20;
        auto pcm = generate_sine(tone, frames, cfg.channels, cfg.sample_rate);
        engine->PushSourcePcm(pcm.data(), frames, 0);

        engine->SetTarget(0, 1.5f, sse::QualityMode::Q1);
        auto mono = render_mono(engine.get(), cfg.channels, 200, 4);

        double f = measure_freq_zcr(mono, cfg.sample_rate);
        QVERIFY2(std::abs(f - tone) < 55.0,
            qPrintable(QString("1.5x Q1 fundamental %1 Hz; expected ~%2 Hz").arg(f).arg(tone)));
    }

    // Slow-mo in Q2 must preserve pitch (0.2x stays 440, not ~88 Hz).
    void test_q2_slomo_preserves_pitch() {
        sse::SseConfig cfg = sse::default_config();
        auto engine = sse::ScrubStretchEngine::Create(cfg);

        const double tone = 440.0;
        int64_t frames = cfg.sample_rate * 10;
        auto pcm = generate_sine(tone, frames, cfg.channels, cfg.sample_rate);
        engine->PushSourcePcm(pcm.data(), frames, 0);

        // Start a couple seconds in so slomo has source on both sides.
        engine->SetTarget(2000000, 0.2f, sse::QualityMode::Q2);
        auto mono = render_mono(engine.get(), cfg.channels, 200, 4);

        double f = measure_freq_zcr(mono, cfg.sample_rate);
        QVERIFY2(std::abs(f - tone) < 55.0,
            qPrintable(QString("0.2x Q2 fundamental %1 Hz; expected ~%2 Hz").arg(f).arg(tone)));
    }

    // Reverse at 2x in Q1 must preserve pitch (sign of speed doesn't shift pitch).
    void test_q1_reverse_2x_preserves_pitch() {
        sse::SseConfig cfg = sse::default_config();
        auto engine = sse::ScrubStretchEngine::Create(cfg);

        const double tone = 440.0;
        int64_t frames = cfg.sample_rate * 20;
        auto pcm = generate_sine(tone, frames, cfg.channels, cfg.sample_rate);
        engine->PushSourcePcm(pcm.data(), frames, 0);

        // Start near the end, play backward at 2x.
        engine->SetTarget(15000000, -2.0f, sse::QualityMode::Q1);
        auto mono = render_mono(engine.get(), cfg.channels, 200, 4);

        double f = measure_freq_zcr(mono, cfg.sample_rate);
        QVERIFY2(std::abs(f - tone) < 70.0,
            qPrintable(QString("-2x Q1 fundamental %1 Hz; expected ~%2 Hz").arg(f).arg(tone)));
    }

    // Q3 decimate is INTENTIONALLY varispeed (chipmunk above 4x): at 8x the
    // fundamental SHOULD scale with speed. This pins that decimate is NOT
    // pitch-corrected, so the Q1/Q2 branch is genuinely separate.
    void test_q3_decimate_does_not_pitch_correct() {
        sse::SseConfig cfg = sse::default_config();
        auto engine = sse::ScrubStretchEngine::Create(cfg);

        const double tone = 440.0;
        int64_t frames = cfg.sample_rate * 60;
        auto pcm = generate_sine(tone, frames, cfg.channels, cfg.sample_rate);
        engine->PushSourcePcm(pcm.data(), frames, 0);

        engine->SetTarget(0, 8.0f, sse::QualityMode::Q3_DECIMATE);
        auto mono = render_mono(engine.get(), cfg.channels, 100, 4);

        double f = measure_freq_zcr(mono, cfg.sample_rate);
        // 8x varispeed → ~3520 Hz. Assert it is clearly NOT held near 440.
        QVERIFY2(f > 1500.0,
            qPrintable(QString("8x Q3 fundamental %1 Hz; decimate must NOT pitch-correct "
                "(expected to scale up with speed)").arg(f)));
    }
};

QTEST_MAIN(TestSSEPitch)
#include "test_sse_pitch.moc"
