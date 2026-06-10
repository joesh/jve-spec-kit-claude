"""Unit tests for pure-data helpers in verbs.py — argument validators.

The verbs themselves require a live Resolve handle; the validators don't.
These tests cover the wire boundary contracts that are independent of
Resolve API state.
"""
import tempfile
import unittest

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



if __name__ == "__main__":
    unittest.main(verbosity=2)
