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
#   - `read_grades` (T029b) — per-item ASC CDL recovery via
#     `timeline.Export(EXPORT_EDL, EXPORT_CDL)` + fidelity from
#     `GetNodeGraph().GetToolsInNode()` (spec.md:30). Pure-data parser
#     + classifier live in `cdl_edl.py`; this verb owns the Resolve API
#     plumbing.
#   - `stamp_identity_marker` (T048) — stamp `customData == clip.id`
#     on a timeline item's marker; idempotent on (change_token,
#     resolve_item_id, custom_data); refuses on conflicting prior
#     identity (no silent overwrite).
#
# Render-queue verbs (`queue_render` / `render_status`) were carved out
# 2026-06-02 — preserved at tag `spec023-render-relink-deferred`.
# See `feedback_render_relink_carved_out` for the rationale.

import functools
import os
import tempfile

from cdl_edl import (
    CdlEdlParseError,
    classify_fidelity,
    integer_frame_rate_from_setting,
    parse_cdl_edl,
)
from protocol import PROTOCOL_VERSION


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


def _stateful_verb(fn):
    """Decorator for verbs that require a live Resolve handle (FR-009).

    Revalidates the handle before dispatching to the verb body. On
    revalidation failure, returns the error envelope verbatim. On
    success, invokes `fn(args, resolve, project, envelope_id,
    helper_version)`.

    Why a decorator (and not a helper call repeated per verb): the
    4-line revalidation block was duplicated verbatim across every
    state-changing verb. Each verb's body opened with logic unrelated
    to the verb itself; lifting that into the decorator means each
    verb body starts with the verb's actual work.

    `ping` is NOT decorated — it downgrades to alive=True on certain
    handle errors and needs the raw status tuple to choose between
    error envelope and downgraded ok. `_unimplemented` thunks aren't
    decorated either — they must NOT touch the handle (so a coverage
    gap reads as `not_implemented`, never `resolve_api_error`).
    """
    @functools.wraps(fn)
    def wrapper(args, handle, envelope_id, helper_version):
        handle_result = _revalidate(handle, envelope_id)
        if handle_result[0] != "ok":
            return handle_result[1]
        _, resolve, project = handle_result
        return fn(args, resolve, project, envelope_id, helper_version)
    return wrapper


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


_TRACK_TYPES_LOWER = {"video", "audio"}


def _validate_clip_positions(value):
    # `clip_positions` is JVE's [(clip.id, track_type, track_index,
    # record_start), ...] map — supplied because the helper has no JVE
    # state (FR-021). Each entry must be a JSON object with the four
    # documented fields. Returns ("ok", list[dict]) | ("error", msg).
    if not isinstance(value, list):
        return ("error",
            "clip_positions must be list of {clip_id, track_type, "
            "track_index, record_start}")
    out = []
    for i, entry in enumerate(value):
        if not isinstance(entry, dict):
            return ("error",
                f"clip_positions[{i}] must be JSON object")
        clip_id = entry.get("clip_id")
        track_type = entry.get("track_type")
        track_index = entry.get("track_index")
        record_start = entry.get("record_start")
        if not isinstance(clip_id, str) or not clip_id:
            return ("error",
                f"clip_positions[{i}].clip_id must be non-empty string")
        if track_type not in _TRACK_TYPES_LOWER:
            return ("error",
                f"clip_positions[{i}].track_type must be 'video' or "
                f"'audio' (got {track_type!r})")
        if not isinstance(track_index, int) or isinstance(
                track_index, bool) or track_index < 1:
            return ("error",
                f"clip_positions[{i}].track_index must be 1-based "
                f"integer (got {track_index!r})")
        if not isinstance(record_start, int) or isinstance(
                record_start, bool) or record_start < 0:
            return ("error",
                f"clip_positions[{i}].record_start must be "
                f"non-negative integer (got {record_start!r})")
        out.append({
            "clip_id":      clip_id,
            "track_type":   track_type,
            "track_index":  track_index,
            "record_start": record_start,
        })
    # No duplicate position keys — would make matching ambiguous.
    seen = set()
    for entry in out:
        key = (entry["track_type"], entry["track_index"],
            entry["record_start"])
        if key in seen:
            return ("error",
                f"clip_positions has duplicate position key "
                f"(track_type={entry['track_type']!r}, "
                f"track_index={entry['track_index']}, "
                f"record_start={entry['record_start']}) — JVE clips "
                "may not stack at the same position on one track")
        seen.add(key)
    return ("ok", out)


