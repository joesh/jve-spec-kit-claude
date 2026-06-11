"""Unit tests for pure-data helpers in verbs.py — argument validators.

The verbs themselves require a live Resolve handle; the validators don't.
These tests cover the wire boundary contracts that are independent of
Resolve API state.
"""
import tempfile
import unittest

import verbs
from verbs import _validate_read_grades_args, _validate_apply_test_grade_args


class ValidateReadGradesArgsTests(unittest.TestCase):
    # Contract per helper-protocol.md §read_grades:
    # args = { item_ids?: [string], bake_lut_dir?: string }.
    # Unknown keys rejected, malformed shape rejected, all per rule 2.32.

    def test_empty_args_ok_no_filter_no_bake(self):
        ok, payload = _validate_read_grades_args({})
        self.assertEqual(ok, "ok")
        self.assertIsNone(payload["item_ids"])
        self.assertIsNone(payload["bake_lut_dir"])

    def test_item_ids_list_ok_payload_is_set(self):
        ok, payload = _validate_read_grades_args(
            {"item_ids": ["a", "b", "a"]})  # dedup via set semantics
        self.assertEqual(ok, "ok")
        self.assertEqual(payload["item_ids"], {"a", "b"})

    def test_item_ids_empty_list_ok_distinct_from_none(self):
        ok, payload = _validate_read_grades_args({"item_ids": []})
        self.assertEqual(ok, "ok")
        self.assertEqual(payload["item_ids"], set())  # empty set, not None

    def test_item_ids_non_list_rejected(self):
        ok, msg = _validate_read_grades_args({"item_ids": "x"})
        self.assertEqual(ok, "error")
        self.assertIn("item_ids", msg)

    def test_item_ids_non_string_element_rejected(self):
        ok, msg = _validate_read_grades_args({"item_ids": ["a", 7]})
        self.assertEqual(ok, "error")
        self.assertIn("item_ids[1]", msg)

    def test_item_ids_empty_string_element_rejected(self):
        ok, msg = _validate_read_grades_args({"item_ids": [""]})
        self.assertEqual(ok, "error")
        self.assertIn("item_ids[0]", msg)

    def test_bake_lut_dir_absolute_path_ok(self):
        with tempfile.TemporaryDirectory() as tmp:
            ok, payload = _validate_read_grades_args(
                {"bake_lut_dir": tmp})
            self.assertEqual(ok, "ok")
            self.assertEqual(payload["bake_lut_dir"], tmp)

    def test_bake_lut_dir_relative_path_rejected(self):
        # Relative paths would resolve against Resolve's CWD, not JVE's
        # — invites cross-process surprises. Force absolute.
        ok, msg = _validate_read_grades_args(
            {"bake_lut_dir": "relative/path"})
        self.assertEqual(ok, "error")
        self.assertIn("absolute", msg)

    def test_bake_lut_dir_empty_string_rejected(self):
        ok, msg = _validate_read_grades_args({"bake_lut_dir": ""})
        self.assertEqual(ok, "error")
        self.assertIn("bake_lut_dir", msg)

    def test_bake_lut_dir_non_string_rejected(self):
        ok, msg = _validate_read_grades_args({"bake_lut_dir": 42})
        self.assertEqual(ok, "error")
        self.assertIn("bake_lut_dir", msg)

    def test_unknown_field_rejected(self):
        ok, msg = _validate_read_grades_args({"oops": True})
        self.assertEqual(ok, "error")
        self.assertIn("oops", msg)

    def test_combined_item_ids_and_bake_lut_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            ok, payload = _validate_read_grades_args(
                {"item_ids": ["a"], "bake_lut_dir": tmp})
            self.assertEqual(ok, "ok")
            self.assertEqual(payload["item_ids"], {"a"})
            self.assertEqual(payload["bake_lut_dir"], tmp)


class _LocaleCorruptedTimeline:
    """Stand-in whose GetSetting returns "23" — the live signature of
    the non-US-locale fractional-rate truncation (23.976 read back as
    an integer, FR-020 / research.md §8)."""
    def GetSetting(self, key):
        assert key == "timelineFrameRate"
        return "23"


class _ProjectWithCorruptedTimeline:
    def GetCurrentTimeline(self):
        return _LocaleCorruptedTimeline()


class _OkHandle:
    def acquire(self):
        return ("ok", object(), _ProjectWithCorruptedTimeline())


class LocaleRateWireCodeTests(unittest.TestCase):
    def test_read_timeline_maps_truncated_rate_to_locale_code(self):
        # FR-020: the corrupted rate must surface as the closed-set
        # wire code `locale_rate_corruption` (helper-protocol.md error
        # table), not generic resolve_api_error — JVE refuses the
        # conform on this code specifically.
        resp = verbs.verb_read_timeline(
            {}, _OkHandle(), "env-locale-1", "test")
        self.assertFalse(resp["ok"])
        self.assertEqual(
            resp["error"]["code"], "locale_rate_corruption",
            f"got {resp['error']!r}")
        self.assertIn("23.976", resp["error"]["message"])


