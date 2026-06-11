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
import sys
import tempfile

from cdl_edl import (
    CdlEdlParseError,
    classify_fidelity,
    any_beyond_primary_tools,
    is_identity_cdl,
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


def _api(label, fn, *args, **kwargs):
    """Call a Resolve scripting-API method, re-raising any exception as a
    RuntimeError tagged with `label` so the dispatch wrapper surfaces a
    structured `resolve_api_error` with a useful breadcrumb.

    Lifted from 25+ hand-rolled `try: X(); except Exception as exc:
    raise RuntimeError(f"X raised: {exc}")` blocks. The Resolve API has
    no typed exception hierarchy — any internal failure surfaces as a
    bare Exception — so the helper-side contract is "every API call
    must be wrapped, labeled, and re-raised through this seam." Single
    source of truth keeps the label format consistent and removes the
    visual noise of a 4-line try/except around every one-line call.

    Multi-call try blocks that share one handler are NOT a fit for this
    helper — leave them as plain try/except where the group label makes
    sense.
    """
    try:
        return fn(*args, **kwargs)
    except Exception as exc:
        raise RuntimeError(f"{label} raised: {exc}") from exc


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
    # Non-fatal: ping returns alive=True + connected=False on ANY
    # non-ok acquire result so JVE can gate UI without false "helper
    # dead" alarms when Resolve is just not running. version_string()
    # raises in the same conditions acquire() failed for (terminal
    # state / scriptapp returns None) — calling it here would crash
    # the dispatch handler (post-pass5 re-raises). Send None instead;
    # last_error already conveys why the connection is down.
    # Prior shape whitelisted ("handle_stale", "resolve_api_error",
    # "not_studio") — adding a new acquire code (license_expired,
    # project_locked, ...) without updating that set would fall through
    # to _error and crash the dispatcher. Treat every non-ok status as
    # ping-non-fatal.
    _, code, msg = status
    return _ok(envelope_id, {
        "alive": True,
        "resolve_connected": False,
        "resolve_version": None,
        "helper_version": helper_version,
        "last_error": {"code": code, "message": msg},
    })


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
    n = _api("GetTimelineCount", project.GetTimelineCount)
    for i in range(1, n + 1):
        tl = _api(f"GetTimelineByIndex({i})", project.GetTimelineByIndex, i)
        if tl is None:
            continue
        tl_id = _api("timeline.GetUniqueId", tl.GetUniqueId)
        if tl_id not in prev_timeline_ids:
            return tl
    return None


def _find_timeline_by_uid(project, uid):
    # Resolve provides no GetTimelineById; iterate (1-indexed).
    count = _api("GetTimelineCount", project.GetTimelineCount)
    for i in range(1, count + 1):
        tl = _api(f"GetTimelineByIndex({i})", project.GetTimelineByIndex, i)
        if tl is None:
            continue
        if _api(f"timeline[{i}].GetUniqueId", tl.GetUniqueId) == uid:
            return tl
    return None


def _snapshot_timeline_ids(project):
    n = _api("GetTimelineCount", project.GetTimelineCount)
    ids = set()
    for i in range(1, n + 1):
        tl = _api(f"GetTimelineByIndex({i})", project.GetTimelineByIndex, i)
        if tl is None:
            continue
        ids.add(_api(f"timeline[{i}].GetUniqueId", tl.GetUniqueId))
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
    media_paths = args.get("media_paths")
    if not isinstance(drt_path, str) or not drt_path:
        return _error(envelope_id, "bad_request", "drt_path missing")
    if not isinstance(media_paths, list) or not all(
            isinstance(p, str) and p for p in media_paths):
        return _error(envelope_id, "bad_request",
            "media_paths must be list[non-empty string]")
    if not os.path.exists(drt_path):
        return _error(envelope_id, "bad_request",
            f"drt_path does not exist: {drt_path}")
    positions_check = _validate_clip_positions(args.get("clip_positions"))
    if positions_check[0] != "ok":
        return _error(envelope_id, "bad_request", positions_check[1])
    clip_positions = positions_check[1]

    # Pre-import is what makes Resolve link the DRT's items to real pool
    # clips with byte-correct source ranges; materializing pool items
    # from the DRT's embedded XML instead yields degenerate item ranges
    # (live-bisected 2026-06-10, VM Resolve 20.3). A missing media file
    # can therefore never produce a faithful timeline — reject before
    # any Resolve mutation.
    missing_media = [p for p in media_paths if not os.path.exists(p)]
    if missing_media:
        return _error(envelope_id, "bad_request",
            f"media_paths do not exist: {missing_media}")

    try:
        prev_ids = _snapshot_timeline_ids(project)
    except RuntimeError as exc:
        return _error(envelope_id, "resolve_api_error", str(exc))

    media_pool = project.GetMediaPool()
    if media_pool is None:
        return _error(envelope_id, "resolve_api_error",
            "GetMediaPool() returned None")

    # ImportMedia is idempotent on an already-present path (live-probed
    # 2026-06-10: re-import returns the existing pool item, no duplicate).
    for path in media_paths:
        try:
            got = media_pool.ImportMedia([path])
        except Exception as exc:
            return _error(envelope_id, "resolve_api_error",
                f"ImportMedia({path!r}) raised: {exc}")
        if not got:
            return _error(envelope_id, "relink_failed",
                f"ImportMedia({path!r}) returned falsy — Resolve could "
                f"not import the media this DRT references")

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

    try:
        timeline_uid = _api("timeline.GetUniqueId", timeline.GetUniqueId)
    except RuntimeError as exc:
        return _error(envelope_id, "resolve_api_error", str(exc))

    return _ok(envelope_id, {
        "resolve_timeline_id":   timeline_uid,
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
    uid = _api("item.GetUniqueId()", item.GetUniqueId)
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
        n_tracks = _api(f"GetTrackCount({track_type!r})",
            timeline.GetTrackCount, track_type)
        for tidx in range(1, n_tracks + 1):
            items = _api(
                f"GetItemListInTrack({track_type!r}, {tidx})",
                timeline.GetItemListInTrack, track_type, tidx) or []
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
    markers = item.GetMarkers()
    if markers is None:
         # Resolve API returns None if the item is invalid or an internal
         # error occurred. Don't fallback to {} (Rule 2.13).
         raise RuntimeError("item.GetMarkers() returned None")
    if not isinstance(markers, dict):
        # API drift — a future Resolve returning a list/string here would
        # silently look like "no markers found" if we returned None.
        # Raise so a real shape change surfaces as resolve_api_error
        # instead of poisoning the id-anchored read path with empty results.
        raise RuntimeError(
            f"item.GetMarkers() returned non-dict: "
            f"{type(markers).__name__} = {markers!r}")
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
        name            = item.GetName()
        mp_item         = item.GetMediaPoolItem()
        media_file_path = mp_item.GetClipProperty("File Path") if mp_item else ""
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
            "name":            name,
            "media_file_path": media_file_path,
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
        integer_rate = _timeline_integer_frame_rate(timeline)
    except RuntimeError as exc:
        return _error(envelope_id, "resolve_api_error", str(exc))

    items = []
    audio_items_skipped = 0
    try:
        for track_type, tidx, item in _iter_all_timeline_items(timeline):
            # V1 scope: video items only. Audio support lands with T054
            # (subframe-aware {frame, subframe} extraction, sample-rate
            # mismatch handling on the JVE side). Surface skip count
            # so the caller knows why total != video_count (review #9).
            if track_type != "video":
                audio_items_skipped += 1
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
        "audio_items_skipped": audio_items_skipped,
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
        if _api("item.GetUniqueId()", item.GetUniqueId) == resolve_item_id:
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


# ─── Test-only grade application (T034/T033 live fixtures) ───────────
#
# State-changing. Exposed ONLY so the fidelity-downgrade (T034) and
# pixel-compare (T033) live tests can put a KNOWN grade on a fixture
# timeline item — the operator-equivalent of grading the clip in
# Resolve's UI. Same test-only posture as delete_timeline: no JVE-side
# command exists; misuse protection is change_token + the idempotency
# ledger. The verb maps one-to-one onto Resolve's documented item APIs:
# SetCDL (primary corrector values) and SetLUT (node LUT carrier).

_CDL_TRIPLE_KEYS = ("slope", "offset", "power")


def _validate_apply_test_grade_args(args):
    # Pure-data validator (offline-testable). Returns ("ok", payload)
    # or ("error", message). change_token is owned by
    # _validate_change_token at the verb boundary, not here.
    resolve_item_id = args.get("resolve_item_id")
    if not isinstance(resolve_item_id, str) or not resolve_item_id:
        return ("error", "apply_test_grade args.resolve_item_id "
            "required (non-empty string)")

    extras = sorted(k for k in args.keys() if k not in
        ("resolve_item_id", "cdl", "lut_path", "change_token"))
    if extras:
        return ("error",
            f"apply_test_grade: unknown args fields: {extras}")

    cdl = args.get("cdl")
    lut_path = args.get("lut_path")
    if cdl is None and lut_path is None:
        return ("error", "apply_test_grade: at least one of args.cdl "
            "/ args.lut_path required")

    if cdl is not None:
        if not isinstance(cdl, dict):
            return ("error", "apply_test_grade args.cdl must be a map")
        cdl_extras = sorted(k for k in cdl.keys()
            if k not in _CDL_TRIPLE_KEYS + ("sat",))
        if cdl_extras:
            return ("error",
                f"apply_test_grade cdl: unknown keys: {cdl_extras}")
        for key in _CDL_TRIPLE_KEYS:
            triple = cdl.get(key)
            if (not isinstance(triple, list) or len(triple) != 3
                    or not all(isinstance(v, (int, float))
                               and not isinstance(v, bool)
                               for v in triple)):
                return ("error", f"apply_test_grade cdl.{key} must be "
                    "[r, g, b] numbers")
        sat = cdl.get("sat")
        if not isinstance(sat, (int, float)) or isinstance(sat, bool):
            return ("error", "apply_test_grade cdl.sat must be a number")

    if lut_path is not None:
        if not isinstance(lut_path, str) or not lut_path:
            return ("error", "apply_test_grade args.lut_path must be a "
                "non-empty string")
        if not lut_path.startswith("/"):
            return ("error", "apply_test_grade args.lut_path must be "
                "an absolute path")

    return ("ok", {"resolve_item_id": resolve_item_id,
                   "cdl": cdl, "lut_path": lut_path})


def _cdl_triple_str(triple):
    return " ".join(repr(float(v)) for v in triple)


@_stateful_verb
def verb_apply_test_grade(args, _resolve, project, envelope_id,
                           helper_version):
    del helper_version

    token_check = _validate_change_token(args, "apply_test_grade")
    if token_check[0] != "ok":
        return _error(envelope_id, "bad_request", token_check[1])
    args_check = _validate_apply_test_grade_args(args)
    if args_check[0] != "ok":
        return _error(envelope_id, "bad_request", args_check[1])
    payload = args_check[1]

    timeline, err = _require_current_timeline(project, envelope_id)
    if err is not None:
        return err

    try:
        item = _find_timeline_item_by_uid(
            timeline, payload["resolve_item_id"])
    except RuntimeError as exc:
        return _error(envelope_id, "resolve_api_error", str(exc))
    if item is None:
        return _error(envelope_id, "handle_stale",
            f"resolve_item_id {payload['resolve_item_id']!r} not found "
            "in current timeline")

    if payload["cdl"] is not None:
        cdl = payload["cdl"]
        cdl_map = {
            "NodeIndex":  "1",
            "Slope":      _cdl_triple_str(cdl["slope"]),
            "Offset":     _cdl_triple_str(cdl["offset"]),
            "Power":      _cdl_triple_str(cdl["power"]),
            "Saturation": repr(float(cdl["sat"])),
        }
        try:
            ok = item.SetCDL(cdl_map)
        except Exception as exc:
            return _error(envelope_id, "resolve_api_error",
                f"SetCDL raised: {exc}")
        if not ok:
            return _error(envelope_id, "resolve_api_error",
                "SetCDL returned False — Resolve refused the CDL")

    if payload["lut_path"] is not None:
        try:
            ok = item.SetLUT(1, payload["lut_path"])
        except Exception as exc:
            return _error(envelope_id, "resolve_api_error",
                f"SetLUT raised: {exc}")
        if not ok:
            return _error(envelope_id, "resolve_api_error",
                f"SetLUT(1, {payload['lut_path']!r}) returned False — "
                "Resolve refused the LUT (bad path or unsupported "
                "format)")

    return _ok(envelope_id, {"applied": True})


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
        target = _find_timeline_by_uid(project, resolve_timeline_id)
    except RuntimeError as exc:
        return _error(envelope_id, "resolve_api_error", str(exc))

    if target is None:
        # Idempotent: a re-sent delete after the timeline is already
        # gone returns deleted=False rather than handle_stale, so the
        # caller's teardown doesn't fail on a clean second run.
        return _ok(envelope_id, {"deleted": False})

    # DeleteTimelines lives on MediaPool, not Project (Resolve scripting
    # API; calling the nonexistent Project attribute raised
    # "'NoneType' object is not callable" against live 20.3 — caught by
    # the T026 live teardown 2026-06-09).
    media_pool = project.GetMediaPool()
    if media_pool is None:
        return _error(envelope_id, "resolve_api_error",
            "GetMediaPool() returned None")
    try:
        ok = media_pool.DeleteTimelines([target])
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
        ok = _api("timeline.Export(EDL+CDL)", timeline.Export,
            edl_path, resolve.EXPORT_EDL, resolve.EXPORT_CDL)
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


def _timeline_integer_frame_rate(timeline):
    # Timeline.GetSetting('timelineFrameRate') returns the fractional
    # rate as a string ("23.976", "24", "24.0", "29.97", "59.94"…).
    # Convert to the TC-counter integer rate (24 for 23.976, etc.).
    #
    # MUST query the timeline, not the project: a Resolve project can
    # hold timelines at mixed rates and the user-visible truth in the
    # Timeline > Settings dialog is the timeline-level value. Querying
    # project.GetSetting returned the project default and produced
    # spurious `timeline_rate_mismatch` errors when the active timeline
    # differed from the project default (anamnesis-gold-timeline,
    # 2026-06-03: timeline 25, project 24).
    setting = _api("timeline.GetSetting('timelineFrameRate')",
        timeline.GetSetting, "timelineFrameRate")
    try:
        return integer_frame_rate_from_setting(setting)
    except CdlEdlParseError as exc:
        raise RuntimeError(
            f"timelineFrameRate {setting!r}: {exc}") from exc


def _inspect_node_graph(item):
    # One walk of the item's node graph feeding both fidelity inputs:
    #   per_node_tools — GetToolsInNode(n) per node, handed verbatim to
    #     cdl_edl.any_beyond_primary_tools (which owns the
    #     primary-vs-beyond partition; live-probed 2026-06-10: Resolve
    #     names ALL corrector activity, incl. bare primaries — the old
    #     "empty list == primary-only" model classified every graded
    #     clip unrepresentable).
    #   lut_ref — first non-empty GetLUT(n) across nodes (the README
    #     contract takes a 1-based nodeIndex; the previous argless
    #     item.GetLUT() call was off-contract and only saw node 1 at
    #     best). Empty string = no LUT on that node.
    # Returns (per_node_tools, lut_ref_or_None).
    graph = _api("item.GetNodeGraph()", item.GetNodeGraph)
    if graph is None:
        # Item has no color graph at all — degenerate ungraded shape.
        return [], None
    num_nodes = _api("graph.GetNumNodes()", graph.GetNumNodes)
    if not isinstance(num_nodes, int) or num_nodes < 0:
        raise RuntimeError(
            f"graph.GetNumNodes() returned non-int / negative: "
            f"{num_nodes!r}")
    per_node_tools = []
    lut_ref = None
    for n in range(1, num_nodes + 1):
        per_node_tools.append(
            _api(f"graph.GetToolsInNode({n})", graph.GetToolsInNode, n))
        lut = _api(f"item.GetLUT({n})", item.GetLUT, n)
        if lut is None or lut == "":
            continue
        if not isinstance(lut, str):
            raise RuntimeError(
                f"item.GetLUT({n}) returned non-string non-None: "
                f"{type(lut).__name__} = {lut!r}")
        if lut_ref is None:
            lut_ref = lut
    return per_node_tools, lut_ref


def _bake_item_lut(item, resolve_item_id, bake_lut_dir, resolve):
    # Resolve's TimelineItem.ExportLUT bakes the full node-graph result
    # (primaries + curves + CST/ACES + Gamut Mapping). Qualifiers,
    # windows, blurs and other neighborhood operations are silently
    # dropped by the bake (Resolve documented behavior, V1-accepted
    # fidelity limit). Returns the absolute path on success, or None
    # on failure (per-clip skip — bake failure does not abort the
    # whole sync; see verb_read_grades docstring).
    #
    # 33pt CUBE is the industry default carrier (Premiere/FCP/Nuke
    # expect it). 17pt is too coarse for shadows; 65pt is overkill.
    try:
        cube_kind = resolve.EXPORT_LUT_33PTCUBE
    except AttributeError as exc:
        sys.stderr.write(
            f"[read_grades] resolve.EXPORT_LUT_33PTCUBE unavailable: "
            f"{exc}\n")
        return None
    out_path = os.path.join(bake_lut_dir, f"{resolve_item_id}.cube")
    try:
        ok = item.ExportLUT(cube_kind, out_path)
    except Exception as exc:
        sys.stderr.write(
            f"[read_grades] ExportLUT raised for "
            f"resolve_item_id={resolve_item_id!r}: {exc}\n")
        return None
    if not ok:
        sys.stderr.write(
            f"[read_grades] ExportLUT returned falsy for "
            f"resolve_item_id={resolve_item_id!r} → {out_path!r}\n")
        return None
    if not os.path.isfile(out_path):
        sys.stderr.write(
            f"[read_grades] ExportLUT claimed success but file absent: "
            f"{out_path!r}\n")
        return None
    return out_path


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


def _validate_read_grades_args(args):
    # read_grades extends `_validate_item_ids` with the optional
    # bake_lut_dir arg (absolute path JVE supplies; helper writes
    # `<dir>/<resolve_item_id>.cube` per non-CDL-graded clip). FR-021
    # — JVE owns path discipline; the helper just writes where told.
    allowed = {"item_ids", "bake_lut_dir"}
    extras = sorted(k for k in args.keys() if k not in allowed)
    if extras:
        return ("error", f"unknown args fields: {extras}")
    item_ids = args.get("item_ids")
    if item_ids is not None:
        if not isinstance(item_ids, list):
            return ("error",
                "item_ids must be a list of strings (got "
                f"{type(item_ids).__name__})")
        for i, x in enumerate(item_ids):
            if not isinstance(x, str) or x == "":
                return ("error",
                    f"item_ids[{i}] must be non-empty string (got "
                    f"{type(x).__name__})")
        item_ids = set(item_ids)
    bake_lut_dir = args.get("bake_lut_dir")
    if bake_lut_dir is not None:
        if not isinstance(bake_lut_dir, str) or bake_lut_dir == "":
            return ("error",
                f"bake_lut_dir must be non-empty string when present "
                f"(got {type(bake_lut_dir).__name__})")
        if not os.path.isabs(bake_lut_dir):
            return ("error",
                f"bake_lut_dir must be absolute path (got {bake_lut_dir!r})")
    return ("ok", {"item_ids": item_ids, "bake_lut_dir": bake_lut_dir})


@_stateful_verb
def verb_read_grades(args, resolve, project, envelope_id, helper_version):
    # spec.md:30 / helper-protocol.md §read_grades — read per-clip
    # grade state via `timeline.Export(EDL+CDL)` (CDL primaries) +
    # `GetNodeGraph().GetToolsInNode()` (fidelity). cdl_edl.py owns
    # the pure-data EDL parser; this verb owns the Resolve-API
    # plumbing + per-item classification.
    #
    # bake_lut_dir (optional): when set, partial/unrepresentable clips
    # are baked via `item.ExportLUT(EXPORT_LUT_33PTCUBE, …)` into
    # `<dir>/<resolve_item_id>.cube` and emitted with lut.ref set to
    # that path. Resolve's bake captures primaries + curves + CST/ACES
    # gamut nodes; qualifiers / windows / blurs are silently dropped
    # (V1 fidelity limit, Joe-accepted). Bake failures are logged and
    # the clip falls back to its no-LUT classification — never fails
    # the whole sync (rule 1.14 with proportional scope).
    del helper_version

    validation = _validate_read_grades_args(args)
    if validation[0] != "ok":
        return _error(envelope_id, "bad_request", validation[1])
    item_id_filter = validation[1]["item_ids"]
    bake_lut_dir = validation[1]["bake_lut_dir"]
    if bake_lut_dir is not None:
        try:
            os.makedirs(bake_lut_dir, exist_ok=True)
        except OSError as exc:
            return _error(envelope_id, "bad_request",
                f"bake_lut_dir {bake_lut_dir!r} not creatable: {exc}")

    # In-band anomaly channel (helper-protocol.md §read_grades
    # `warnings`): bake/page anomalies that don't fail the sync but
    # leave user-visible damage (clips without a grade carrier, Resolve
    # stuck on the Color page) MUST reach the JVE client, which logs
    # them at warn — default-visible. stderr alone proved invisible in
    # the 2026-06-10 incident (supervisor relays stderr at event level,
    # off by default). The list object is shared with the response so
    # the page-restore finally below can append after _ok() is built.
    warnings = []

    # ExportLUT requires the Color page to be the active Resolve page —
    # empirically confirmed by t033_probe_export_lut.py (without
    # OpenPage("color") every call returns False; with it, items with
    # real node graphs bake successfully). The API doesn't document
    # this prerequisite. We switch only when a bake is actually
    # requested, and restore the user's prior page afterwards so the
    # observed Resolve state is unchanged when read_grades returns.
    prior_page = None
    if bake_lut_dir is not None:
        # Capture prior page BEFORE switching to Color so the finally
        # block can restore it. If GetCurrentPage raises, refuse to
        # switch — otherwise the finally would have no prior to restore
        # (prior_page stays None, guard `prior_page is not None` skips
        # OpenPage(prior_page), Resolve stays stuck on Color despite the
        # contract promising the user's page is observably unchanged).
        try:
            prior_page = resolve.GetCurrentPage()
        except Exception as exc:
            return _error(envelope_id, "resolve_api_error",
                f"GetCurrentPage failed; refusing to switch to Color "
                f"because we cannot restore the user's page: {exc}")
        if prior_page == "color":
            # Resolve sitting on the Color page when a sync begins is
            # the signature of an earlier sync killed mid-bake (the
            # page-restore finally never ran — observed 2026-06-10).
            # The restore below is skipped by design (nothing to
            # restore TO); say so instead of silently normalizing it.
            warnings.append(
                "Resolve was already on the Color page when the sync "
                "began — the prior-page restore is skipped (possibly "
                "left there by an earlier interrupted sync)")
        try:
            resolve.OpenPage("color")
        except Exception as exc:
            sys.stderr.write(
                f"[read_grades] resolve.OpenPage('color') raised: "
                f"{exc} — bakes will likely fail\n")

    # Single try/finally from this point forward so EVERY early return
    # below the OpenPage("color") switch goes through the page-restore
    # finally. Prior shape had three pre-loop returns (require_timeline,
    # timeline_integer_frame_rate, export_edl_cdl) outside the try —
    # any of those failing left Resolve stuck on Color even though the
    # contract promised to restore the user's prior page.
    grades = []
    bake_attempts = 0
    bake_failures = 0
    page_probed_after_failure = False
    try:
        timeline, err = _require_current_timeline(project, envelope_id)
        if err is not None:
            return err

        try:
            integer_rate = _timeline_integer_frame_rate(timeline)
        except RuntimeError as exc:
            return _error(envelope_id, "resolve_api_error", str(exc))

        try:
            cdl_by_rec_in = _export_edl_cdl(timeline, resolve, integer_rate)
        except RuntimeError as exc:
            return _error(envelope_id, "resolve_api_error", str(exc))

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
            # FR-021: helper holds no JVE state. We emit our native
            # `resolve_item_id` (= TimelineItem:GetUniqueId()); the
            # Lua side joins to JVE clip.id via identity_ledger. No
            # marker recovery here — marker-as-join was the pre-fix
            # design, broken because it required a stamping pre-pass
            # before the first sync (helper-protocol.md §read_grades).
            try:
                record_start = item.GetStart()
            except Exception as exc:
                return _error(envelope_id, "resolve_api_error",
                    f"item.GetStart() raised: {exc}")
            if not isinstance(record_start, int):
                return _error(envelope_id, "resolve_api_error",
                    f"item.GetStart() non-int: {record_start!r}")
            # cdl_entry may be None — ungraded clips and LUT-only /
            # non-CDL-only graphs produce no ASC_SOP/ASC_SAT in the
            # EDL+CDL export. classify_fidelity handles the
            # cdl_present=False branch and returns one of
            # {"none", "partial", "unrepresentable"} accordingly
            # (helper-protocol.md §read_grades, spec.md FR-015).
            cdl_entry = cdl_by_rec_in.get(record_start)
            # Identity block ≡ no CDL grade (Resolve emits identity
            # SOP/SAT for ungraded clips on some timelines, omits the
            # block on others — see cdl_edl.is_identity_cdl).
            if cdl_entry is not None and is_identity_cdl(cdl_entry):
                cdl_entry = None
            try:
                per_node_tools, item_lut = _inspect_node_graph(item)
            except RuntimeError as exc:
                return _error(envelope_id, "resolve_api_error", str(exc))
            try:
                fidelity = classify_fidelity(
                    any_non_cdl_tools=any_beyond_primary_tools(
                        per_node_tools),
                    item_lut_ref=item_lut,
                    cdl_present=(cdl_entry is not None))
            except CdlEdlParseError as exc:
                return _error(envelope_id, "resolve_api_error", str(exc))
            row = {"resolve_item_id": resolve_item_id, "fidelity": fidelity}
            if fidelity == "primary":
                row["cdl"] = _cdl_to_wire(cdl_entry)
            # LUT reference precedence (when populated):
            #   1. Successful bake (overrides user item_lut — bake captures
            #      user LUT + grade together, so it's strictly more
            #      complete).
            #   2. User-applied item-level LUT from Resolve.
            # Bake gate: only fidelity in {partial, unrepresentable}.
            # Primaries already carry full grade via CDL; ungraded
            # ("none") has nothing to bake.
            baked_path = None
            if (bake_lut_dir is not None
                    and fidelity in ("partial", "unrepresentable")):
                bake_attempts += 1
                baked_path = _bake_item_lut(
                    item, resolve_item_id, bake_lut_dir, resolve)
                if baked_path is None:
                    bake_failures += 1
                    if not page_probed_after_failure:
                        # One-shot diagnosis of the dominant failure
                        # mode: the user (or anything else) switched
                        # Resolve off the Color page mid-bake, which
                        # makes this and every later ExportLUT fail
                        # (observed 2026-06-10: ~620 clips silently
                        # lost their grade carrier). Probe once, not
                        # per failure — one warning, not hundreds.
                        page_probed_after_failure = True
                        try:
                            now_page = resolve.GetCurrentPage()
                        except Exception as exc:
                            warnings.append(
                                "LUT bake failed and the page probe "
                                f"also raised: {exc}")
                        else:
                            if now_page != "color":
                                warnings.append(
                                    "Resolve left the Color page "
                                    f"mid-bake (now on {now_page!r}) — "
                                    "subsequent bakes will fail; "
                                    "re-run SyncGradesFromResolve")
            if baked_path is not None:
                row["lut"] = {"ref": baked_path}
            elif item_lut is not None:
                row["lut"] = {"ref": item_lut}
            grades.append(row)
        if bake_failures > 0:
            warnings.append(
                f"{bake_failures} of {bake_attempts} LUT bake(s) "
                "failed — affected clips carry no displayable grade "
                "in JVE (shown ungraded)")
        # `warnings` is the same list object the finally below appends
        # to — restore anomalies land in the already-built response.
        response = _ok(envelope_id,
            {"grades": grades, "warnings": warnings})
    except RuntimeError as exc:
        response = _error(envelope_id, "resolve_api_error", str(exc))
    finally:
        # Restore the user's Resolve page if we switched it. Done in
        # finally so success, RuntimeError, and any future early-return
        # all leave Resolve in the page the user invoked us from.
        # Verified afterwards: a restore that raises OR silently
        # doesn't take leaves the user stranded on the Color page —
        # exactly the 2026-06-10 incident — so both shapes append to
        # `warnings` (visible in the ok-response; error responses are
        # already loud).
        if bake_lut_dir is not None and prior_page is not None \
                and prior_page != "color":
            try:
                resolve.OpenPage(prior_page)
                now_page = resolve.GetCurrentPage()
            except Exception as exc:
                sys.stderr.write(
                    f"[read_grades] OpenPage({prior_page!r}) restore "
                    f"raised: {exc}\n")
                warnings.append(
                    f"page restore to {prior_page!r} raised: {exc} — "
                    "Resolve is likely still on the Color page")
            else:
                if now_page != prior_page:
                    warnings.append(
                        f"page restore to {prior_page!r} did not take "
                        f"(Resolve reports {now_page!r})")

    return response


VERB_TABLE = {
    "ping": verb_ping,
    "import_timeline": verb_import_timeline,
    "read_identities": verb_read_identities,
    "read_timeline":   verb_read_timeline,
    "read_grades":     verb_read_grades,
    "stamp_identity_marker": verb_stamp_identity_marker,
    "apply_test_grade": verb_apply_test_grade,
    "delete_timeline": verb_delete_timeline,
}


def dispatch(verb, args, handle, envelope_id, helper_version):
    fn = VERB_TABLE.get(verb)
    if fn is None:
        return _error(envelope_id, "bad_request",
            f"unknown verb '{verb}'")
    return fn(args, handle, envelope_id, helper_version)