def _find_imported_timeline(project, prev_timeline_ids):
    # ImportTimelineFromFile returns the imported Timeline handle on
    # newer Resolve versions and a bool on older ones. We rely on the
    # post-import delta against the pre-import GetTimelineByIndex list
    # to find the new timeline either way (timelines are 1-indexed).
    try:
        n = project.GetTimelineCount()
    except Exception as exc:
        raise RuntimeError(
            f"GetTimelineCount raised: {exc}") from exc
    for i in range(1, n + 1):
        try:
            tl = project.GetTimelineByIndex(i)
        except Exception as exc:
            raise RuntimeError(
                f"GetTimelineByIndex({i}) raised: {exc}") from exc
        if tl is None:
            continue
        try:
            tl_id = tl.GetUniqueId()
        except Exception as exc:
            raise RuntimeError(
                f"timeline.GetUniqueId raised: {exc}") from exc
        if tl_id not in prev_timeline_ids:
            return tl
    return None


def _snapshot_timeline_ids(project):
    try:
        n = project.GetTimelineCount()
    except Exception as exc:
        raise RuntimeError(
            f"GetTimelineCount raised: {exc}") from exc
    ids = set()
    for i in range(1, n + 1):
        try:
            tl = project.GetTimelineByIndex(i)
            if tl is None:
                continue
            ids.add(tl.GetUniqueId())
        except Exception as exc:
            raise RuntimeError(
                f"timeline snapshot raised at index {i}: {exc}") from exc
    return ids


def _build_position_index(clip_positions):
    return {
        (c["track_type"], c["track_index"], c["record_start"]): c["clip_id"]
        for c in clip_positions
    }


def _stamp_marker_safe(item, clip_id):
    # Idempotent per the §stamp_identity_marker convention. Skips if
    # the item already carries the matching customData; raises on
    # conflict or AddMarker failure.
    existing = _recover_jve_guid(item)  # may raise on ambiguity
    if existing == clip_id:
        return False
    if existing is not None:
        raise RuntimeError(
            f"item already carries conflicting marker "
            f"(customData={existing!r}, would-stamp={clip_id!r})")
    added = item.AddMarker(
        _IDENTITY_MARKER_FRAME,
        _IDENTITY_MARKER_COLOR,
        _IDENTITY_MARKER_NAME,
        _IDENTITY_MARKER_NOTE,
        _IDENTITY_MARKER_DURATION_FRAMES,
        clip_id,
    )
    if not added:
        raise RuntimeError(
            f"item.AddMarker(customData={clip_id!r}) returned False")
    return True


