--- drt_round_trip — FR-004 validator.
---
--- Spec 023 FR-004: "Before sending any file to Resolve, JVE MUST
--- validate the authored file by round-tripping it through JVE's own
--- importer and confirming the timeline reads back as intended."
---
--- We parse the .drt with the production drp_importer and confirm
--- that, structurally, what came out matches what went in:
---   1. parse succeeded;
---   2. exactly one timeline is present;
---   3. the set of clip.ids the writer was given equals the set of
---      DbIds the parser reads off Sm2Ti{Video,Audio}Clip elements
---      (FR-011b — identity carrier round-trips).
---   4. every clip carries the identity marker
---      (color="Purple", name="JVE clip identity", custom_data=clip.id)
---      so the live-API carrier reads back via the same parser the
---      helper's `read_identities` uses (spec.md:116 — DRT carries
---      clip.id via BOTH carriers).
---
--- Deeper invariants (per-clip TC / duration / file_uuid byte-equality)
--- are the long-running T004 integration test's job. Here we want a
--- fast pre-send check that catches "writer regressed and the file is
--- unreadable" or "DbId got cross-wired" — both of which would otherwise
--- arrive at Resolve as silent corruption.
---
--- Returns `true` on success; on failure, returns
--- `false, code (string), message (string)` matching the
--- on_complete(nil, code, message) shape SendToResolve already uses.

local importer = require("importers.drp_importer")

local M = {}

local function collect_payload_clip_ids(payload)
    local ids, n = {}, 0
    for _, track in ipairs(payload.sequence.tracks) do
        for _, clip in ipairs(track.clips) do
            assert(type(clip.id) == "string" and clip.id ~= "",
                "drt_round_trip: payload clip missing id "
                .. "(payload_builder contract violation)")
            assert(ids[clip.id] == nil, string.format(
                "drt_round_trip: payload clip.id %s duplicated — "
                .. "FR-002 stable-identity violation in payload_builder",
                clip.id))
            ids[clip.id] = true
            n = n + 1
        end
    end
    return ids, n
end

-- Returns (ids_set, count) on success, or (nil, error_message) on failure.
local function collect_parsed_clip_ids(parsed_timeline)
    assert(type(parsed_timeline.tracks) == "table",
        "drt_round_trip: parsed timeline.tracks missing — "
        .. "drp_importer contract violation (parse_sequence at "
        .. "drp_importer.lua:1697 always populates a tracks array)")
    local ids, n = {}, 0
    for _, track in ipairs(parsed_timeline.tracks) do
        assert(type(track.clips) == "table",
            "drt_round_trip: parsed track.clips missing — "
            .. "drp_importer contract violation")
        for _, clip in ipairs(track.clips) do
            if type(clip.clip_id) ~= "string" or clip.clip_id == "" then
                return nil, "parsed clip missing Sm2Ti DbId (FR-011b "
                    .. "identity carrier dropped)"
            end
            if ids[clip.clip_id] ~= nil then
                return nil, string.format(
                    "parsed timeline has duplicate DbId %s — writer "
                    .. "wrote the same identity onto two clips",
                    clip.clip_id)
            end
            ids[clip.clip_id] = true
            n = n + 1
        end
    end
    return ids, n
end

-- Identity marker fingerprint — MUST mirror drt_writer.lua's
-- IDENTITY_MARKER_* + tools/resolve-helper/verbs.py:_IDENTITY_MARKER_*.
-- If these drift, the helper's idempotent stamp check
-- (verbs.py:_stamp_marker_safe) re-stamps on every Send and we get
-- duplicate markers; a round-trip mismatch here catches that drift
-- before anything reaches Resolve.
local IDENTITY_MARKER_COLOR = "Purple"
local IDENTITY_MARKER_NAME  = "JVE clip identity"

-- Find the identity marker on a parsed clip, or nil if none. parse_resolve_markers
-- attaches the array as clip.markers (drp_importer.lua:2103); a clip without
-- an Sm2TiItemLockableBlob for its DbId gets no .markers field at all.
local function identity_marker_of(clip)
    if type(clip.markers) ~= "table" then return nil end
    for _, m in ipairs(clip.markers) do
        if m.color == IDENTITY_MARKER_COLOR
            and m.name == IDENTITY_MARKER_NAME then
            return m
        end
    end
    return nil
end

--- Validate the .drt at `out_path` round-trips against `payload`.
--- @param out_path string  absolute path to the just-authored .drt
--- @param payload  table   the same payload handed to drt_writer.author
--- @return boolean ok
--- @return string|nil code      (only on failure)
--- @return string|nil message   (only on failure)
function M.validate(out_path, payload)
    assert(type(out_path) == "string" and out_path ~= "",
        "drt_round_trip.validate: out_path required")
    assert(type(payload) == "table"
        and type(payload.sequence) == "table"
        and type(payload.sequence.tracks) == "table",
        "drt_round_trip.validate: payload.sequence.tracks required")

    local parsed = importer.parse_drp_file(out_path)
    if not parsed.success then
        return false, "drt_round_trip_failed", string.format(
            "drp_importer rejected the authored file: %s",
            tostring(parsed.error))
    end
    if type(parsed.timelines) ~= "table" or #parsed.timelines ~= 1 then
        return false, "drt_round_trip_failed", string.format(
            "expected 1 timeline in authored .drt, got %d",
            parsed.timelines and #parsed.timelines or 0)
    end

    local want_ids, want_n = collect_payload_clip_ids(payload)
    local got_ids, got_n_or_err = collect_parsed_clip_ids(parsed.timelines[1])
    if got_ids == nil then
        return false, "drt_round_trip_failed", got_n_or_err
    end
    local got_n = got_n_or_err

    if want_n ~= got_n then
        return false, "drt_round_trip_failed", string.format(
            "clip count drift: payload=%d, parsed=%d", want_n, got_n)
    end
    for id in pairs(want_ids) do
        if not got_ids[id] then
            return false, "drt_round_trip_failed", string.format(
                "clip.id %s in payload but missing from parsed timeline "
                .. "(FR-002 identity round-trip broken)", id)
        end
    end
    for id in pairs(got_ids) do
        if not want_ids[id] then
            return false, "drt_round_trip_failed", string.format(
                "parsed timeline carries DbId %s the payload did not "
                .. "supply (cross-wired or invented identity)", id)
        end
    end

    -- Identity-marker carrier check (FR-002, spec.md:116 — "both carriers").
    -- The DbId carrier is verified above; the live-API carrier is the
    -- clip identity marker. parse_resolve_markers populates clip.markers
    -- by matching <BlobOwner> to clip.clip_id (the Sm2Ti DbId), so a
    -- missing identity marker here means either the writer dropped the
    -- Sm2TiItemLockableBlob or the BlobOwner mismatches. Either ships
    -- silent corruption: the helper's read_identities sees an unkeyed
    -- item, first sync falls back to positional match, and grades land
    -- on the wrong clip if positions drift between Send and Read.
    for _, track in ipairs(parsed.timelines[1].tracks) do
        for _, clip in ipairs(track.clips) do
            local mk = identity_marker_of(clip)
            if not mk then
                return false, "drt_round_trip_failed", string.format(
                    "clip %s lacks identity marker (live-API carrier "
                    .. "dropped — FR-002)", clip.clip_id)
            end
            if mk.custom_data ~= clip.clip_id then
                return false, "drt_round_trip_failed", string.format(
                    "clip %s identity marker custom_data=%q does not "
                    .. "match clip.id (carrier mis-stamped)",
                    clip.clip_id, tostring(mk.custom_data))
            end
        end
    end
    return true
end

return M
