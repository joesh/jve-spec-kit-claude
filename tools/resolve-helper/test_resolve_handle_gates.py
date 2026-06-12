"""ResolveHandle.acquire() Studio gate must emit the closed-set code
`not_studio`, not `resolve_api_error` (FR-010, helper-protocol.md §error
codes table: "`not_studio` | connected Resolve is not Studio").

The gate is terminal: once a non-Studio product is seen, every later
acquire short-circuits to the same error without touching the API
(a Studio license doesn't appear at runtime).

The fusionscript boundary is faked the same way test_ping_disconnected
fakes the handle: a stand-in module in sys.modules whose product names
are the REAL strings Resolve returns ("DaVinci Resolve" for free,
"DaVinci Resolve Studio" for Studio — live-probed Studio 20.3.2.9,
phase0-findings.md). No live Resolve is contacted.

Run: `python3 -m unittest test_resolve_handle_gates` from
tools/resolve-helper/.
"""
import os
import sys
import unittest
from pathlib import Path

THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(THIS_DIR))


class _FakeResolveApp:
    def __init__(self, product):
        self._product = product
        self.product_name_calls = 0

    def GetProductName(self):
        self.product_name_calls += 1
        return self._product


class _FakeFusionscript:
    """Stands in for the DaVinciResolveScript module."""
    def __init__(self, product):
        self.app = _FakeResolveApp(product)
        self.scriptapp_calls = 0

    def scriptapp(self, name):
        assert name == "Resolve"
        self.scriptapp_calls += 1
        return self.app


class _HandleEnv:
    """Build a ResolveHandle against a faked fusionscript module.

    Sets the two RESOLVE_* env vars (so _bootstrap doesn't consult the
    machine's install paths) and pre-seeds sys.modules so the
    `import DaVinciResolveScript` inside _bootstrap binds to the fake.
    Restores everything on exit.
    """
    def __init__(self, product):
        self._fake = _FakeFusionscript(product)

    def __enter__(self):
        self._saved_env = {}
        for k in ("RESOLVE_SCRIPT_API", "RESOLVE_SCRIPT_LIB"):
            self._saved_env[k] = os.environ.get(k)
            os.environ[k] = "/nonexistent-for-test"
        self._saved_mod = sys.modules.get("DaVinciResolveScript")
        sys.modules["DaVinciResolveScript"] = self._fake
        return self._fake

    def __exit__(self, *_):
        for k, v in self._saved_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        if self._saved_mod is None:
            sys.modules.pop("DaVinciResolveScript", None)
        else:
            sys.modules["DaVinciResolveScript"] = self._saved_mod


class StudioGateTests(unittest.TestCase):

    def _handle(self):
        import resolve_handle
        return resolve_handle.ResolveHandle()

    def test_free_resolve_acquire_is_not_studio(self):
        with _HandleEnv("DaVinci Resolve") as fake:
            rh = self._handle()
            status = rh.acquire()
        self.assertEqual(status[0], "error")
        self.assertEqual(
            status[1], "not_studio",
            "FR-010: non-Studio product must map to the closed-set "
            "code 'not_studio' (helper-protocol.md error table), "
            f"got {status[1]!r}")
        self.assertIn("DaVinci Resolve", status[2])
        self.assertEqual(fake.app.product_name_calls, 1)

    def test_not_studio_is_terminal_and_sticky(self):
        with _HandleEnv("DaVinci Resolve") as fake:
            rh = self._handle()
            first = rh.acquire()
            second = rh.acquire()
        self.assertEqual(first[1], "not_studio")
        self.assertEqual(second[1], "not_studio")
        # Terminal short-circuit: the second acquire must not have
        # gone back to the API.
        self.assertEqual(fake.scriptapp_calls, 1)
        self.assertEqual(fake.app.product_name_calls, 1)

    def test_studio_product_passes_the_gate(self):
        # Studio proceeds past the product check; the fake has no
        # GetProjectManager, so the next failure is a resolve_api_error
        # from that call — proving the gate itself didn't fire.
        with _HandleEnv("DaVinci Resolve Studio"):
            rh = self._handle()
            status = rh.acquire()
        self.assertEqual(status[0], "error")
        self.assertEqual(status[1], "resolve_api_error")
        self.assertIn("GetProjectManager", status[2])


if __name__ == "__main__":
    unittest.main()