@_stateful_verb
def verb_import_timeline(args, _resolve, project, envelope_id, helper_version):
    del helper_version

    token_check = _validate_change_token(args, "import_timeline")
    if token_check[0] != "ok":
        return _error(envelope_id, "bad_request", token_check[1])

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
    positions_check = _validate_clip_positions(args.get("clip_positions"))
    if positions_check[0] != "ok":
        return _error(envelope_id, "bad_request", positions_check[1])
    clip_positions = positions_check[1]

    try:
        prev_ids = _snapshot_timeline_ids(project)
    except RuntimeError as exc:
        return _error(envelope_id, "resolve_api_error", str(exc))

    media_pool = project.GetMediaPool()
    if media_pool is None:
        return _error(envelope_id, "resolve_api_error",
            "GetMediaPool() returned None")

    try:
        imported = media_pool.ImportTimelineFromFile(drt_path)
    except Exception as exc:
        return _error(envelope_id, "resolve_api_error",
            f"ImportTimelineFromFile raised: {exc}")
    if not imported:
        return _error(envelope_id, "relink_failed",
            "ImportTimelineFromFile returned falsy (Resolve refused .drt)")

    try:
        timeline = _find_imported_timeline(project, prev_ids)
    except RuntimeError as exc:
        return _error(envelope_id, "resolve_api_error", str(exc))
    if timeline is None:
        return _error(envelope_id, "resolve_api_error",
            "post-import timeline scan: no new timeline appeared "
            "(GetTimelineCount delta empty)")

    pos_to_clip_id = _build_position_index(clip_positions)
    mapping = []
    unkeyed_resolve_items = []
    try:
        for track_type, tidx, item in _iter_all_timeline_items(timeline):
            try:
                resolve_item_id = item.GetUniqueId()
                record_start = item.GetStart()
            except Exception as exc:
                return _error(envelope_id, "resolve_api_error",
                    f"item attribute read raised: {exc}")
            if not isinstance(resolve_item_id, str) or not resolve_item_id:
                return _error(envelope_id, "resolve_api_error",
                    "item.GetUniqueId() returned empty/non-string")
            if not isinstance(record_start, int):
                return _error(envelope_id, "resolve_api_error",
                    f"item.GetStart() must be int, got "
                    f"{type(record_start).__name__}")
            key = (track_type, tidx, record_start)
            jve_guid = pos_to_clip_id.get(key)
            if jve_guid is None:
                unkeyed_resolve_items.append({
                    "resolve_item_id": resolve_item_id,
                    "track_type":      track_type,
                    "track_index":     tidx,
                    "record_start":    record_start,
                })
                continue
            try:
                _stamp_marker_safe(item, jve_guid)
            except RuntimeError as exc:
                return _error(envelope_id, "resolve_api_error",
                    f"stamping clip_id={jve_guid!r} at {key}: {exc}")
            mapping.append({
                "jve_guid":        jve_guid,
                "resolve_item_id": resolve_item_id,
            })
    except RuntimeError as exc:
        return _error(envelope_id, "resolve_api_error", str(exc))

    # JVE clip_ids whose position has no live counterpart. The most
    # common cause is Resolve silently dropping a clip whose media
    # couldn't be relinked (FR-001/007 intent), but the helper can't
    # distinguish that from "DRT didn't actually contain the clip"
    # without parsing the DRT — so the reason names what the helper
    # actually observed.
    matched_clip_ids = {row["jve_guid"] for row in mapping}
    unrelinked = []
    for entry in clip_positions:
        if entry["clip_id"] not in matched_clip_ids:
            unrelinked.append({
                "jve_guid": entry["clip_id"],
                "reason":   "absent_from_live_timeline",
            })

    return _ok(envelope_id, {
        "mapping":               mapping,
        "unrelinked":            unrelinked,
        "unkeyed_resolve_items": unkeyed_resolve_items,
    })


def _require_current_timeline(project, envelope_id):
    # Shared guard for verbs that operate on the project's current
    # timeline. Returns (timeline, None) on success, or (None, error
    # response) when the API call fails or no timeline is open. Lifted
    # from four near-identical try/except + None-check stanzas across
    # read_identities / read_timeline / stamp_identity_marker /
    # read_grades.
    try:
        timeline = project.GetCurrentTimeline()
    except Exception as exc:
        return None, _error(envelope_id, "resolve_api_error",
            f"GetCurrentTimeline raised: {exc}")
    if timeline is None:
        return None, _error(envelope_id, "handle_stale",
            "no current timeline — open one in Resolve")
    return timeline, None


def _safe_uid(item):
    # Shared "read item.GetUniqueId and assert it's a non-empty string"
    # for the three verbs that follow that exact pattern (read_identities,
    # read_video_item, read_grades). Each caller wraps a broader for-
    # loop in `try/except RuntimeError` and converts to a structured
    # resolve_api_error; raising here lets that single conversion catch
    # both the Resolve-API surprise and the empty-result anomaly.
    #
    # Two callsites are deliberately NOT routed through this helper:
    # verb_import_timeline bundles GetUniqueId + GetStart in one try,
    # and _find_timeline_item_by_uid doesn't do the non-empty check.
    # Don't invent a fan-out signature to shoehorn them in.
    try:
        uid = item.GetUniqueId()
    except Exception as exc:
        raise RuntimeError(
            f"item.GetUniqueId() raised: {exc}") from exc
    if not isinstance(uid, str) or not uid:
        raise RuntimeError(
            "item.GetUniqueId() returned empty/non-string — "
            "Resolve API contract broken")
    return uid


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


