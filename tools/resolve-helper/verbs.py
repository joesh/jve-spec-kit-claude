# Verb dispatch — every verb revalidates the handle first (FR-009), then
# touches the Resolve API. Errors map to the closed code set from
# contracts/helper-protocol.md; nothing raises across the socket boundary.
#
# Scope of THIS file (T021 landing):
#   - `ping` — full implementation
#   - `import_timeline` — wired skeleton (DRT path validation + relink
#     call gates, with the real API import deferred to a live-Resolve
#     iteration). Returns `resolve_api_error` with a precise message until
#     wired so failures are never silent.
#
# Other verbs (read_identities / read_timeline / read_grades /
# queue_render / render_status) belong to T029 / T038 / T039 / T052 and
# return `resolve_api_error` with "not yet implemented" — never a no-op.

import logging
import os

PROTOCOL_VERSION = 1


def _ok(envelope_id, result):
    return {
        "v": PROTOCOL_VERSION,
        "id": envelope_id,
        "ok": True,
        "result": result,
    }


def _error(envelope_id, code, message):
    return {
        "v": PROTOCOL_VERSION,
        "id": envelope_id,
        "ok": False,
        "error": {"code": code, "message": message},
    }


def _revalidate(handle, envelope_id):
    status = handle.acquire()
    if status[0] == "ok":
        return ("ok", status[1], status[2])
    _, code, msg = status
    return ("error", _error(envelope_id, code, msg))


def verb_ping(args, handle, envelope_id, helper_version):
    del args  # ping carries no args
    status = handle.acquire()
    if status[0] == "ok":
        return _ok(envelope_id, {
            "alive": True,
            "resolve_connected": True,
            "resolve_version": handle.version_string(),
            "helper_version": helper_version,
        })
    # Non-fatal: ping returns alive=True + connected=False on
    # handle errors so JVE can gate UI without false "helper dead"
    # alarms when Resolve is just not running.
    _, code, msg = status
    if code in ("handle_stale", "resolve_api_error", "not_studio"):
        return _ok(envelope_id, {
            "alive": True,
            "resolve_connected": False,
            "resolve_version": handle.version_string(),
            "helper_version": helper_version,
            "last_error": {"code": code, "message": msg},
        })
    return _error(envelope_id, code, msg)


def verb_import_timeline(args, handle, envelope_id, helper_version):
    del helper_version
    log = logging.getLogger("verb.import_timeline")

    drt_path = args.get("drt_path")
    media_roots = args.get("media_roots")
    if not isinstance(drt_path, str) or not drt_path:
        return _error(envelope_id, "bad_request", "drt_path missing")
    if not isinstance(media_roots, list) or not all(
            isinstance(r, str) for r in media_roots):
        return _error(envelope_id, "bad_request",
            "media_roots must be list[string]")
    if not os.path.exists(drt_path):
        return _error(envelope_id, "bad_request",
            f"drt_path does not exist: {drt_path}")

    handle_result = _revalidate(handle, envelope_id)
    if handle_result[0] != "ok":
        return handle_result[1]
    _, resolve, project = handle_result

    media_pool = project.GetMediaPool()
    if media_pool is None:
        return _error(envelope_id, "resolve_api_error",
            "GetMediaPool() returned None")

    try:
        imported = media_pool.ImportTimelineFromFile(drt_path)
    except Exception as exc:
        log.exception("ImportTimelineFromFile raised")
        return _error(envelope_id, "resolve_api_error",
            f"ImportTimelineFromFile raised: {exc}")
    if not imported:
        return _error(envelope_id, "relink_failed",
            "ImportTimelineFromFile returned falsy (Resolve refused .drt)")

    # Identity-mapping + relink remain to be implemented against the live
    # Resolve scripting surface. Surfacing a precise unimplemented error
    # instead of returning empty arrays keeps callers honest.
    return _error(envelope_id, "resolve_api_error",
        "import_timeline mapping + relink not yet implemented "
        "(T029 follow-on)")


def _unimplemented(verb_name):
    def thunk(args, handle, envelope_id, helper_version):
        del args, handle, helper_version
        return _error(envelope_id, "resolve_api_error",
            f"verb '{verb_name}' not yet implemented in this helper build")
    return thunk


VERB_TABLE = {
    "ping": verb_ping,
    "import_timeline": verb_import_timeline,
    "read_identities": _unimplemented("read_identities"),
    "read_timeline":   _unimplemented("read_timeline"),
    "read_grades":     _unimplemented("read_grades"),
    "queue_render":    _unimplemented("queue_render"),
    "render_status":   _unimplemented("render_status"),
}


def dispatch(verb, args, handle, envelope_id, helper_version):
    fn = VERB_TABLE.get(verb)
    if fn is None:
        return _error(envelope_id, "bad_request",
            f"unknown verb '{verb}'")
    return fn(args, handle, envelope_id, helper_version)
