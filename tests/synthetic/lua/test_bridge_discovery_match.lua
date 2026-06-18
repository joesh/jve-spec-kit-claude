-- T049a (moved by connect fold) — discovery.match pure-data matcher
--           (spec 023, FR-011c).
--
-- Black-box: feed M.match a JVE-clip list, a helper read_identities
-- items array, and a helper read_timeline items array; assert the four
-- buckets (marker_matched, pos_matched, ambiguous, unmatched) match
-- domain expectations under each FR-011c scenario.
--
-- Match channels (FR-011c priority order):
--   (a) marker channel via read_identities (jve_guid recovered from
--       customData)
--   (b) position channel — (track_type, track_index, record_start)
--       triple match against read_timeline rows
--
-- This is pure-data; no DB connection, no helper running.

require("test_env")

local discovery = require("core.resolve_bridge.discovery")

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== discovery.match Tests ===")

-- Common shape helpers.
local function clip(id, ti, rec_start, src_in, src_out)
    return {
        id              = id,
        name            = "C-" .. id,
        track_id        = "v" .. ti,
        track_type      = "video",
        track_index     = ti,
        sequence_start  = rec_start,
        duration        = (src_out - src_in),
        source_in       = src_in,
        source_out      = src_out,
        media_file_path = "/path/to/" .. id .. ".mov",
    }
end

local function tl_item(rid, ti, rec_start, dur, src_in, src_out, clip_id)
    -- Derive expected content keys from clip_id for the happy path
    local c_id = clip_id or rid
    return {
        resolve_item_id = rid,
        kind            = "media",
        track_type      = "video",
        track_index     = ti,
        record_start    = rec_start,
        record_duration = dur,
        source_in       = src_in,
        source_out      = src_out,
        enabled         = true,
        name            = "C-" .. c_id,
        media_file_path = "/path/to/" .. c_id .. ".mov",
    }
end

-- Non-media timeline items (generators, transitions, adjustment clips,
-- some Fusion comps) — helper omits source_in/source_out because there's
-- no indexable source frame range. Matcher must skip these BEFORE
-- applying the position-match key (otherwise a non_media item at the
-- same (track, record_start) as a JVE clip would falsely match).
local function tl_item_non_media(rid, ti, rec_start, dur)
    return {
        resolve_item_id = rid,
        kind            = "non_media",
        track_type      = "video",
        track_index     = ti,
        record_start    = rec_start,
        record_duration = dur,
        enabled         = true,
    }
end

local function id_item(rid, jve_guid)
    return { resolve_item_id = rid, jve_guid = jve_guid }
end

-- Content-channel shapes: a JVE clip carrying its source-clip identity
-- (master.import_uuid) and a Resolve media item carrying the same pool
-- MediaRef identity. content_match keys on identity + source-TC overlap,
-- independent of record position (a moved clip keeps its identity).
local function clip_u(id, ti, rec_start, src_in, src_out, import_uuid)
    local c = clip(id, ti, rec_start, src_in, src_out)
    c.import_uuid = import_uuid
    return c
end

local function tl_item_u(rid, ti, rec_start, dur, src_in, src_out,
                          clip_id, import_uuid)
    local t = tl_item(rid, ti, rec_start, dur, src_in, src_out, clip_id)
    t.import_uuid = import_uuid
    return t
end

