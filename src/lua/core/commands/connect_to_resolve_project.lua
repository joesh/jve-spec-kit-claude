--- ConnectToResolveProject — link a JVE sequence's clips to the
--- currently-open Resolve project's timeline items (spec 023, T049,
--- FR-011c, FR-023).
---
--- Two match channels, per FR-011c priority order:
---   (a) **Clip marker carrying `clip.id`** in `customData`
---       (`TimelineItem:AddMarker`/`GetMarkers`). Recovered via the
---       helper's `read_identities` verb (T029a). Id-anchored:
---       Resolve `customData` IS the JVE `clip.id`.
---   (b) **Position match** (V1 scope) — for each JVE clip not yet
---       linked via (a), find a `read_timeline` row on the same
---       `(track_type, track_index)` whose `record_start` equals the
---       JVE clip's `sequence_start`. Track identity is positional
---       (helper-protocol.md §read_timeline); record_start uniquely
---       identifies a clip on a track (Resolve enforces non-overlap).
---       Full content match per FR-011c spec wording
---       (`name + record-TC + source-TC + media identity`) needs media
---       identity on the helper response, which read_timeline does not
---       yet carry; that lands as T049b (see
---       todo_t049b_content_match_media_identity).
---
--- Match results land in `resolve_bridge_link` via
--- `identity_ledger.upsert`. Unmatched JVE clips are reported, never
--- silently skipped (FR-011c).
---
--- Marker stamping is the user-consented mutation that converts a
--- position match into a marker-anchored link so subsequent syncs are
--- id-anchored. Driven by `args.stamp_position_matches`:
---   • nil / false (default): pure discovery. No mutation.
---   • true: after persisting the ledger, dispatch
---     `stamp_identity_marker` (T048) for every `pos_matched` pair.
---     Marker-matched pairs are skipped (already id-anchored).
---     Stamps surface as `result.stamped / skipped / failures` in
---     `on_complete`. Failures are surfaced verbatim (rule 2.32) —
---     a `resolve_api_error` from the helper (conflicting customData
---     etc.) does NOT cascade into bypassing remaining stamps.
---
--- Not undoable — this command writes a discovery result to the
--- ledger; reverting would be "forget what we just learned about
--- Resolve" which has no UX. If the user wants to redo, they re-invoke
--- ConnectToResolveProject (the upsert is idempotent on clip_id).
---
--- Asynchronous: `M.execute` returns once the helper request is
--- enqueued; `on_complete` carries `{matched, unmatched, ambiguous}`
--- on success or `(nil, code, msg)` on error.

local M = {}

local Track             = require("models.track")
local Sequence          = require("models.sequence")
local database          = require("core.database")
local change_token      = require("core.resolve_bridge.change_token")
local identity_ledger   = require("core.resolve_bridge.identity_ledger")
local supervisor        = require("core.resolve_bridge.helper_supervisor")
local bridge_command    = require("core.commands.bridge_command")
local log               = require("core.logger").for_area("commands")

local OP = bridge_command.declare(
    "ConnectToResolveProject", "connect_to_resolve_project_completed")
local notify = OP.notify

local function validate_args(args)
    assert(type(args) == "table", "ConnectToResolveProject: args required")
    assert(type(args.project_id) == "string" and args.project_id ~= "",
        "ConnectToResolveProject: project_id required")
    assert(type(args.sequence_id) == "string" and args.sequence_id ~= "",
        "ConnectToResolveProject: sequence_id required")
    assert(args.stamp_position_matches == nil
        or type(args.stamp_position_matches) == "boolean",
        "ConnectToResolveProject: stamp_position_matches must be boolean "
        .. "(user-consented marker mutation per FR-011c)")
    assert(args.on_complete == nil or type(args.on_complete) == "function",
        "ConnectToResolveProject: on_complete, when supplied, must be a "
        .. "function — terminal results also surface via the "
        .. "connect_to_resolve_project_completed signal (FR-023).")
end

