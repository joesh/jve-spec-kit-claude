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


class ResolveHandle:
    def __init__(self):
        self._log = logging.getLogger("resolve_handle")
        self._terminal_error = None  # ("code", "msg") once set, sticky
        self._dvr = None
        self._bootstrap()

    def _bootstrap(self):
        api = os.environ.get("RESOLVE_SCRIPT_API")
        lib = os.environ.get("RESOLVE_SCRIPT_LIB")
        if not api or not lib:
            # Defaults are macOS-only by Resolve's install layout. On
            # other platforms refuse to guess — the caller must export
            # the env vars (rule 2.13: no platform-specific silent
            # fallbacks; the JVE supervisor is the right owner of any
            # future platform-aware resolution).
            if sys.platform != "darwin":
                raise RuntimeError(
                    "RESOLVE_SCRIPT_API and RESOLVE_SCRIPT_LIB environment "
                    f"variables are required on {sys.platform} (no helper "
                    "defaults; only macOS has known install paths)."
                )
            api = (
                "/Library/Application Support/Blackmagic Design/DaVinci Resolve/"
                "Developer/Scripting"
            )
            lib = (
                "/Applications/DaVinci Resolve/DaVinci Resolve.app/Contents/"
                "Libraries/Fusion/fusionscript.so"
            )
            if not os.path.exists(api) or not os.path.exists(lib):
                raise RuntimeError(
                    "RESOLVE_SCRIPT_API and RESOLVE_SCRIPT_LIB environment variables "
                    "are not set, and the macOS default paths do not exist "
                    f"(api={api!r}, lib={lib!r}). Helper cannot bootstrap."
                )
            os.environ["RESOLVE_SCRIPT_API"] = api
            os.environ["RESOLVE_SCRIPT_LIB"] = lib

        modules = os.path.join(api, "Modules")
        if modules not in sys.path:
            sys.path.insert(0, modules)
        try:
            import DaVinciResolveScript as dvr  # type: ignore[import]
            self._dvr = dvr
        except ImportError as exc:
            raise RuntimeError(f"DaVinciResolveScript import failed: {exc}") from exc

    def acquire(self):
        if self._terminal_error is not None:
            code, msg = self._terminal_error
            return ("error", code, msg)
        try:
            resolve = self._dvr.scriptapp("Resolve")
        except Exception as exc:
            return ("error", "resolve_api_error",
                f"scriptapp('Resolve') raised: {exc}")
        if resolve is None:
            return ("error", "handle_stale",
                "scriptapp('Resolve') returned None — Resolve may be closed")

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
            pm = resolve.GetProjectManager()
            if pm is None:
                 return ("error", "resolve_api_error",
                     "GetProjectManager() returned None")
            project = pm.GetCurrentProject()
        except Exception as exc:
            return ("error", "resolve_api_error",
                f"GetCurrentProject failed: {exc}")
        if project is None:
            return ("error", "handle_stale",
                "no current project — Resolve UI may have closed it")

        return ("ok", resolve, project)

    def version_string(self):
        # Logged with every ping per protocol.md ("API-drift landmine").
        # Rule 2.13: no "unavailable" fallback. If we can't get the version,
        # it's a diagnostic-worthy failure.
        if self._terminal_error is not None:
            code, msg = self._terminal_error
            raise RuntimeError(f"Cannot get version in terminal state: {code} ({msg})")
            
        resolve = self._dvr.scriptapp("Resolve")
        if resolve is None:
            raise RuntimeError("scriptapp('Resolve') returned None")
            
        ver = resolve.GetVersionString()
        if ver is None:
             raise RuntimeError("GetVersionString() returned None")
        return ver