@_stateful_verb
def verb_read_identities(args, _resolve, project, envelope_id, helper_version):
    del helper_version
    # Contract: args is none. Reject any field so closed-set discipline
    # holds at the wire boundary — silently ignoring extras would let a
    # caller pass garbage and never know (rule 2.32).
    if args:
        return _error(envelope_id, "bad_request",
            f"read_identities takes no args; got: {sorted(args.keys())}")

    timeline, err = _require_current_timeline(project, envelope_id)
    if err is not None:
        return err

    items = []
    unkeyed_count = 0
    try:
        for _track_type, _tidx, item in _iter_all_timeline_items(timeline):
            resolve_item_id = _safe_uid(item)
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
    # Per helper-protocol.md §read_timeline. Resolve docs
    # (Developer/Scripting/README.txt §TimelineItem):
    #   GetStart()          → start frame on timeline (record-side)
    #   GetDuration()       → duration in frames
    #   GetSourceStartFrame → start frame in source media (None for
    #                         items with no indexable source — generators,
    #                         Text+, transitions, adjustment clips, some
    #                         Fusion comps)
    #   GetSourceEndFrame   → end frame in source media (mirror of above)
    #   GetClipEnabled      → bool
    #
    # Discriminator for `kind`: presence of integer source TC on BOTH
    # source_in and source_out. This is what JVE actually needs (a source
    # range to index into) — not the higher-level "is this a media-pool
    # item" question, which mis-classifies generators (have a media-pool
    # entry but no source range) and compound clips (DO have a source
    # range and should be matchable once DRP importer covers them).
    #
    # • kind="media" → source_in / source_out included, both ints
    # • kind="non_media" → source_in / source_out omitted
    # Record-side fields (record_start, record_duration, enabled) are
    # present for both kinds — those Resolve API calls work on every
    # timeline-item type. Each Resolve call is gated with try/except so
    # an API surprise becomes resolve_api_error, never a silent failure
    # (rule 2.32).
    resolve_item_id = _safe_uid(item)
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
    ):
        if not isinstance(value, int) or isinstance(value, bool):
            raise RuntimeError(
                f"item.{field_name} must be int (Resolve timeline items "
                f"are integer-frame on the record side); got "
                f"{type(value).__name__} = {value!r}")
    if not isinstance(enabled, bool):
        raise RuntimeError(
            f"item.GetClipEnabled() must return bool; got "
            f"{type(enabled).__name__} = {enabled!r}")
    src_in_is_int  = isinstance(source_in,  int) and not isinstance(source_in,  bool)
    src_out_is_int = isinstance(source_out, int) and not isinstance(source_out, bool)
    if src_in_is_int and src_out_is_int:
        return {
            "resolve_item_id": resolve_item_id,
            "kind":            "media",
            "record_start":    record_start,
            "record_duration": record_duration,
            "source_in":       source_in,
            "source_out":      source_out,
            "enabled":         enabled,
        }
    if src_in_is_int or src_out_is_int:
        # Partial-int source TC is a Resolve API surprise, not a kind
        # boundary — surface loudly. Silent downgrade to non_media would
        # hide a real regression (rule 2.32).
        raise RuntimeError(
            f"timeline-item source TC partially present: "
            f"source_in={source_in!r} source_out={source_out!r} — "
            f"expected both int or both None")
    return {
        "resolve_item_id": resolve_item_id,
        "kind":            "non_media",
        "record_start":    record_start,
        "record_duration": record_duration,
        "enabled":         enabled,
    }


@_stateful_verb
def verb_read_timeline(args, _resolve, project, envelope_id, helper_version):
    del helper_version

    validation = _validate_item_ids(args)
    if validation[0] != "ok":
        return _error(envelope_id, "bad_request", validation[1])
    item_id_filter = validation[1]  # None = all; set = whitelist

    timeline, err = _require_current_timeline(project, envelope_id)
    if err is not None:
        return err

    # JVE-side ConnectToResolveProject uses `(track_type, track_index,
    # record_start)` as the position-match key. record_start is in
    # frames; if Resolve's timeline rate disagrees with the JVE
    # sequence's rate, frames at the same numeric record_start refer to
    # different real times → false-positive matches. Surface the
    # integer TC counter so the caller asserts equality before matching.
    try:
        integer_rate = _timeline_integer_frame_rate(project)
    except RuntimeError as exc:
        return _error(envelope_id, "resolve_api_error", str(exc))

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

    return _ok(envelope_id, {
        "items": items,
        "timeline_integer_rate": integer_rate,
    })