-- ── Scenario 1: pure marker matches ─────────────────────────────────
do
    local jve_clips = {
        clip("c_a", 1, 0,   0, 100),
        clip("c_b", 1, 100, 0, 100),
    }
    -- Resolve has both items, each marker-stamped with its JVE clip id.
    local identities = {
        id_item("R1", "c_a"),
        id_item("R2", "c_b"),
    }
    local timeline = {
        tl_item("R1", 1, 0,   100, 0, 100, "c_a"),
        tl_item("R2", 1, 100, 100, 0, 100, "c_b"),
    }
    local m = discovery.match(jve_clips, identities, timeline)
    check("scenario 1: marker_matched c_a → R1",
        m.marker_matched["c_a"] == "R1")
    check("scenario 1: marker_matched c_b → R2",
        m.marker_matched["c_b"] == "R2")
    check("scenario 1: no pos_matched (already covered by marker)",
        next(m.pos_matched) == nil)
    check("scenario 1: zero unmatched",  #m.unmatched == 0)
    check("scenario 1: zero ambiguous",  #m.ambiguous == 0)
end

-- ── Scenario 2: position match only (no markers stamped yet) ────────
do
    local jve_clips = {
        clip("c_a", 1, 0,   0, 100),
        clip("c_b", 2, 100, 0, 100),  -- different track
    }
    local identities = {}  -- no markers stamped yet (first-connect)
    local timeline = {
        tl_item("R1", 1, 0,   100, 0, 100, "c_a"),
        tl_item("R2", 2, 100, 100, 0, 100, "c_b"),
    }
    local m = discovery.match(jve_clips, identities, timeline)
    check("scenario 2: marker_matched empty",
        next(m.marker_matched) == nil)
    check("scenario 2: pos_matched c_a → R1",
        m.pos_matched["c_a"] == "R1")
    check("scenario 2: pos_matched c_b → R2",
        m.pos_matched["c_b"] == "R2")
    check("scenario 2: zero unmatched",  #m.unmatched == 0)
end

-- ── Scenario 3: mixed (some marker-anchored, some first-connect) ────
do
    local jve_clips = {
        clip("c_marked", 1, 0,   0, 100),
        clip("c_pos",    1, 100, 0, 100),
    }
    local identities = { id_item("R_m", "c_marked") }
    local timeline = {
        tl_item("R_m", 1, 0,   100, 0, 100, "c_marked"),
        tl_item("R_p", 1, 100, 100, 0, 100, "c_pos"),
    }
    local m = discovery.match(jve_clips, identities, timeline)
    check("scenario 3: c_marked via marker",
        m.marker_matched["c_marked"] == "R_m")
    check("scenario 3: c_pos via position",
        m.pos_matched["c_pos"] == "R_p")
    check("scenario 3: zero unmatched",  #m.unmatched == 0)
end

-- ── Scenario 4: JVE clip with no Resolve counterpart → unmatched ────
do
    local jve_clips = {
        clip("c_a",       1, 0,   0, 100),
        clip("c_orphan",  1, 500, 0, 100),  -- no Resolve item here
    }
    local identities = {}
    local timeline = {
        tl_item("R1", 1, 0, 100, 0, 100, "c_a"),
    }
    local m = discovery.match(jve_clips, identities, timeline)
    check("scenario 4: c_a position-matched",
        m.pos_matched["c_a"] == "R1")
    check("scenario 4: c_orphan listed in unmatched",
        m.unmatched[1] and m.unmatched[1].clip_id == "c_orphan")
    check("scenario 4: unmatched carries clip_name",
        m.unmatched[1] and m.unmatched[1].clip_name == "C-c_orphan")
end

-- ── Scenario 5: marker claims a Resolve item; another JVE clip
--    occupies the same position → ambiguous, NOT silently overwriting ─
do
    local jve_clips = {
        clip("c_marker", 1, 0, 0, 100),
        clip("c_pos",    1, 0, 0, 100),  -- same position as c_marker
    }
    local identities = { id_item("R_shared", "c_marker") }
    local timeline = {
        tl_item("R_shared", 1, 0, 100, 0, 100, "c_marker"),
    }
    local m = discovery.match(jve_clips, identities, timeline)
    check("scenario 5: c_marker via marker",
        m.marker_matched["c_marker"] == "R_shared")
    check("scenario 5: c_pos NOT pos_matched (R_shared already claimed)",
        m.pos_matched["c_pos"] == nil)
    -- c_pos position-key hits R_shared which is already_claimed →
    -- surfaces as ambiguous with the documented reason.
    local found = false
    for _, a in ipairs(m.ambiguous) do
        if a.clip_id == "c_pos"
            and a.resolve_item_id == "R_shared"
            and a.reason == "position_match_already_claimed" then
            found = true
        end
    end
    check("scenario 5: c_pos surfaced as ambiguous "
        .. "(position_match_already_claimed)", found)
end

-- ── Scenario 6: read_identities returns a jve_guid that names a clip
--    OUTSIDE this sequence → silently ignored (no false claim) ───────
do
    local jve_clips = {
        clip("c_in_seq", 1, 0, 0, 100),
    }
    local identities = {
        id_item("R_strange", "some_other_sequences_clip_id"),
    }
    local timeline = {
        tl_item("R_strange", 1, 0, 100, 0, 100, "c_in_seq"),
    }
    local m = discovery.match(jve_clips, identities, timeline)
    -- The cross-sequence jve_guid is not used for any clip in this
    -- sequence's match list. R_strange becomes a position match for
    -- c_in_seq instead (since R_strange isn't claimed by any marker
    -- IN-sequence).
    check("scenario 6: cross-sequence jve_guid ignored "
        .. "(not claimed by in-seq match)",
        m.marker_matched["c_in_seq"] == nil)
    check("scenario 6: c_in_seq position-matches R_strange",
        m.pos_matched["c_in_seq"] == "R_strange")
end

-- ── Scenario 7: non_media items are skipped before position match ──
do
    local jve_clips = {
        clip("c_a", 1, 0,   0, 100),
        clip("c_b", 1, 100, 0, 100),
    }
    local identities = {}
    -- A generator sits at the same (track, record_start) as c_a's
    -- intended position match. If the matcher didn't filter by kind,
    -- the position key would collide; with kind filtering, the
    -- generator is invisible to position match and c_a position-matches
    -- the real media item.
    local timeline = {
        tl_item_non_media("R_gen", 1, 0, 50),   -- generator at (V1, 0)
        tl_item("R_a", 1, 0,   100, 0, 100, "c_a"),    -- real media at (V1, 0)
        tl_item("R_b", 1, 100, 100, 0, 100, "c_b"),    -- real media at (V1, 100)
    }
    local m = discovery.match(jve_clips, identities, timeline)
    check("scenario 7: c_a position-matches the media item, not generator",
        m.pos_matched["c_a"] == "R_a")
    check("scenario 7: c_b position-matches",
        m.pos_matched["c_b"] == "R_b")
    check("scenario 7: zero unmatched",   #m.unmatched  == 0)
    check("scenario 7: zero ambiguous",   #m.ambiguous  == 0)
end

-- ── Scenario 7b: two non_media items at the SAME position do NOT
--    trip the duplicate-position-key assert. The assert exists to
--    catch Resolve invariant breaks among matchable items; two
--    generators stacked at the same record_start is a normal user
--    timeline (composited title over a transition, etc.). ─────────────
do
    local jve_clips = { clip("c_a", 1, 100, 0, 100) }
    local identities = {}
    local timeline = {
        tl_item_non_media("R_gen1", 1, 0, 50),
        tl_item_non_media("R_gen2", 1, 0, 50),  -- same position, ok
        tl_item("R_a", 1, 100, 100, 0, 100, "c_a"),
    }
    local m = discovery.match(jve_clips, identities, timeline)
    check("scenario 7b: stacked non_media at same pos does not assert",
        m.pos_matched["c_a"] == "R_a")
end

-- ── Scenario 7c: items with missing/unknown `kind` must NOT crash JVE
--    (external Resolve wire data; rule 1.14). They must route to
--    ambiguous with a reason that names "kind" (rule 2.32: no silent
--    failure — the protocol violation surfaces in the report). ─────────
do
    local jve_clips = { clip("c_a", 1, 0, 0, 100) }
    local identities = {}
    local bad_item = {
        resolve_item_id = "R_bad",
        -- kind omitted — simulates protocol violation from helper
        track_type      = "video",
        track_index     = 1,
        record_start    = 0,
        record_duration = 100,
        source_in       = 0,
        source_out      = 100,
        enabled         = true,
    }
    local ok, result = pcall(discovery.match, jve_clips, identities, { bad_item })
    check("scenario 7c: missing kind does not crash (wire data → ambiguous)",
        ok == true)
    check("scenario 7c: bad-kind item lands in ambiguous",
        ok and #result.ambiguous >= 1)
    check("scenario 7c: ambiguous reason names 'kind'",
        ok and result.ambiguous[1] and
        tostring(result.ambiguous[1].reason):find("kind", 1, true) ~= nil)
end

-- ── Scenario 8: Content mismatch (name, media_file_path, source_in).
--    If an item sits at the correct position but the content doesn't
--    match, it surfaces as ambiguous (content_mismatch). ──────────────
do
    local jve_clips = {
        clip("c_a", 1, 0, 0, 100),
    }
    local identities = {}
    local timeline = {
        tl_item("R_mismatch", 1, 0, 100, 0, 100, "c_different"),
    }
    local m = discovery.match(jve_clips, identities, timeline)
    check("scenario 8: content mismatch is NOT pos_matched",
        m.pos_matched["c_a"] == nil)
    
    local found = false
    for _, a in ipairs(m.ambiguous) do
        if a.clip_id == "c_a"
            and a.resolve_item_id == "R_mismatch"
            and a.reason == "content_mismatch" then
            found = true
        end
    end
    check("scenario 8: c_a surfaced as ambiguous (content_mismatch)", found)
end

-- ── Scenario 9: pre-claimed items (existing ledger links) ───────────
-- A clip already linked to a live item never enters the channels; its
-- item is pre-claimed. Another clip landing on that item by position
-- must NOT steal it — it surfaces as ambiguous, never silently linked.
do
    local jve_clips = { clip("c_new", 1, 0, 0, 100) }
    local identities = {}
    -- The live item at c_new's position belongs to an existing link
    -- (different clip). Content keys even "match" — claim still wins.
    local timeline = {
        tl_item("R_taken", 1, 0, 100, 0, 100, "c_new"),
    }
    local m = discovery.match(jve_clips, identities, timeline,
        { R_taken = true })
    check("scenario 9: pre-claimed item is not position-matched",
        m.pos_matched["c_new"] == nil)
    local found = false
    for _, a in ipairs(m.ambiguous) do
        if a.clip_id == "c_new" and a.resolve_item_id == "R_taken"
            and a.reason == "position_match_already_claimed" then
            found = true
        end
    end
    check("scenario 9: surfaced as position_match_already_claimed", found)
    check("scenario 9: clip reported unmatched", #m.unmatched == 1
        and m.unmatched[1].clip_id == "c_new")
end

-- ── Scenario 10: marker names a clip on a pre-claimed item ──────────
-- The persisted ledger says the item belongs to some OTHER clip, but
-- its marker names this one — conflicting identity sources. Reported,
-- never silently resolved either way (rule 2.32).
do
    local jve_clips = { clip("c_marked", 1, 0, 0, 100) }
    local identities = {
        { resolve_item_id = "R_owned", jve_guid = "c_marked" },
    }
    local m = discovery.match(jve_clips, identities, {},
        { R_owned = true })
    check("scenario 10: conflicting marker is not marker_matched",
        m.marker_matched["c_marked"] == nil)
    local found = false
    for _, a in ipairs(m.ambiguous) do
        if a.clip_id == "c_marked" and a.resolve_item_id == "R_owned"
            and a.reason == "marker_conflicts_existing_link" then
            found = true
        end
    end
    check("scenario 10: surfaced as marker_conflicts_existing_link", found)
end

-- ── Scenario 11: direct-id channel — clip.id == resolve_item_id ──────
-- A clip imported from a DRP exported off this Resolve project carries
-- the Resolve timeline-item id as its own clip.id (Sm2Ti DbId adopted on
-- import == live GetUniqueId for a consistent export — inbound-findings
-- §2). That id equality IS the identity — the strongest, rate-
-- independent signal. It must link EVEN WHEN name and source_in diverge
-- (those are representation, not identity: absolute-TC vs media-relative
-- source_in, custom vs media name).
do
    local jve_clips = {
        clip("ID-MATCH-1", 1, 5000, 99, 200),  -- source_in=99, name "C-ID-MATCH-1"
    }
    local identities = {}  -- no markers stamped
    local timeline = {
        {
            resolve_item_id = "ID-MATCH-1",      -- SAME as clip.id
            kind            = "media",
            track_type      = "video",
            track_index     = 1,
            record_start    = 5000,
            record_duration = 100,
            source_in       = 0,                  -- diverges from clip.source_in=99
            source_out      = 100,
            enabled         = true,
            name            = "Totally Different Label",  -- diverges from clip.name
            media_file_path = "/some/other/path.mov",     -- diverges too
        },
    }
    local m = discovery.match(jve_clips, identities, timeline)
    check("scenario 11: clip.id == resolve_item_id links via id channel",
        m.id_matched and m.id_matched["ID-MATCH-1"] == "ID-MATCH-1")
    check("scenario 11: id match wins despite name/source_in/path divergence",
        #m.ambiguous == 0)
    check("scenario 11: id-matched clip is not unmatched",
        #m.unmatched == 0)
    check("scenario 11: id match does not also double-count as position",
        m.pos_matched["ID-MATCH-1"] == nil)
end

-- ── Scenario 12: id channel beats marker when both present ───────────
-- If a clip both has clip.id == an item id AND a marker naming it, the
-- direct-id channel claims it (highest priority); it must not be double-
-- reported or marked ambiguous.
do
    local jve_clips = { clip("DUAL", 1, 0, 0, 100) }
    local identities = { id_item("DUAL", "DUAL") }  -- marker on item "DUAL" naming clip "DUAL"
    local timeline = {
        tl_item("DUAL", 1, 0, 100, 0, 100, "DUAL"),
    }
    local m = discovery.match(jve_clips, identities, timeline)
    check("scenario 12: id channel links DUAL",
        m.id_matched and m.id_matched["DUAL"] == "DUAL")
    check("scenario 12: no ambiguity from id+marker overlap",
        #m.ambiguous == 0)
    check("scenario 12: clip not left unmatched",
        #m.unmatched == 0)
end

-- ── Scenario 13: content channel — a moved clip keeps its identity ───
-- The colorist moved a clip to a new record position; the position key no
-- longer hits. But the clip's source-clip identity (import_uuid) plus an
-- overlapping source-TC range identify it unambiguously. content_match
-- links it where position cannot.
do
    local jve_clips = {
        clip_u("c_moved", 1, 0, 10, 110, "U-src"),
    }
    local identities = {}
    local timeline = {
        -- Same identity, moved to record_start 900 (position key (video,1,0)
        -- misses), source range overlaps the clip's [10,110).
        tl_item_u("R_moved", 1, 900, 100, 5, 120, "c_moved", "U-src"),
    }
    local m = discovery.match(jve_clips, identities, timeline)
    check("scenario 13: c_moved content-matches R_moved",
        m.content_matched and m.content_matched["c_moved"] == "R_moved")
    check("scenario 13: not position-matched (it moved)",
        m.pos_matched["c_moved"] == nil)
    check("scenario 13: zero unmatched", #m.unmatched == 0)
    check("scenario 13: zero ambiguous", #m.ambiguous == 0)
end

-- ── Scenario 14: content BEATS position on disagreement ──────────────
-- The clip moved (its true item is elsewhere, identity U). A DECOY item
-- with identical content keys (name/source_in/path) but a DIFFERENT
-- identity sits at the clip's old position — position alone would link the
-- clip to the decoy. Because content runs first, the clip follows its
-- source identity to the moved item, and the decoy is left for no one.
do
    local jve_clips = {
        clip_u("c", 1, 0, 10, 110, "U-true"),
    }
    local identities = {}
    local timeline = {
        tl_item_u("R_true",  1, 900, 200, 0, 200, "c", "U-true"),  -- moved, real
        tl_item_u("R_decoy", 1, 0,   100, 10, 110, "c", "V-other"), -- old slot, wrong source
    }
    local m = discovery.match(jve_clips, identities, timeline)
    check("scenario 14: clip follows identity to the moved item",
        m.content_matched and m.content_matched["c"] == "R_true")
    check("scenario 14: clip is NOT position-matched to the decoy",
        m.pos_matched["c"] == nil)
    check("scenario 14: zero unmatched (clip settled by content)",
        #m.unmatched == 0)
end

-- ── Scenario 15: same identity, two overlapping items → ambiguous ────
-- A source clip used twice on the Resolve timeline yields two items with
-- the same identity, both overlapping the clip's source TC. content_match
-- cannot pick one — it reports ambiguous (duplicate_identity_content),
-- never silently chooses (rule 2.32). With no position hit either, the
-- clip is reported unmatched.
do
    local jve_clips = {
        clip_u("c", 1, 777, 10, 110, "U-dup"),  -- record_start 777: no position hit
    }
    local identities = {}
    local timeline = {
        tl_item_u("R_a", 1, 100, 200, 0,  200, "c", "U-dup"),
        tl_item_u("R_b", 1, 300, 100, 50, 150, "c", "U-dup"),
    }
    local m = discovery.match(jve_clips, identities, timeline)
    check("scenario 15: not content-matched (ambiguous identity)",
        m.content_matched["c"] == nil)
    local dup = 0
    for _, a in ipairs(m.ambiguous) do
        if a.clip_id == "c" and a.reason == "duplicate_identity_content" then
            dup = dup + 1
        end
    end
    check("scenario 15: both items reported duplicate_identity_content",
        dup == 2)
    check("scenario 15: clip reported unmatched", #m.unmatched == 1
        and m.unmatched[1].clip_id == "c")
end

-- ── Scenario 16: content channel is rate-independent ─────────────────
-- On a TC-rate mismatch the position channel is skipped (record_start is
-- rate-relative). content_match keys on source TC + identity, not
-- record_start, so it STILL recovers a moved clip's link even when
-- position cannot run.
do
    local jve_clips = {
        clip_u("c_moved", 1, 0, 10, 110, "U-src"),
    }
    local identities = {}
    local timeline = {
        tl_item_u("R_moved", 1, 900, 100, 5, 120, "c_moved", "U-src"),
    }
    local m = discovery.match(jve_clips, identities, timeline, nil, true)
    check("scenario 16: content-matches even with position skipped",
        m.content_matched and m.content_matched["c_moved"] == "R_moved")
    check("scenario 16: position channel produced nothing",
        next(m.pos_matched) == nil)
end

-- ── Scenario 17: no source identity → falls through to position ───────
-- A native/compound clip carries no import_uuid. The content channel must
-- ignore it (not crash on nil) and let the position channel match it.
do
    local jve_clips = {
        clip_u("c_native", 1, 0, 0, 100, nil),
    }
    local identities = {}
    local timeline = {
        tl_item("R1", 1, 0, 100, 0, 100, "c_native"),  -- no import_uuid
    }
    local m = discovery.match(jve_clips, identities, timeline)
    check("scenario 17: nil-identity clip not content-matched",
        m.content_matched["c_native"] == nil)
    check("scenario 17: position channel matches it",
        m.pos_matched["c_native"] == "R1")
    check("scenario 17: zero unmatched", #m.unmatched == 0)
end

-- ── Scenario 18: id channel still beats content ──────────────────────
-- A clip whose id == a live item id AND whose identity matches another
-- item must link via the direct-id channel; content must not double-claim.
do
    local jve_clips = {
        clip_u("DID", 1, 0, 10, 110, "U-src"),
    }
    local identities = {}
    local timeline = {
        tl_item_u("DID",     1, 0,   100, 10, 110, "DID", "U-src"),  -- id match
        tl_item_u("R_other", 1, 500, 100, 0,  200, "DID", "U-src"),  -- same identity
    }
    local m = discovery.match(jve_clips, identities, timeline)
    check("scenario 18: links via direct-id channel",
        m.id_matched and m.id_matched["DID"] == "DID")
    check("scenario 18: content channel does not also claim it",
        m.content_matched["DID"] == nil)
    check("scenario 18: zero ambiguous", #m.ambiguous == 0)
    check("scenario 18: zero unmatched", #m.unmatched == 0)
end

-- ── Failure paths: validate args (rule 2.32) ────────────────────────
do
    local ok1 = pcall(discovery.match, nil, {}, {})
    check("match: asserts on nil jve_clips", not ok1)
    local ok2 = pcall(discovery.match, {}, nil, {})
    check("match: asserts on nil identities_items", not ok2)
    local ok3 = pcall(discovery.match, {}, {}, nil)
    check("match: asserts on nil timeline_items", not ok3)
end

-- ── Defensive: duplicate Resolve position-keys → ambiguous (not crash) ─
-- Two Resolve items at identical (track, record_start) violate Resolve's
-- own invariant but arrive as external wire data — must NOT crash the
-- sync. Both items route to report.ambiguous with reason
-- 'position_key_collision'; neither lands in pos_matched.
do
    local jve_clips = { clip("c_a", 1, 0, 0, 100) }
    local identities = {}
    local timeline = {
        tl_item("R1", 1, 0, 100, 0, 100, "c_a"),
        tl_item("R2", 1, 0, 100, 0, 100, "c_a"),  -- same (track, record_start)
    }
    local report = discovery.match(jve_clips, identities, timeline)
    check("duplicate position key: no crash (external data → ambiguous)",
        report ~= nil)
    check("duplicate position key: both items in ambiguous",
        #report.ambiguous == 2)
    check("duplicate position key: reason is position_key_collision",
        report.ambiguous[1] and
        report.ambiguous[1].reason == "position_key_collision")
    check("duplicate position key: pos_matched is empty",
        next(report.pos_matched) == nil)
end

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
assert(fail == 0, "test_bridge_discovery_match.lua: failures present")
print("✅ test_bridge_discovery_match.lua passed")
