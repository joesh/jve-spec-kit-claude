# Verb dispatch — state-changing verbs revalidate the handle via
# `_revalidate` before touching the Resolve API (FR-009). Liveness
# (`ping`) calls `handle.acquire()` directly so it can downgrade to
# alive=True/resolve_connected=False without raising. Unwired verbs
# return `not_implemented` without touching the handle — distinct from
# `resolve_api_error` so log readers can tell a Resolve API failure
# from a helper coverage gap.
#
# Scope:
#   - `ping` — full implementation
#   - `import_timeline` — DRT path validation + handle revalidation gate;
#     mapping + relink still TBD (T052 follow-on). Returns
#     `not_implemented` BEFORE touching the Resolve API so partial state
#     change is impossible.
#   - `read_identities` (T029a) — full implementation: enumerates
#     timeline items, recovers `jve_guid` via the marker channel
#     (customData convention per helper-protocol.md §read_identities),
#     reports unkeyed items via `unkeyed_count`.
#
# Other verbs (read_grades / read_timeline / queue_render /
# render_status) belong to T029b / T052 / T039 and return
# `not_implemented` — never a no-op. read_grades is split off because
# CDL extraction needs live-Resolve API exploration (see
# todo_read_grades_cdl_extraction).

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


def _iter_all_timeline_items(timeline):
    # Walk every (track_type, track_index, item) of the current timeline.
    # Resolve indexes tracks from 1; track types are the strings "video"
    # and "audio". `GetItemListInTrack` may return None for an empty
    # track — treat as empty list, not as an error.
    for track_type in ("video", "audio"):
        try:
            n_tracks = timeline.GetTrackCount(track_type)
        except Exception as exc:
            raise RuntimeError(
                f"GetTrackCount({track_type!r}) raised: {exc}") from exc
        for tidx in range(1, n_tracks + 1):
            try:
                items = timeline.GetItemListInTrack(track_type, tidx) or []
            except Exception as exc:
                raise RuntimeError(
                    f"GetItemListInTrack({track_type!r}, {tidx}) "
                    f"raised: {exc}") from exc
            for item in items:
                yield track_type, tidx, item


def _recover_jve_guid(item):
    # Marker channel per helper-protocol.md §read_identities: JVE stamps
    # `customData == clip.id` on a timeline-item marker. Reader walks
    # GetMarkers() (dict keyed by frame), surfaces any non-empty
    # customData as jve_guid. Returns None if no marker carries one.
    # Other marker fields (color/name/note) are reserved for user use —
    # not inspected.
    #
    # Multi-marker discipline: if two markers carry different non-empty
    # customData strings, that is ambiguous stamping (rule 2.32 — no
    # silent first-wins). Raise so the caller surfaces resolve_api_error
    # rather than committing the wrong jve_guid.
    try:
        markers = item.GetMarkers() or {}
    except Exception as exc:
        raise RuntimeError(
            f"item.GetMarkers() raised: {exc}") from exc
    if not isinstance(markers, dict):
        return None
    found = None
    for _frame, m in markers.items():
        if not isinstance(m, dict):
            continue
        cd = m.get("customData")
        if not isinstance(cd, str) or cd == "":
            continue
        if found is None:
            found = cd
        elif found != cd:
            raise RuntimeError(
                f"ambiguous identity marker: item carries multiple "
                f"distinct customData values ({found!r}, {cd!r})")
    return found


def verb_read_identities(args, handle, envelope_id, helper_version):
    del helper_version
    # Contract: args is none. Reject any field so closed-set discipline
    # holds at the wire boundary — silently ignoring extras would let a
    # caller pass garbage and never know (rule 2.32).
    if args:
        return _error(envelope_id, "bad_request",
            f"read_identities takes no args; got: {sorted(args.keys())}")

    handle_result = _revalidate(handle, envelope_id)
    if handle_result[0] != "ok":
        return handle_result[1]
    _, _resolve, project = handle_result

    try:
        timeline = project.GetCurrentTimeline()
    except Exception as exc:
        return _error(envelope_id, "resolve_api_error",
            f"GetCurrentTimeline raised: {exc}")
    if timeline is None:
        return _error(envelope_id, "handle_stale",
            "no current timeline — open one in Resolve")

    items = []
    unkeyed_count = 0
    try:
        for _track_type, _tidx, item in _iter_all_timeline_items(timeline):
            try:
                resolve_item_id = item.GetUniqueId()
            except Exception as exc:
                return _error(envelope_id, "resolve_api_error",
                    f"item.GetUniqueId() raised: {exc}")
            if not isinstance(resolve_item_id, str) or not resolve_item_id:
                return _error(envelope_id, "resolve_api_error",
                    "item.GetUniqueId() returned empty/non-string — "
                    "Resolve API contract broken")
            jve_guid = _recover_jve_guid(item)
            if jve_guid is None:
                unkeyed_count += 1
            else:
                items.append({
                    "resolve_item_id": resolve_item_id,
                    "jve_guid": jve_guid,
                })
    except RuntimeError as exc:
        return _error(envelope_id, "resolve_api_error", str(exc))

    return _ok(envelope_id, {
        "items": items,
        "unkeyed_count": unkeyed_count,
    })


def _unimplemented(verb_name):
    def thunk(args, handle, envelope_id, helper_version):
        del args, handle, helper_version
        return _error(envelope_id, "not_implemented",
            f"verb '{verb_name}' not yet implemented in this helper build")
    return thunk


VERB_TABLE = {
    "ping": verb_ping,
    "import_timeline": verb_import_timeline,
    "read_identities": verb_read_identities,
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
