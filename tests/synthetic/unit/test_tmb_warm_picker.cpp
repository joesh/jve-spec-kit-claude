// Unit test for TimelineMediaBuffer::pick_proximity_warm_job — the
// READER_WARM job picker that determines which clip's decoder is warmed
// next when the queue has multiple pending jobs.
//
// Failing-test target: the pre-fix LIFO picker would always return the
// LAST-pushed READER_WARM job regardless of playhead. The proximity picker
// must return the job whose sequence_start is closest to the playhead in
// the playback direction.
//
// This is a PURE unit test — no controller, no workers, no audio device.
// Direct calls into a free static function with no side effects.

#include <QtTest>
#include <editor_media_platform/emp_timeline_media_buffer.h>
#include <vector>

using emp::TimelineMediaBuffer;
using emp::TrackId;
using emp::TrackType;

class TestTMBWarmPicker : public QObject
{
    Q_OBJECT

private:
    using Job = TimelineMediaBuffer::PreBufferJob;

    // Build a READER_WARM job at a given sequence_start.
    Job warm(int64_t seq_start, const char* clip_id) {
        Job j;
        j.type = Job::READER_WARM;
        j.track = TrackId{TrackType::Video, 0};
        j.clip_id = clip_id;
        j.media_path = "/dev/null";
        j.sequence_start = seq_start;
        return j;
    }

    // Build a SPEED_DETECT job (picker should ignore these).
    Job probe(int64_t seq_start) {
        Job j;
        j.type = Job::SPEED_DETECT;
        j.track = TrackId{TrackType::Video, 0};
        j.media_path = "/dev/null";
        j.sequence_start = seq_start;  // shouldn't affect ordering
        return j;
    }

private slots:
    void test_empty_returns_minus_one() {
        std::vector<Job> jobs;
        QCOMPARE(TimelineMediaBuffer::pick_proximity_warm_job(jobs, 0, 1), -1);
    }

    void test_single_warm_returned() {
        std::vector<Job> jobs = { warm(100, "A") };
        QCOMPARE(TimelineMediaBuffer::pick_proximity_warm_job(jobs, 0, 1), 0);
    }

    void test_speed_detect_ignored() {
        std::vector<Job> jobs = { probe(100), probe(200) };
        QCOMPARE(TimelineMediaBuffer::pick_proximity_warm_job(jobs, 0, 1), -1);
    }

    // THIS IS THE BUG. Pre-fix LIFO picker would return the last job pushed
    // (index 2, sequence_start=500) regardless of playhead. The proximity
    // picker must return index 0 (sequence_start=100) — closest to playhead=50
    // in the forward direction.
    //
    // In Joe's live diag with Lua pushing clips front-to-back (100, 300, 500),
    // LIFO chose the FURTHEST upcoming clip (500); the imminent one (100) sat
    // at the queue head waiting, which means the prep_worker burned its time
    // warming a clip the playhead wouldn't reach for ~10 wall-seconds while
    // the imminent boundary stalled the picture.
    void test_forward_picks_closest_ahead() {
        // Lua pushes in sequence-start order, just like the real path.
        std::vector<Job> jobs = {
            warm(100, "A"),   // immediately ahead of playhead — should be picked
            warm(300, "B"),
            warm(500, "C"),
        };
        // playhead=50, forward direction. Closest-ahead is A (50 frames ahead).
        QCOMPARE(TimelineMediaBuffer::pick_proximity_warm_job(jobs, 50, 1), 0);
    }

    // Playhead between two clips — pick the one ahead, not behind.
    void test_forward_skips_passed() {
        std::vector<Job> jobs = {
            warm(100, "A"),   // BEHIND playhead — should NOT be picked
            warm(300, "B"),   // ahead, closest — should be picked
            warm(500, "C"),
        };
        QCOMPARE(TimelineMediaBuffer::pick_proximity_warm_job(jobs, 200, 1), 1);
    }

    // Reverse playback: closest behind (in time, ahead in reverse direction).
    void test_reverse_picks_closest_behind_playhead() {
        std::vector<Job> jobs = {
            warm(100, "A"),
            warm(300, "B"),   // closest behind playhead=400 — should be picked
            warm(500, "C"),   // ahead of playhead in reverse — NOT picked
        };
        QCOMPARE(TimelineMediaBuffer::pick_proximity_warm_job(jobs, 400, -1), 1);
    }

    // Fallback: every job is behind the playhead in the current direction.
    // Picker falls back to closest-by-abs-distance. This happens when the
    // playhead has raced past multiple submitted-but-unprocessed clips.
    void test_all_behind_falls_back_to_closest_abs() {
        std::vector<Job> jobs = {
            warm(100, "A"),
            warm(200, "B"),   // closest to playhead=300 — should be picked
            warm(150, "C"),
        };
        // All BEHIND playhead=300 in forward direction.
        QCOMPARE(TimelineMediaBuffer::pick_proximity_warm_job(jobs, 300, 1), 1);
    }

    // Park (direction=0): pick closest by absolute distance.
    void test_park_picks_abs_closest() {
        std::vector<Job> jobs = {
            warm(100, "A"),   // 100 from playhead
            warm(220, "B"),   // 20 from playhead — should be picked
            warm(400, "C"),   // 200 from playhead
        };
        QCOMPARE(TimelineMediaBuffer::pick_proximity_warm_job(jobs, 200, 0), 1);
    }

    // Mix of WARM and SPEED_DETECT: WARM proximity ignores SPEED_DETECT slots.
    void test_mixed_ignores_probes_in_index_count() {
        std::vector<Job> jobs = {
            probe(50),        // index 0 — ignored
            warm(100, "A"),   // index 1 — picked (closest ahead)
            warm(500, "B"),   // index 2
        };
        QCOMPARE(TimelineMediaBuffer::pick_proximity_warm_job(jobs, 0, 1), 1);
    }

    // Exact-match (playhead == sequence_start): signed_dist == 0, still picks.
    void test_playhead_at_seq_start_picks_zero_dist() {
        std::vector<Job> jobs = {
            warm(100, "A"),
            warm(200, "B"),   // playhead lands exactly here — dist=0 wins
            warm(300, "C"),
        };
        QCOMPARE(TimelineMediaBuffer::pick_proximity_warm_job(jobs, 200, 1), 1);
    }
};

QTEST_GUILESS_MAIN(TestTMBWarmPicker)
#include "test_tmb_warm_picker.moc"
