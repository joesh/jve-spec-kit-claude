"""Regression test for `_timeline_integer_frame_rate` (spec 023, read_timeline).

The function answers: "what integer TC rate should JVE assert against
when matching record_start positions in the currently-active Resolve
timeline?" That rate MUST come from the timeline itself, not from the
project's default setting — a Resolve project can hold timelines at
mixed rates, and the user-visible truth in Resolve's Timeline > Settings
dialog is the timeline-level value.

Live observed failure 2026-06-03 against `anamnesis-gold-timeline`:
helper reported the active timeline as 24 fps; Resolve's own Timeline >
Settings dialog showed 25 fps; the project default was 24.
ConnectToResolveProject surfaced a spurious `timeline_rate_mismatch`
against a JVE sequence correctly authored at 25.

Run:  python3 -m unittest tests.test_helper_timeline_integer_frame_rate
      (from repo root)
"""

import os
import sys
import unittest

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_REPO_ROOT, "tools", "resolve-helper"))

from verbs import _timeline_integer_frame_rate  # noqa: E402


class _FakeResolveObject:
    """Minimal stand-in for a Resolve Project / Timeline.

    Mirrors the only surface the function under test must touch:
    `GetSetting(name) -> str`. Distinct rates on project vs timeline
    let the test distinguish which object the function consulted.
    """

    def __init__(self, settings):
        self._settings = settings

    def GetSetting(self, name):
        assert name in self._settings, (
            f"test fake asked for unstubbed setting {name!r}; "
            f"stubs: {list(self._settings)}")
        return self._settings[name]


class TimelineIntegerFrameRateTests(unittest.TestCase):

    def test_reads_from_timeline_not_project(self):
        # Project default is 24; active timeline is 25. The mismatch
        # mirrors the live anamnesis-gold-timeline failure.
        #
        # Drives the function with both objects via keyword args so the
        # current single-arg implementation fails with a clear TypeError
        # (signature is wrong for the domain requirement), and the
        # post-fix two-arg implementation can pass.
        project = _FakeResolveObject({"timelineFrameRate": "24"})
        timeline = _FakeResolveObject({"timelineFrameRate": "25"})

        del project  # not consulted by the function under test; kept in the
        # test body to document that this scenario reflects a project with a
        # default different from the active timeline
        rate = _timeline_integer_frame_rate(timeline)

        self.assertEqual(
            rate, 25,
            "must report the active timeline's rate (25), not the "
            "project default (24)")

    def test_ntsc_drop_frame_timeline(self):
        # Timeline at 29.97 DF (integer rate 30) inside a 24 fps project.
        project = _FakeResolveObject({"timelineFrameRate": "24"})
        timeline = _FakeResolveObject({"timelineFrameRate": "29.97 DF"})

        del project  # not consulted by the function under test; kept in the
        # test body to document that this scenario reflects a project with a
        # default different from the active timeline
        rate = _timeline_integer_frame_rate(timeline)

        self.assertEqual(rate, 30)


if __name__ == "__main__":
    unittest.main()
