// Black-box tests for filterVisibleVideoTracks — the mute/solo composite filter.
//
// Domain behavior: during playback the C++ compositor (deliverFrame) walks the
// video tracks top-to-bottom and shows the topmost clip. Muted / non-soloed
// tracks must be excluded from THAT walk — but only the composite, not the
// decode (prefetch keeps every track warm so unmute is instant). This pure
// function is exactly that exclusion: given the candidate tracks (already
// top-to-bottom) and the effective/visible set resolved by Lua, return the
// candidates that composite, order preserved.
//
// Expected values come from NLE compositing semantics, not from tracing code.

#include <QtTest>
#include <vector>
#include "playback_controller.h"

class TestVideoTrackFilter : public QObject {
    Q_OBJECT

private slots:

    // Boot default: Lua hasn't pushed an effective set yet → everything composites.
    void test_invalid_effective_passes_all_through() {
        std::vector<int> candidates{3, 2, 1};
        auto out = filterVisibleVideoTracks(candidates, {}, /*effective_valid=*/false);
        QCOMPARE(out, (std::vector<int>{3, 2, 1}));
    }

    // Even with a non-empty effective set, invalid flag means "not yet known" →
    // pass all (the flag, not the set, gates this).
    void test_invalid_flag_ignores_effective_contents() {
        std::vector<int> candidates{2, 1};
        auto out = filterVisibleVideoTracks(candidates, {2}, /*effective_valid=*/false);
        QCOMPARE(out, (std::vector<int>{2, 1}));
    }

    // All tracks visible → unchanged, order preserved (top-to-bottom).
    void test_all_visible_preserves_order() {
        std::vector<int> candidates{3, 2, 1};
        auto out = filterVisibleVideoTracks(candidates, {1, 2, 3}, true);
        QCOMPARE(out, (std::vector<int>{3, 2, 1}));
    }

    // Mute the topmost (V3): it drops out, V2 becomes the topmost compositor.
    void test_muted_top_track_excluded() {
        std::vector<int> candidates{3, 2, 1};
        auto out = filterVisibleVideoTracks(candidates, {1, 2}, true);
        QCOMPARE(out, (std::vector<int>{2, 1}));  // 3 excluded, order kept
    }

    // Mute a middle track: the gap closes, surrounding order is preserved.
    void test_muted_middle_track_excluded() {
        std::vector<int> candidates{3, 2, 1};
        auto out = filterVisibleVideoTracks(candidates, {3, 1}, true);
        QCOMPARE(out, (std::vector<int>{3, 1}));
    }

    // Solo a single track (effective = just that one): only it composites.
    void test_solo_single_track() {
        std::vector<int> candidates{3, 2, 1};
        auto out = filterVisibleVideoTracks(candidates, {2}, true);
        QCOMPARE(out, (std::vector<int>{2}));
    }

    // Everything muted (valid but empty effective) → nothing composites → black.
    void test_all_muted_yields_empty() {
        std::vector<int> candidates{3, 2, 1};
        auto out = filterVisibleVideoTracks(candidates, {}, true);
        QVERIFY(out.empty());
    }

    // The effective set is authoritative: an index not present in the candidate
    // tracks (no clips there) never appears in the output.
    void test_effective_track_without_clip_is_not_invented() {
        std::vector<int> candidates{2, 1};
        auto out = filterVisibleVideoTracks(candidates, {1, 2, 5}, true);
        QCOMPARE(out, (std::vector<int>{2, 1}));  // 5 has no clip → not added
    }

    // Output ordering always follows the CANDIDATE (composite) order, never the
    // effective-set order — occlusion is top-to-bottom regardless of how Lua
    // happened to order the visible list.
    void test_order_follows_candidates_not_effective() {
        std::vector<int> candidates{3, 2, 1};
        auto out = filterVisibleVideoTracks(candidates, {1, 3, 2}, true);
        QCOMPARE(out, (std::vector<int>{3, 2, 1}));
    }

    // No candidates (no video clips at this frame) → empty regardless of set.
    void test_no_candidates_yields_empty() {
        auto out = filterVisibleVideoTracks({}, {1, 2, 3}, true);
        QVERIFY(out.empty());
    }
};

QTEST_MAIN(TestVideoTrackFilter)
#include "test_video_track_filter.moc"