-- Hashmap count (#t doesn't work on string-keyed tables).
local function table_len(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Schema-level track_type values are uppercase ("VIDEO"/"AUDIO"); the
-- helper's read_timeline wire shape (and the matcher key) uses
-- lowercase ("video"/"audio"). Single source of truth — adding a new
-- track type tomorrow only needs an entry here.
local TRACK_TYPE_TO_WIRE = {
    VIDEO = "video",
    AUDIO = "audio",
}

-- Iterate JVE clips on a track via the database.select_rows helper.
-- The helper guarantees prepare → bind → exec → next → finalize so a
-- caller cannot recreate the missing-exec bug that originally produced
-- "0 JVE clip(s)" here (2026-06-03 fix). Returns lightweight tables in
-- matcher-input shape.
local function load_clips_on_track(db, track)
    local wire_track_type = TRACK_TYPE_TO_WIRE[track.track_type] or error(
        "ConnectToResolveProject: unsupported track.track_type "
        .. tostring(track.track_type))
    return database.select_rows(db, [[
        SELECT id, name, sequence_start_frame, duration_frames,
               source_in_frame, source_out_frame
        FROM clips
        WHERE track_id = ?
        ORDER BY sequence_start_frame
    ]], { track.id }, function(stmt)
        return {
            id              = stmt:value(0),
            name            = stmt:value(1),
            track_id        = track.id,
            -- Wire-side track_type derived from the schema value
            -- (uppercase "VIDEO"/"AUDIO") so a future widening that
            -- drops the V1 video-only filter automatically tags audio
            -- correctly (rule 2.13 — no hidden assumptions).
            track_type      = wire_track_type,
            track_index     = track.track_index,
            sequence_start  = stmt:value(2),
            duration        = stmt:value(3),
            source_in       = stmt:value(4),
            source_out      = stmt:value(5),
        }
    end)
end

-- Build the list of JVE clips the matcher walks AND the list of audio
-- clips deliberately skipped under V1 scope (FR-024 — read_timeline's
-- V1 response is video-only; T054 widens to audio). The skipped list
-- is surfaced on the result so the user sees "audio not connected
-- because V1", not silent omission (rule 2.32). Returns (video_clips,
-- audio_skipped) where audio_skipped is a list of {clip_id, track_id,
-- clip_name, reason} entries.
local function load_jve_clips_for_sequence(sequence_id, db)
    local video_clips = {}
    for _, track in ipairs(Track.find_by_sequence(sequence_id, "VIDEO")) do
        for _, c in ipairs(load_clips_on_track(db, track)) do
            video_clips[#video_clips + 1] = c
        end
    end
    local audio_skipped = {}
    for _, track in ipairs(Track.find_by_sequence(sequence_id, "AUDIO")) do
        for _, c in ipairs(load_clips_on_track(db, track)) do
            audio_skipped[#audio_skipped + 1] = {
                clip_id   = c.id,
                track_id  = c.track_id,
                clip_name = c.name,
                reason    = "audio_v1_unsupported",
            }
        end
    end
    return video_clips, audio_skipped
end

-- Exported for black-box regression coverage of the JVE-side load
-- (e.g. the missing-stmt:exec() bug that returned 0 clips on a
-- populated sequence). Production callers should keep going through
-- M.execute.
M.load_jve_clips_for_sequence = load_jve_clips_for_sequence

-- Position-match: (track_type, track_index, record_start) keys are
-- unique per timeline (Resolve enforces non-overlap among media items).
-- For each Resolve media item, index by that triple; for each JVE clip
-- with no marker match yet, look up the triple and link if found.
--
-- Non-media items (kind="non_media": generators, Text+, transitions,
-- adjustment clips, some Fusion comps — per helper-protocol.md
-- §read_timeline) carry no source range JVE can match against, and
-- Resolve allows them to stack at the same (track, record_start) as
-- media items or each other (compositing). Skip them BEFORE the
-- position-key collision check — otherwise a generator stacked over a
-- media clip would falsely trip the duplicate-key assert.
--
-- Returns the index + the count of non_media items skipped (logged by
-- the caller). `kind` is required (rule 2.32 — closed-set discipline
-- at the wire boundary; no silent default).
local function index_items_by_position(items)
    local by_pos = {}
    local non_media_skipped = 0
    for _, item in ipairs(items) do
        assert(item.kind == "media" or item.kind == "non_media",
            string.format(
                "ConnectToResolveProject: read_timeline item %s missing "
                .. "or invalid kind (got %q) — helper-protocol "
                .. "§read_timeline requires kind ∈ "
                .. "{\"media\",\"non_media\"}",
                tostring(item.resolve_item_id), tostring(item.kind)))
        if item.kind == "non_media" then
            non_media_skipped = non_media_skipped + 1
        else
            local key = string.format("%s:%d:%d",
                item.track_type, item.track_index, item.record_start)
            -- Two MEDIA items at the same (track, record_start) would
            -- be a Resolve invariant break; surface defensively rather
            -- than silently picking the second.
            assert(by_pos[key] == nil, string.format(
                "ConnectToResolveProject: duplicate position key %q on "
                .. "Resolve side (resolve_item_id=%s and %s) — Resolve "
                .. "invariant violated", key,
                tostring(by_pos[key] and by_pos[key].resolve_item_id),
                tostring(item.resolve_item_id)))
            by_pos[key] = item
        end
    end
    return by_pos, non_media_skipped
end

local function match_by_marker(jve_clips, identities_items)
    -- read_identities returns {items: [{resolve_item_id, jve_guid}], ...}.
    -- Build clip_id → resolve_item_id map for jve_guids that name JVE
    -- clips actually in this sequence. Resolve items whose jve_guid
    -- names a clip outside this sequence are silently ignored
    -- (cross-sequence marker collision is the user's problem to
    -- resolve; we don't second-guess the marker).
    local jve_clip_ids = {}
    for _, c in ipairs(jve_clips) do jve_clip_ids[c.id] = true end

    local marker_matched = {}  -- jve_clip_id → resolve_item_id
    for _, item in ipairs(identities_items) do
        if jve_clip_ids[item.jve_guid] then
            marker_matched[item.jve_guid] = item.resolve_item_id
        end
    end
    return marker_matched
end

local function match_by_position(jve_clips, items_by_pos, marker_matched,
                                  already_claimed)
    -- For each JVE clip without a marker match, look up its position
    -- triple in the Resolve index. Skip Resolve items already claimed
    -- by a marker match (a single Resolve item can only link to one
    -- JVE clip per identity_ledger invariant).
    local pos_matched = {}     -- jve_clip_id → resolve_item_id
    local ambiguous   = {}     -- {jve_clip_id, resolve_item_id, reason}
    for _, clip in ipairs(jve_clips) do
        if not marker_matched[clip.id] then
            local key = string.format("%s:%d:%d",
                clip.track_type, clip.track_index, clip.sequence_start)
            local hit = items_by_pos[key]
            if hit ~= nil and not already_claimed[hit.resolve_item_id] then
                pos_matched[clip.id] = hit.resolve_item_id
                already_claimed[hit.resolve_item_id] = true
            elseif hit ~= nil then
                ambiguous[#ambiguous + 1] = {
                    clip_id         = clip.id,
                    resolve_item_id = hit.resolve_item_id,
                    reason          = "position_match_already_claimed",
                }
            end
        end
    end
    return pos_matched, ambiguous
end

-- Persist a matched-clip map into the identity_ledger. Idempotent —
-- identity_ledger.upsert handles existing rows correctly.
local function persist_matches(matched_map, db, source_label, log_list)
    for clip_id, resolve_item_id in pairs(matched_map) do
        identity_ledger.upsert(clip_id, {
            resolve_item_id = resolve_item_id,
        }, db)
        log_list[#log_list + 1] = {
            clip_id         = clip_id,
            resolve_item_id = resolve_item_id,
            source          = source_label,
        }
    end
end

local function build_unmatched_list(jve_clips, marker_matched, pos_matched)
    local unmatched = {}
    for _, clip in ipairs(jve_clips) do
        if marker_matched[clip.id] == nil
            and pos_matched[clip.id]    == nil then
            unmatched[#unmatched + 1] = {
                clip_id    = clip.id,
                track_id   = clip.track_id,
                clip_name  = clip.name,
            }
        end
    end
    return unmatched
end

--- Pure-data matcher (no DB, no helper) — exposed for unit testing.
--- Given the matcher-shape JVE clips plus the helper's identities +
--- timeline payloads, produces the four buckets:
---   • `marker_matched`: clip_id → resolve_item_id via marker channel
---   • `pos_matched`:    clip_id → resolve_item_id via position channel
---   • `ambiguous`:      [{clip_id, resolve_item_id, reason}, ...] for
---     position keys collided with a marker-claimed Resolve item
---   • `unmatched`:      [{clip_id, track_id, clip_name}, ...]
function M.match(jve_clips, identities_items, timeline_items)
    assert(type(jve_clips)        == "table",
        "ConnectToResolveProject.match: jve_clips array required")
    assert(type(identities_items) == "table",
        "ConnectToResolveProject.match: identities_items array required")
    assert(type(timeline_items)   == "table",
        "ConnectToResolveProject.match: timeline_items array required")

    local marker_matched  = match_by_marker(jve_clips, identities_items)
    local items_by_pos, non_media_skipped =
        index_items_by_position(timeline_items)
    if non_media_skipped > 0 then
        log.event("ConnectToResolveProject: skipping %d non-media "
            .. "timeline item(s) (generators/transitions/etc. — DRP "
            .. "importer does not yet cover these kinds)",
            non_media_skipped)
    end
    local already_claimed = {}
    for _, rid in pairs(marker_matched) do
        already_claimed[rid] = true
    end
    local pos_matched, ambiguous = match_by_position(
        jve_clips, items_by_pos, marker_matched, already_claimed)
    local unmatched = build_unmatched_list(
        jve_clips, marker_matched, pos_matched)
    return {
        marker_matched = marker_matched,
        pos_matched    = pos_matched,
        ambiguous      = ambiguous,
        unmatched      = unmatched,
    }
end

-- Build the JVE-side translator's wire-shape converter for
-- read_timeline. Mirrors sync_edits_from_resolve's
-- translate_wire_response but does NOT swap track_type/track_index
-- for JVE track_id — ConnectToResolveProject keys on the wire shape
-- directly because position match uses the same coords on both sides.
local function load_resolve_state(client, on_done)
    client:request("read_identities", {},
        function(idr, code1, msg1)
            if idr == nil then on_done(nil, code1, msg1); return end
            local id_items = idr.result.items
            client:request("read_timeline", {},
                function(rtr, code2, msg2)
                    if rtr == nil then
                        on_done(nil, code2, msg2)
                        return
                    end
                    on_done({
                        identities            = id_items,
                        items                 = rtr.result.items,
                        timeline_integer_rate = rtr.result.timeline_integer_rate,
                    }, nil, nil)
                end)
        end)
end

-- Asynchronously stamp customData markers on each pos_matched
-- (clip_id, resolve_item_id) pair using the helper's
-- stamp_identity_marker verb. Each stamp is one helper roundtrip;
-- we fan them in sequence to keep the result accumulation simple
-- and to surface the first hard failure clearly. Calls `done(stamped,
-- skipped, failures)` once every pair has been processed.
--
--   stamped:  array of {clip_id, resolve_item_id} that were freshly
--             stamped (helper returned stamped=true).
--   skipped:  array of {clip_id, resolve_item_id} that were already
--             stamped with the matching customData (stamped=false —
--             idempotent no-op).
--   failures: array of {clip_id, resolve_item_id, code, message} for
--             any stamp the helper refused (conflicting customData,
--             handle_stale, etc.). Surfaced verbatim — never silenced.
local function stamp_each(client, token, pairs_list, done)
    local stamped, skipped, failures = {}, {}, {}
    local idx = 0

    local function step()
        idx = idx + 1
        if idx > #pairs_list then
            done(stamped, skipped, failures); return
        end
        local pair = pairs_list[idx]
        client:request("stamp_identity_marker", {
            resolve_item_id = pair.resolve_item_id,
            custom_data     = pair.clip_id,
            change_token    = token,
        }, function(response, code, message)
            if response == nil then
                failures[#failures + 1] = {
                    clip_id         = pair.clip_id,
                    resolve_item_id = pair.resolve_item_id,
                    code            = code,
                    message         = message,
                }
            elseif response.result.stamped == true then
                stamped[#stamped + 1] = pair
            else
                skipped[#skipped + 1] = pair
            end
            step()
        end)
    end

    step()
end

local function pos_matched_pairs(matched)
    local out = {}
    for clip_id, resolve_item_id in pairs(matched.pos_matched) do
        out[#out + 1] = {
            clip_id         = clip_id,
            resolve_item_id = resolve_item_id,
        }
    end
    return out
end

-- `_command` accepted for register_executor's executor signature; not
-- used here because ConnectToResolveProject is non-undoable.
function M.execute(args, db, _command)
    validate_args(args)
    assert(db, "ConnectToResolveProject: db required (passed by "
        .. "register's executor closure; SQL isolation policy keeps "
        .. "the global DB lookup out of commands)")

    local jve_clips, audio_skipped = load_jve_clips_for_sequence(
        args.sequence_id, db)
    if #audio_skipped > 0 then
        log.event("ConnectToResolveProject: skipping %d audio clip(s) "
            .. "(audio_v1_unsupported — FR-024 V1 video-only scope)",
            #audio_skipped)
    end

    -- Sequence load up-front so a missing sequence fails BEFORE the
    -- helper request is queued (rule 1.14). Also needed for
    -- change_token when stamp_position_matches=true.
    local seq = Sequence.load(args.sequence_id)
    assert(seq, "ConnectToResolveProject: sequence not found: "
        .. args.sequence_id)
    assert(seq.mutation_generation,
        "ConnectToResolveProject: sequence missing mutation_generation "
        .. "— schema expected V12+ (FU-2)")
    assert(type(seq.frame_rate) == "table"
        and type(seq.frame_rate.fps_numerator) == "number"
        and seq.frame_rate.fps_numerator > 0
        and type(seq.frame_rate.fps_denominator) == "number"
        and seq.frame_rate.fps_denominator > 0,
        "ConnectToResolveProject: sequence missing frame_rate."
        .. "fps_numerator/fps_denominator — required for the "
        .. "rate-mismatch guard before position match (rule 1.14)")

    local client, sv_code, sv_msg = supervisor.ensure_client()
    if not client then
        notify(args, nil, sv_code, sv_msg)
        return
    end

    log.event("ConnectToResolveProject: loading Resolve state for "
        .. "sequence %s (%d JVE clip(s))",
        args.sequence_id, #jve_clips)

    load_resolve_state(client, function(state, code, message)
        if state == nil then
            notify(args, nil, code, message)
            return
        end
        -- Async-tail asserts (M.match invariants, duplicate position
        -- keys, ledger upsert) crash by design — bridge_completion.lua's
        -- executor pcall only catches sync-phase asserts. Contract lives
        -- in bridge_completion's docstring; mirror it here so a reader
        -- of this file sees the rule without grep.

        -- Position-match key `(track_type, track_index, record_start)`
        -- is rate-relative. If Resolve's timeline rate disagrees with
        -- JVE's sequence rate, the SAME numeric record_start refers to
        -- DIFFERENT real times on the two sides and the match would
        -- silently fire false positives. Surface as a structured
        -- closed-set error (see helper-protocol.md error table) rather
        -- than asserting — this is a user-recoverable condition
        -- ("change Resolve's timeline rate back"), not an internal
        -- invariant violation.
        local jve_integer_rate = math.ceil(
            seq.frame_rate.fps_numerator / seq.frame_rate.fps_denominator)
        local resolve_integer_rate = state.timeline_integer_rate
        assert(type(resolve_integer_rate) == "number"
            and resolve_integer_rate > 0,
            "ConnectToResolveProject: helper response missing "
            .. "result.timeline_integer_rate — helper-protocol "
            .. "§read_timeline contract violation")
        if jve_integer_rate ~= resolve_integer_rate then
            notify(args, nil, "timeline_rate_mismatch", string.format(
                "JVE sequence %s is at TC rate %d (%d/%d); Resolve "
                .. "timeline is at TC rate %d. Position match is "
                .. "rate-relative; rates must agree before "
                .. "ConnectToResolveProject can proceed.",
                args.sequence_id, jve_integer_rate,
                seq.frame_rate.fps_numerator,
                seq.frame_rate.fps_denominator,
                resolve_integer_rate))
            return
        end

        local matched = M.match(jve_clips, state.identities, state.items)

        local matched_log = {}
        persist_matches(matched.marker_matched, db, "marker",
            matched_log)
        persist_matches(matched.pos_matched,    db, "position_match",
            matched_log)

        log.event("ConnectToResolveProject: %d matched "
            .. "(%d marker, %d position), %d unmatched, %d ambiguous",
            #matched_log,
            table_len(matched.marker_matched),
            table_len(matched.pos_matched),
            #matched.unmatched, #matched.ambiguous)

        local result = {
            matched       = matched_log,
            unmatched     = matched.unmatched,
            ambiguous     = matched.ambiguous,
            audio_skipped = audio_skipped,
        }

        if args.stamp_position_matches ~= true then
            notify(args, result, nil, nil)
            return
        end

        -- Stamp every position match. Marker-channel hits don't need
        -- stamping (they're already id-anchored by the existing
        -- marker that read_identities surfaced).
        local pairs_to_stamp = pos_matched_pairs(matched)
        if #pairs_to_stamp == 0 then
            result.stamped  = {}
            result.skipped  = {}
            result.failures = {}
            notify(args, result, nil, nil)
            return
        end

        local token = change_token.build(args.project_id,
            args.sequence_id, seq.mutation_generation)
        stamp_each(client, token, pairs_to_stamp,
            function(stamped, skipped, failures)
                result.stamped  = stamped
                result.skipped  = skipped
                result.failures = failures
                log.event("ConnectToResolveProject: stamped %d, "
                    .. "skipped %d (already-stamped), %d failures",
                    #stamped, #skipped, #failures)
                notify(args, result, nil, nil)
            end)
    end)
end

local SPEC = {
    undoable      = false,
    mutates_clips = false,  -- writes resolve_bridge_link, not clips
    args = {
        project_id              = { required = true },
        sequence_id             = { required = true },
        stamp_position_matches  = { required = false, kind = "boolean" },
        on_complete             = { required = false, kind = "function" },
    },
}

M.register = OP.make_register(M.execute, SPEC)

return M
