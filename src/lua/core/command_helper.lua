--- Shared helper functions for command implementations.
local M = {}

local uuid = require("uuid")
local Clip = require("models.clip")
local Track = require("models.track")
local Sequence = require("models.sequence")
local Property = require("models.property")
local log = require("core.logger").for_area("commands")

local function lookup_track_sequence(track_id)
    if not track_id or track_id == "" then return nil end
    return Track.get_sequence_id(track_id)
end

-- Canonical clips-row INSERT, shared by the apply_mutations forward path
-- (batch INSERT for plan_insert mutations) and the undo-delete revert
-- path (one-off INSERT to restore a captured pre-delete snapshot). The
-- bind helper takes a normalized row table — each call site adapts its
-- own field naming into this shape so the column-order is single-sourced.
local CLIP_INSERT_SQL = [[
    INSERT INTO clips (
        id, project_id, name, track_id,
        owner_sequence_id, sequence_id,
        sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe,
        master_layer_track_id, master_audio_track_id,
        fps_mismatch_policy,
        enabled, volume, mark_in_frame, mark_out_frame, playhead_frame,
        created_at, modified_at
    )
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
]]

-- Bind a normalized clips row to a prepared CLIP_INSERT_SQL statement.
-- AUDIO/VIDEO subframe contract (V11 FR-005) is enforced upstream by
-- clip_mutator.plan_insert; this helper trusts the row shape and trips
-- only on the schema-required NOT NULLs that every clip must carry
-- regardless of track type.
local function bind_clip_insert(stmt, row)
    assert(stmt, "bind_clip_insert: stmt required")
    assert(row,  "bind_clip_insert: row required")
    local function required(field, value)
        assert(value ~= nil, string.format(
            "bind_clip_insert: row missing required field %q (clip id=%s)",
            field, tostring(row.id)))
        return value
    end
    stmt:bind_value(1,  required("id",                   row.id))
    stmt:bind_value(2,  required("project_id",           row.project_id))
    stmt:bind_value(3,  required("name",                 row.name))
    stmt:bind_value(4,  required("track_id",             row.track_id))
    stmt:bind_value(5,  required("owner_sequence_id",    row.owner_sequence_id))
    stmt:bind_value(6,  required("nested_sequence_id",   row.nested_sequence_id))
    stmt:bind_value(7,  required("sequence_start_frame", row.sequence_start_frame))
    stmt:bind_value(8,  required("duration_frames",      row.duration_frames))
    stmt:bind_value(9,  required("source_in_frame",      row.source_in_frame))
    stmt:bind_value(10, required("source_out_frame",     row.source_out_frame))
    stmt:bind_value(11, row.source_in_subframe)   -- AUDIO non-NULL / VIDEO NULL
    stmt:bind_value(12, row.source_out_subframe)  -- (enforced by plan_insert + schema)
    stmt:bind_value(13, row.master_layer_track_id)
    stmt:bind_value(14, row.master_audio_track_id)
    stmt:bind_value(15, required("fps_mismatch_policy", row.fps_mismatch_policy))
    stmt:bind_value(16, required("enabled",             row.enabled))
    stmt:bind_value(17, required("volume",              row.volume))
    if row.mark_in_frame  ~= nil then stmt:bind_value(18, row.mark_in_frame)  end
    if row.mark_out_frame ~= nil then stmt:bind_value(19, row.mark_out_frame) end
    stmt:bind_value(20, required("playhead_frame", row.playhead_frame))
    stmt:bind_value(21, required("created_at",     row.created_at))
    stmt:bind_value(22, required("modified_at",    row.modified_at))
end

function M.resolve_active_sequence_id(sequence_id_param, timeline_state)
    if sequence_id_param and sequence_id_param ~= "" then
        return sequence_id_param
    end
    if timeline_state and timeline_state.get_tab_strip then
        local ok, seq = pcall(function()
            return timeline_state.get_tab_strip():active_sequence_id()
        end)
        if ok and seq and seq ~= "" then
            return seq
        end
    end
    return nil
end

