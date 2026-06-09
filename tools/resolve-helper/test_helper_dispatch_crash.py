"""Helper dispatch-crash lifecycle (spec 023 FR-007, review HIGH E#8).

When `handle_line` raises an unexpected exception, `serve()` must:
  1. Write a structured `resolve_api_error` crash envelope back to the
     in-flight client (correlation id recovered from the crashing line).
  2. Re-raise so the process exits and the supervisor respawns clean.

Prior behavior caught the exception, synthesized an envelope, and kept
serving — contradicting FR-007's "wire-level corruption … closes the
socket; the supervisor's next request respawns" lifecycle and leaving
the idempotency ledger potentially inconsistent with what the Resolve
API actually committed.
"""
import json
import sys
import unittest
from pathlib import Path
from unittest import mock

THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(THIS_DIR))

import helper  # noqa: E402
from protocol import PROTOCOL_VERSION  # noqa: E402


class _FakeConn:
    """Stand-in for a real `conn` from `sock.accept()` — captures the
    bytes the server writes and serves up the pre-loaded request line
    on `recv`. Returns b"" after the request to break the inner loop
    if the server didn't re-raise (which would fail the test loudly).
    """
    def __init__(self, request_line):
        self._to_send = request_line + b"\n"
        self.written = bytearray()

    def recv(self, n):
        if not self._to_send:
            return b""
        chunk = self._to_send[:n]
        self._to_send = self._to_send[n:]
        return chunk

    def sendall(self, data):
        self.written.extend(data)

    def close(self):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False


class _FakeSock:
    """One-shot accept that returns _FakeConn then errors on the next
    accept so the outer while-True loop in serve() doesn't spin if the
    server forgot to re-raise."""
    def __init__(self, conn):
        self._conn = conn
        self._consumed = False

    def accept(self):
        if self._consumed:
            raise RuntimeError(
                "test sock.accept called twice — server did not re-raise")
        self._consumed = True
        return self._conn, ("", 0)


class DispatchCrashTests(unittest.TestCase):

    def test_crash_envelope_written_then_serve_reraises(self):
        request = {
            "v": PROTOCOL_VERSION,
            "id": "test-corr-42",
            "verb": "ping",
            "args": {},
        }
        conn = _FakeConn(json.dumps(request).encode("utf-8"))
        sock = _FakeSock(conn)
        ledger = mock.MagicMock()
        ledger.compute_key.return_value = None
        handle = mock.MagicMock()

        with mock.patch.object(helper, "dispatch",
                side_effect=RuntimeError("boom — verb exploded mid-call")):
            with self.assertRaises(RuntimeError) as ctx:
                helper.serve(sock, handle, ledger)

        self.assertIn("boom", str(ctx.exception))

        self.assertTrue(conn.written.endswith(b"\n"),
            "envelope must be newline-terminated")
        envelope = json.loads(conn.written.rstrip(b"\n"))
        self.assertEqual(envelope["v"], PROTOCOL_VERSION)
        self.assertEqual(envelope["id"], "test-corr-42")
        self.assertFalse(envelope["ok"])
        self.assertEqual(envelope["error"]["code"], "resolve_api_error")
        self.assertIn("boom", envelope["error"]["message"])
        ledger.store.assert_not_called()

    def test_crash_envelope_write_failure_does_not_mask_dispatch_error(self):
        class _BrokenConn(_FakeConn):
            def sendall(self, data):
                raise OSError("broken pipe")

        request = {
            "v": PROTOCOL_VERSION,
            "id": "test-corr-99",
            "verb": "ping",
            "args": {},
        }
        conn = _BrokenConn(json.dumps(request).encode("utf-8"))
        sock = _FakeSock(conn)
        ledger = mock.MagicMock()
        ledger.compute_key.return_value = None
        handle = mock.MagicMock()

        with mock.patch.object(helper, "dispatch",
                side_effect=RuntimeError("original verb failure")):
            with self.assertRaises(RuntimeError) as ctx:
                helper.serve(sock, handle, ledger)

        self.assertIn("original verb failure", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
