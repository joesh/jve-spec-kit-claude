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
    """Item node graph. Default tools are beyond-primary → the item
    classifies unrepresentable (bake candidate); None = untouched."""
    def __init__(self, tools=("Custom Curves",)):
        self._tools = list(tools) if tools else None

    def GetNumNodes(self):
        return 1

    def GetToolsInNode(self, n):
        assert n == 1
        return self._tools


class _FakeGroupGraph:
    """Group pre/post-clip graph; counts walks for the cache test."""
    def __init__(self, tools_by_node):
        self._tools_by_node = tools_by_node  # list, one entry per node
        self.walk_count = 0

    def GetNumNodes(self):
        return len(self._tools_by_node)

    def GetToolsInNode(self, n):
        self.walk_count += 1
        return self._tools_by_node[n - 1]


class _FakeColorGroup:
    def __init__(self, name, pre_tools, post_tools):
        self._name = name
        self.pre = _FakeGroupGraph(pre_tools)
        self.post = _FakeGroupGraph(post_tools)

    def GetName(self):
        return self._name

    def GetPreClipNodeGraph(self):
        return self.pre

    def GetPostClipNodeGraph(self):
        return self.post


class _FakeItem:
    """Timeline item whose grade exceeds CDL (bake candidate)."""
    def __init__(self, uid, start, export_lut, group=None,
                 own_tools=("Custom Curves",)):
        self._uid = uid
        self._start = start
        self._export_lut = export_lut  # fn(kind, path) -> bool
        self._group = group
        self._own_tools = list(own_tools) if own_tools else None
        self.export_lut_calls = 0

    def GetUniqueId(self):
        return self._uid

    def GetStart(self):
        return self._start

    def GetNodeGraph(self):
        return _FakeGraph(self._own_tools)

    def GetLUT(self, n):
        return ""

    def GetColorGroup(self):
        return self._group

    def ExportLUT(self, kind, path):
        self.export_lut_calls += 1
        return self._export_lut(kind, path)


class _FakeTimeline:
    def __init__(self, items, cdl_at_one_hour=False,
                 timeline_graph_tools=None):
        self._items = items
        self._cdl_at_one_hour = cdl_at_one_hour
        # one entry per timeline-graph node (None = untouched node);
        # default single clean node like a real fresh timeline graph
        self._tl_tools = (timeline_graph_tools
                          if timeline_graph_tools is not None else [None])

    def GetNodeGraph(self):
        return _FakeGroupGraph(self._tl_tools)

    def GetSetting(self, key):
        assert key == "timelineFrameRate"
        return "24"

    def Export(self, path, fmt, kind):
        # Minimal CMX-3600 shell. Default: zero CDL events — items
        # classify via the no-CDL branch. With cdl_at_one_hour, one
        # non-identity SOP/SAT event at record 01:00:00:00 (frame 86400
        # at the fake's 24 fps) so an item starting there reads
        # cdl_present=True.
        with open(path, "w", encoding="utf-8") as f:
            f.write("TITLE: fake\nFCM: NON-DROP FRAME\n\n")
            if self._cdl_at_one_hour:
                f.write(
                    "001  AX       V     C        "
                    "00:00:00:00 00:00:04:00 01:00:00:00 01:00:04:00\n"
                    "*ASC_SOP (1.050000 0.980000 0.920000)"
                    "(0.010000 0.000000 -0.020000)"
                    "(1.100000 1.000000 0.950000)\n"
                    "*ASC_SAT 0.850000\n")
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

    def test_mid_bake_page_departure_warns_once_and_stops_baking(self):
        resolve = _FakeResolve("edit")

        def bake_then_user_switches(kind, path):
            # simulate the user flipping Resolve back to Edit between
            # bakes — this and every later ExportLUT would fail
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
        # Once the page is verifiably lost, further ExportLUT calls are
        # doomed (Color page is a hard prerequisite) — uid-c must be
        # SKIPPED, not attempted (1 failed of 2 attempted).
        self.assertEqual(items[2].export_lut_calls, 0)
        counts = [w for w in result["warnings"] if "1 of 2" in w]
        self.assertEqual(len(counts), 1, result["warnings"])
        skipped = [w for w in result["warnings"] if "skipped" in w]
        self.assertEqual(len(skipped), 1, result["warnings"])

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

    def test_modal_blocks_color_switch_skips_all_bakes(self):
        # 2026-06-11 VM incident: a missing-DCTL modal blocked Resolve's
        # UI — OpenPage("color") didn't take and every ExportLUT was
        # doomed. The verb must detect the failed switch (verify via
        # GetCurrentPage), warn ONCE naming the likely modal, and skip
        # every bake attempt rather than failing 1000 times.
        resolve = _FakeResolve("edit")
        resolve.refuse_open_pages = {"color"}
        items = [_FakeItem("uid-a", 86400, _write_cube),
                 _FakeItem("uid-b", 86500, _write_cube)]
        with tempfile.TemporaryDirectory() as d:
            result = self._run(resolve, items, d)
        self.assertEqual(items[0].export_lut_calls, 0)
        self.assertEqual(items[1].export_lut_calls, 0)
        blocked = [w for w in result["warnings"]
                   if "modal" in w and "No LUT bakes attempted" in w]
        self.assertEqual(len(blocked), 1, result["warnings"])
        # rows still emitted (classification works without bakes)
        self.assertEqual(len(result["grades"]), 2)