def _validate_change_token(args, verb_name):
    # FR-008: state-changing verbs MUST carry a `change_token`
    # shaped as `{project_id, sequence_id, mutation_generation}`.
    # Enforced inside each state-changing verb so a malformed token
    # surfaces as bad_request, not as a cache-layer crash.
    ct = args.get("change_token")
    if ct is None:
        return ("error",
            f"{verb_name}: args.change_token required (FR-008)")
    if not isinstance(ct, dict):
        return ("error",
            f"{verb_name}: args.change_token must be JSON object")
    for field, expected_py_type, type_name in (
        ("project_id",          str, "string"),
        ("sequence_id",         str, "string"),
        ("mutation_generation", int, "integer"),
    ):
        val = ct.get(field)
        if not isinstance(val, expected_py_type) or (
                expected_py_type is str and val == ""):
            return ("error",
                f"{verb_name}: args.change_token.{field} required "
                f"({type_name})")
        if expected_py_type is int and isinstance(val, bool):
            return ("error",
                f"{verb_name}: args.change_token.{field} must be "
                f"integer (got bool)")
    return ("ok", ct)


# ─── Identity marker stamp (T048) ─────────────────────────────────────

# Marker properties used when stamping per helper-protocol.md
# §stamp_identity_marker. `customData` carries the JVE clip.id (the
# identity field). `color`/`name`/`note` are reserved for user use and
# NOT consulted by read_identities — values here are chosen so the
# marker is visually distinguishable in Resolve's UI from user-created
# markers.
_IDENTITY_MARKER_COLOR = "Purple"
_IDENTITY_MARKER_NAME  = "JVE clip identity"
_IDENTITY_MARKER_NOTE  = ""
_IDENTITY_MARKER_DURATION_FRAMES = 1
_IDENTITY_MARKER_FRAME = 0  # item-relative; placed at the head


def _find_timeline_item_by_uid(timeline, resolve_item_id):
    for _track_type, _tidx, item in _iter_all_timeline_items(timeline):
        try:
            uid = item.GetUniqueId()
        except Exception as exc:
            raise RuntimeError(
                f"item.GetUniqueId() raised: {exc}") from exc
        if uid == resolve_item_id:
            return item
    return None


@_stateful_verb
def verb_stamp_identity_marker(args, _resolve, project, envelope_id,
                                helper_version):
    del helper_version

    token_check = _validate_change_token(args, "stamp_identity_marker")
    if token_check[0] != "ok":
        return _error(envelope_id, "bad_request", token_check[1])

    resolve_item_id = args.get("resolve_item_id")
    custom_data     = args.get("custom_data")
    if not isinstance(resolve_item_id, str) or not resolve_item_id:
        return _error(envelope_id, "bad_request",
            "stamp_identity_marker args.resolve_item_id required "
            "(non-empty string)")
    if not isinstance(custom_data, str) or not custom_data:
        return _error(envelope_id, "bad_request",
            "stamp_identity_marker args.custom_data required "
            "(non-empty string, typically the JVE clip.id)")

    timeline, err = _require_current_timeline(project, envelope_id)
    if err is not None:
        return err

    try:
        item = _find_timeline_item_by_uid(timeline, resolve_item_id)
    except RuntimeError as exc:
        return _error(envelope_id, "resolve_api_error", str(exc))
    if item is None:
        return _error(envelope_id, "handle_stale",
            f"resolve_item_id {resolve_item_id!r} not found in current "
            "timeline (item may have been deleted in Resolve)")

    # Idempotency + conflict detection. _recover_jve_guid raises on
    # multi-marker ambiguity already (rule 2.32) — same discipline as
    # the reader (T029a).
    try:
        existing = _recover_jve_guid(item)
    except RuntimeError as exc:
        return _error(envelope_id, "resolve_api_error", str(exc))
    if existing is not None:
        if existing == custom_data:
            # Already stamped with the same id — no-op success.
            return _ok(envelope_id, {"stamped": False})
        return _error(envelope_id, "resolve_api_error",
            f"resolve_item_id {resolve_item_id!r} already carries a "
            f"different identity marker (customData={existing!r}); "
            "refuse to overwrite — resolve the ambiguity JVE-side")

    try:
        added = item.AddMarker(
            _IDENTITY_MARKER_FRAME,
            _IDENTITY_MARKER_COLOR,
            _IDENTITY_MARKER_NAME,
            _IDENTITY_MARKER_NOTE,
            _IDENTITY_MARKER_DURATION_FRAMES,
            custom_data,
        )
    except Exception as exc:
        return _error(envelope_id, "resolve_api_error",
            f"item.AddMarker raised: {exc}")
    if not added:
        return _error(envelope_id, "resolve_api_error",
            "item.AddMarker returned False (Resolve refused the "
            "stamp — possibly a frame collision with an existing "
            "marker at the same position)")

    return _ok(envelope_id, {"stamped": True})


