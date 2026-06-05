"""Unit tests for pure-data helpers in verbs.py — argument validators.

The verbs themselves require a live Resolve handle; the validators don't.
These tests cover the wire boundary contracts that are independent of
Resolve API state.
"""
import tempfile
import unittest

from verbs import _validate_read_grades_args


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


if __name__ == "__main__":
    unittest.main(verbosity=2)