# ─── read_grades timeline-graph classification (force-bake, t054 +
# t055: ExportLUT composes the timeline grade into every item's bake
# — timeline applied AFTER the clip grade — so timeline activity must
# defeat none/primary exactly like group activity does) ──────────────

class ReadGradesTimelineClassificationTests(unittest.TestCase):
    def _run(self, items, bake_dir, timeline_graph_tools,
             cdl_at_one_hour=False):
        resolve = _FakeResolve("edit")
        project = _FakeProject(_FakeTimeline(
            items, cdl_at_one_hour=cdl_at_one_hour,
            timeline_graph_tools=timeline_graph_tools))

        class _Handle:
            def acquire(self):
                return ("ok", resolve, project)

        resp = verbs.verb_read_grades(
            {"bake_lut_dir": bake_dir} if bake_dir else {},
            _Handle(), "env-tl1", "test")
        self.assertTrue(resp["ok"], f"verb failed: {resp!r}")
        return resp["result"]

    def _rows(self, result):
        return {row["resolve_item_id"]: row
                for row in result["grades"]}

    def test_timeline_tools_defeat_primary(self):
        # A CDL-primary clip under a timeline grade: Resolve displays
        # clipCDL then timeline grade on every frame, so the CDL alone
        # misrepresents the look. The clip must be carried by the bake
        # (which composes both — t055) instead of shipped CDL-only.
        items = [_FakeItem("uid-a", 86400, _write_cube,
                           group=None, own_tools=None)]
        with tempfile.TemporaryDirectory() as d:
            rows = self._rows(self._run(
                items, d, [["Primary Offset"]], cdl_at_one_hour=True))
        row = rows["uid-a"]
        self.assertNotEqual(row["fidelity"], "primary", row)
        self.assertIn("lut", row, "clip under a timeline grade must "
                      "carry the baked LUT (bake composes clip + "
                      "timeline grades — t055)")
        self.assertNotIn("cdl", row, "CDL alongside the bake would "
                         "double-apply the primary (the bake already "
                         "contains it)")

    def test_timeline_tools_defeat_none(self):
        # An ungraded clip under a timeline grade displays GRADED in
        # Resolve (the timeline grade applies to every clip — t054
        # proved its bake carries exactly that). 'none' would make
        # JVE drop the grade row and show it ungraded.
        items = [_FakeItem("uid-b", 86400, _write_cube,
                           group=None, own_tools=None)]
        with tempfile.TemporaryDirectory() as d:
            rows = self._rows(self._run(
                items, d, [["Primary Offset"]]))
        row = rows["uid-b"]
        self.assertNotEqual(row["fidelity"], "none", row)
        self.assertIn("lut", row, "ungraded clip under a timeline "
                      "grade must carry the baked LUT (= the timeline "
                      "grade — t054)")

    def test_clean_timeline_graph_unchanged(self):
        # Regression guard: no timeline grade → primary stays a CDL
        # carrier (exact, no bake) and ungraded stays none.
        primary = _FakeItem("uid-p", 86400, _write_cube,
                            group=None, own_tools=None)
        ungraded = _FakeItem("uid-n", 172800, _write_cube,
                             group=None, own_tools=None)
        with tempfile.TemporaryDirectory() as d:
            rows = self._rows(self._run(
                [primary, ungraded], d, None, cdl_at_one_hour=True))
        self.assertEqual(rows["uid-p"]["fidelity"], "primary")
        self.assertIn("cdl", rows["uid-p"])
        self.assertNotIn("lut", rows["uid-p"])
        self.assertEqual(primary.export_lut_calls, 0)
        self.assertEqual(rows["uid-n"]["fidelity"], "none")

    def test_timeline_grade_with_bake_dir_no_warning(self):
        # With a bake dir the bakes carry the timeline look — presence
        # alone is no longer user-visible damage, so the warning is
        # reserved for the carrier-less (no bake_lut_dir) sync; bake
        # failures keep their own warning.
        items = [_FakeItem("uid-c", 86400, _write_cube,
                           group=None, own_tools=None)]
        with tempfile.TemporaryDirectory() as d:
            result = self._run(items, d, [["Primary Offset"]])
        tl_warns = [w for w in result["warnings"]
                    if "timeline-level grade" in w]
        self.assertEqual(tl_warns, [], result["warnings"])


