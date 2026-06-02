# Offline tests for cdl_edl.py (spec 023 T029b parser layer).
#
# Run: `python3 -m unittest tools.resolve-helper.test_cdl_edl` from the
# repo root, or `python3 -m unittest test_cdl_edl` from
# tools/resolve-helper/.
#
# Coverage discipline (ENGINEERING 2.32):
#   - happy path with non-trivial CDL values (data-model.md §non-trivial
#     test values)
#   - boundary: TC at exactly 01:00:00:00 (timeline start), at non-zero
#     hour, with frame field = rate-1, NTSC drop-frame
#   - empty EDL (only TITLE/FCM/blank) — returns {}
#   - ungraded clip (identity CDL still emitted by Resolve) — present
#   - multi-event EDL with mixed graded/identity items
#   - failure paths via assertRaises, all asserting message specificity
#
# Test values derive from domain math (TC math, ASC CDL spec) not from
# tracing the parser — rule 2.34.

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cdl_edl import (
    CdlEdlParseError,
    classify_fidelity,
    integer_frame_rate_from_setting,
    parse_cdl_edl,
    tc_to_frames,
)


_LIVE_RESOLVE_EXAMPLE = """\
TITLE: /tmp/sample.edl
FCM: NON-DROP FRAME

001  AX       V     C        00:00:00:00 00:00:04:12 01:00:00:00 01:00:04:12
*ASC_SOP (1.000000 1.000000 1.000000)(0.000000 0.000000 0.000000)(1.000000 1.000000 1.000000)
*ASC_SAT 1.000000
"""

# Non-trivial CDL per data-model.md §107: slope (1.05, 0.98, 0.92),
# offset (0.01, 0.0, -0.02), power (1.1, 1.0, 0.95), sat 0.85.
_NON_TRIVIAL_EVENT = (
    "002  AX       V     C        "
    "00:00:00:00 00:00:02:00 01:00:04:12 01:00:06:12  \n"
    "*ASC_SOP (1.050000 0.980000 0.920000)"
    "(0.010000 0.000000 -0.020000)"
    "(1.100000 1.000000 0.950000)\n"
    "*ASC_SAT 0.850000\n"
)


class TcToFramesTests(unittest.TestCase):
    def test_timeline_start_at_01h_24fps(self):
        # 01:00:00:00 @ 24fps = 1*3600*24 = 86400. Confirms parity with
        # Resolve's timeline.GetStartFrame() = 86400 for that TC.
        self.assertEqual(tc_to_frames("01:00:00:00", 24), 86400)

    def test_known_offset_at_01h_4s_12f_24fps(self):
        # Derived: 86400 + 4*24 + 12 = 86508.
        self.assertEqual(tc_to_frames("01:00:04:12", 24), 86508)

    def test_zero_tc(self):
        self.assertEqual(tc_to_frames("00:00:00:00", 24), 0)

    def test_last_frame_of_second(self):
        # 00:00:00:23 @ 24fps = 23. ff = rate-1 is the largest legal
        # frame field.
        self.assertEqual(tc_to_frames("00:00:00:23", 24), 23)

    def test_25fps(self):
        # PAL: 01:00:00:00 @ 25 = 90000.
        self.assertEqual(tc_to_frames("01:00:00:00", 25), 90000)

    def test_30fps_non_drop(self):
        self.assertEqual(tc_to_frames("00:01:00:00", 30), 1800)

    def test_drop_frame_29_97_two_drops_per_minute(self):
        # SMPTE DF at 30: at 00:01:00;02 the absolute frame count is
        # 1800. base = (1*60)*30 + 2 = 1802; drop_per_minute=2;
        # total_minutes=1; subtract 2*(1 - 0) = 2 → 1800.
        self.assertEqual(tc_to_frames("00:01:00;02", 30), 1800)

    def test_drop_frame_at_10_minute_boundary_no_drop(self):
        # Every 10th minute is NOT dropped. 00:10:00;00 → base =
        # 10*60*30 = 18000; subtract drop_per_minute=2 *
        # (total_minutes 10 - 10//10 = 1) = 2*9 = 18; expected 17982.
        self.assertEqual(tc_to_frames("00:10:00;00", 30), 17982)

    def test_drop_frame_unsupported_rate_raises(self):
        with self.assertRaises(CdlEdlParseError) as cm:
            tc_to_frames("00:01:00;02", 24)
        self.assertIn("not 30 or 60", str(cm.exception))

    def test_malformed_tc_too_few_fields(self):
        with self.assertRaises(CdlEdlParseError) as cm:
            tc_to_frames("01:00:00", 24)
        self.assertIn("HH:MM:SS:FF", str(cm.exception))

    def test_malformed_tc_alpha(self):
        with self.assertRaises(CdlEdlParseError) as cm:
            tc_to_frames("aa:bb:cc:dd", 24)
        self.assertIn("non-integer", str(cm.exception))

    def test_frame_field_exceeds_rate(self):
        # 00:00:00:24 @ 24fps is illegal (max ff is 23).
        with self.assertRaises(CdlEdlParseError) as cm:
            tc_to_frames("00:00:00:24", 24)
        self.assertIn(">=", str(cm.exception))

    def test_empty_tc_string(self):
        with self.assertRaises(CdlEdlParseError):
            tc_to_frames("", 24)

    def test_negative_rate(self):
        with self.assertRaises(CdlEdlParseError):
            tc_to_frames("00:00:00:00", -24)