class ValidateApplyTestGradeArgsTests(unittest.TestCase):
    # Contract per helper-protocol.md §apply_test_grade (test-only):
    # args = { resolve_item_id, cdl?: {slope:[r,g,b], offset:[r,g,b],
    # power:[r,g,b], sat}, lut_path?, change_token } — at least one of
    # cdl / lut_path required. change_token is validated separately by
    # _validate_change_token; this validator owns the grade payload.

    CDL = {"slope": [1.2, 0.9, 0.85], "offset": [0.02, -0.01, 0.03],
           "power": [0.95, 1.1, 1.05], "sat": 0.8}

    def test_cdl_only_ok(self):
        ok, payload = _validate_apply_test_grade_args(
            {"resolve_item_id": "uid1", "cdl": dict(self.CDL),
             "change_token": {}})
        self.assertEqual(ok, "ok")
        self.assertEqual(payload["resolve_item_id"], "uid1")
        self.assertEqual(payload["cdl"]["sat"], 0.8)
        self.assertIsNone(payload["lut_path"])

    def test_lut_only_ok(self):
        ok, payload = _validate_apply_test_grade_args(
            {"resolve_item_id": "uid1", "lut_path": "/luts/k2383.cube",
             "change_token": {}})
        self.assertEqual(ok, "ok")
        self.assertEqual(payload["lut_path"], "/luts/k2383.cube")
        self.assertIsNone(payload["cdl"])

    def test_both_cdl_and_lut_ok(self):
        ok, payload = _validate_apply_test_grade_args(
            {"resolve_item_id": "uid1", "cdl": dict(self.CDL),
             "lut_path": "/luts/k2383.cube", "change_token": {}})
        self.assertEqual(ok, "ok")
        self.assertIsNotNone(payload["cdl"])
        self.assertIsNotNone(payload["lut_path"])

    def test_neither_cdl_nor_lut_rejected(self):
        ok, msg = _validate_apply_test_grade_args(
            {"resolve_item_id": "uid1", "change_token": {}})
        self.assertEqual(ok, "error")
        self.assertIn("cdl", msg)
        self.assertIn("lut_path", msg)

    def test_missing_resolve_item_id_rejected(self):
        ok, msg = _validate_apply_test_grade_args(
            {"cdl": dict(self.CDL), "change_token": {}})
        self.assertEqual(ok, "error")
        self.assertIn("resolve_item_id", msg)

    def test_cdl_triple_wrong_arity_rejected(self):
        bad = dict(self.CDL); bad["slope"] = [1.0, 1.0]
        ok, msg = _validate_apply_test_grade_args(
            {"resolve_item_id": "uid1", "cdl": bad, "change_token": {}})
        self.assertEqual(ok, "error")
        self.assertIn("slope", msg)

    def test_cdl_non_number_component_rejected(self):
        bad = dict(self.CDL); bad["offset"] = [0.1, "x", 0.2]
        ok, msg = _validate_apply_test_grade_args(
            {"resolve_item_id": "uid1", "cdl": bad, "change_token": {}})
        self.assertEqual(ok, "error")
        self.assertIn("offset", msg)

    def test_cdl_missing_sat_rejected(self):
        bad = dict(self.CDL); del bad["sat"]
        ok, msg = _validate_apply_test_grade_args(
            {"resolve_item_id": "uid1", "cdl": bad, "change_token": {}})
        self.assertEqual(ok, "error")
        self.assertIn("sat", msg)

    def test_cdl_unknown_key_rejected(self):
        bad = dict(self.CDL); bad["gamma"] = 1.0
        ok, msg = _validate_apply_test_grade_args(
            {"resolve_item_id": "uid1", "cdl": bad, "change_token": {}})
        self.assertEqual(ok, "error")
        self.assertIn("gamma", msg)

    def test_lut_path_relative_rejected(self):
        ok, msg = _validate_apply_test_grade_args(
            {"resolve_item_id": "uid1", "lut_path": "k2383.cube",
             "change_token": {}})
        self.assertEqual(ok, "error")
        self.assertIn("absolute", msg)

    def test_unknown_args_field_rejected(self):
        ok, msg = _validate_apply_test_grade_args(
            {"resolve_item_id": "uid1", "cdl": dict(self.CDL),
             "drx": "/x.drx", "change_token": {}})
        self.assertEqual(ok, "error")
        self.assertIn("drx", msg)


# ─── read_grades result.warnings (bake-anomaly instrumentation) ──────
#
# Forensic background (2026-06-10 incident): a sync killed mid-bake left
# Resolve stuck on the Color page; the NEXT sync ran with prior_page ==
# "color" (restore skipped), and the user switching back to Edit mid-bake
# made ~620 ExportLUT calls fail — every affected clip silently lost its
# grade carrier and displayed ungraded. All of it was invisible at
# default log level. These tests pin the in-band `warnings` channel that
# surfaces each anomaly to the JVE client (which logs at warn).

class _FakeGraph:
    def GetNumNodes(self):
        return 1

    def GetToolsInNode(self, n):
        assert n == 1
        return ["Custom Curves"]  # beyond-primary → unrepresentable


