--- discovery — match JVE clips to live Resolve timeline items and
--- persist the links (spec 023, FR-011c).
---
--- Discovery is automatic: every sync command runs it at the start of
--- the pull (SyncGradesFromResolve / SyncEditsFromResolve), so the
--- user never performs ANY identity step — no connect, no stamping
--- command. The ledger join the syncs depend on is established (and
--- drift-repaired: a clip the colorist added Resolve-side gets
--- matched on the next sync) as a side effect of syncing, and newly
--- position-matched pairs are marker-stamped in the same pass so the
--- links survive Resolve-side cuts (FR-012 durability) — see
--- "Auto-stamping" below.
---
--- Clips that already hold a ledger link to a LIVE Resolve item skip
--- the match channels entirely: their identity is settled; re-running
--- content checks against them would misreport long-linked clips as
--- unmatched/ambiguous the moment names or paths drift (observed
--- 2026-06-12: 1199 false "ambiguous" on a fully-linked project).
--- Their items are pre-claimed so no channel can re-assign them.
---
--- Three match channels for the rest, in priority order:
---   (a) **Direct id** — `clip.id == resolve_item_id`. A clip imported
---       from a DRP exported off this Resolve project carries the
---       Resolve timeline-item id (`Sm2Ti DbId`) as its own `clip.id`.
---       `TimelineItem:GetUniqueId()` returns that same persisted
---       `Sm2Ti DbId`, so id equality IS the identity within a consistent
---       project snapshot: exact UUID match, no representation-dependent
---       field, rate-independent (3/3 fresh export, 1202/1202 live —
---       reconciled in spec FR-011c; the old "0/1003" was a stale
---       cross-instance fixture, not a namespace gap). This channel links
---       the ids that coincide; a clip whose id matches no live item
---       (stale/cross-instance, or churned by a re-edit) falls through to
---       (b)/(c). The id is its own durable anchor, so id matches are
---       persisted to the ledger but NOT marker-stamped (see below).
---   (b) **Clip marker carrying `clip.id`** in `customData`
---       (`TimelineItem:AddMarker`/`GetMarkers`). Recovered via the
---       helper's `read_identities` verb (T029a). Id-anchored:
---       Resolve `customData` IS the JVE `clip.id`. The durable channel
---       for clips whose live id has churned (re-edit) since export.
---   (c) **Position match** (V1 scope) — for each JVE clip not yet
---       linked via (a)/(b), find a `read_timeline` row on the same
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
--- The position channel is rate-relative: record_start frames refer to
--- different real times when the JVE sequence and the Resolve timeline
--- disagree on TC rate. On mismatch the position channel is SKIPPED
--- (never silently mismatched) and the report carries the reason; the
--- direct-id and marker channels are id-anchored and rate-independent,
--- so they always run. Syncs surface the skip as a warning and proceed
--- on id + marker matches + already-persisted links.
---
--- Match results land in `resolve_bridge_link` via
--- `identity_ledger.upsert` — idempotent on the ledger. Unmatched JVE
--- clips are reported, never silently skipped (FR-011c).
---
--- **Auto-stamping (FR-012)**: a position match is anchored to WHERE a
--- clip currently sits; a marker (clip marker whose `customData` is
--- the JVE `clip.id`) is anchored to the item itself and survives the
--- colorist cutting, moving, or splitting it. So each NEWLY
--- position-matched pair is stamped immediately via the helper's
--- `stamp_identity_marker` verb — the only Resolve-side mutation
--- discovery performs, idempotent (an identical existing marker
--- reports as skipped), and a refusal (e.g. the item already carries a
--- DIFFERENT sequence's marker) lands in `report.stamp_failures`,
--- never silently — the ledger link still works for this project.
--- Already-linked and marker-matched clips are not re-stamped (their
--- anchor already exists), keeping the per-sync stamp cost
--- proportional to NEW matches, not timeline size.

local M = {}

local Track             = require("models.track")
local Sequence          = require("models.sequence")
local Clip              = require("models.clip")
local database          = require("core.database")
local wire              = require("core.resolve_bridge.wire_decode")
local identity_ledger   = require("core.resolve_bridge.identity_ledger")
local change_token      = require("core.resolve_bridge.change_token")
local log               = require("core.logger").for_area("bridge")

-- Iterate JVE clips on a track. The id-list select goes through
-- database.select_rows (prepare → bind → exec → next → finalize, so a
-- caller cannot recreate the missing-exec bug that originally produced
-- "0 JVE clip(s)" here — 2026-06-03 fix); each clip then loads via
-- Clip.load so the media link follows the ONE V13 chain (nested master
-- → media_ref → media, honoring the master's default layer when
-- master_layer_track_id is unset) — the same mechanism payload_builder
-- uses on the send side. A hand-rolled JOIN here previously required
-- master_layer_track_id to be set and silently yielded nil media paths
-- for default-layer clips, which the matcher then reported as
-- content_mismatch (T050 live, 2026-06-10). Returns lightweight tables
-- in matcher-input shape.
-- Source-clip identity for a clip's source: the master's import_uuid
-- (the Resolve pool MediaRef DbId adopted on DRP import). A clip's
-- `sequence_id` is its SOURCE sequence — a master for media-backed clips —
-- so the master's import_uuid is read straight off it. nil for native
-- masters (no Resolve pool) and for compound sources, which then fall
-- through to the position channel. Cached per source-sequence id so a
-- timeline of N clips over a few masters costs a handful of loads, not N.
local function master_import_uuid(source_sequence_id, cache)
    local cached = cache[source_sequence_id]
    if cached ~= nil then return cached.value end
    local seq = Sequence.load(source_sequence_id)
    assert(seq, "discovery: clip source sequence vanished: "
        .. tostring(source_sequence_id))
    local value = seq.import_uuid
    cache[source_sequence_id] = { value = value }
    return value
end

local function load_clips_on_track(db, track, uuid_cache)
    local wire_track_type = wire.JVE_TO_WIRE_TRACK_TYPE[track.track_type]
        or error("discovery: unsupported track.track_type "
            .. tostring(track.track_type))
    local ids = database.select_rows(db,
        "SELECT id FROM clips WHERE track_id = ? "
        .. "ORDER BY sequence_start_frame",
        { track.id }, function(stmt) return stmt:value(0) end)
    local rows = {}
    for _, id in ipairs(ids) do
        local loaded = Clip.load(id)
        assert(loaded,
            "discovery: clip vanished between id-list and load: "
            .. tostring(id))
        rows[#rows + 1] = {
            id              = loaded.id,
            name            = loaded.name,
            track_id        = track.id,
            -- Wire-side track_type derived from the schema value
            -- (uppercase "VIDEO"/"AUDIO") so a future widening that
            -- drops the V1 video-only filter automatically tags audio
            -- correctly (rule 2.13 — no hidden assumptions).
            track_type      = wire_track_type,
            track_index     = track.track_index,
            sequence_start  = loaded.sequence_start,
            duration        = loaded.duration,
            source_in       = loaded.source_in,
            source_out      = loaded.source_out,
            -- nil when the clip's source is a non-master sequence
            -- (compound) — such a clip can never content-match a live
            -- media item and surfaces as ambiguous, not silently.
            media_file_path = loaded.media_path,
            -- Source-clip identity for the content channel: the master's
            -- import_uuid (Resolve pool MediaRef DbId). nil → no content
            -- match, falls through to position.
            import_uuid     = master_import_uuid(loaded.sequence_id, uuid_cache),
        }
    end
    return rows
end

--- Build the list of JVE clips the matcher walks AND the list of audio
--- clips deliberately skipped under V1 scope (FR-024 — read_timeline's
--- V1 response is video-only; T054 widens to audio). The skipped list
--- is surfaced on the report so the user sees "audio not connected
--- because V1", not silent omission (rule 2.32). Returns (video_clips,
--- audio_skipped) where audio_skipped is a list of {clip_id, track_id,
--- clip_name, reason} entries. Exported for black-box regression
--- coverage of the JVE-side load (e.g. the missing-stmt:exec() bug
--- that returned 0 clips on a populated sequence).
function M.load_jve_clips_for_sequence(sequence_id, db)
    -- One identity cache for the whole sequence load: many clips share a
    -- few source masters, so import_uuid lookups dedupe to one per master.
    local uuid_cache = {}
    local video_clips = {}
    for _, track in ipairs(Track.find_by_sequence(sequence_id, "VIDEO")) do
        for _, c in ipairs(load_clips_on_track(db, track, uuid_cache)) do
            video_clips[#video_clips + 1] = c
        end
    end
    local audio_skipped = {}
    for _, track in ipairs(Track.find_by_sequence(sequence_id, "AUDIO")) do
        for _, c in ipairs(load_clips_on_track(db, track, uuid_cache)) do
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
-- Returns (by_pos, non_media_skipped, pos_key_collisions).
-- `kind` is required (rule 2.32 — closed-set discipline at the wire
-- boundary; no silent default).
-- pos_key_collisions: [{resolve_item_id, reason}] for any pair of
-- MEDIA items sharing a (track, record_start) key — a Resolve invariant
-- violation, but externally-sourced data; route to ambiguous instead of
-- asserting so one bad timeline doesn't crash the whole sync.
local function index_items_by_position(items)
    local by_pos              = {}
    local pos_key_collisions  = {}
    local non_media_skipped   = 0
    for _, item in ipairs(items) do
        local valid, kind_err = wire.validate_item_kind(item.kind, string.format(
            "discovery: read_timeline item %s",
            tostring(item.resolve_item_id)))
        if not valid then
            pos_key_collisions[#pos_key_collisions + 1] = {
                resolve_item_id = item.resolve_item_id,
                reason          = kind_err,
            }
        elseif item.kind == "non_media" then
            non_media_skipped = non_media_skipped + 1
        else
            local key = string.format("%s:%d:%d",
                item.track_type, item.track_index, item.record_start)
            if by_pos[key] ~= nil then
                -- Two MEDIA items at the same position — Resolve invariant
                -- violation. Route both to collisions so neither is
                -- position-matched; the caller merges them into ambiguous.
                -- Never assert on external Resolve wire data.
                pos_key_collisions[#pos_key_collisions + 1] = {
                    resolve_item_id = by_pos[key].resolve_item_id,
                    reason          = "position_key_collision",
                }
                pos_key_collisions[#pos_key_collisions + 1] = {
                    resolve_item_id = item.resolve_item_id,
                    reason          = "position_key_collision",
                }
                by_pos[key] = nil  -- neither wins the position index
            else
                by_pos[key] = item
            end
        end
    end
    return by_pos, non_media_skipped, pos_key_collisions
end

local function match_by_marker(jve_clips, identities_items, already_claimed)
    -- read_identities returns {items: [{resolve_item_id, jve_guid}], ...}.
    -- Build clip_id → resolve_item_id map for jve_guids that name JVE
    -- clips actually in this sequence. Resolve items whose jve_guid
    -- names a clip outside this sequence are silently ignored
    -- (cross-sequence marker collision is the user's problem to
    -- resolve; we don't second-guess the marker).
    local jve_clip_ids = {}
    for _, c in ipairs(jve_clips) do jve_clip_ids[c.id] = true end

    local marker_matched = {}  -- jve_clip_id → resolve_item_id
    local ambiguous      = {}  -- {clip_id, resolve_item_id, reason}
    for _, item in ipairs(identities_items) do
        local guid = item.jve_guid
        if jve_clip_ids[guid] then
            if already_claimed[item.resolve_item_id] then
                -- The item already belongs to a DIFFERENT clip via a
                -- persisted ledger link (clips with live existing
                -- links never enter the channels), yet its marker
                -- names this one. Something rewired identities —
                -- report, don't silently pick a winner (rule 2.32).
                ambiguous[#ambiguous + 1] = {
                    clip_id         = guid,
                    resolve_item_id = item.resolve_item_id,
                    reason          = "marker_conflicts_existing_link",
                }
            else
                -- Rule 2.32: No silent last-write-wins. If two Resolve
                -- items carry the same JVE GUID (e.g. colorist duplicated
                -- a clip — customData is copied), route both to ambiguous
                -- rather than asserting: this is externally-sourced data
                -- and an assert would crash the async sync tail.
                if marker_matched[guid] ~= nil then
                    -- De-list the first match so neither wins.
                    ambiguous[#ambiguous + 1] = {
                        clip_id         = guid,
                        resolve_item_id = marker_matched[guid],
                        reason          = "duplicate_identity_marker",
                    }
                    already_claimed[marker_matched[guid]] = nil
                    marker_matched[guid] = nil
                    ambiguous[#ambiguous + 1] = {
                        clip_id         = guid,
                        resolve_item_id = item.resolve_item_id,
                        reason          = "duplicate_identity_marker",
                    }
                else
                    marker_matched[guid] = item.resolve_item_id
                    -- Prevent a second different GUID from also claiming
                    -- this Resolve item in the same marker-channel pass.
                    already_claimed[item.resolve_item_id] = true
                end
            end
        end
    end
    return marker_matched, ambiguous
end

-- Half-open source-TC range overlap (used by the content channel).
local function ranges_overlap(a_in, a_out, b_in, b_out)
    return a_in < b_out and b_in < a_out
end

-- Content channel (source-clip identity) — runs BEFORE position so an
-- identity match beats a geometric one when they disagree: a clip the
-- colorist MOVED in Resolve keeps its source-clip identity (the master's
-- import_uuid) even though its record position changed, while position
-- would mis-assign it to whatever now sits at its old slot. Keys on
-- import_uuid + overlapping source TC, both rate-independent, so this
-- channel also runs when position is skipped on a TC-rate mismatch.
--
-- Only clips carrying a source-clip identity participate; native/compound
-- clips (import_uuid nil) fall straight through to position. A single
-- unclaimed identity+TC hit links; more than one (the same source clip
-- used several times on the Resolve timeline, all overlapping) is
-- reported `duplicate_identity_content` — never a silent pick (rule 2.32)
-- — and the clip falls through to position, which disambiguates by
-- record_start. Like position (and unlike id/marker), a content match is
-- not self-anchored, so the caller marker-stamps it for durability.
local function match_by_content(jve_clips, timeline_items, settled,
                                 already_claimed)
    -- Index unclaimed media items by source-clip identity.
    local by_identity = {}
    for _, item in ipairs(timeline_items) do
        local uuid = item.import_uuid
        if type(uuid) == "string" and uuid ~= ""
            and item.kind == "media"
            and not already_claimed[item.resolve_item_id] then
            local bucket = by_identity[uuid]
            if bucket == nil then bucket = {}; by_identity[uuid] = bucket end
            bucket[#bucket + 1] = item
        end
    end
    local content_matched = {}  -- jve_clip_id → resolve_item_id
    local ambiguous       = {}  -- {clip_id, resolve_item_id, reason}
    for _, clip in ipairs(jve_clips) do
        local uuid = clip.import_uuid
        if not settled[clip.id]
            and type(uuid) == "string" and uuid ~= "" then
            local bucket = by_identity[uuid]
            if bucket ~= nil then
                local hits = {}
                for _, item in ipairs(bucket) do
                    if not already_claimed[item.resolve_item_id]
                        and ranges_overlap(clip.source_in, clip.source_out,
                            item.source_in, item.source_out) then
                        hits[#hits + 1] = item
                    end
                end
                if #hits == 1 then
                    content_matched[clip.id] = hits[1].resolve_item_id
                    already_claimed[hits[1].resolve_item_id] = true
                elseif #hits > 1 then
                    for _, item in ipairs(hits) do
                        ambiguous[#ambiguous + 1] = {
                            clip_id         = clip.id,
                            resolve_item_id = item.resolve_item_id,
                            reason          = "duplicate_identity_content",
                        }
                    end
                end
            end
        end
    end
    return content_matched, ambiguous
end

local function match_by_position(jve_clips, items_by_pos, settled,
                                  already_claimed)
    -- For each JVE clip not yet settled by an earlier channel (id, marker,
    -- content), look up its position triple in the Resolve index. Skip
    -- Resolve items already claimed (a single Resolve item can only link
    -- to one JVE clip per identity_ledger invariant).
    local pos_matched = {}     -- jve_clip_id → resolve_item_id
    local ambiguous   = {}     -- {jve_clip_id, resolve_item_id, reason}
    for _, clip in ipairs(jve_clips) do
        if not settled[clip.id] then
            local key = string.format("%s:%d:%d",
                clip.track_type, clip.track_index, clip.sequence_start)
            local hit = items_by_pos[key]
            if hit ~= nil and not already_claimed[hit.resolve_item_id] then
                if hit.name == clip.name
                    and hit.source_in == clip.source_in
                    and hit.media_file_path == clip.media_file_path then
                    pos_matched[clip.id] = hit.resolve_item_id
                    already_claimed[hit.resolve_item_id] = true
                else
                    -- Capture WHICH of the three content keys diverged
                    -- (and a sample of each side) so the report names the
                    -- failing field, not just "content_mismatch" (rule
                    -- 2.32 — the differing field is the load-bearing fact).
                    local fields = {}
                    if hit.name ~= clip.name then
                        fields[#fields + 1] = "name"
                    end
                    if hit.source_in ~= clip.source_in then
                        fields[#fields + 1] = "source_in"
                    end
                    if hit.media_file_path ~= clip.media_file_path then
                        fields[#fields + 1] = "media_file_path"
                    end
                    ambiguous[#ambiguous + 1] = {
                        clip_id         = clip.id,
                        resolve_item_id = hit.resolve_item_id,
                        reason          = "content_mismatch",
                        mismatch_fields = fields,
                        jve_name        = clip.name,
                        resolve_name    = hit.name,
                        jve_source_in   = clip.source_in,
                        resolve_source_in = hit.source_in,
                        jve_media_path    = clip.media_file_path,
                        resolve_media_path = hit.media_file_path,
                    }
                end
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

-- Direct-id channel (highest priority, rate-independent). A clip
-- imported from a DRP exported off this Resolve project carries the
-- Resolve timeline-item id as its own clip.id (Sm2Ti DbId adopted on
-- import). GetUniqueId returns that same persisted DbId, so within a
-- consistent project snapshot `clip.id == resolve_item_id` IS the
-- identity: exact UUID equality, no representation-dependent field
-- involved (reconciled — see module docstring (a)). This links the ids
-- that coincide; a clip whose id matches no live item (stale/cross-
-- instance, or churned by a re-edit) falls through to the marker/position
-- channels. id_matched needs no marker stamp — the id itself is the
-- durable anchor (caller stamps only no-anchor matches).
local function match_by_direct_id(jve_clips, timeline_items, already_claimed)
    local live_ids = {}
    for _, item in ipairs(timeline_items) do
        live_ids[item.resolve_item_id] = true
    end
    local id_matched = {}  -- clip_id → resolve_item_id (== clip_id)
    for _, clip in ipairs(jve_clips) do
        if live_ids[clip.id] and not already_claimed[clip.id] then
            id_matched[clip.id] = clip.id
            already_claimed[clip.id] = true  -- resolve_item_id == clip.id
        end
    end
    return id_matched
end

local function build_unmatched_list(jve_clips, id_matched, marker_matched,
                                    content_matched, pos_matched)
    local unmatched = {}
    for _, clip in ipairs(jve_clips) do
        if id_matched[clip.id]      == nil
            and marker_matched[clip.id]  == nil
            and content_matched[clip.id] == nil
            and pos_matched[clip.id]     == nil then
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
--- timeline payloads, produces the buckets:
---   • `id_matched`:      clip_id → resolve_item_id via direct-id channel
---     (clip.id == resolve_item_id; highest priority, rate-independent)
---   • `marker_matched`:  clip_id → resolve_item_id via marker channel
---   • `content_matched`: clip_id → resolve_item_id via source-clip
---     identity (master.import_uuid + source-TC overlap), rate-
---     independent; runs BEFORE position so identity beats geometry
---   • `pos_matched`:     clip_id → resolve_item_id via position channel
---   • `ambiguous`:       [{clip_id, resolve_item_id, reason}, ...] —
---     position keys colliding with a claimed item, or several live items
---     sharing one source identity (`duplicate_identity_content`)
---   • `unmatched`:       [{clip_id, track_id, clip_name}, ...]
--- `pre_claimed` (optional): set of resolve_item_ids already owned by
--- persisted ledger links — no channel may assign them to a new clip;
--- a marker naming a different clip on such an item is reported
--- ambiguous (`marker_conflicts_existing_link`), and a position hit on
--- one reports `position_match_already_claimed`.
--- `skip_position` (optional): when true, the position channel is not
--- run (caller passes this on a TC-rate mismatch — record_start is
--- rate-relative, so position would be silently wrong). The direct-id
--- and marker channels are rate-independent and ALWAYS run.
function M.match(jve_clips, identities_items, timeline_items, pre_claimed,
                 skip_position)
    assert(type(jve_clips)        == "table",
        "discovery.match: jve_clips array required")
    assert(type(identities_items) == "table",
        "discovery.match: identities_items array required")
    assert(type(timeline_items)   == "table",
        "discovery.match: timeline_items array required")
    assert(pre_claimed == nil or type(pre_claimed) == "table",
        "discovery.match: pre_claimed must be a set table when present")

    local ambiguous = {}
    local already_claimed = {}
    if pre_claimed then
        for rid in pairs(pre_claimed) do
            already_claimed[rid] = true
        end
    end
    -- Direct-id channel first: clip.id == resolve_item_id is the
    -- strongest, rate-independent identity signal. Its claims block the
    -- marker/position channels from re-assigning the same items.
    local id_matched = match_by_direct_id(
        jve_clips, timeline_items, already_claimed)
    -- Clips settled by id skip the remaining channels entirely.
    local unsettled = {}
    for _, c in ipairs(jve_clips) do
        if id_matched[c.id] == nil then unsettled[#unsettled + 1] = c end
    end
    local marker_matched, marker_ambiguous = match_by_marker(
        unsettled, identities_items, already_claimed)
    for _, a in ipairs(marker_ambiguous) do
        ambiguous[#ambiguous + 1] = a
    end
    for _, rid in pairs(marker_matched) do
        already_claimed[rid] = true
    end
    -- `settled` accumulates clips claimed by a higher-priority channel, so
    -- the content and position channels skip them. id-matched clips are
    -- already excluded from `unsettled`; markers add to it here.
    local settled = {}
    for cid in pairs(marker_matched) do settled[cid] = true end
    -- Content channel (source-clip identity) — BEFORE position so identity
    -- beats geometry on disagreement (a moved clip follows its source
    -- clip, not its old slot). Rate-independent (source-TC based), so it
    -- runs even when position is skipped on a rate mismatch.
    local content_matched, content_ambiguous = match_by_content(
        unsettled, timeline_items, settled, already_claimed)
    for _, a in ipairs(content_ambiguous) do
        ambiguous[#ambiguous + 1] = a
    end
    for cid in pairs(content_matched) do settled[cid] = true end
    -- Position channel (skipped on TC-rate mismatch — record_start is
    -- rate-relative). Runs over `unsettled` minus everything already
    -- settled: an already-claimed item would otherwise mis-report
    -- position_match_already_claimed against its own clip.
    local pos_matched = {}
    if not skip_position then
        local items_by_pos, non_media_skipped, pos_key_collisions =
            index_items_by_position(timeline_items)
        if non_media_skipped > 0 then
            log.event("discovery: skipping %d non-media timeline item(s) "
                .. "(generators/transitions/etc. — DRP importer does not "
                .. "yet cover these kinds)", non_media_skipped)
        end
        for _, c in ipairs(pos_key_collisions) do
            ambiguous[#ambiguous + 1] = c
            log.warn("discovery: position-key collision for %s — "
                .. "Resolve invariant violation; item excluded from match",
                tostring(c.resolve_item_id))
        end
        local pos_ambiguous
        pos_matched, pos_ambiguous = match_by_position(
            unsettled, items_by_pos, settled, already_claimed)
        for _, a in ipairs(pos_ambiguous) do
            ambiguous[#ambiguous + 1] = a
        end
    end
    local unmatched = build_unmatched_list(
        jve_clips, id_matched, marker_matched, content_matched, pos_matched)
    return {
        id_matched      = id_matched,
        marker_matched  = marker_matched,
        content_matched = content_matched,
        pos_matched     = pos_matched,
        ambiguous       = ambiguous,
        unmatched       = unmatched,
    }
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

-- Verify the JVE sequence has the fields the rate-mismatch guard needs.
-- Position-match keys on (track_type, track_index, record_start) which is
-- rate-relative — if rates disagree the same numeric record_start refers
-- to different real times on each side and matches go silently wrong.
local function assert_sequence_shape(seq, sequence_id)
    assert(seq, "discovery: sequence not found: " .. tostring(sequence_id))
    assert(seq.mutation_generation,
        "discovery: sequence missing mutation_generation (schema V12+, FU-2)")
    assert(type(seq.frame_rate) == "table"
        and type(seq.frame_rate.fps_numerator) == "number"
        and seq.frame_rate.fps_numerator > 0
        and type(seq.frame_rate.fps_denominator) == "number"
        and seq.frame_rate.fps_denominator > 0,
        "discovery: sequence missing frame_rate.fps_*")
end

-- Returns nil when the JVE sequence's integer TC rate agrees with the
-- Resolve timeline's, else a human-readable mismatch description. The
-- position channel must not run on a mismatch (silently wrong links);
-- policy on what to DO about it belongs to the caller.
-- If timeline_integer_rate is missing from the wire response (version skew),
-- skip the position channel conservatively rather than crashing JVE.
local function rate_mismatch_reason(seq, sequence_id, timeline_integer_rate)
    if type(timeline_integer_rate) ~= "number" or timeline_integer_rate <= 0 then
        return "helper did not send result.timeline_integer_rate "
            .. "(helper-protocol §read_timeline — version skew?); "
            .. "position channel skipped conservatively"
    end
    local jve_integer_rate = math.ceil(
        seq.frame_rate.fps_numerator / seq.frame_rate.fps_denominator)
    if jve_integer_rate == timeline_integer_rate then return nil end
    return string.format(
        "JVE sequence %s is at TC rate %d (%d/%d); Resolve timeline is "
        .. "at TC rate %d. Position match is rate-relative; only the "
        .. "marker channel ran.",
        sequence_id, jve_integer_rate,
        seq.frame_rate.fps_numerator, seq.frame_rate.fps_denominator,
        timeline_integer_rate)
end

-- Hashmap count (#t doesn't work on string-keyed tables).
local function table_len(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- Split this sequence's persisted links into live (item present in the
-- current read_timeline response — identity settled, item pre-claimed)
-- and dead (item gone — its clip re-enters the match channels; if the
-- colorist recreated it at the same position, position match re-links;
-- if not, it reports unmatched and the FR-013a stale walk covers its
-- grade). Returns (existing_by_clip, pre_claimed, live_count).
local function split_existing_links(sequence_id, db, timeline_items)
    local live_item_ids = {}
    for _, item in ipairs(timeline_items) do
        live_item_ids[item.resolve_item_id] = true
    end
    local existing_by_clip, pre_claimed, live_count = {}, {}, 0
    for _, link in ipairs(
            identity_ledger.iter_links_for_sequence(sequence_id, db)) do
        if live_item_ids[link.resolve_item_id] then
            existing_by_clip[link.clip_id] = link.resolve_item_id
            pre_claimed[link.resolve_item_id] = true
            live_count = live_count + 1
        end
    end
    return existing_by_clip, pre_claimed, live_count
end

-- Asynchronously stamp customData markers on each newly matched, NOT-
-- self-anchored (clip_id, resolve_item_id) pair — content and position
-- matches (id and marker matches already carry their own anchor) — using
-- the helper's stamp_identity_marker verb (FR-012 durability — see module
-- docstring "Auto-stamping"). Each stamp is one helper roundtrip,
-- fanned in sequence to keep result accumulation simple. Calls
-- `done(stamped, skipped, failures)`:
--   stamped:  [{clip_id, resolve_item_id}] freshly stamped
--   skipped:  [{clip_id, resolve_item_id}] already carried the same
--             customData (idempotent no-op)
--   failures: [{clip_id, resolve_item_id, code, message}] for stamps
--             the helper refused (conflicting customData, etc.) —
--             surfaced verbatim, never silenced (rule 2.32); the
--             ledger link still works without the marker.
local function stamp_unanchored_matches(client, token, unanchored, done)
    local pairs_list = {}
    for clip_id, resolve_item_id in pairs(unanchored) do
        pairs_list[#pairs_list + 1] = {
            clip_id         = clip_id,
            resolve_item_id = resolve_item_id,
        }
    end
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
            elseif type(response.result) ~= "table" then
                failures[#failures + 1] = {
                    clip_id         = pair.clip_id,
                    resolve_item_id = pair.resolve_item_id,
                    code            = "bad_response",
                    message         = "stamp_identity_marker: response.result missing",
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

--- Emit log.warn lines for non-fatal discovery conditions (rate mismatch,
--- ambiguous matches, stamp failures). Called by SyncGradesFromResolve and
--- SyncEditsFromResolve after discover_and_link succeeds.
--- caller_prefix: short op name, e.g. "SyncGradesFromResolve".
function M.log_discovery_warnings(report, caller_prefix)
    assert(type(report) == "table",
        "discovery.log_discovery_warnings: report required")
    assert(type(caller_prefix) == "string" and caller_prefix ~= "",
        "discovery.log_discovery_warnings: caller_prefix required")
    if report.rate_mismatch ~= nil then
        log.warn("%s discovery: %s", caller_prefix, report.rate_mismatch)
    end
    if #report.ambiguous > 0 then
        -- Histogram by reason so the WARN (on by default) names WHICH
        -- bucket the clips fell into — a bare count can't distinguish a
        -- per-clip content_mismatch from a per-item-pair
        -- position_key_collision, and the reason is the load-bearing
        -- fact for diagnosis (rule 2.32).
        local by_reason = {}
        for _, a in ipairs(report.ambiguous) do
            by_reason[a.reason] = (by_reason[a.reason] or 0) + 1
        end
        local parts = {}
        for reason, n in pairs(by_reason) do
            parts[#parts + 1] = string.format("%s=%d", reason, n)
        end
        table.sort(parts)
        log.warn("%s discovery: %d ambiguous match(es) [%s] — those clips "
            .. "stay unlinked; see result.discovery.ambiguous",
            caller_prefix, #report.ambiguous, table.concat(parts, ", "))
        -- Surface one content_mismatch sample so the WARN names the
        -- diverging field + both sides' values (rule 2.32 — diagnosis
        -- needs the actual values, not just the bucket).
        local field_combo, source_in_deltas, sample = {}, {}, nil
        for _, a in ipairs(report.ambiguous) do
            if a.reason == "content_mismatch" then
                sample = sample or a
                local combo = table.concat(a.mismatch_fields or {}, ",")
                field_combo[combo] = (field_combo[combo] or 0) + 1
                if type(a.jve_source_in) == "number"
                    and type(a.resolve_source_in) == "number" then
                    local d = a.jve_source_in - a.resolve_source_in
                    source_in_deltas[d] = (source_in_deltas[d] or 0) + 1
                end
            end
        end
        local combo_parts = {}
        for combo, n in pairs(field_combo) do
            combo_parts[#combo_parts + 1] = string.format("{%s}=%d", combo, n)
        end
        table.sort(combo_parts)
        local delta_parts = {}
        for d, n in pairs(source_in_deltas) do
            delta_parts[#delta_parts + 1] = string.format("%+d:%d", d, n)
        end
        table.sort(delta_parts)
        log.warn("%s discovery: content_mismatch field combos [%s]; "
            .. "source_in (jve-resolve) delta histogram [%s]",
            caller_prefix, table.concat(combo_parts, ", "),
            table.concat(delta_parts, ", "))
        if sample then
            log.warn("%s discovery: content_mismatch sample clip=%s "
                .. "source_in(jve=%s resolve=%s) media_path(jve=%q)",
                caller_prefix, tostring(sample.clip_id),
                tostring(sample.jve_source_in),
                tostring(sample.resolve_source_in),
                tostring(sample.jve_media_path))
        end
    end
    if #report.stamp_failures > 0 then
        log.warn("%s discovery: %d identity-marker stamp(s) refused — links "
            .. "work but won't survive Resolve-side cuts; "
            .. "see result.discovery.stamp_failures",
            caller_prefix, #report.stamp_failures)
    end
end

--- Run full identity discovery against the live Resolve timeline:
--- read_identities + read_timeline → existing-link split → match the
--- rest → ledger upserts → auto-stamp new position matches. The
--- marker stamps are the only Resolve-side mutation; everything else
--- is read-only, and the ledger writes are idempotent.
---
--- `on_done(report)` on success, `on_done(nil, code, message)` on
--- helper error. The report carries:
---   • matched:   [{clip_id, resolve_item_id, source}] NEW links
---     persisted this run (existing live links are settled identity,
---     not re-reported)
---   • already_linked: count of clips whose persisted link points at a
---     live item (skipped the channels, items pre-claimed)
---   • marker_matched / content_matched / pos_matched: the raw new-
---     channel maps
---   • unmatched / ambiguous / audio_skipped: per M.match +
---     load_jve_clips_for_sequence
---   • rate_mismatch: nil, or the reason string when the position
---     channel was skipped (marker channel still ran)
---   • stamped / stamp_skipped / stamp_failures: auto-stamp accounting
---     (see stamp_new_position_matches)
---   • sequence: the loaded Sequence
---   • read_timeline_result: the raw helper §read_timeline result, so
---     a sync that needs the live timeline (SyncEditsFromResolve)
---     reuses it instead of paying a second roundtrip
function M.discover_and_link(client, sequence_id, db, on_done)
    assert(client, "discovery.discover_and_link: client required")
    assert(type(sequence_id) == "string" and sequence_id ~= "",
        "discovery.discover_and_link: sequence_id required")
    assert(db, "discovery.discover_and_link: db required")
    assert(type(on_done) == "function",
        "discovery.discover_and_link: on_done callback required")

    local jve_clips, audio_skipped =
        M.load_jve_clips_for_sequence(sequence_id, db)
    local seq = Sequence.load(sequence_id)
    assert_sequence_shape(seq, sequence_id)
    assert(type(seq.project_id) == "string" and seq.project_id ~= "",
        "discovery: sequence missing project_id (schema invariant)")

    client:request("read_identities", {}, function(idr, code1, msg1)
        if idr == nil then on_done(nil, code1, msg1); return end
        client:request("read_timeline", {}, function(rtr, code2, msg2)
            if rtr == nil then on_done(nil, code2, msg2); return end
            local mismatch = rate_mismatch_reason(
                seq, sequence_id, rtr.result.timeline_integer_rate)
            local existing_by_clip, pre_claimed, already_linked =
                split_existing_links(sequence_id, db, rtr.result.items)
            local clips_to_match = {}
            for _, c in ipairs(jve_clips) do
                if existing_by_clip[c.id] == nil then
                    clips_to_match[#clips_to_match + 1] = c
                end
            end
            -- The direct-id and marker channels are rate-independent, so
            -- they always run on the full item list; only the position
            -- channel is skipped on a TC-rate mismatch (record_start is
            -- rate-relative). Never silently position-match across rates.
            local matched = M.match(clips_to_match, idr.result.items,
                rtr.result.items, pre_claimed, mismatch ~= nil)
            local matched_log = {}
            -- id_matched: clip.id == resolve_item_id is the durable anchor
            -- itself, so it is persisted to the ledger but NOT stamped.
            -- The no-anchor matches (content + position) get a marker
            -- stamped below for FR-012 durability.
            persist_matches(matched.id_matched, db,
                "direct_id", matched_log)
            persist_matches(matched.marker_matched, db,
                "marker", matched_log)
            persist_matches(matched.content_matched, db,
                "content_match", matched_log)
            persist_matches(matched.pos_matched, db,
                "position_match", matched_log)
            log.event("discovery: %d already linked, %d newly matched "
                .. "(%d id, %d marker, %d content, %d position), %d "
                .. "unmatched, %d ambiguous%s",
                already_linked, #matched_log,
                table_len(matched.id_matched),
                table_len(matched.marker_matched),
                table_len(matched.content_matched),
                table_len(matched.pos_matched),
                #matched.unmatched, #matched.ambiguous,
                mismatch and " [position channel skipped: rate mismatch]"
                    or "")
            local token = change_token.build(seq.project_id,
                sequence_id, seq.mutation_generation)
            -- Content + position matches are both anchored to WHERE/WHAT a
            -- clip is, not to a per-clip marker, so both get stamped.
            local unanchored = {}
            for cid, rid in pairs(matched.content_matched) do
                unanchored[cid] = rid
            end
            for cid, rid in pairs(matched.pos_matched) do
                unanchored[cid] = rid
            end
            stamp_unanchored_matches(client, token, unanchored,
                function(stamped, skipped, failures)
                    if #stamped + #skipped + #failures > 0 then
                        log.event("discovery: stamped %d marker(s), "
                            .. "%d already stamped, %d refused",
                            #stamped, #skipped, #failures)
                    end
                    on_done({
                        matched              = matched_log,
                        already_linked       = already_linked,
                        id_matched           = matched.id_matched,
                        marker_matched       = matched.marker_matched,
                        content_matched      = matched.content_matched,
                        pos_matched          = matched.pos_matched,
                        unmatched            = matched.unmatched,
                        ambiguous            = matched.ambiguous,
                        audio_skipped        = audio_skipped,
                        rate_mismatch        = mismatch,
                        stamped              = stamped,
                        stamp_skipped        = skipped,
                        stamp_failures       = failures,
                        sequence             = seq,
                        read_timeline_result = rtr.result,
                    })
                end)
        end)
    end)
end

return M