class FrameRateSettingTests(unittest.TestCase):
    def test_integer_string(self):
        self.assertEqual(integer_frame_rate_from_setting("24"), 24)

    def test_decimal_integer(self):
        # Resolve emits "24.0" for 24fps timelines (verified live).
        self.assertEqual(integer_frame_rate_from_setting("24.0"), 24)

    def test_ntsc_progressive(self):
        self.assertEqual(integer_frame_rate_from_setting("23.976"), 24)

    def test_ntsc_drop(self):
        self.assertEqual(integer_frame_rate_from_setting("29.97"), 30)

    def test_pal(self):
        self.assertEqual(integer_frame_rate_from_setting("25"), 25)

    def test_60(self):
        self.assertEqual(integer_frame_rate_from_setting("60"), 60)

    def test_59_94(self):
        self.assertEqual(integer_frame_rate_from_setting("59.94"), 60)

    def test_unknown_rate_raises(self):
        with self.assertRaises(CdlEdlParseError) as cm:
            integer_frame_rate_from_setting("12.5")
        self.assertIn("not a recognised TC counter rate", str(cm.exception))

    def test_accepts_float_per_live_resolve(self):
        # Resolve Studio 20.3.2.9 returns timelineFrameRate as float
        # (24.0) even though the BMD docs say string. Live evidence
        # from 2026-06-02 smoke probe.
        self.assertEqual(integer_frame_rate_from_setting(24.0), 24)
        self.assertEqual(integer_frame_rate_from_setting(23.976), 24)
        self.assertEqual(integer_frame_rate_from_setting(29.97), 30)

    def test_accepts_int(self):
        # Defensive: some legacy Resolve versions may return int for
        # integer rates.
        self.assertEqual(integer_frame_rate_from_setting(24), 24)
        self.assertEqual(integer_frame_rate_from_setting(60), 60)

    def test_bool_raises(self):
        # bool is a subclass of int — without the explicit guard, True
        # would round to 1 and crash the closed-set check far from the
        # cause. Caught at the boundary instead.
        with self.assertRaises(CdlEdlParseError) as cm:
            integer_frame_rate_from_setting(True)
        self.assertIn("bool", str(cm.exception))

    def test_other_types_raise(self):
        with self.assertRaises(CdlEdlParseError):
            integer_frame_rate_from_setting(None)
        with self.assertRaises(CdlEdlParseError):
            integer_frame_rate_from_setting([24])

    def test_empty_string_raises(self):
        with self.assertRaises(CdlEdlParseError):
            integer_frame_rate_from_setting("")

    def test_unparseable_raises(self):
        with self.assertRaises(CdlEdlParseError):
            integer_frame_rate_from_setting("not a number")