--- Resolve target clips at playhead using selection-aware two-tier logic.
-- 1. If clips are selected AND any intersect playhead → those clips
--    (selection is explicit user intent — trumps the autoselect filter)
-- 2. Otherwise → all clips at playhead on tracks with autoselect=1
--    (spec 015 §F4 / spec 019 §FR-024 — the canonical "which clip does
--    the user mean under the playhead" policy honors the track-arm toggle)
-- Returns target_clips (may be empty), playhead (integer frames).
function M.resolve_clips_at_playhead()
    local timeline_state = require("ui.timeline.timeline_state")

    local playhead = timeline_state.get_playhead_position()
    assert(type(playhead) == "number", "resolve_clips_at_playhead: playhead must be integer")

    local strip = timeline_state.get_tab_strip()

    local function filter_autoselect(clips)
        local kept = {}
        for _, c in ipairs(clips) do
            local track = timeline_state.get_track_by_id(c.track_id)
            assert(track, string.format(
                "resolve_clips_at_playhead: track %s not found for clip %s",
                tostring(c.track_id), tostring(c.id)))
            if track.autoselect then
                kept[#kept + 1] = c
            end
        end
        return kept
    end

    local selected = timeline_state.get_selected_clips()
    local target_clips

    if selected and #selected > 0 then
        target_clips = strip:clips_at_time(playhead, selected)
        if #target_clips == 0 then
            target_clips = filter_autoselect(strip:clips_at_time(playhead))
        end
    else
        target_clips = filter_autoselect(strip:clips_at_time(playhead))
    end

    return target_clips, playhead
end

--- Pick best clip from candidates: video trumps audio, then topmost track_index.
-- @param candidates array of clip tables (must have track_id)
-- @return best clip table
function M.pick_best_clip(candidates)
    local timeline_state = require("ui.timeline.timeline_state")
    assert(#candidates > 0, "pick_best_clip: candidates must be non-empty")

    local function track_info(clip)
        assert(clip.track_id, string.format(
            "pick_best_clip: clip %s has no track_id", tostring(clip.id)))
        local track = timeline_state.get_track_by_id(clip.track_id)
        assert(track, string.format(
            "pick_best_clip: track %s not found for clip %s",
            tostring(clip.track_id), tostring(clip.id)))
        return track.track_index, track.track_type
    end

    local video_clips = {}
    local audio_clips = {}
    for _, clip in ipairs(candidates) do
        local _, track_type = track_info(clip)
        if track_type == "VIDEO" then
            video_clips[#video_clips + 1] = clip
        else
            audio_clips[#audio_clips + 1] = clip
        end
    end

    local pool = #video_clips > 0 and video_clips or audio_clips
    local best = nil
    local best_index = -1
    for _, clip in ipairs(pool) do
        local idx = track_info(clip)
        if idx > best_index then
            best = clip
            best_index = idx
        end
    end
    return best
end

function M.trim_string(value)
    if type(value) ~= "string" then
        return ""
    end
    local stripped = value:match("^%s*(.-)%s*$")
    if stripped == nil then
        return ""
    end
    return stripped
end

function M.reload_timeline(sequence_id)
    local timeline_state_mod = package.loaded["ui.timeline.timeline_state"]
    if not timeline_state_mod or type(timeline_state_mod.reload_clips) ~= "function" then
        return
    end
    local target_sequence = sequence_id
    if not target_sequence or target_sequence == "" then
        target_sequence = timeline_state_mod.get_tab_strip():active_sequence_id()
    end
    if target_sequence and target_sequence ~= "" then
        timeline_state_mod.reload_clips(target_sequence)
    end
end

function M.ensure_timeline_mutation_bucket(command, sequence_id)
    if not sequence_id then
        local cmd_type = command and command.type or "unknown_command"
        error(string.format("%s: Missing sequence_id for timeline mutation bucket", tostring(cmd_type)), 2)
    end
    local mutations = command:get_parameter("__timeline_mutations")
    if not mutations then
        mutations = {}
        command:set_parameter("__timeline_mutations", mutations)
    elseif mutations.sequence_id or mutations.inserts or mutations.updates or mutations.deletes then
        local existing_bucket = mutations
        mutations = {[existing_bucket.sequence_id or sequence_id] = existing_bucket}
        command:set_parameter("__timeline_mutations", mutations)
    end

    if not mutations[sequence_id] then
        mutations[sequence_id] = {
            sequence_id = sequence_id,
            inserts = {},
            updates = {},
            deletes = {}
        }
    end
    return mutations[sequence_id]
end

function M.clip_update_payload(source, fallback_sequence_id)
    assert(source, "clip_update_payload: source is required")
    assert(source.id, "clip_update_payload: source.id is required")
    local track_sequence_id = source.owner_sequence_id or source.track_sequence_id or fallback_sequence_id
    assert(track_sequence_id, string.format("clip_update_payload: no sequence_id for clip %s", tostring(source.id)))
    local frame_rate = source.frame_rate
    assert(frame_rate
        and frame_rate.fps_numerator
        and frame_rate.fps_denominator,
        string.format("clip_update_payload: clip %s missing frame_rate table",
            tostring(source.id)))

    -- All coords must be integers (no Rational backward-compat)
    assert(type(source.sequence_start) == "number", string.format("clip_update_payload: sequence_start must be integer for clip %s", tostring(source.id)))
    assert(type(source.duration) == "number", string.format("clip_update_payload: duration must be integer for clip %s", tostring(source.id)))
    assert(type(source.source_in) == "number", string.format("clip_update_payload: source_in must be integer for clip %s", tostring(source.id)))
    assert(type(source.source_out) == "number", string.format("clip_update_payload: source_out must be integer for clip %s", tostring(source.id)))

    -- Mutation-payload shape matches clip-row shape (M4-real rename,
    -- 2026-05-27): the canonical names sequence_start / duration /
    -- source_in / source_out replace the pre-Rational-era _value suffix.
    return {
        clip_id = source.id,
        track_id = source.track_id,
        track_sequence_id = track_sequence_id,
        sequence_start = source.sequence_start,
        duration = source.duration,
        source_in = source.source_in,
        source_out = source.source_out,
        frame_rate = frame_rate,
        enabled = source.enabled ~= false
    }
end

-- NOTE: there is intentionally NO clip_insert_payload here. A timeline-cache
-- insert entry is always built by re-reading the just-written DB row via
-- _mutation_entry.build_insert_entry (-> database.load_clip_entry), the SAME
-- canonical builder db.load_clips uses. Hand-projecting a clip object into an
-- insert payload drifts whenever a clip column is added (it broke offline,
-- then label, then volume) — re-read instead.

function M.add_update_mutation(command, sequence_id, update)
    assert(update, "add_update_mutation: update payload is required")
    local bucket = M.ensure_timeline_mutation_bucket(command, sequence_id)
    if not bucket then
        return
    end

    -- Validate update mutation payload to catch incomplete undo mutations
    local function validate_update(entry)
        assert(entry.clip_id, "add_update_mutation: missing clip_id")
        -- Must have at least one updatable field — reject bare {clip_id = "..."} payloads
        local has_field = entry.sequence_start or entry.duration or entry.track_id
            or entry.source_in or entry.source_out
            or entry.enabled ~= nil or entry.name ~= nil
        if not has_field then
            error(string.format(
                "add_update_mutation: empty payload for clip %s - no updatable fields.",
                tostring(entry.clip_id)
            ), 2)
        end
    end

    if update[1] then
        for _, entry in ipairs(update) do
            validate_update(entry)
            table.insert(bucket.updates, entry)
        end
    else
        validate_update(update)
        table.insert(bucket.updates, update)
    end
    command:set_parameter("__timeline_mutations", command:get_parameter("__timeline_mutations"))
end

function M.add_insert_mutation(command, sequence_id, clip)
    assert(clip, "add_insert_mutation: clip payload is required")
    local bucket = M.ensure_timeline_mutation_bucket(command, sequence_id)
    if not bucket then
        return
    end

    -- Validate insert mutation payload at the executor boundary, INSIDE the
    -- active DB transaction. A shape bug here was the root cause of the
    -- audit pass 19f orphan-row contamination: MCTT emitted legacy
    -- `start_value`/`duration_value` field names; downstream UI processing
    -- (clip_geometry.normalize_clip_integers) asserts on canonical
    -- `sequence_start`/`duration`. The UI assert fires AFTER
    -- db_module.commit() — the orphan persists across the "failed" command
    -- and contaminates future runs. Catching here, before commit, makes
    -- rollback work correctly. Post-M4-real canonical shape (no `_value`
    -- aliases): id, track_id, sequence_start, duration.
    local function validate_insert(entry)
        assert(entry.id, "add_insert_mutation: missing id")
        -- Reject legacy `_value`-suffixed shape loudly. Producers must
        -- emit canonical names so clip_geometry et al. don't trip.
        assert(entry.start_value == nil and entry.duration_value == nil
            and entry.source_in_value == nil and entry.source_out_value == nil,
            string.format(
                "add_insert_mutation: legacy `_value`-suffixed fields on clip %s — "
                .. "post-M4-real canonical names are sequence_start/duration/"
                .. "source_in/source_out (no _value). Update the producer.",
                tostring(entry.id)))
        assert(entry.track_id, string.format(
            "add_insert_mutation: missing track_id for clip %s", tostring(entry.id)))
        assert(type(entry.sequence_start) == "number", string.format(
            "add_insert_mutation: clip %s sequence_start must be number, got %s",
            tostring(entry.id), type(entry.sequence_start)))
        assert(type(entry.duration) == "number" and entry.duration > 0, string.format(
            "add_insert_mutation: clip %s duration must be positive number, got %s",
            tostring(entry.id), tostring(entry.duration)))
    end

    if clip[1] then
        for _, entry in ipairs(clip) do
            validate_insert(entry)
            table.insert(bucket.inserts, entry)
        end
    else
        validate_insert(clip)
        table.insert(bucket.inserts, clip)
    end
    command:set_parameter("__timeline_mutations", command:get_parameter("__timeline_mutations"))
end

-- Append delete mutation(s). Each entry may be:
--   - a clip_id string (minimal, legacy shape), or
--   - a record {clip_id, track_id, sequence_start, duration} which lets
--     the viewport policy derive the change region without needing to
--     reconstruct the deleted clip's position from elsewhere.
-- Callers with the full clip state available SHOULD pass records so
-- undo/redo can surface the affected region on both directions.
-- Walk a command's __timeline_mutations payload (single-bucket or
-- multi-bucket shape) and return a set of clip_ids the command marks
-- for deletion. Handles both rich-record entries
-- ({clip_id, track_id, sequence_start, duration}) and legacy string
-- entries — this is the read-side dual of add_delete_mutation, so it
-- has to recognize the same shapes the writer produces.
function M.collect_deleted_clip_ids(command)
    local set = {}
    local mutations = command:get_parameter("__timeline_mutations")
    if type(mutations) ~= "table" then return set end
    local function scan_bucket(bucket)
        if type(bucket) ~= "table" or type(bucket.deletes) ~= "table" then return end
        for _, entry in ipairs(bucket.deletes) do
            local cid = type(entry) == "table" and entry.clip_id or entry
            if type(cid) == "string" and cid ~= "" then set[cid] = true end
        end
    end
    if mutations.inserts or mutations.updates or mutations.deletes or mutations.sequence_id then
        scan_bucket(mutations)
    else
        for _, b in pairs(mutations) do scan_bucket(b) end
    end
    return set
end

function M.add_delete_mutation(command, sequence_id, entries)
    assert(entries, "add_delete_mutation: entries required")
    local bucket = M.ensure_timeline_mutation_bucket(command, sequence_id)
    if not bucket then
        return
    end
    local function is_list(t)
        if type(t) ~= "table" then return false end
        -- Record-shaped (clip_id field present) is not a list of entries.
        if t.clip_id or t.id then return false end
        return t[1] ~= nil
    end
    if is_list(entries) then
        for _, entry in ipairs(entries) do
            table.insert(bucket.deletes, entry)
        end
    else
        table.insert(bucket.deletes, entries)
    end
    command:set_parameter("__timeline_mutations", command:get_parameter("__timeline_mutations"))
end

--- Translate a list of planner mutations (clip_mutator.plan_{insert,update,
--- delete} shape) into the timeline_mutations bucket via add_*_mutation.
--- Single canonical home for the planner→bucket mapping, used by every
--- "carve space" command (Paste, LiftRange, ExtractRange, OverwriteTrimEdge).
--- The planner only emits insert/update/delete; bulk_shift / ripple
--- mutations come from different planners and must be reported via their
--- own paths — unknown types assert (no silent skip).
function M.report_planner_mutations(command, sequence_id, mutations)
    assert(type(mutations) == "table",
        "report_planner_mutations: mutations table required (got " .. type(mutations) .. ")")
    local mutation_entry = require("core.commands._mutation_entry")
    for _, mut in ipairs(mutations) do
        if mut.type == "insert" then
            -- Re-read the just-applied clip so the cache entry carries the
            -- full canonical clip shape INCLUDING the media-status denorm
            -- (media_path/offline) — field-reading the mutation would drop
            -- it and the inserted clip would wrongly render online. All
            -- callers report post-apply, so the row exists.
            assert(mut.clip_id and mut.clip_id ~= "",
                "report_planner_mutations: insert mutation missing clip_id")
            M.add_insert_mutation(command, sequence_id,
                mutation_entry.build_insert_entry(mut.clip_id, "report_planner_mutations"))
        elseif mut.type == "update" then
            M.add_update_mutation(command, sequence_id, {
                clip_id          = mut.clip_id,
                track_id         = mut.track_id,
                sequence_start   = mut.sequence_start_frame,
                duration         = mut.duration_frames,
                source_in        = mut.source_in_frame,
                source_out       = mut.source_out_frame,
                -- Planners are inconsistent: some emit enabled as 1/0,
                -- some as a boolean. Accept both.
                enabled          = (mut.enabled == 1) or (mut.enabled == true),
            })
        elseif mut.type == "delete" then
            M.add_delete_mutation(command, sequence_id, mut.clip_id)
        elseif mut.type == "bulk_shift" then
            M.add_bulk_shift_mutation(command, sequence_id, {
                track_id     = mut.track_id,
                shift_frames = mut.shift_frames,
                start_frame  = mut.start_frame,
            })
        else
            assert(false, string.format(
                "report_planner_mutations: unknown mut.type=%q (clip_id=%s) — "
                .. "planner emitted a mutation shape this translator doesn't "
                .. "handle; extend the translator or use a sibling reporter",
                tostring(mut.type), tostring(mut.clip_id)))
        end
    end
end

function M.resolve_sequence_id_for_edges(command, primary_edge, edge_list)
    local provided = command:get_parameter("sequence_id")

    local function lookup_sequence_id(edge)
        if not edge or not edge.clip_id or edge.clip_id == "" then
            return nil
        end

        -- Resolution lookup: clip may not exist yet (e.g. during validation).
        -- Clip.get_sequence_id errors on missing clip, so guard with load_optional.
        local clip = Clip.load_optional(edge.clip_id)
        if not clip or not clip.track_id then
            return nil
        end
        return Clip.get_sequence_id(edge.clip_id)
    end

    local resolved = lookup_sequence_id(primary_edge)
    if not resolved and edge_list then
        for _, edge in ipairs(edge_list) do
            resolved = lookup_sequence_id(edge)
            if resolved then
                break
            end
        end
    end

    if not resolved or resolved == "" then
        resolved = provided
    end

    if resolved and resolved ~= "" and resolved ~= provided then
        command:set_parameter("sequence_id", resolved)
    end

    return resolved
end

function M.resolve_sequence_for_track(sequence_id_param, track_id)
    local provided = sequence_id_param
    if not track_id or track_id == "" then
        return provided
    end

    local track_sequence_id = Track.get_sequence_id(track_id)
    if not track_sequence_id or track_sequence_id == "" then
        return provided
    end

    if provided and provided ~= "" and provided ~= track_sequence_id then
        log.warn("resolve_sequence_for_track: sequence_id %s does not match track %s (sequence_id=%s); using track sequence",
            tostring(provided),
            tostring(track_id),
            tostring(track_sequence_id))
    end

    return track_sequence_id
end

function M.restore_clip_state(state)
    if not state then return end
    -- V13: gaps were collapsed into in-memory clips by feature 005; no DB
    -- gap row exists. The pre-013 `state.clip_kind == "gap"` skip was V8
    -- residue and is removed.

    -- Fill missing ownership if possible
    local seq_id = state.owner_sequence_id or state.track_sequence_id or lookup_track_sequence(state.track_id)
    state.owner_sequence_id = state.owner_sequence_id or seq_id
    state.track_sequence_id = state.track_sequence_id or seq_id

    if not state.project_id or state.project_id == "" then
        local resolved_project_id = nil

        if seq_id and seq_id ~= "" then
            local sequence = Sequence.load(seq_id)
            if sequence and sequence.project_id then
                resolved_project_id = sequence.project_id
            end
        end

        if (not resolved_project_id or resolved_project_id == "") and state.id and state.id ~= "" then
            local existing_clip = Clip.load_optional(state.id)
            if existing_clip and existing_clip.project_id then
                resolved_project_id = existing_clip.project_id
            end
        end

        if not resolved_project_id or resolved_project_id == "" then
            error("restore_clip_state: missing project_id and unable to resolve from database", 2)
        end

        state.project_id = resolved_project_id
    end

    local clip = Clip.load_optional(state.id)
    
    if not clip then
        -- V13: Clip.create takes a single fields table. State carries V13
        -- names only (no master_clip_id alias). capture_clip_state asserts
        -- the same fields non-nil at write — read straight here too.
        local nested_id = state.sequence_id
        assert(nested_id and nested_id ~= "",
            "restore_clip_state: state missing sequence_id")
        assert(type(state.name) == "string" and state.name ~= "",
            "restore_clip_state: state.name required")
        assert(type(state.fps_mismatch_policy) == "string"
            and state.fps_mismatch_policy ~= "",
            "restore_clip_state: state.fps_mismatch_policy required")
        assert(type(state.enabled) == "boolean",
            "restore_clip_state: state.enabled must be boolean")
        assert(type(state.volume) == "number",
            "restore_clip_state: state.volume required")
        assert(type(state.playhead) == "number",
            "restore_clip_state: state.playhead required")
        -- 018 V1 (FR-013): thread captured subframes through restore.
        -- Captures preserve audio (0,0) and video (nil,nil).
        local new_id = Clip.create({
            id = state.id,
            project_id = state.project_id,
            name = state.name,
            track_id = state.track_id,
            owner_sequence_id = state.owner_sequence_id or state.track_sequence_id,
            sequence_id = nested_id,
            sequence_start_frame = state.sequence_start,
            duration_frames = state.duration,
            source_in_frame = state.source_in,
            source_out_frame = state.source_out,
            source_in_subframe = state.source_in_subframe,
            source_out_subframe = state.source_out_subframe,
            master_layer_track_id = state.master_layer_track_id,
            master_audio_track_id = state.master_audio_track_id,
            fps_mismatch_policy = state.fps_mismatch_policy,
            enabled = state.enabled and 1 or 0,
            volume = state.volume,
            mark_in_frame = state.mark_in,
            mark_out_frame = state.mark_out,
            playhead_frame = state.playhead,
        })
        clip = Clip.load(new_id)
        if clip and clip.restore_without_occlusion then
            clip:restore_without_occlusion(nil)
        end
    else
        -- Update existing
        clip.track_id = state.track_id or clip.track_id
        clip.sequence_start = state.sequence_start
        clip.duration = state.duration
        clip.source_in = state.source_in
        clip.source_out = state.source_out
        clip.enabled = state.enabled ~= false
        if state.volume ~= nil then clip.volume = state.volume end
        if state.mark_in ~= nil then clip.mark_in = state.mark_in end
        if state.mark_out ~= nil then clip.mark_out = state.mark_out end
        if state.playhead ~= nil then clip.playhead = state.playhead end
        clip:restore_without_occlusion(nil)
    end
    
    return clip
end

function M.capture_clip_state(clip)
    if not clip then return nil end
    local rate = clip.frame_rate
    if not rate or not rate.fps_numerator or not rate.fps_denominator then
        error(string.format("capture_clip_state: Clip %s missing rate metadata", tostring(clip.id)), 2)
    end
    local is_gap = clip.is_gap == true
    -- Real (non-gap) clips loaded from the DB carry fps_mismatch_policy
    -- (NOT NULL in schema). Gaps are synthesized in-memory and are filtered
    -- out at persist time, so they don't need the field.
    if not is_gap then
        assert(type(clip.fps_mismatch_policy) == "string"
            and clip.fps_mismatch_policy ~= "", string.format(
            "capture_clip_state: clip %s missing fps_mismatch_policy",
            tostring(clip.id)))
    end
    -- V13 snapshot: ONLY V13 fields. V8 aliases (clip_kind, master_clip_id,
    -- media_id, offline) deleted per FR-018.
    local state = {
        id = clip.id,
        project_id = clip.project_id,
        track_type = clip.track_type,
        -- Mark gap captures so persistence can filter them out — gaps are
        -- in-memory-only (recomputed by timeline_state at apply/undo time);
        -- they have no source_in/source_out and would crash revert_mutations.
        is_gap = is_gap or nil,
        owner_sequence_id = clip.owner_sequence_id or clip.track_sequence_id,
        track_sequence_id = clip.track_sequence_id or clip.owner_sequence_id,
        sequence_id = clip.sequence_id,
        master_layer_track_id = clip.master_layer_track_id,
        master_audio_track_id = clip.master_audio_track_id,
        fps_mismatch_policy = clip.fps_mismatch_policy,
        track_id = clip.track_id,
        sequence_start = clip.sequence_start,
        duration = clip.duration,
        source_in = clip.source_in,
        source_out = clip.source_out,
        -- 018 V11 (FR-005, FR-013): subframe round-trips through capture.
        -- Audio clips carry non-NULL (0..tpf-1); video carries NULL.
        source_in_subframe = clip.source_in_subframe,
        source_out_subframe = clip.source_out_subframe,
        name = clip.name,
        enabled = clip.enabled,
        frame_rate = rate,
    }
    -- Timestamps needed for restore operations (may be nil if not set)
    if clip.created_at then state.created_at = clip.created_at end
    if clip.modified_at then state.modified_at = clip.modified_at end
    -- Per-clip metadata: volume, source viewer marks/playhead. The timeline
    -- cache loader (db.load_clips) carries volume but still omits playhead +
    -- marks, so fetch the full clip when any required field is absent. Key on
    -- BOTH volume and playhead (both NOT NULL in schema) — not volume alone:
    -- volume is now present on load_clips clips, so a volume-only trigger
    -- would skip the reload and leave playhead nil.
    local volume = clip.volume
    local mark_in = clip.mark_in
    local mark_out = clip.mark_out
    local playhead = clip.playhead or clip.playhead_frame
    if (volume == nil or playhead == nil or not state.created_at) and clip.id then
        local full_clip = Clip.load_optional(clip.id)
        if full_clip then
            volume = full_clip.volume
            mark_in = full_clip.mark_in
            mark_out = full_clip.mark_out
            playhead = full_clip.playhead_frame
            if not state.created_at then state.created_at = full_clip.created_at end
            if not state.modified_at then state.modified_at = full_clip.modified_at end
        end
    end
    if volume ~= nil then state.volume = volume end
    if mark_in ~= nil then state.mark_in = mark_in end
    if mark_out ~= nil then state.mark_out = mark_out end
    if playhead ~= nil then state.playhead = playhead end
    -- Real (non-gap) captures must carry volume + playhead so restore can
    -- re-INSERT the row. The schema requires both NOT NULL on clips.
    if not is_gap then
        assert(type(state.volume) == "number", string.format(
            "capture_clip_state: clip %s has no volume (DB row missing?)",
            tostring(clip.id)))
        assert(type(state.playhead) == "number", string.format(
            "capture_clip_state: clip %s has no playhead_frame (DB row missing?)",
            tostring(clip.id)))
    end
    return state
end

function M.snapshot_properties_for_clip(clip_id)
    assert(clip_id and clip_id ~= "", "snapshot_properties_for_clip: clip_id is required")
    return Property.load_for_clip(clip_id)
end

function M.fetch_clip_properties_for_copy(clip_id)
    assert(clip_id and clip_id ~= "", "fetch_clip_properties_for_copy: clip_id is required")
    return Property.copy_for_clip(clip_id)
end

function M.insert_properties_for_clip(clip_id, properties)
    if not properties or #properties == 0 then
        return true
    end

    -- Generate fresh UUIDs for each property to avoid UPSERT conflicts
    -- when the same copied_properties list is used for multiple clips
    local properties_with_new_ids = {}
    for _, prop in ipairs(properties) do
        table.insert(properties_with_new_ids, {
            id = uuid.generate(),
            property_name = prop.property_name,
            property_value = prop.property_value,
            property_type = prop.property_type,
            default_value = prop.default_value
        })
    end

    Property.save_for_clip(clip_id, properties_with_new_ids)
    return true
end

function M.delete_properties_for_clip(clip_id)
    assert(clip_id and clip_id ~= "", "delete_properties_for_clip: clip_id is required")
    Property.delete_for_clip(clip_id)
    return true
end

function M.add_bulk_shift_mutation(command, sequence_id, payload)
    if not command or not payload then
        return
    end
    local bucket = M.ensure_timeline_mutation_bucket(command, sequence_id)
    if not bucket then
        return
    end
    bucket.bulk_shifts = bucket.bulk_shifts or {}
    table.insert(bucket.bulk_shifts, payload)
    command:set_parameter("__timeline_mutations", command:get_parameter("__timeline_mutations"))
end

-- Applies a list of mutations (from clip_mutator) to the database.
-- Caller must handle transaction.
function M.apply_mutations(db, mutations)
    if not db then
        return false, "No database connection provided for apply_mutations"
    end
    if not mutations or #mutations == 0 then
        return true
    end

    -- Locked-track gate. Refuses if any mutation targets a tracks.locked=1
    -- row; undo/redo bypass so a track locked AFTER an edit can still be
    -- reverted. Implemented in core.track_lock_guard.
    local guard = require("core.track_lock_guard")
    local track_ids = {}
    local seen = {}
    local function add(tid)
        if type(tid) == "string" and tid ~= "" and not seen[tid] then
            seen[tid] = true; track_ids[#track_ids + 1] = tid
        end
    end
    for _, m in ipairs(mutations) do
        add(m.track_id)
        if m.previous then add(m.previous.track_id) end
    end
    local ok_lock, lock_err = guard.check_writable(db, track_ids)
    if not ok_lock then return false, lock_err end

    local now = os.time()
    local update_stmt = nil
    local delete_stmt = nil
    local insert_stmt = nil
    local bulk_shift_by_id_stmt = nil
    local bulk_shift_select_desc_stmt = nil
    local bulk_shift_select_asc_stmt = nil

    local function finalize_stmt(stmt)
        if stmt and stmt.finalize then
            stmt:finalize()
        end
    end

    -- Finalize every prepared statement this call owns. Used by error
    -- paths to release handles before returning; idempotent because
    -- finalize_stmt no-ops on nil.
    local function finalize_all_stmts()
        finalize_stmt(update_stmt)
        finalize_stmt(delete_stmt)
        finalize_stmt(insert_stmt)
        finalize_stmt(bulk_shift_by_id_stmt)
        finalize_stmt(bulk_shift_select_desc_stmt)
        finalize_stmt(bulk_shift_select_asc_stmt)
    end

    local function reset_stmt(stmt)
        if not stmt then return end
        if stmt.reset then stmt:reset() end
        if stmt.clear_bindings then stmt:clear_bindings() end
    end

    local function ensure_update_stmt()
        if update_stmt then
            return update_stmt
        end
        update_stmt = db:prepare([[ -- lint-allow: R011 cached prepared statement (process-lifetime upvalue, reused via bind+reset)
            UPDATE clips
            SET track_id = ?, sequence_start_frame = ?, duration_frames = ?, source_in_frame = ?, source_out_frame = ?, enabled = ?, modified_at = ?
            WHERE id = ?
        ]])
        if not update_stmt then
            return nil, "Failed to prepare UPDATE statement: " .. tostring(db:last_error() or "unknown")
        end
        return update_stmt
    end

    local function ensure_delete_stmt()
        if delete_stmt then
            return delete_stmt
        end
        delete_stmt = db:prepare("DELETE FROM clips WHERE id = ?")
        if not delete_stmt then
            return nil, "Failed to prepare DELETE statement: " .. tostring(db:last_error() or "unknown")
        end
        return delete_stmt
    end

    local function ensure_insert_stmt()
        if insert_stmt then
            return insert_stmt
        end
        insert_stmt = db:prepare(CLIP_INSERT_SQL)
        if not insert_stmt then
            return nil, "Failed to prepare INSERT statement: " .. tostring(db:last_error() or "unknown")
        end
        return insert_stmt
    end

    local function ensure_bulk_shift_by_id_stmt()
        if bulk_shift_by_id_stmt then
            return bulk_shift_by_id_stmt
        end
        bulk_shift_by_id_stmt = db:prepare("UPDATE clips SET sequence_start_frame = sequence_start_frame + ?, modified_at = ? WHERE id = ?")
        if not bulk_shift_by_id_stmt then
            return nil, "Failed to prepare bulk shift per-clip UPDATE statement: " .. tostring(db:last_error() or "unknown")
        end
        return bulk_shift_by_id_stmt
    end

	    local function ensure_bulk_shift_select_stmt(order_desc)
	        if order_desc then
	            if bulk_shift_select_desc_stmt then
	                return bulk_shift_select_desc_stmt
	            end
	            bulk_shift_select_desc_stmt = db:prepare([[
	                SELECT id FROM clips
	                WHERE track_id = ? AND sequence_start_frame >= ?
	                ORDER BY sequence_start_frame DESC
	            ]])
	            if not bulk_shift_select_desc_stmt then
	                return nil, "Failed to prepare bulk shift SELECT statement: " .. tostring(db:last_error() or "unknown")
	            end
	            return bulk_shift_select_desc_stmt
	        end

	        if bulk_shift_select_asc_stmt then
	            return bulk_shift_select_asc_stmt
	        end
	        bulk_shift_select_asc_stmt = db:prepare([[
	            SELECT id FROM clips
	            WHERE track_id = ? AND sequence_start_frame >= ?
	            ORDER BY sequence_start_frame ASC
	        ]])
	        if not bulk_shift_select_asc_stmt then
	            return nil, "Failed to prepare bulk shift SELECT statement: " .. tostring(db:last_error() or "unknown")
	        end
	        return bulk_shift_select_asc_stmt
	    end

    for _, mut in ipairs(mutations) do
        if mut.type == "update" then
            -- Validate required fields before attempting UPDATE
            if not mut.clip_id or mut.clip_id == "" then
                finalize_all_stmts()
                return false, "Mutation missing clip_id for UPDATE operation"
            end
            if not mut.sequence_start_frame then
                finalize_all_stmts()
                return false, string.format("Mutation for clip %s missing sequence_start_frame", mut.clip_id)
            end
            if not mut.duration_frames or mut.duration_frames <= 0 then
                finalize_all_stmts()
                return false, string.format("Mutation for clip %s has invalid duration: %s",
                                             mut.clip_id, tostring(mut.duration_frames))
            end

            local stmt, stmt_err = ensure_update_stmt()
            if not stmt then
                finalize_all_stmts()
                return false, stmt_err
            end
            stmt:bind_value(1, mut.track_id)
            stmt:bind_value(2, mut.sequence_start_frame)
            stmt:bind_value(3, mut.duration_frames)
            stmt:bind_value(4, mut.source_in_frame)
            stmt:bind_value(5, mut.source_out_frame)
            stmt:bind_value(6, mut.enabled)
            stmt:bind_value(7, now)
            stmt:bind_value(8, mut.clip_id)
            local ok = stmt:exec()
            local err = db:last_error()
            reset_stmt(stmt)
            if not ok then
                finalize_all_stmts()
                return false, "Failed to execute UPDATE for clip " .. tostring(mut.clip_id) .. ": " .. tostring(err or "unknown")
            end
        elseif mut.type == "delete" then
            -- Capture clip_link rows BEFORE the DELETE — the FK ON DELETE
            -- CASCADE wipes them in the same statement otherwise, and
            -- revert_mutations would have nothing to restore. Stash on
            -- mut.previous so the persisted mutation carries them.
            if mut.previous then
                mut.previous.captured_links =
                    require("models.clip_link").capture_for_clip(mut.clip_id, db)
            end
            local stmt, stmt_err = ensure_delete_stmt()
            if not stmt then
                finalize_all_stmts()
                return false, stmt_err
            end
            stmt:bind_value(1, mut.clip_id)
            local ok = stmt:exec()
            local err = db:last_error()
            reset_stmt(stmt)
            if not ok then
                finalize_all_stmts()
                return false, "Failed to execute DELETE for clip " .. tostring(mut.clip_id) .. ": " .. tostring(err or "unknown")
            end
        elseif mut.type == "insert" then
            local stmt, stmt_err = ensure_insert_stmt()
            if not stmt then
                finalize_all_stmts()
                return false, stmt_err
            end
            -- V13 INSERT: callers must provide sequence_id (the
            -- referenced sequence) and fps_mismatch_policy. No V8 alias.
            local nested_id = mut.sequence_id
            if not nested_id or nested_id == "" then
                finalize_all_stmts()
                return false, "INSERT mutation missing sequence_id for clip " .. tostring(mut.clip_id)
            end
            local policy = mut.fps_mismatch_policy or "resample"
            if mut.created_at == nil or mut.modified_at == nil then
                finalize_all_stmts()
                return false, "INSERT mutation missing created_at/modified_at for clip " .. tostring(mut.clip_id)
            end
            -- volume/playhead_frame are NOT NULL in the schema. Plan_insert
            -- substitutes semantic neutrals (1.0, 0) when the source row
            -- omits them — both values are the only correct choices for a
            -- brand-new clip, so we accept them here without reasserting.
            bind_clip_insert(stmt, {
                id                    = mut.clip_id,
                project_id            = mut.project_id,
                name                  = mut.name,
                track_id              = mut.track_id,
                owner_sequence_id     = mut.owner_sequence_id,
                nested_sequence_id    = nested_id,
                sequence_start_frame  = mut.sequence_start_frame,
                duration_frames       = mut.duration_frames,
                source_in_frame       = mut.source_in_frame,
                source_out_frame      = mut.source_out_frame,
                source_in_subframe    = mut.source_in_subframe,
                source_out_subframe   = mut.source_out_subframe,
                master_layer_track_id = mut.master_layer_track_id,
                master_audio_track_id = mut.master_audio_track_id,
                fps_mismatch_policy   = policy,
                enabled               = mut.enabled,
                volume                = mut.volume or 1.0,
                mark_in_frame         = mut.mark_in_frame,
                mark_out_frame        = mut.mark_out_frame,
                playhead_frame        = mut.playhead_frame or 0,
                created_at            = mut.created_at,
                modified_at           = mut.modified_at,
            })
            local ok = stmt:exec()
            local err = db:last_error()
            reset_stmt(stmt)
            if not ok then
                finalize_all_stmts()
                return false, "Failed to execute INSERT for clip " .. tostring(mut.clip_id) .. ": " .. tostring(err or "unknown")
            end
        elseif mut.type == "bulk_shift" then
            -- Canonical shape: { type, track_id, shift_frames, start_frame }.
            -- Every clip on `track_id` with sequence_start_frame >= start_frame
            -- gets shifted by shift_frames. Order matters on video tracks to
            -- avoid transient VIDEO_OVERLAP trigger fires: positive shift
            -- processes DESC (highest first), negative shift ASC.
            if not mut.track_id or mut.track_id == "" then
                finalize_all_stmts()
                return false, "bulk_shift mutation missing track_id"
            end
            if type(mut.shift_frames) ~= "number" then
                finalize_all_stmts()
                return false, "bulk_shift mutation missing numeric shift_frames"
            end
            if type(mut.start_frame) ~= "number" then
                finalize_all_stmts()
                return false, "bulk_shift mutation missing numeric start_frame"
            end

            local order_desc = mut.shift_frames > 0
            local select_stmt, select_err = ensure_bulk_shift_select_stmt(order_desc)
            if not select_stmt then
                finalize_all_stmts()
                return false, select_err
            end
            select_stmt:bind_value(1, mut.track_id)
            select_stmt:bind_value(2, mut.start_frame)
            local ok_select = select_stmt:exec()
            if not ok_select then
                local err = db:last_error()
                reset_stmt(select_stmt)
                finalize_all_stmts()
                return false, "bulk_shift: failed to enumerate clips for track " .. tostring(mut.track_id) .. ": " .. tostring(err or "unknown")
            end

            -- Collect the clip IDs first, then release the cursor before
            -- issuing UPDATEs. SQLite prepared statements can't overlap
            -- SELECT iteration with write operations on the same table.
            local clip_ids = {}
            while select_stmt:next() do
                local clip_id = select_stmt:value(0)
                if clip_id then
                    table.insert(clip_ids, clip_id)
                end
            end
            reset_stmt(select_stmt)

            -- Output invariant: a bulk_shift must find at least one
            -- clip at or past start_frame. The producer computes
            -- start_frame from a clip it just looked up on the track,
            -- so zero affected rows means stale state or a producer
            -- bug. Surface the silent drop rather than returning OK.
            if #clip_ids == 0 then
                finalize_all_stmts()
                return false, string.format(
                    "bulk_shift: no clips on track %s at or past start_frame %d "
                    .. "(producer bug or stale state)",
                    tostring(mut.track_id), mut.start_frame)
            end

            local update_shift_stmt, update_shift_err = ensure_bulk_shift_by_id_stmt()
            if not update_shift_stmt then
                finalize_all_stmts()
                return false, update_shift_err
            end
            for _, clip_id in ipairs(clip_ids) do
                update_shift_stmt:bind_value(1, mut.shift_frames)
                update_shift_stmt:bind_value(2, now)
                update_shift_stmt:bind_value(3, clip_id)
                local ok_update = update_shift_stmt:exec()
                local update_err = db:last_error()
                reset_stmt(update_shift_stmt)
                if not ok_update then
                    finalize_all_stmts()
                    return false, "Failed to execute bulk shift for clip " .. tostring(clip_id) .. ": " .. tostring(update_err or "unknown")
                end
            end
        else
            finalize_all_stmts()
            return false, "Unknown mutation type: " .. tostring(mut.type)
        end
    end

    finalize_all_stmts()
	    return true
	end

-- Revert a forward `bulk_shift` mutation. The forward shift moved every
-- clip on `track_id` with sequence_start_frame >= start_frame by
-- +shift_frames; we enumerate from the post-shift position and shift each
-- clip back by -shift_frames. Ordering matters on video tracks (mirrors
-- the forward path in apply_mutations): positive undo delta → DESC,
-- negative → ASC, so the trigger never sees a transient overlap.
-- Returns (true, nil) | (false, reason). When undo_delta == 0 (forward
-- shift was a no-op), nothing happens.
local function revert_bulk_shift_mutation(db, mut)
    if type(mut.shift_frames) ~= "number" then
        return false, "bulk_shift undo: missing numeric shift_frames"
    end
    if not mut.track_id or mut.track_id == "" then
        return false, "bulk_shift undo: missing track_id"
    end
    if type(mut.start_frame) ~= "number" then
        return false, "bulk_shift undo: missing numeric start_frame"
    end

    local undo_delta = -mut.shift_frames
    if undo_delta == 0 then return true end

    local post_shift_start = mut.start_frame + mut.shift_frames
    local order_desc = undo_delta > 0
    local select_sql = order_desc
        and "SELECT id FROM clips WHERE track_id = ? AND sequence_start_frame >= ? ORDER BY sequence_start_frame DESC"
        or  "SELECT id FROM clips WHERE track_id = ? AND sequence_start_frame >= ? ORDER BY sequence_start_frame ASC"
    local select_stmt = db:prepare(select_sql)
    if not select_stmt then
        return false, "bulk_shift undo: failed to prepare clip enumeration: "
            .. tostring(db:last_error())
    end
    select_stmt:bind_value(1, mut.track_id)
    select_stmt:bind_value(2, post_shift_start)
    if not select_stmt:exec() then
        local err = db:last_error()
        select_stmt:finalize()
        return false, "bulk_shift undo: failed to enumerate clips: " .. tostring(err)
    end

    -- Drain the cursor before issuing UPDATEs (SQLite prepared statements
    -- can't overlap read and write on the same table).
    local clip_ids = {}
    while select_stmt:next() do
        local cid = select_stmt:value(0)
        if cid then clip_ids[#clip_ids + 1] = cid end
    end
    select_stmt:finalize()

    -- Output invariant: the forward shift moved at least one clip
    -- (apply_mutations asserts that); reverting must find the same set
    -- at the post-shift position. Zero here means the DB diverged
    -- between forward and reverse — bug we want to see loudly.
    if #clip_ids == 0 then
        return false, string.format(
            "bulk_shift undo: no clips on track %s at or past post_shift_start %d "
            .. "(DB diverged from forward mutation)",
            tostring(mut.track_id), post_shift_start)
    end

    local update_stmt = db:prepare(
        "UPDATE clips SET sequence_start_frame = sequence_start_frame + ?, modified_at = ? WHERE id = ?")
    if not update_stmt then
        return false, "bulk_shift undo: failed to prepare clip update: "
            .. tostring(db:last_error())
    end
    local now = os.time()
    for _, cid in ipairs(clip_ids) do
        update_stmt:bind_value(1, undo_delta)
        update_stmt:bind_value(2, now)
        update_stmt:bind_value(3, cid)
        local ok = update_stmt:exec()
        local err = db:last_error()
        update_stmt:reset()
        update_stmt:clear_bindings()
        if not ok then
            update_stmt:finalize()
            return false, "bulk_shift undo: failed to shift clip "
                .. tostring(cid) .. ": " .. tostring(err)
        end
    end
    update_stmt:finalize()
    return true
end

-- Type-assert that v is a number, with a context-aware error message
-- naming the originating command so divergence in undo capture is
-- easy to trace.
local function require_int_frame(v, label, command_type)
    assert(type(v) == "number", string.format(
        "undo %s: %s must be integer, got %s",
        command_type or "update", label or "value", type(v)))
    return v
end

local function require_clip_frame_rate(prev, context)
    assert(prev and prev.frame_rate
        and prev.frame_rate.fps_numerator
        and prev.frame_rate.fps_denominator,
        string.format("%s: clip %s missing frame_rate table",
            context or "undo", tostring(prev and prev.id)))
    return prev.frame_rate.fps_numerator, prev.frame_rate.fps_denominator
end

-- Reverse a forward `update` mutation: UPDATE the clip back to its
-- captured `previous` state. Records the reverse mutation on the undo
-- command so apply_command_mutations can sync clip_state.
local function apply_update_revert(db, mut, command, sequence_id)
    local prev = mut.previous
    if not prev then return false, "Cannot undo update: missing previous state" end
    local cmd_type = command and command.type or nil
    local ts = require_int_frame(prev.sequence_start or prev.start_value, "sequence_start", cmd_type)
    local dur = require_int_frame(prev.duration, "duration", cmd_type)
    local src_in = require_int_frame(prev.source_in, "source_in", cmd_type)
    local src_out = require_int_frame(prev.source_out, "source_out", cmd_type)

    local stmt = db:prepare([[
        UPDATE clips
        SET track_id = ?, sequence_start_frame = ?, duration_frames = ?,
            source_in_frame = ?, source_out_frame = ?, enabled = ?, modified_at = ?
        WHERE id = ?
    ]])
    if not stmt then
        return false, "Failed to prepare undo update: " .. tostring(db:last_error())
    end
    stmt:bind_value(1, prev.track_id)
    stmt:bind_value(2, ts)
    stmt:bind_value(3, dur)
    stmt:bind_value(4, src_in)
    stmt:bind_value(5, src_out)
    stmt:bind_value(6, prev.enabled and 1 or 0)
    stmt:bind_value(7, os.time())
    stmt:bind_value(8, prev.id)
    local ok = stmt:exec()
    local err = db:last_error()
    stmt:finalize()
    if not ok then
        return false, "Failed to execute undo update: " .. tostring(err)
    end

    if command then
        local fps_num, fps_den = require_clip_frame_rate(prev, "undo update")
        M.add_update_mutation(command, sequence_id, {
            clip_id          = prev.id,
            track_id         = prev.track_id,
            sequence_start   = ts,
            duration         = dur,
            source_in        = src_in,
            source_out       = src_out,
            fps_numerator    = fps_num,
            fps_denominator  = fps_den,
            enabled          = prev.enabled,
            volume           = prev.volume,
        })
    end
    return true
end

-- Reverse a forward `delete` mutation: re-INSERT the clip from its
-- captured `previous` state. Records the reverse mutation on the undo
-- command for clip_state sync.
local function restore_deleted_clip_revert(db, mut, command, sequence_id)
    local prev = mut.previous
    if not prev then return false, "Cannot undo delete: missing previous state" end
    if prev.created_at == nil or prev.modified_at == nil then
        return false, "undo delete: missing created_at/modified_at for clip " .. tostring(prev.id)
    end
    local nested_id = prev.sequence_id
    if not nested_id or nested_id == "" then
        return false, "undo delete: missing sequence_id for clip " .. tostring(prev.id)
    end
    local cmd_type = command and command.type or nil
    local ts = require_int_frame(prev.sequence_start or prev.start_value, "sequence_start", cmd_type)
    local dur = require_int_frame(prev.duration, "duration", cmd_type)
    local src_in = require_int_frame(prev.source_in, "source_in", cmd_type)
    local src_out = require_int_frame(prev.source_out, "source_out", cmd_type)
    local policy = prev.fps_mismatch_policy or "resample"

    local stmt = db:prepare(CLIP_INSERT_SQL)
    if not stmt then
        return false, "Failed to prepare undo delete: " .. tostring(db:last_error())
    end
    -- Snapshots from older capture sites may not carry volume/playhead
    -- (mainly because capture_clip_state pre-V13 didn't include them on
    -- every path). Schema requires both NOT NULL — substitute the same
    -- semantic neutrals used at clip creation rather than refusing to
    -- restore. mark_in/out remain nullable.
    bind_clip_insert(stmt, {
        id                    = prev.id,
        project_id            = prev.project_id,
        name                  = prev.name,
        track_id              = prev.track_id,
        owner_sequence_id     = prev.owner_sequence_id or prev.track_sequence_id,
        nested_sequence_id    = nested_id,
        sequence_start_frame  = ts,
        duration_frames       = dur,
        source_in_frame       = src_in,
        source_out_frame      = src_out,
        source_in_subframe    = prev.source_in_subframe,
        source_out_subframe   = prev.source_out_subframe,
        master_layer_track_id = prev.master_layer_track_id,
        master_audio_track_id = prev.master_audio_track_id,
        fps_mismatch_policy   = policy,
        enabled               = prev.enabled and 1 or 0,
        volume                = prev.volume or 1.0,
        mark_in_frame         = prev.mark_in,
        mark_out_frame        = prev.mark_out,
        playhead_frame        = prev.playhead or 0,
        created_at            = prev.created_at,
        modified_at           = prev.modified_at,
    })

    local ok = stmt:exec()
    stmt:finalize()
    if not ok then
        return false, "Failed to execute undo delete: " .. (db:last_error() or "")
    end

    -- Restore clip_link rows that the original DELETE cascade-removed.
    -- apply_mutations captured them onto prev.captured_links before the
    -- delete; replay here re-creates the parent-side rows. May be nil for
    -- old-shape mutations persisted before the capture site landed.
    if prev.captured_links then
        require("models.clip_link").restore_rows(prev.captured_links, db)
    end

    if command then
        -- Media-status denorm (media_path/offline/offline_note) comes from
        -- the media JOIN, which `prev` (a captured clip state) doesn't carry.
        -- The row is back in the DB now, so re-derive via load_clip_entry —
        -- otherwise the restored cache clip has no media_path and renders
        -- online even though its media is missing (the "undo cleared
        -- offline" bug, 2026-05-28).
        local joined = require("core.database").load_clip_entry(prev.id)
        assert(joined, string.format(
            "undo delete: load_clip_entry returned nil for restored clip %s",
            tostring(prev.id)))
        M.add_insert_mutation(command, sequence_id, {
            id                 = prev.id,
            track_id           = prev.track_id,
            sequence_id = nested_id,
            sequence_start     = ts,
            duration           = dur,
            source_in          = src_in,
            source_out         = src_out,
            enabled            = prev.enabled,
            name               = prev.name,
            volume             = prev.volume,
            media_path         = joined.media_path,
            offline            = joined.offline,
            offline_note       = joined.offline_note,
        })
    end
    return true
end

function M.revert_mutations(db, mutations, command, sequence_id)
    if not db then return false, "No database connection" end
    if not mutations or #mutations == 0 then return true end

    local updates = {}
    local restore_deletes = {}
    local preserve_strict_order = command and command.type == "BatchRippleEdit"

    for i = #mutations, 1, -1 do
        local mut = mutations[i]
        if mut.type == "insert" then
            -- Delete properties first (properties table has no ON DELETE CASCADE)
            M.delete_properties_for_clip(mut.clip_id)

            local stmt = db:prepare("DELETE FROM clips WHERE id = ?")
            if not stmt then return false, "Failed to prepare undo insert: " .. tostring(db:last_error()) end
            stmt:bind_value(1, mut.clip_id)
            local ok = stmt:exec()
            stmt:finalize()
            if not ok then return false, "Failed to execute undo insert: " .. tostring(db:last_error()) end

            if command then
                M.add_delete_mutation(command, sequence_id, mut.clip_id)
            end
        elseif mut.type == "delete" then
            if preserve_strict_order then
                local ok, err = restore_deleted_clip_revert(db, mut, command, sequence_id)
                if not ok then return false, err end
            else
                table.insert(restore_deletes, mut)
            end
        elseif mut.type == "update" then
            if preserve_strict_order then
                local ok, err = apply_update_revert(db, mut, command, sequence_id)
                if not ok then return false, err end
            else
                table.insert(updates, mut)
            end
        elseif mut.type == "bulk_shift" then
            local ok, err = revert_bulk_shift_mutation(db, mut)
            if not ok then return false, err end

            if command and sequence_id then
                -- Record the reverse mutation on the undo command so that
                -- apply_command_mutations can sync in-memory clip_state
                -- after the SQL reversal above. clip_state is still at
                -- post-forward positions (>= mut.start_frame + shift_frames)
                -- when this mutation is applied, so the reverse's
                -- start_frame must match that post-shift boundary.
                M.add_bulk_shift_mutation(command, sequence_id, {
                    track_id     = mut.track_id,
                    shift_frames = -mut.shift_frames,
                    start_frame  = mut.start_frame + mut.shift_frames,
                })
            end
        else
            return false, "Unknown mutation type: " .. tostring(mut.type)
        end
    end

    if #updates > 0 then
        -- For AddClipsToSequence undo, updates are un-ripples (shift left)
        -- Must process in ascending order (leftmost clips first) to avoid overlaps
        if command and command.type == "AddClipsToSequence" then
            local function start_frames(mut)
                local prev = mut.previous
                if not prev then return 0 end
                local ts = prev.sequence_start or prev.start_value
                assert(ts == nil or type(ts) == "number", string.format("undo AddClipsToSequence: sequence_start must be integer for clip %s", tostring(prev.id)))
                return ts or 0
            end
            table.sort(updates, function(a, b)
                return start_frames(a) < start_frames(b)  -- ascending order
            end)
        elseif command and command.type == "Nudge" then
            local nudge = command.get_parameter and command:get_parameter("nudge_amount")
            assert(type(nudge) == "number", "undo Nudge: nudge_amount must be integer")
            local sign = (nudge > 0) and 1 or ((nudge < 0) and -1 or 0)
            local function start_frames(mut)
                local prev = mut.previous
                assert(prev, "undo Nudge: mutation missing 'previous' state")
                local ts = prev.sequence_start or prev.start_value
                assert(type(ts) == "number", string.format("undo Nudge: sequence_start must be integer for clip %s", tostring(prev.id)))
                return ts
            end
            table.sort(updates, function(a, b)
                local sa = start_frames(a)
                local sb = start_frames(b)
                if sign < 0 then
                    return sa > sb
                else
                    return sa < sb
                end
            end)
        end

        for _, mut in ipairs(updates) do
            local ok, err = apply_update_revert(db, mut, command, sequence_id)
            if not ok then return false, err end
        end
    end

    for _, mut in ipairs(restore_deletes) do
        local ok, err = restore_deleted_clip_revert(db, mut, command, sequence_id)
        if not ok then return false, err end
    end
    return true
end

return M