# ─── Timeline delete (T025b test cleanup; FR-024 follow-on) ──────────
#
# State-changing. Exposed PRIMARILY for the SendToResolve end-to-end
# live test (T025b), which needs to delete the timeline it just
# imported so consecutive runs don't accumulate fixture timelines in
# the colorist's project. There is intentionally no JVE-side command
# for this verb — production callers should never see it. Misuse
# protection lives in the same place as every other state-changing
# verb: change_token, idempotency ledger, the user's awareness that
# the helper sits beside Resolve and edits its state.
@_stateful_verb
def verb_delete_timeline(args, _resolve, project, envelope_id,
                          helper_version):
    del helper_version

    token_check = _validate_change_token(args, "delete_timeline")
    if token_check[0] != "ok":
        return _error(envelope_id, "bad_request", token_check[1])

    resolve_timeline_id = args.get("resolve_timeline_id")
    if not isinstance(resolve_timeline_id, str) or not resolve_timeline_id:
        return _error(envelope_id, "bad_request",
            "delete_timeline args.resolve_timeline_id required "
            "(non-empty string — the live Resolve timeline UID from "
            "Timeline.GetUniqueId)")

    extras = sorted(k for k in args.keys()
        if k not in ("resolve_timeline_id", "change_token"))
    if extras:
        return _error(envelope_id, "bad_request",
            f"delete_timeline: unknown args fields: {extras}")

    # Walk the project's timelines to find the one whose GetUniqueId
    # matches. Resolve provides no GetTimelineById; iterate.
    try:
        count = project.GetTimelineCount()
    except Exception as exc:
        return _error(envelope_id, "resolve_api_error",
            f"GetTimelineCount raised: {exc}")
    if not isinstance(count, int) or count < 0:
        return _error(envelope_id, "resolve_api_error",
            f"GetTimelineCount returned non-int / negative: {count!r}")

    target = None
    for i in range(1, count + 1):
        try:
            tl = project.GetTimelineByIndex(i)
        except Exception as exc:
            return _error(envelope_id, "resolve_api_error",
                f"GetTimelineByIndex({i}) raised: {exc}")
        if tl is None:
            continue
        try:
            uid = tl.GetUniqueId()
        except Exception as exc:
            return _error(envelope_id, "resolve_api_error",
                f"timeline[{i}].GetUniqueId raised: {exc}")
        if uid == resolve_timeline_id:
            target = tl
            break

    if target is None:
        # Idempotent: a re-sent delete after the timeline is already
        # gone returns deleted=False rather than handle_stale, so the
        # caller's teardown doesn't fail on a clean second run.
        return _ok(envelope_id, {"deleted": False})

    try:
        ok = project.DeleteTimelines([target])
    except Exception as exc:
        return _error(envelope_id, "resolve_api_error",
            f"DeleteTimelines raised: {exc}")
    if not isinstance(ok, bool):
        return _error(envelope_id, "resolve_api_error",
            f"DeleteTimelines returned non-bool: {ok!r}")
    if not ok:
        return _error(envelope_id, "resolve_api_error",
            f"DeleteTimelines({resolve_timeline_id!r}) returned False "
            "— Resolve refused")

    return _ok(envelope_id, {"deleted": True})


def _unimplemented(verb_name):
    def thunk(args, handle, envelope_id, helper_version):
        del args, handle, helper_version
        return _error(envelope_id, "not_implemented",
            f"verb '{verb_name}' not yet implemented in this helper build")
    return thunk