class ParseCdlEdlHappyPathTests(unittest.TestCase):
    def test_live_resolve_identity_emission(self):
        # Verbatim bytes captured from a live Resolve EDL export on
        # 2026-06-02 (ungraded clip → identity CDL). Confirms the parser
        # accepts Resolve's actual format, not a tidied version.
        out = parse_cdl_edl(_LIVE_RESOLVE_EXAMPLE, 24)
        # rec_in = 01:00:00:00 @ 24 = 86400.
        self.assertEqual(set(out.keys()), {86400})
        row = out[86400]
        self.assertEqual(row["slope"],  [1.0, 1.0, 1.0])
        self.assertEqual(row["offset"], [0.0, 0.0, 0.0])
        self.assertEqual(row["power"],  [1.0, 1.0, 1.0])
        self.assertEqual(row["sat"],    1.0)

    def test_non_trivial_cdl_values(self):
        # data-model.md §107: non-unity per-channel values that would
        # expose channel-swap bugs.
        out = parse_cdl_edl(_NON_TRIVIAL_EVENT, 24)
        # rec_in = 01:00:04:12 @ 24 = 86508.
        self.assertEqual(set(out.keys()), {86508})
        row = out[86508]
        self.assertEqual(row["slope"],  [1.05, 0.98, 0.92])
        self.assertEqual(row["offset"], [0.01, 0.0, -0.02])
        self.assertEqual(row["power"],  [1.1, 1.0, 0.95])
        self.assertEqual(row["sat"],    0.85)

    def test_multi_event_mixed(self):
        text = (
            "TITLE: /tmp/multi.edl\n"
            "FCM: NON-DROP FRAME\n"
            "\n"
            "001  AX       V     C        "
            "00:00:00:00 00:00:04:12 01:00:00:00 01:00:04:12\n"
            "*ASC_SOP (1.0 1.0 1.0)(0.0 0.0 0.0)(1.0 1.0 1.0)\n"
            "*ASC_SAT 1.0\n"
            + _NON_TRIVIAL_EVENT
        )
        out = parse_cdl_edl(text, 24)
        self.assertEqual(set(out.keys()), {86400, 86508})
        self.assertEqual(out[86400]["sat"], 1.0)
        self.assertEqual(out[86508]["sat"], 0.85)

    def test_empty_edl(self):
        # Only TITLE/FCM/blank lines → no events → {}.
        text = "TITLE: /tmp/empty.edl\nFCM: NON-DROP FRAME\n\n"
        self.assertEqual(parse_cdl_edl(text, 24), {})

    def test_event_without_cdl_block_is_skipped(self):
        # Defensive: a Resolve future might emit events without CDL.
        text = (
            "TITLE: /tmp/x.edl\nFCM: NON-DROP FRAME\n\n"
            "001  AX       V     C        "
            "00:00:00:00 00:00:04:12 01:00:00:00 01:00:04:12\n"
            "* FROM CLIP NAME: foo.mov\n"
        )
        self.assertEqual(parse_cdl_edl(text, 24), {})

    def test_from_clip_name_comment_does_not_disturb_parse(self):
        text = (
            "TITLE: /tmp/x.edl\nFCM: NON-DROP FRAME\n\n"
            "001  AX       V     C        "
            "00:00:00:00 00:00:04:12 01:00:00:00 01:00:04:12\n"
            "* FROM CLIP NAME: foo.mov\n"
            "*ASC_SOP (1.0 1.0 1.0)(0.0 0.0 0.0)(1.0 1.0 1.0)\n"
            "*ASC_SAT 1.0\n"
        )
        self.assertIn(86400, parse_cdl_edl(text, 24))

    def test_negative_offset_supported(self):
        # ASC CDL offset is a free-signed value (the "lift" axis).
        text = (
            "001  AX       V     C        "
            "00:00:00:00 00:00:01:00 01:00:00:00 01:00:01:00\n"
            "*ASC_SOP (1.0 1.0 1.0)(-0.05 -0.10 -0.02)(1.0 1.0 1.0)\n"
            "*ASC_SAT 1.0\n"
        )
        out = parse_cdl_edl(text, 24)
        self.assertEqual(out[86400]["offset"], [-0.05, -0.10, -0.02])


