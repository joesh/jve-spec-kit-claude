# Parser for Resolve EXPORT_EDL+EXPORT_CDL output (spec 023 T029b,
# helper-protocol.md §read_grades, spec.md:30).
#
# Resolve's per-item ASC CDL annotation is emitted as part of a CMX-3600
# style EDL when `timeline.Export(path, EXPORT_EDL, EXPORT_CDL)` runs.
# Verified live emission (2026-06-02, host probe):
#
#     TITLE: /tmp/.../*.edl
#     FCM: NON-DROP FRAME
#
#     001  AX       V     C        00:00:00:00 00:00:04:12 01:00:00:00 01:00:04:12
#     *ASC_SOP (1.000000 1.000000 1.000000)(0.000000 0.000000 0.000000)(1.000000 1.000000 1.000000)
#     *ASC_SAT 1.000000
#
# Resolve emits a CDL block for every clip (identity values for
# ungraded clips), so a missing block on a known timeline item is a
# Resolve-state anomaly, NOT the normal ungraded case — handled as
# resolve_api_error upstream (rule 2.32).
#
# This module is pure-data: no Resolve API, no I/O. Offline tests live
# in `tools/resolve-helper/test_cdl_edl.py`.

import re


class CdlEdlParseError(ValueError):
    pass


# CMX-3600 event header (line starts with the event number):
#   NNN  REEL VV    T        SRC_IN SRC_OUT REC_IN REC_OUT  [transition param]
# `VV` is one or two chars (V/A/B/V1/A1/AA), `T` is the transition type
# (C/D/W/K). Some transitions inject an extra numeric parameter between
# the type and the TC fields; the optional non-capturing group catches it.
_EVENT_HEADER = re.compile(
    r"^\s*(\d+)\s+"                       # 1 event number
    r"\S+\s+"                              # reel name
    r"\S+\s+"                              # channels (V/A/AA/V1/etc.)
    r"[CDWK](?:\d+)?\s+"                   # transition type + optional length
    r"(?:\S+\s+)?"                         # optional transition parameter
    r"(\S+)\s+(\S+)\s+(\S+)\s+(\S+)"       # 2 src_in 3 src_out 4 rec_in 5 rec_out
    r"\s*$"
)

# ASC CDL lines (S-2014-009-01). Resolve renders `*ASC_SOP` with no
# space after the asterisk; the regex permits optional whitespace either
# way so alternate exporters (FilmLight, etc.) parse too if we ever
# ingest them. Paren-group contents are not constrained at the regex
# level — `_parse_triple` validates each as three floats with an
# actionable error message (rule 1.14: actionable assert, not silent
# regex miss).
_ASC_SOP = re.compile(
    r"^\s*\*\s*ASC_SOP\s*"
    r"\(([^)]*)\)\s*"                      # 1 slope r g b
    r"\(([^)]*)\)\s*"                      # 2 offset r g b
    r"\(([^)]*)\)"                         # 3 power r g b
    r"\s*$"
)
_ASC_TOKEN = re.compile(r"^\s*\*\s*ASC_([A-Za-z0-9_]+)")
_ASC_SAT = re.compile(
    r"^\s*\*\s*ASC_SAT\s+([\-0-9.eE+]+)\s*$"
)


def _parse_triple(group, channel_label):
    parts = group.split()
    if len(parts) != 3:
        raise CdlEdlParseError(
            f"ASC_SOP {channel_label} expects 3 floats, got {parts!r}")
    try:
        return [float(p) for p in parts]
    except ValueError as exc:
        raise CdlEdlParseError(
            f"ASC_SOP {channel_label}: non-numeric value in {parts!r}"
            ) from exc