class _FakeItem:
    """Timeline item whose grade exceeds CDL (bake candidate)."""
    def __init__(self, uid, start, export_lut):
        self._uid = uid
        self._start = start
        self._export_lut = export_lut  # fn(kind, path) -> bool

    def GetUniqueId(self):
        return self._uid

    def GetStart(self):
        return self._start

    def GetNodeGraph(self):
        return _FakeGraph()

    def GetLUT(self, n):
        return ""

    def ExportLUT(self, kind, path):
        return self._export_lut(kind, path)


class _FakeTimeline:
    def __init__(self, items):
        self._items = items

    def GetSetting(self, key):
        assert key == "timelineFrameRate"
        return "24"

    def Export(self, path, fmt, kind):
        # Minimal CMX-3600 shell with zero CDL events — every item
        # classifies via the no-CDL branch (tools ⇒ unrepresentable).
        with open(path, "w", encoding="utf-8") as f:
            f.write("TITLE: fake\n\n")
        return True

    def GetTrackCount(self, track_type):
        return 1 if track_type == "video" else 0

    def GetItemListInTrack(self, track_type, tidx):
        assert track_type == "video" and tidx == 1
        return self._items


class _FakeProject:
    def __init__(self, timeline):
        self._timeline = timeline

    def GetCurrentTimeline(self):
        return self._timeline


class _FakeResolve:
    """Stateful page model: OpenPage mutates, GetCurrentPage reads."""
    EXPORT_EDL = object()
    EXPORT_CDL = object()
    EXPORT_LUT_33PTCUBE = object()

    def __init__(self, page):
        self.page = page
        self.open_page_calls = []
        self.refuse_open_pages = set()  # pages OpenPage won't reach

    def GetCurrentPage(self):
        return self.page

    def OpenPage(self, page):
        self.open_page_calls.append(page)
        if page in self.refuse_open_pages:
            return False
        self.page = page
        return True


def _write_cube(_kind, path):
    with open(path, "w", encoding="utf-8") as f:
        f.write("LUT_3D_SIZE 2\n" + "0 0 0\n" * 8)
    return True


class ReadGradesWarningsTests(unittest.TestCase):
    def _run(self, resolve, items, bake_dir):
        project = _FakeProject(_FakeTimeline(items))

        class _Handle:
            def acquire(self):
                return ("ok", resolve, project)

        resp = verbs.verb_read_grades(
            {"bake_lut_dir": bake_dir}, _Handle(), "env-w1", "test")
        self.assertTrue(resp["ok"], f"verb failed: {resp!r}")
        return resp["result"]

    def test_clean_bake_run_has_empty_warnings(self):
        resolve = _FakeResolve("edit")
        items = [_FakeItem("uid-a", 86400, _write_cube)]
        with tempfile.TemporaryDirectory() as d:
            result = self._run(resolve, items, d)
        self.assertEqual(result["warnings"], [])
        # page restored to where the user was
        self.assertEqual(resolve.page, "edit")

    def test_mid_bake_page_departure_warns_once_and_counts(self):
        resolve = _FakeResolve("edit")

        def bake_then_user_switches(kind, path):
            # simulate the user flipping Resolve back to Edit between
            # bakes — this and every later ExportLUT fails
            resolve.page = "edit"
            return False

        items = [
            _FakeItem("uid-a", 86400, _write_cube),
            _FakeItem("uid-b", 86500, bake_then_user_switches),
            _FakeItem("uid-c", 86600, lambda k, p: False),
        ]
        with tempfile.TemporaryDirectory() as d:
            result = self._run(resolve, items, d)
        departure = [w for w in result["warnings"] if "mid-bake" in w]
        self.assertEqual(len(departure), 1, result["warnings"])
        self.assertIn("edit", departure[0])
        counts = [w for w in result["warnings"] if "2 of 3" in w]
        self.assertEqual(len(counts), 1, result["warnings"])

    def test_prior_page_color_warns_restore_skipped(self):
        # Resolve already on Color when the sync begins (the signature
        # of an earlier sync killed mid-bake) — restore is skipped by
        # design; the user must hear about it.
        resolve = _FakeResolve("color")
        items = [_FakeItem("uid-a", 86400, _write_cube)]
        with tempfile.TemporaryDirectory() as d:
            result = self._run(resolve, items, d)
        already = [w for w in result["warnings"]
                   if "already on the Color page" in w]
        self.assertEqual(len(already), 1, result["warnings"])
        self.assertEqual(resolve.open_page_calls, ["color"])

    def test_restore_failure_warning_reaches_response(self):
        # Restore runs in the verb's finally AFTER the response is
        # built — the warning must still be visible in the returned
        # result (same-list mutation, not a copy).
        resolve = _FakeResolve("edit")
        resolve.refuse_open_pages = {"edit"}
        items = [_FakeItem("uid-a", 86400, _write_cube)]
        with tempfile.TemporaryDirectory() as d:
            result = self._run(resolve, items, d)
        restore = [w for w in result["warnings"]
                   if "restore" in w and "edit" in w]
        self.assertEqual(len(restore), 1, result["warnings"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