class ParseCdlEdlFailurePathTests(unittest.TestCase):
    def test_sop_without_sat_at_eof(self):
        text = (
            "001  AX       V     C        "
            "00:00:00:00 00:00:01:00 01:00:00:00 01:00:01:00\n"
            "*ASC_SOP (1.0 1.0 1.0)(0.0 0.0 0.0)(1.0 1.0 1.0)\n"
        )
        with self.assertRaises(CdlEdlParseError) as cm:
            parse_cdl_edl(text, 24)
        msg = str(cm.exception)
        self.assertIn("ASC_SOP", msg)
        self.assertIn("ASC_SAT", msg)

    def test_sop_without_sat_before_next_event(self):
        text = (
            "001  AX       V     C        "
            "00:00:00:00 00:00:01:00 01:00:00:00 01:00:01:00\n"
            "*ASC_SOP (1.0 1.0 1.0)(0.0 0.0 0.0)(1.0 1.0 1.0)\n"
            "002  AX       V     C        "
            "00:00:00:00 00:00:01:00 01:00:01:00 01:00:02:00\n"
            "*ASC_SOP (1.0 1.0 1.0)(0.0 0.0 0.0)(1.0 1.0 1.0)\n"
            "*ASC_SAT 1.0\n"
        )
        with self.assertRaises(CdlEdlParseError):
            parse_cdl_edl(text, 24)

    def test_sat_without_sop(self):
        text = (
            "001  AX       V     C        "
            "00:00:00:00 00:00:01:00 01:00:00:00 01:00:01:00\n"
            "*ASC_SAT 1.0\n"
        )
        with self.assertRaises(CdlEdlParseError) as cm:
            parse_cdl_edl(text, 24)
        self.assertIn("ASC_SAT without preceding", str(cm.exception))

    def test_sop_wrong_arity(self):
        text = (
            "001  AX       V     C        "
            "00:00:00:00 00:00:01:00 01:00:00:00 01:00:01:00\n"
            "*ASC_SOP (1.0 1.0)(0.0 0.0 0.0)(1.0 1.0 1.0)\n"
            "*ASC_SAT 1.0\n"
        )
        with self.assertRaises(CdlEdlParseError) as cm:
            parse_cdl_edl(text, 24)
        self.assertIn("slope", str(cm.exception))

    def test_sop_non_numeric(self):
        text = (
            "001  AX       V     C        "
            "00:00:00:00 00:00:01:00 01:00:00:00 01:00:01:00\n"
            "*ASC_SOP (xxx 1.0 1.0)(0.0 0.0 0.0)(1.0 1.0 1.0)\n"
            "*ASC_SAT 1.0\n"
        )
        with self.assertRaises(CdlEdlParseError) as cm:
            parse_cdl_edl(text, 24)
        self.assertIn("non-numeric", str(cm.exception))

    def test_sat_non_numeric_falls_to_eof_error(self):
        # ASC_SAT regex requires numeric; a non-numeric line falls
        # through to "ignored", leaving the SOP pending → caught at EOF.
        text = (
            "001  AX       V     C        "
            "00:00:00:00 00:00:01:00 01:00:00:00 01:00:01:00\n"
            "*ASC_SOP (1.0 1.0 1.0)(0.0 0.0 0.0)(1.0 1.0 1.0)\n"
            "*ASC_SAT yyy\n"
        )
        with self.assertRaises(CdlEdlParseError):
            parse_cdl_edl(text, 24)

    def test_duplicate_record_in(self):
        text = (
            "001  AX       V     C        "
            "00:00:00:00 00:00:01:00 01:00:00:00 01:00:01:00\n"
            "*ASC_SOP (1.0 1.0 1.0)(0.0 0.0 0.0)(1.0 1.0 1.0)\n"
            "*ASC_SAT 1.0\n"
            "002  AX       V     C        "
            "00:00:00:00 00:00:01:00 01:00:00:00 01:00:01:00\n"
            "*ASC_SOP (1.0 1.0 1.0)(0.0 0.0 0.0)(1.0 1.0 1.0)\n"
            "*ASC_SAT 1.0\n"
        )
        with self.assertRaises(CdlEdlParseError) as cm:
            parse_cdl_edl(text, 24)
        self.assertIn("duplicate record-in frame", str(cm.exception))

    def test_non_string_edl_text(self):
        with self.assertRaises(CdlEdlParseError):
            parse_cdl_edl(None, 24)
        with self.assertRaises(CdlEdlParseError):
            parse_cdl_edl(b"x", 24)