def tc_to_frames(tc_string, integer_frame_rate):
    """Convert a CMX-3600 timecode string to absolute frame number.

    `integer_frame_rate` is the timecode counter rate (24 for 23.976,
    30 for 29.97, etc. — what the timecode itself counts in, not the
    fractional playback rate). Drop-frame is detected from the
    separator: `;` between SS and FF indicates drop, `:` is non-drop.

    Raises CdlEdlParseError on malformed input.
    """
    if not isinstance(tc_string, str) or not tc_string:
        raise CdlEdlParseError(
            f"timecode must be non-empty string, got {tc_string!r}")
    if not isinstance(integer_frame_rate, int) or integer_frame_rate <= 0:
        raise CdlEdlParseError(
            f"integer_frame_rate must be positive int, got "
            f"{integer_frame_rate!r}")
    if ";" in tc_string:
        is_drop = True
        norm = tc_string.replace(";", ":")
    else:
        is_drop = False
        norm = tc_string
    parts = norm.split(":")
    if len(parts) != 4:
        raise CdlEdlParseError(
            f"timecode {tc_string!r} not HH:MM:SS:FF / HH:MM:SS;FF")
    try:
        hh, mm, ss, ff = (int(p) for p in parts)
    except ValueError as exc:
        raise CdlEdlParseError(
            f"timecode {tc_string!r} has non-integer fields") from exc
    if ff >= integer_frame_rate:
        raise CdlEdlParseError(
            f"timecode {tc_string!r}: frame field {ff} >= rate "
            f"{integer_frame_rate}")
    base = ((hh * 3600 + mm * 60 + ss) * integer_frame_rate) + ff
    if not is_drop:
        return base
    # SMPTE 12M drop-frame: drop 2 frames per minute except every 10th
    # for 30000/1001; drop 4 for 60000/1001. Other rates don't carry DF.
    if integer_frame_rate == 30:
        drop_per_minute = 2
    elif integer_frame_rate == 60:
        drop_per_minute = 4
    else:
        raise CdlEdlParseError(
            f"drop-frame timecode {tc_string!r} but integer_frame_rate "
            f"{integer_frame_rate} is not 30 or 60 (DF undefined)")
    total_minutes = hh * 60 + mm
    return base - drop_per_minute * (total_minutes - total_minutes // 10)


def parse_cdl_edl(edl_text, integer_frame_rate):
    """Parse Resolve EXPORT_EDL+EXPORT_CDL output.

    Returns dict keyed by absolute record-in frame → grade dict
    `{slope:[r,g,b], offset:[r,g,b], power:[r,g,b], sat: float}`.

    `integer_frame_rate` is the timecode counter rate (round of the
    fractional playback rate — see `tc_to_frames`).

    Raises CdlEdlParseError on:
      - ASC_SOP without matching ASC_SAT
      - ASC_SAT without preceding ASC_SOP
      - malformed CDL block (non-numeric, wrong arity)
      - duplicate record-in frame across two events (would silently
        clobber)
    """
    if not isinstance(edl_text, str):
        raise CdlEdlParseError(
            f"edl_text must be string, got {type(edl_text).__name__}")

    by_rec_in = {}
    current_event = None      # rec_in frame number for the open event
    pending_sop = None        # (slope, offset, power) awaiting ASC_SAT

    for line_number, raw in enumerate(edl_text.splitlines(), start=1):
        m = _EVENT_HEADER.match(raw)
        if m:
            if pending_sop is not None:
                raise CdlEdlParseError(
                    f"line {line_number}: new event opens while previous "
                    f"event (rec_in frame {current_event}) has ASC_SOP "
                    "without matching ASC_SAT")
            current_event = tc_to_frames(m.group(4), integer_frame_rate)
            pending_sop = None
            continue
        sop_m = _ASC_SOP.match(raw)
        if sop_m:
            if current_event is None:
                raise CdlEdlParseError(
                    f"line {line_number}: ASC_SOP before any event header")
            if pending_sop is not None:
                raise CdlEdlParseError(
                    f"line {line_number}: second ASC_SOP for event "
                    f"rec_in frame {current_event} before its ASC_SAT")
            pending_sop = (
                _parse_triple(sop_m.group(1), "slope"),
                _parse_triple(sop_m.group(2), "offset"),
                _parse_triple(sop_m.group(3), "power"),
            )
            continue
        sat_m = _ASC_SAT.match(raw)
        if sat_m:
            if pending_sop is None:
                raise CdlEdlParseError(
                    f"line {line_number}: ASC_SAT without preceding "
                    "ASC_SOP in the current event")
            try:
                sat_value = float(sat_m.group(1))
            except ValueError as exc:
                raise CdlEdlParseError(
                    f"line {line_number}: ASC_SAT value not numeric: "
                    f"{sat_m.group(1)!r}") from exc
            slope, offset, power = pending_sop
            if current_event in by_rec_in:
                raise CdlEdlParseError(
                    f"line {line_number}: duplicate record-in frame "
                    f"{current_event} — two events resolve to the same "
                    "timeline position (overlapping items on parallel "
                    "tracks?). Caller must disambiguate by track.")
            by_rec_in[current_event] = {
                "slope":  slope,
                "offset": offset,
                "power":  power,
                "sat":    sat_value,
            }
            pending_sop = None
            continue
        # Closed-set guard for `*ASC_*` lines (Rule 2.32 — no silent
        # failures on unknown protocol extensions). Two failure modes:
        #   (a) unknown token (e.g. `*ASC_SOP_HDR` if Resolve adds one) —
        #       letting it pass would silently misread the file as
        #       fully-primary.
        #   (b) known token (SOP/SAT) but the strict regex above didn't
        #       match — malformed value. Previously fell through to EOF
        #       error ("ASC_SOP without ASC_SAT"); now raises with the
        #       actual line context.
        asc_m = _ASC_TOKEN.match(raw)
        if asc_m:
            token = asc_m.group(1)
            if token in ("SOP", "SAT"):
                raise CdlEdlParseError(
                    f"line {line_number}: malformed ASC_{token} "
                    f"directive: {raw.strip()!r}")
            raise CdlEdlParseError(
                f"line {line_number}: unknown ASC_{token} directive — "
                f"only ASC_SOP and ASC_SAT are handled")
        # Any other line (TITLE, FCM, blank, FROM CLIP NAME comments,
        # etc.) is silently ignored — they carry no CDL state.

    if pending_sop is not None:
        raise CdlEdlParseError(
            f"EDL ended with ASC_SOP for event rec_in frame "
            f"{current_event} but no matching ASC_SAT")
    return by_rec_in


# Closed set of TC counter rates we accept. Real-world video rates and
# their TC counters; anything else surfaces rather than silently
# rounding (FR-020 spirit applied to TC math).
_KNOWN_TC_COUNTER_RATES = frozenset({24, 25, 30, 48, 50, 60})


_FIDELITY_VALUES = ("primary", "partial", "unrepresentable")


def classify_fidelity(any_non_cdl_tools, item_lut_ref, cdl_present):
    """Decide FR-015 fidelity bucket from observed Resolve state.

    Args:
      any_non_cdl_tools: True if `Graph.GetToolsInNode(n)` returned a
        non-empty list for any node in the item's graph (curves,
        qualifier, OFX, masks — anything beyond bare primary correction).
      item_lut_ref: `TimelineItem.GetLUT()` result — a non-empty local
        path string when an item-level LUT is bound, else None.
      cdl_present: True if the EDL+CDL export emitted an
        `*ASC_SOP`/`*ASC_SAT` block for this item.

    Returns one of `"primary" | "partial" | "unrepresentable" | "none"`.

    `cdl_present` is a real signal, not an anomaly: ungraded clips and
    LUT-only / non-CDL-only graphs do NOT produce ASC_SOP/ASC_SAT in
    the EDL+CDL export (empirically disproved on the Anamnesis
    sequence, 2026-06-04). The earlier "Resolve emits CDL for every
    clip" assumption was wrong.

    Semantics:
      cdl_present == True:
        - only CDL (no extra tools, no LUT) → primary.
        - CDL + LUT (no extra tools) → partial — the LUT carrier is
          the partial representation; CDL alone misrepresents the look.
        - CDL + non-CDL tools + LUT carrier → partial — same shape;
          the LUT bake captures what CDL alone cannot.
        - CDL + non-CDL tools + NO LUT carrier → unrepresentable —
          the Resolve grade exceeds what CDL+LUT can represent and we
          have no honest carrier to ship.
      cdl_present == False:
        - no LUT, no non-CDL tools → none — clip is genuinely
          ungraded. Distinct from "Resolve item absent" (FR-013a),
          which the caller models by OMITTING the row entirely.
        - LUT present → partial — LUT alone represents the grade.
        - non-CDL tools present, no LUT → unrepresentable.
    """
    if not isinstance(any_non_cdl_tools, bool):
        raise CdlEdlParseError(
            f"classify_fidelity: any_non_cdl_tools must be bool, got "
            f"{type(any_non_cdl_tools).__name__}")
    if not isinstance(cdl_present, bool):
        raise CdlEdlParseError(
            f"classify_fidelity: cdl_present must be bool, got "
            f"{type(cdl_present).__name__}")
    if item_lut_ref is not None and (
            not isinstance(item_lut_ref, str) or item_lut_ref == ""):
        raise CdlEdlParseError(
            f"classify_fidelity: item_lut_ref must be None or non-empty "
            f"string, got {item_lut_ref!r}")
    if cdl_present:
        if not any_non_cdl_tools and item_lut_ref is None:
            return "primary"
        if item_lut_ref is not None:
            return "partial"
        return "unrepresentable"
    # cdl_present == False — Resolve item observed without a CDL block.
    if not any_non_cdl_tools and item_lut_ref is None:
        return "none"
    if item_lut_ref is not None:
        return "partial"
    return "unrepresentable"


def integer_frame_rate_from_setting(timeline_frame_rate_setting):
    """Convert Resolve's `timelineFrameRate` project setting to the
    timecode-counter integer rate. Accepts whatever `GetSetting` returns
    in any Resolve version observed in the wild: BMD docs say string,
    but live Studio 20.3.2.9 returns float (e.g. `24.0`); some legacy
    versions may return int. We accept str/int/float and rebuff bool
    explicitly (bool is a subclass of int in Python — the convenient
    `int` check would silently let `True` through, which would round to
    1 and crash the closed-set check far from the cause).

    Raises CdlEdlParseError on unrecognised input — never invents a
    default (rule 2.13).
    """
    if isinstance(timeline_frame_rate_setting, bool):
        raise CdlEdlParseError(
            f"timelineFrameRate must be str/int/float, got bool "
            f"({timeline_frame_rate_setting!r})")
    if isinstance(timeline_frame_rate_setting, (int, float)):
        f = float(timeline_frame_rate_setting)
    elif isinstance(timeline_frame_rate_setting, str):
        if timeline_frame_rate_setting == "":
            raise CdlEdlParseError(
                "timelineFrameRate string must be non-empty")
            # (defensive: float("") raises but the message wouldn't
            # name the field; explicit assert is more actionable)
        # Resolve appends " DF" to drop-frame rates (per Scripting
        # README §timelineFrameRate: `"29.97 DF" will enable drop frame
        # and "29.97" will disable drop frame`). DF-ness is orthogonal
        # to the integer TC counter rate (29.97 DF and 29.97 NDF both
        # round to 30), so strip the suffix before float conversion.
        numeric = timeline_frame_rate_setting
        if numeric.endswith(" DF"):
            numeric = numeric[:-3]
        try:
            f = float(numeric)
        except ValueError as exc:
            raise CdlEdlParseError(
                f"timelineFrameRate {timeline_frame_rate_setting!r} not "
                "parseable as float") from exc
    else:
        raise CdlEdlParseError(
            f"timelineFrameRate must be str/int/float, got "
            f"{type(timeline_frame_rate_setting).__name__}")
    rounded = round(f)
    if rounded not in _KNOWN_TC_COUNTER_RATES:
        raise CdlEdlParseError(
            f"timelineFrameRate {timeline_frame_rate_setting!r} (rounded "
            f"{rounded}) is not a recognised TC counter rate "
            f"(expected one of {sorted(_KNOWN_TC_COUNTER_RATES)})")
    return rounded