def _export_edl_cdl(timeline, resolve, integer_rate):
    # Resolve's `Timeline.Export(fileName, EXPORT_EDL, EXPORT_CDL)`
    # emits a CMX-3600 EDL annotated with ASC_SOP/ASC_SAT per event
    # (spec.md:30). Returns the parsed `{record_in_frame → cdl}` dict.
    # Cleans up the temp file unconditionally.
    fd, edl_path = tempfile.mkstemp(prefix="jve-read-grades-", suffix=".edl")
    os.close(fd)
    try:
        try:
            ok = timeline.Export(
                edl_path, resolve.EXPORT_EDL, resolve.EXPORT_CDL)
        except Exception as exc:
            raise RuntimeError(
                f"timeline.Export(EDL+CDL) raised: {exc}") from exc
        if not ok:
            raise RuntimeError(
                "timeline.Export(EDL+CDL) returned False — Resolve "
                "refused to write the EDL")
        try:
            with open(edl_path, "r", encoding="utf-8") as f:
                edl_text = f.read()
        except OSError as exc:
            raise RuntimeError(
                f"reading exported EDL at {edl_path!r}: {exc}") from exc
        try:
            return parse_cdl_edl(edl_text, integer_rate)
        except CdlEdlParseError as exc:
            raise RuntimeError(
                f"parsing exported EDL at {edl_path!r}: {exc}") from exc
    finally:
        try:
            os.unlink(edl_path)
        except OSError:
            # Best-effort cleanup; the leak is bounded to one temp file
            # per call. Don't mask the real error with a cleanup failure.
            pass


def _timeline_integer_frame_rate(project):
    # Project.GetSetting('timelineFrameRate') returns the fractional
    # rate as a string ("23.976", "24", "24.0", "29.97", "59.94"…).
    # Convert to the TC-counter integer rate (24 for 23.976, etc.).
    try:
        setting = project.GetSetting("timelineFrameRate")
    except Exception as exc:
        raise RuntimeError(
            f"project.GetSetting('timelineFrameRate') raised: {exc}"
            ) from exc
    try:
        return integer_frame_rate_from_setting(setting)
    except CdlEdlParseError as exc:
        raise RuntimeError(
            f"timelineFrameRate {setting!r}: {exc}") from exc


def _item_lut_ref(item):
    # TimelineItem.GetLUT() returns a local path string when an
    # item-level LUT is bound, None otherwise. Empty string is treated
    # as None (defensive — Resolve sometimes returns "" for no LUT).
    try:
        lut = item.GetLUT()
    except Exception as exc:
        raise RuntimeError(
            f"item.GetLUT() raised: {exc}") from exc
    if lut is None:
        return None
    if isinstance(lut, str):
        return lut if lut != "" else None
    raise RuntimeError(
        f"item.GetLUT() returned non-string non-None: "
        f"{type(lut).__name__} = {lut!r}")


def _any_non_cdl_tools(item):
    # Walk the item's node graph; GetToolsInNode(n) returns the list of
    # NON-primary tools attached to node n (curves, qualifier, OFX,
    # masks). An empty list per node = primary-only correction.
    try:
        graph = item.GetNodeGraph()
    except Exception as exc:
        raise RuntimeError(
            f"item.GetNodeGraph() raised: {exc}") from exc
    if graph is None:
        # Item has no color graph at all — treat as primary-only
        # (degenerate; the EDL will still carry identity CDL).
        return False
    try:
        num_nodes = graph.GetNumNodes()
    except Exception as exc:
        raise RuntimeError(
            f"graph.GetNumNodes() raised: {exc}") from exc
    if not isinstance(num_nodes, int) or num_nodes < 0:
        raise RuntimeError(
            f"graph.GetNumNodes() returned non-int / negative: "
            f"{num_nodes!r}")
    for n in range(1, num_nodes + 1):
        try:
            tools = graph.GetToolsInNode(n)
        except Exception as exc:
            raise RuntimeError(
                f"graph.GetToolsInNode({n}) raised: {exc}") from exc
        if tools is None:
            continue
        if not isinstance(tools, list):
            raise RuntimeError(
                f"graph.GetToolsInNode({n}) returned non-list: "
                f"{type(tools).__name__}")
        if tools:
            return True
    return False


def _cdl_to_wire(cdl_entry):
    # Translate the parser's `{slope:[r,g,b], offset:[r,g,b],
    # power:[r,g,b], sat:float}` to the helper-protocol.md §read_grades
    # wire shape. Same content, same field names — the contract IS the
    # parser's output shape.
    return {
        "slope":  cdl_entry["slope"],
        "offset": cdl_entry["offset"],
        "power":  cdl_entry["power"],
        "sat":    cdl_entry["sat"],
    }