class ClassifyFidelityTests(unittest.TestCase):
    # FR-015 closed set {primary, partial, unrepresentable}; cdl emit
    # strictly gated on fidelity == "primary"; lut.ref carrier when
    # item-level LUT is present.

    def test_cdl_only_clean_graph_returns_primary(self):
        # Bare primary correction, no extra tools, no LUT.
        self.assertEqual(
            classify_fidelity(
                any_non_cdl_tools=False, item_lut_ref=None,
                cdl_present=True),
            "primary")

    def test_cdl_plus_lut_returns_partial(self):
        # CDL + an item-level LUT — even with no extra tools the LUT is
        # a layered op that CDL alone cannot reproduce.
        self.assertEqual(
            classify_fidelity(
                any_non_cdl_tools=False,
                item_lut_ref="/path/to/film.cube",
                cdl_present=True),
            "partial")

    def test_cdl_plus_curves_plus_lut_returns_partial(self):
        # Non-CDL tools present, LUT carrier available → partial.
        self.assertEqual(
            classify_fidelity(
                any_non_cdl_tools=True,
                item_lut_ref="/path/to/baked.cube",
                cdl_present=True),
            "partial")

    def test_cdl_plus_non_cdl_tools_no_lut_returns_unrepresentable(self):
        # Exceeds CDL with no LUT carrier — honestly unrepresentable.
        self.assertEqual(
            classify_fidelity(
                any_non_cdl_tools=True, item_lut_ref=None,
                cdl_present=True),
            "unrepresentable")

    def test_cdl_absent_raises(self):
        # CDL absent for a known item is a Resolve API anomaly.
        with self.assertRaises(CdlEdlParseError) as cm:
            classify_fidelity(
                any_non_cdl_tools=False, item_lut_ref=None,
                cdl_present=False)
        self.assertIn("resolve_api_error", str(cm.exception))

    def test_non_bool_any_tools_raises(self):
        with self.assertRaises(CdlEdlParseError):
            classify_fidelity(
                any_non_cdl_tools="yes", item_lut_ref=None,
                cdl_present=True)

    def test_non_bool_cdl_present_raises(self):
        with self.assertRaises(CdlEdlParseError):
            classify_fidelity(
                any_non_cdl_tools=False, item_lut_ref=None,
                cdl_present=1)

    def test_empty_lut_ref_raises(self):
        with self.assertRaises(CdlEdlParseError):
            classify_fidelity(
                any_non_cdl_tools=False, item_lut_ref="",
                cdl_present=True)

    def test_non_string_lut_ref_raises(self):
        with self.assertRaises(CdlEdlParseError):
            classify_fidelity(
                any_non_cdl_tools=False, item_lut_ref=42,
                cdl_present=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
