"""ResolveHandle._bootstrap platform gate (review M#16, 2026-06-09).

When RESOLVE_SCRIPT_API / RESOLVE_SCRIPT_LIB are not in the env, the
helper used to fall back to macOS install paths regardless of platform.
On linux/windows that gave a misleading "default paths do not exist"
diagnostic. Now: non-mac platforms refuse to guess and raise a precise
"required on <platform>" message.
"""
import os
import sys
import unittest
from pathlib import Path
from unittest import mock

THIS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(THIS_DIR))

import resolve_handle  # noqa: E402


class _NoEnv:
    """Strip the two RESOLVE_* env vars and restore them on exit."""
    def __enter__(self):
        self._saved = {}
        for k in ("RESOLVE_SCRIPT_API", "RESOLVE_SCRIPT_LIB"):
            self._saved[k] = os.environ.pop(k, None)
        return self

    def __exit__(self, *_):
        for k, v in self._saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


class BootstrapPlatformGateTests(unittest.TestCase):

    def test_linux_refuses_to_guess(self):
        with _NoEnv(), mock.patch.object(
                resolve_handle.sys, "platform", "linux"):
            with self.assertRaises(RuntimeError) as cm:
                resolve_handle.ResolveHandle()
        msg = str(cm.exception)
        self.assertIn("required on linux", msg)
        self.assertIn("only macOS", msg)

    def test_windows_refuses_to_guess(self):
        with _NoEnv(), mock.patch.object(
                resolve_handle.sys, "platform", "win32"):
            with self.assertRaises(RuntimeError) as cm:
                resolve_handle.ResolveHandle()
        self.assertIn("required on win32", str(cm.exception))

    def test_macos_with_nonexistent_default_paths_lists_them(self):
        # On a mac without Resolve installed, the second guard catches
        # missing default paths — diagnostic now includes the actual
        # paths we tried so a future contributor can grep for
        # installed-vs-expected mismatches.
        with _NoEnv(), \
             mock.patch.object(resolve_handle.sys, "platform", "darwin"), \
             mock.patch.object(resolve_handle.os.path, "exists",
                               return_value=False):
            with self.assertRaises(RuntimeError) as cm:
                resolve_handle.ResolveHandle()
        msg = str(cm.exception)
        self.assertIn("default paths do not exist", msg)
        self.assertIn("api=", msg)
        self.assertIn("lib=", msg)


if __name__ == "__main__":
    unittest.main()
