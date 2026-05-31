"""MatchFrame degrades gracefully on partial-coverage and offline media.

Origin: tests/integration/test_match_frame_partial_and_offline.lua.

The Lua test pins three scenarios (partial-coverage clamp, stale-volume
file_path + offline_note candidate, missing-file offline) by hand-seeding
multiple master sequences, media rows with stale `/Volumes` paths, and
`offline_note` JSON. None of those fixtures are reachable through real
OS input on the anamnesis template, and there is no UI primitive to
inject offline_note rows, stale-volume media paths, partial-coverage
media_refs, or to flip MatchFrame across an offline master.

Per MIGRATION_ANALYSIS.md (entry for this test, groups with the larger
test_match_frame batch): no smoke rewrite is viable today. Skipped until
either a partial/offline media-fixture primitive exists or the scenarios
are folded into a richer anamnesis template.
"""

import unittest

# TODO: needs offline/partial-coverage media-fixture primitive
# (offline_note injection, stale /Volumes file_path, partial-coverage
# media_ref construction) — see MIGRATION_ANALYSIS.md entry for
# tests/integration/test_match_frame_partial_and_offline.lua.


@unittest.skip("needs offline/partial-coverage media-fixture primitive")
class TestMatchFramePartialAndOffline(unittest.TestCase):
    def test_partial_and_offline_degrade_gracefully(self) -> None:
        pass


if __name__ == "__main__":
    unittest.main()
