# Verb dispatch — state-changing verbs revalidate the handle via
# `_revalidate` before touching the Resolve API (FR-009). Liveness
# (`ping`) calls `handle.acquire()` directly so it can downgrade to
# alive=True/resolve_connected=False without raising. Unwired verbs
# return `not_implemented` without touching the handle — distinct from
# `resolve_api_error` so log readers can tell a Resolve API failure
# from a helper coverage gap.
#
# Scope of THIS file (T021 landing):
#   - `ping` — full implementation
#   - `import_timeline` — DRT path validation + handle revalidation gate;
#     the actual ImportTimelineFromFile call is deferred until the
#     mapping + relink follow-on lands (T029). State-changing verbs must
#     not mutate Resolve state before they can report success, so the
#     verb returns `not_implemented` BEFORE calling the Resolve API.
#
# Other verbs (read_identities / read_timeline / read_grades /
# queue_render / render_status) belong to T029 / T038 / T039 / T052 and
# return `not_implemented` — never a no-op.

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

    # State-changing verbs must not mutate Resolve state before they can
    # report success. ImportTimelineFromFile + mapping + relink are not
    # yet wired (T029 follow-on); calling the import alone would leave a
    # ghost timeline in Resolve while JVE saw a failure. Return early
    # WITHOUT touching the Resolve API.
    return _error(envelope_id, "not_implemented",
        "import_timeline: mapping + relink not yet wired (T029); "
        "Resolve-side import deliberately not performed so state stays "
        "consistent")


def _unimplemented(verb_name):
    def thunk(args, handle, envelope_id, helper_version):
        del args, handle, helper_version
        return _error(envelope_id, "not_implemented",
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
