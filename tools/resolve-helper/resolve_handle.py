# Resolve handle — bootstrap + per-verb revalidation (FR-009, FR-010).
#
# Construction sets up the env vars + PYTHONPATH required to load
# `fusionscript.so` (see phase0-findings.md §Environment). `acquire()` is
# called by every verb; it re-grabs the resolve+project handles and
# returns either `("ok", resolve, project)` or `("error", code, message)`
# with a closed error code from contracts/helper-protocol.md.
#
# Studio gate (FR-010): the first successful acquire checks
# `GetProductName() == "DaVinci Resolve Studio"`; non-Studio sticks the
# handle into the `not_studio` terminal state — subsequent acquires
# short-circuit there until the helper restarts (Studio license doesn't
# get added at runtime).

import logging
import os
import sys


# Documented Resolve scripting env vars (phase0-findings.md §Environment).
DEFAULT_SCRIPT_API = (
    "/Library/Application Support/Blackmagic Design/DaVinci Resolve/"
    "Developer/Scripting"
)
DEFAULT_SCRIPT_LIB = (
    "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/"
    "Libraries/Fusion/fusionscript.so"
)


class ResolveHandle:
    def __init__(self):
        self._log = logging.getLogger("resolve_handle")
        self._terminal_error = None  # ("code", "msg") once set, sticky
        self._dvr = None
        self._bootstrap()

    def _bootstrap(self):
        api = os.environ.get("RESOLVE_SCRIPT_API", DEFAULT_SCRIPT_API)
        lib = os.environ.get("RESOLVE_SCRIPT_LIB", DEFAULT_SCRIPT_LIB)
        os.environ["RESOLVE_SCRIPT_API"] = api
        os.environ["RESOLVE_SCRIPT_LIB"] = lib
        modules = os.path.join(api, "Modules")
        if modules not in sys.path:
            sys.path.insert(0, modules)
        try:
            import DaVinciResolveScript as dvr  # type: ignore[import]
            self._dvr = dvr
        except ImportError as exc:
            self._terminal_error = (
                "resolve_api_error",
                f"DaVinciResolveScript import failed: {exc}",
            )

    def acquire(self):
        if self._terminal_error is not None:
            code, msg = self._terminal_error
            return ("error", code, msg)
        try:
            resolve = self._dvr.scriptapp("Resolve")
        except Exception as exc:
            return ("error", "resolve_api_error",
                f"scriptapp() raised: {exc}")
        if resolve is None:
            return ("error", "handle_stale",
                "scriptapp('Resolve') returned None")

        try:
            product = resolve.GetProductName()
        except Exception as exc:
            return ("error", "resolve_api_error",
                f"GetProductName failed: {exc}")
        if product != "DaVinci Resolve Studio":
            self._terminal_error = (
                "not_studio",
                f"connected Resolve is {product!r}, not Studio",
            )
            code, msg = self._terminal_error
            return ("error", code, msg)

        try:
            project = resolve.GetProjectManager().GetCurrentProject()
        except Exception as exc:
            return ("error", "resolve_api_error",
                f"GetCurrentProject failed: {exc}")
        if project is None:
            return ("error", "handle_stale",
                "no current project — Resolve UI may have closed it")

        return ("ok", resolve, project)

    def version_string(self):
        # Logged with every ping per protocol.md ("API-drift landmine").
        if self._terminal_error is not None:
            return "unavailable"
        try:
            resolve = self._dvr.scriptapp("Resolve")
            if resolve is None:
                return "unavailable"
            return resolve.GetVersionString()
        except Exception:
            return "unavailable"
