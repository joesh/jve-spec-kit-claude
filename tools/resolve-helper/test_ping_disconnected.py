"""verb_ping must NOT call version_string() in the disconnected branch.

Bug (review M#15, 2026-06-09): when handle.acquire() returns an error
("handle_stale" / "resolve_api_error" / "not_studio"), the prior code
also called handle.version_string(), which raises under the EXACT same
conditions acquire() failed for (_terminal_error set, scriptapp returns
None, etc.). Since pass-5 serve() re-raises dispatch crashes per FR-007,
that crash now KILLS the helper instead of returning a "we're not
connected" envelope.

Contract (helper-protocol.md §ping): when resolve_connected is false,
resolve_version is null and last_error carries the reason. JVE must not
assume resolve_version is always a string.
"""
import sys
import unittest
from pathlib import Path

THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(THIS_DIR))

import verbs  # noqa: E402


class _FakeHandle:
    """Simulates a handle in the disconnected/terminal state."""
    def __init__(self, error_code):
        self._error_code = error_code

    def acquire(self):
        return ("error", self._error_code, f"simulated {self._error_code}")

    def version_string(self):
        # If verb_ping calls this in the disconnected branch, it
        # raises just like the real one would. The test catches that
        # the verb does NOT reach this point.
        raise RuntimeError(
            "version_string called in disconnected branch — bug; "
            "fixed in pass 10 to send resolve_version=None instead")


class PingDisconnectedTests(unittest.TestCase):

    def _ping(self, code):
        handle = _FakeHandle(code)
        return verbs.verb_ping(
            args={}, handle=handle,
            envelope_id="ping-test-1",
            helper_version="test")

    def test_handle_stale_returns_envelope_with_null_version(self):
        envelope = self._ping("handle_stale")
        self.assertTrue(envelope["ok"])
        result = envelope["result"]
        self.assertTrue(result["alive"])
        self.assertFalse(result["resolve_connected"])
        self.assertIsNone(result["resolve_version"])
        self.assertEqual(result["last_error"]["code"], "handle_stale")

    def test_resolve_api_error_returns_envelope_with_null_version(self):
        envelope = self._ping("resolve_api_error")
        self.assertTrue(envelope["ok"])
        result = envelope["result"]
        self.assertIsNone(result["resolve_version"])
        self.assertEqual(result["last_error"]["code"], "resolve_api_error")

    def test_not_studio_returns_envelope_with_null_version(self):
        envelope = self._ping("not_studio")
        self.assertTrue(envelope["ok"])
        result = envelope["result"]
        self.assertIsNone(result["resolve_version"])
        self.assertEqual(result["last_error"]["code"], "not_studio")


if __name__ == "__main__":
    unittest.main()