@_stateful_verb
def verb_read_grades(args, resolve, project, envelope_id, helper_version):
    # spec.md:30 / helper-protocol.md §read_grades — read per-clip
    # grade state via `timeline.Export(EDL+CDL)` (CDL primaries) +
    # `GetNodeGraph().GetToolsInNode()` (fidelity). cdl_edl.py owns
    # the pure-data EDL parser; this verb owns the Resolve-API
    # plumbing + per-item classification.
    del helper_version

    validation = _validate_item_ids(args)
    if validation[0] != "ok":
        return _error(envelope_id, "bad_request", validation[1])
    item_id_filter = validation[1]  # None = all; set = whitelist

    timeline, err = _require_current_timeline(project, envelope_id)
    if err is not None:
        return err

    try:
        integer_rate = _timeline_integer_frame_rate(project)
    except RuntimeError as exc:
        return _error(envelope_id, "resolve_api_error", str(exc))

    try:
        cdl_by_rec_in = _export_edl_cdl(timeline, resolve, integer_rate)
    except RuntimeError as exc:
        return _error(envelope_id, "resolve_api_error", str(exc))

    grades = []
    try:
        for track_type, _tidx, item in _iter_all_timeline_items(timeline):
            # V1 video-only scope (mirrors verb_read_timeline). The EDL
            # carries only video CDL events; an audio item sharing a
            # record_start with a video item would otherwise look up the
            # video clip's CDL and surface it as the audio clip's grade.
            # Per helper-protocol.md §read_grades, audio fidelity is V1-
            # deferred along with audio-channel read_timeline.
            if track_type != "video":
                continue
            resolve_item_id = _safe_uid(item)
            if (item_id_filter is not None
                    and resolve_item_id not in item_id_filter):
                continue
            jve_guid = _recover_jve_guid(item)
            if jve_guid is None:
                # No identity carrier — caller can't map the grade back
                # to a JVE clip. Omit from `grades` (mirrors
                # read_identities' "lacking join key" discipline).
                continue
            try:
                record_start = item.GetStart()
            except Exception as exc:
                return _error(envelope_id, "resolve_api_error",
                    f"item.GetStart() raised: {exc}")
            if not isinstance(record_start, int):
                return _error(envelope_id, "resolve_api_error",
                    f"item.GetStart() non-int: {record_start!r}")
            cdl_entry = cdl_by_rec_in.get(record_start)
            if cdl_entry is None:
                return _error(envelope_id, "resolve_api_error",
                    f"item jve_guid={jve_guid!r} at record_start frame "
                    f"{record_start} has no CDL block in the EDL "
                    "export — Resolve emits CDL for every clip, so a "
                    "missing block is an API anomaly")
            try:
                item_lut = _item_lut_ref(item)
                any_tools = _any_non_cdl_tools(item)
            except RuntimeError as exc:
                return _error(envelope_id, "resolve_api_error", str(exc))
            try:
                fidelity = classify_fidelity(
                    any_non_cdl_tools=any_tools,
                    item_lut_ref=item_lut,
                    cdl_present=True)
            except CdlEdlParseError as exc:
                return _error(envelope_id, "resolve_api_error", str(exc))
            row = {"jve_guid": jve_guid, "fidelity": fidelity}
            if fidelity == "primary":
                row["cdl"] = _cdl_to_wire(cdl_entry)
            if item_lut is not None:
                row["lut"] = {"ref": item_lut}
            grades.append(row)
    except RuntimeError as exc:
        return _error(envelope_id, "resolve_api_error", str(exc))

    return _ok(envelope_id, {"grades": grades})


VERB_TABLE = {
    "ping": verb_ping,
    "import_timeline": verb_import_timeline,
    "read_identities": verb_read_identities,
    "read_timeline":   verb_read_timeline,
    "read_grades":     verb_read_grades,
    "stamp_identity_marker": verb_stamp_identity_marker,
    "delete_timeline": verb_delete_timeline,
}


def dispatch(verb, args, handle, envelope_id, helper_version):
    fn = VERB_TABLE.get(verb)
    if fn is None:
        return _error(envelope_id, "bad_request",
            f"unknown verb '{verb}'")
    return fn(args, handle, envelope_id, helper_version)
