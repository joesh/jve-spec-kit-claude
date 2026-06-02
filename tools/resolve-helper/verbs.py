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
#   - `read_timeline` (T052) — V1 video-only. Returns per-item edit
#     state: positional `(track_type, track_index)`, record TC,
#     source TC, enabled. JVE-side translates `(track_type,
#     track_index)` → JVE `track_id` via Track.find_at. Audio items
#     are skipped at the helper layer; audio support lands with T054
#     (subframe-aware fingerprints + sample-rate mismatch handling on
#     the JVE side, paired with this helper carrying audio items in
#     the `{frame, subframe}` shape the contract documents).
#
# Other verbs (read_grades / queue_render / render_status) belong to
# T029b / T039 and return `not_implemented` — never a no-op.
# read_grades is split off because CDL extraction needs live-Resolve
# API exploration (see todo_read_grades_cdl_extraction).

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


def _validate_item_ids(args):
    # Args contract: `{ item_ids?: [string] }`. omit ⇒ all items;
    # empty list ⇒ zero items (distinct from omit). Reject any other key
    # so closed-set discipline holds at the wire boundary (rule 2.32).
    extras = sorted(k for k in args.keys() if k != "item_ids")
    if extras:
        return ("error", f"unknown args fields: {extras}")
    item_ids = args.get("item_ids")
    if item_ids is None:
        return ("ok", None)
    if not isinstance(item_ids, list):
        return ("error",
            "item_ids must be a list of strings (got "
            f"{type(item_ids).__name__})")
    for i, x in enumerate(item_ids):
        if not isinstance(x, str) or x == "":
            return ("error",
                f"item_ids[{i}] must be non-empty string (got "
                f"{type(x).__name__})")
    return ("ok", set(item_ids))


def _read_video_item(item):
    # Per helper-protocol.md §read_timeline (video items): integer frames
    # for every TC field. Resolve docs (Developer/Scripting/README.txt
    # §TimelineItem):
    #   GetStart()          → start frame on timeline (record-side)
    #   GetDuration()       → duration in frames
    #   GetSourceStartFrame → start frame in source media
    #   GetSourceEndFrame   → end frame in source media
    #   GetClipEnabled      → bool
    # Each Resolve call is gated with try/except so a Resolve API
    # surprise becomes resolve_api_error, never a silent failure.
    try:
        resolve_item_id = item.GetUniqueId()
    except Exception as exc:
        raise RuntimeError(f"item.GetUniqueId() raised: {exc}") from exc
    if not isinstance(resolve_item_id, str) or not resolve_item_id:
        raise RuntimeError(
            "item.GetUniqueId() returned empty/non-string — "
            "Resolve API contract broken")
    try:
        record_start    = item.GetStart()
        record_duration = item.GetDuration()
        source_in       = item.GetSourceStartFrame()
        source_out      = item.GetSourceEndFrame()
        enabled         = item.GetClipEnabled()
    except Exception as exc:
        raise RuntimeError(
            f"timeline-item TC/enabled extraction raised: {exc}") from exc
    for field_name, value in (
        ("record_start",    record_start),
        ("record_duration", record_duration),
        ("source_in",       source_in),
        ("source_out",      source_out),
    ):
        if not isinstance(value, int):
            raise RuntimeError(
                f"item.{field_name} must be int (Resolve video items "
                f"are integer-frame); got {type(value).__name__} = "
                f"{value!r}")
    if not isinstance(enabled, bool):
        raise RuntimeError(
            f"item.GetClipEnabled() must return bool; got "
            f"{type(enabled).__name__} = {enabled!r}")
    return {
        "resolve_item_id": resolve_item_id,
        "record_start":    record_start,
        "record_duration": record_duration,
        "source_in":       source_in,
        "source_out":      source_out,
        "enabled":         enabled,
    }


def verb_read_timeline(args, handle, envelope_id, helper_version):
    del helper_version

    validation = _validate_item_ids(args)
    if validation[0] != "ok":
        return _error(envelope_id, "bad_request", validation[1])
    item_id_filter = validation[1]  # None = all; set = whitelist

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
    try:
        for track_type, tidx, item in _iter_all_timeline_items(timeline):
            # V1 scope: video items only. Audio support lands with T054
            # (subframe-aware {frame, subframe} extraction, sample-rate
            # mismatch handling on the JVE side). Skipping audio items
            # here means a JVE walk_ledger_for_deleted on the JVE side
            # may surface audio ledger rows as deleted_in_resolve until
            # T054 lands — documented in data-model.md §V1 scope.
            if track_type != "video":
                continue
            video_fields = _read_video_item(item)
            if item_id_filter is not None and (
                    video_fields["resolve_item_id"] not in item_id_filter):
                continue
            items.append({
                **video_fields,
                "track_type":  track_type,
                "track_index": tidx,
            })
    except RuntimeError as exc:
        return _error(envelope_id, "resolve_api_error", str(exc))

    return _ok(envelope_id, {"items": items})


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
    "read_timeline":   verb_read_timeline,
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