# ─── read_grades color-group classification (t051: H1 — ExportLUT
# bakes group grades, so group activity must defeat none/primary) ────

class ReadGradesGroupClassificationTests(unittest.TestCase):
    def _run(self, items, bake_dir, cdl_at_one_hour=False):
        resolve = _FakeResolve("edit")
        project = _FakeProject(
            _FakeTimeline(items, cdl_at_one_hour=cdl_at_one_hour))

        class _Handle:
            def acquire(self):
                return ("ok", resolve, project)

        resp = verbs.verb_read_grades(
            {"bake_lut_dir": bake_dir} if bake_dir else {},
            _Handle(), "env-g1", "test")
        self.assertTrue(resp["ok"], f"verb failed: {resp!r}")
        return {row["resolve_item_id"]: row
                for row in resp["result"]["grades"]}

    def test_group_tools_defeat_none(self):
        # The 01:02:31:13 case: item's own graph untouched, no CDL, no
        # item LUT — but the color group carries the whole look.
        # Pre-t051 this classified "none" and the clip displayed
        # ungraded in JVE despite being fully graded in Resolve.
        group = _FakeColorGroup("School",
                                pre_tools=[["Primary Balance"]],
                                post_tools=[None])
        items = [_FakeItem("uid-a", 86400, _write_cube,
                           group=group, own_tools=None)]
        with tempfile.TemporaryDirectory() as d:
            rows = self._run(items, d)
        row = rows["uid-a"]
        self.assertNotEqual(row["fidelity"], "none", row)
        self.assertIn("lut", row, "group-graded clip must carry the "
                      "baked LUT (ExportLUT bakes group grades — t051)")

    def test_group_tools_defeat_primary(self):
        # CDL-primary item inside a graded group: the EDL CDL carries
        # no group contribution, so "primary" would misrepresent the
        # look (FR-015 never over-claims). Downgrades to the
        # bake-carried shape — unrepresentable (the established label
        # for tools-without-user-LUT; the bake is the carrier), no cdl
        # claimed, lut present.
        group = _FakeColorGroup("School",
                                pre_tools=[["Custom Curves"]],
                                post_tools=[None])
        item = _FakeItem("uid-a", 86400, _write_cube,
                         group=group, own_tools=None)
        with tempfile.TemporaryDirectory() as d:
            rows = self._run([item], d, cdl_at_one_hour=True)
        row = rows["uid-a"]
        self.assertEqual(row["fidelity"], "unrepresentable", row)
        self.assertNotIn("cdl", row)
        self.assertIn("lut", row)

    def test_clean_item_with_cdl_still_primary(self):
        # Control for defeat_primary: same CDL event, NO group — the
        # classification must remain primary with the CDL attached.
        item = _FakeItem("uid-a", 86400, _write_cube,
                         group=None, own_tools=None)
        with tempfile.TemporaryDirectory() as d:
            rows = self._run([item], d, cdl_at_one_hour=True)
        row = rows["uid-a"]
        self.assertEqual(row["fidelity"], "primary", row)
        self.assertIn("cdl", row)

    def test_ungrouped_clean_item_still_none(self):
        items = [_FakeItem("uid-a", 86400, _write_cube,
                           group=None, own_tools=None)]
        with tempfile.TemporaryDirectory() as d:
            rows = self._run(items, d)
        self.assertEqual(rows["uid-a"]["fidelity"], "none")

    def test_group_without_tools_still_none(self):
        group = _FakeColorGroup("Empty",
                                pre_tools=[None],
                                post_tools=[None])
        items = [_FakeItem("uid-a", 86400, _write_cube,
                           group=group, own_tools=None)]
        with tempfile.TemporaryDirectory() as d:
            rows = self._run(items, d)
        self.assertEqual(rows["uid-a"]["fidelity"], "none")

    def test_timeline_level_grade_warns(self):
        # A sync WITHOUT bake_lut_dir under a timeline-level grade:
        # only LUT bakes carry timeline grades (t054/t055) and this
        # sync produced none, so every clip's JVE display misses the
        # timeline look — the verb must say so, once per sync. (With
        # a bake dir the warning must NOT fire — covered by
        # ReadGradesTimelineClassificationTests.) The gold timeline
        # carries an OFX DCTL + Sizing at timeline level.
        resolve = _FakeResolve("edit")
        items = [_FakeItem("uid-a", 86400, _write_cube,
                           group=None, own_tools=None)]
        project = _FakeProject(_FakeTimeline(
            items, timeline_graph_tools=[["OFX: DCTL"], ["Sizing"]]))

        class _Handle:
            def acquire(self):
                return ("ok", resolve, project)

        resp = verbs.verb_read_grades({}, _Handle(), "env-tg1", "test")
        self.assertTrue(resp["ok"], f"verb failed: {resp!r}")
        tl_warns = [w for w in resp["result"]["warnings"]
                    if "timeline-level grade" in w]
        self.assertEqual(len(tl_warns), 1, resp["result"]["warnings"])
        self.assertIn("OFX: DCTL", tl_warns[0])

    def test_clean_timeline_graph_no_warning(self):
        items = [_FakeItem("uid-a", 86400, _write_cube,
                           group=None, own_tools=None)]
        with tempfile.TemporaryDirectory() as d:
            rows = self._run(items, d)
        # _run asserts ok; the clean-run warnings==[] case is pinned by
        # ReadGradesWarningsTests.test_clean_bake_run_has_empty_warnings
        # whose fake timeline now carries the default clean graph.
        self.assertEqual(rows["uid-a"]["fidelity"], "none")

    def test_group_verdict_cached_per_group(self):
        # 1074 items share ~15 groups on a real timeline — the group
        # graphs must be walked once per GROUP, not once per item.
        group = _FakeColorGroup("School",
                                pre_tools=[["Primary Balance"]],
                                post_tools=[None])
        items = [_FakeItem("uid-a", 86400, _write_cube,
                           group=group, own_tools=None),
                 _FakeItem("uid-b", 86500, _write_cube,
                           group=group, own_tools=None)]
        with tempfile.TemporaryDirectory() as d:
            self._run(items, d)
        self.assertEqual(group.pre.walk_count, 1,
                         "group graph walked once per group, not per item")


if __name__ == "__main__":
    unittest.main(verbosity=2)
