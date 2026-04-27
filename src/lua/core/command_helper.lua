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

function M.resolve_active_sequence_id(sequence_id_param, timeline_state)
    if sequence_id_param and sequence_id_param ~= "" then
        return sequence_id_param
    end
    if timeline_state and type(timeline_state.get_sequence_id) == "function" then
        local ok, seq = pcall(timeline_state.get_sequence_id)
        if ok and seq and seq ~= "" then
            return seq
        end
    end
    return nil
end

--- Resolve target clips at playhead using selection-aware two-tier logic.
-- 1. If clips are selected AND any intersect playhead → those clips
-- 2. Otherwise → all clips at playhead
-- Returns target_clips (may be empty), playhead (integer frames).
function M.resolve_clips_at_playhead()
    local timeline_state = require("ui.timeline.timeline_state")

    local playhead = timeline_state.get_playhead_position()
    assert(type(playhead) == "number", "resolve_clips_at_playhead: playhead must be integer")

    local selected = timeline_state.get_selected_clips()
    local target_clips

    if selected and #selected > 0 then
        target_clips = timeline_state.get_clips_at_time(playhead, selected)
        if #target_clips == 0 then
            -- Selection doesn't intersect playhead — fall back to all clips
            target_clips = timeline_state.get_clips_at_time(playhead)
        end
    else
        target_clips = timeline_state.get_clips_at_time(playhead)
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
    if (not target_sequence or target_sequence == "") and timeline_state_mod.get_sequence_id then
        target_sequence = timeline_state_mod.get_sequence_id()
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
    assert(type(source.timeline_start) == "number", string.format("clip_update_payload: timeline_start must be integer for clip %s", tostring(source.id)))
    assert(type(source.duration) == "number", string.format("clip_update_payload: duration must be integer for clip %s", tostring(source.id)))
    assert(type(source.source_in) == "number", string.format("clip_update_payload: source_in must be integer for clip %s", tostring(source.id)))
    assert(type(source.source_out) == "number", string.format("clip_update_payload: source_out must be integer for clip %s", tostring(source.id)))

    -- Use _value suffix field names that apply_mutations expects
    return {
        clip_id = source.id,
        track_id = source.track_id,
        track_sequence_id = track_sequence_id,
        start_value = source.timeline_start,
        duration_value = source.duration,
        source_in_value = source.source_in,
        source_out_value = source.source_out,
        frame_rate = frame_rate,
        enabled = source.enabled ~= false
    }
end

function M.clip_insert_payload(source, fallback_sequence_id)
    if not source or not source.id then
        return nil
    end
    local track_sequence_id = source.owner_sequence_id or source.track_sequence_id or fallback_sequence_id
    if not track_sequence_id then
        return nil
    end
    local frame_rate = source.frame_rate
    if source.source_in ~= nil or source.source_out ~= nil then
        assert(frame_rate
            and frame_rate.fps_numerator
            and frame_rate.fps_denominator,
            string.format("command_helper.clip_insert_payload: clip %s missing frame_rate table for source bounds",
                tostring(source.id)))
    end
    local label = source.label or source.name
    if (not label or label == "") and source.id then
        label = "Clip " .. source.id:sub(1, 8)
    end
    return {
        id = source.id,
        clip_id = source.id,
        project_id = source.project_id,
        track_type = source.track_type,
        name = source.name,
        label = label,
        track_id = source.track_id,
        track_sequence_id = track_sequence_id,
        owner_sequence_id = source.owner_sequence_id or track_sequence_id,
        nested_sequence_id = source.nested_sequence_id,
        master_layer_track_id = source.master_layer_track_id,
        master_audio_track_id = source.master_audio_track_id,
        fps_mismatch_policy = source.fps_mismatch_policy,

        timeline_start = source.timeline_start,
        duration = source.duration,
        source_in = source.source_in,
        source_out = source.source_out,
        frame_rate = frame_rate,

        enabled = source.enabled ~= false,
        volume = source.volume,
    }
end

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
        local has_field = entry.start_value or entry.duration_value or entry.track_id
            or entry.source_in_value or entry.source_out_value
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

    -- Validate insert mutation payload to catch incomplete undo mutations
    local function validate_insert(entry)
        assert(entry.id, "add_insert_mutation: missing id")
        -- For UI cache inserts, we need position data (not just id)
        -- This catches bugs where undo delete sends {id = "..."} without start_value/duration_value
        if not entry.start_value and not entry.duration_value and not entry.track_id then
            error(string.format(
                "add_insert_mutation: incomplete payload for clip %s - missing start_value, duration_value, and track_id. " ..
                "Undo delete mutations must include full clip state for UI cache inserts.",
                tostring(entry.id)
            ), 2)
        end
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
--   - a record {clip_id, track_id, timeline_start, duration} which lets
--     the viewport policy derive the change region without needing to
--     reconstruct the deleted clip's position from elsewhere.
-- Callers with the full clip state available SHOULD pass records so
-- undo/redo can surface the affected region on both directions.
-- Walk a command's __timeline_mutations payload (single-bucket or
-- multi-bucket shape) and return a set of clip_ids the command marks
-- for deletion. Handles both rich-record entries
-- ({clip_id, track_id, timeline_start, duration}) and legacy string
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
        -- names only (no master_clip_id alias).
        local nested_id = state.nested_sequence_id
        assert(nested_id and nested_id ~= "",
            "restore_clip_state: state missing nested_sequence_id")
        local new_id = Clip.create({
            id = state.id,
            project_id = state.project_id,
            name = state.name or "Restored Clip",
            track_id = state.track_id,
            owner_sequence_id = state.owner_sequence_id or state.track_sequence_id,
            nested_sequence_id = nested_id,
            timeline_start_frame = state.timeline_start,
            duration_frames = state.duration,
            source_in_frame = state.source_in,
            source_out_frame = state.source_out,
            master_layer_track_id = state.master_layer_track_id,
            master_audio_track_id = state.master_audio_track_id,
            fps_mismatch_policy = state.fps_mismatch_policy or "resample",
            enabled = (state.enabled ~= false) and 1 or 0,
            volume = state.volume or 1.0,
            mark_in_frame = state.mark_in,
            mark_out_frame = state.mark_out,
            playhead_frame = state.playhead or 0,
        })
        clip = Clip.load(new_id)
        if clip and clip.restore_without_occlusion then
            clip:restore_without_occlusion(nil)
        end
    else
        -- Update existing
        clip.track_id = state.track_id or clip.track_id
        clip.timeline_start = state.timeline_start
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
    -- V13 snapshot: ONLY V13 fields. V8 aliases (clip_kind, master_clip_id,
    -- media_id, offline) deleted per FR-018.
    local state = {
        id = clip.id,
        project_id = clip.project_id,
        track_type = clip.track_type,
        -- Mark gap captures so persistence can filter them out — gaps are
        -- in-memory-only (recomputed by timeline_state at apply/undo time);
        -- they have no source_in/source_out and would crash revert_mutations.
        is_gap = clip.is_gap == true or nil,
        owner_sequence_id = clip.owner_sequence_id or clip.track_sequence_id,
        track_sequence_id = clip.track_sequence_id or clip.owner_sequence_id,
        nested_sequence_id = clip.nested_sequence_id,
        master_layer_track_id = clip.master_layer_track_id,
        master_audio_track_id = clip.master_audio_track_id,
        fps_mismatch_policy = clip.fps_mismatch_policy or "resample",
        track_id = clip.track_id,
        timeline_start = clip.timeline_start,
        duration = clip.duration,
        source_in = clip.source_in,
        source_out = clip.source_out,
        name = clip.name,
        enabled = clip.enabled,
        frame_rate = rate,
    }
    -- Timestamps needed for restore operations (may be nil if not set)
    if clip.created_at then state.created_at = clip.created_at end
    if clip.modified_at then state.modified_at = clip.modified_at end
    -- Per-clip metadata: volume, source viewer marks/playhead.
    -- load_clips() omits these for performance; fetch from Clip model if missing.
    local volume = clip.volume
    local mark_in = clip.mark_in
    local mark_out = clip.mark_out
    local playhead = clip.playhead or clip.playhead_frame
    if (volume == nil or not state.created_at) and clip.id then
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
        update_stmt = db:prepare([[
            UPDATE clips
            SET track_id = ?, timeline_start_frame = ?, duration_frames = ?, source_in_frame = ?, source_out_frame = ?, enabled = ?, modified_at = ?
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
        insert_stmt = db:prepare([[
            INSERT INTO clips (
                id, project_id, name, track_id,
                owner_sequence_id, nested_sequence_id,
                timeline_start_frame, duration_frames,
                source_in_frame, source_out_frame,
                master_layer_track_id, master_audio_track_id,
                fps_mismatch_policy,
                enabled, volume, mark_in_frame, mark_out_frame, playhead_frame,
                created_at, modified_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])
        if not insert_stmt then
            return nil, "Failed to prepare INSERT statement: " .. tostring(db:last_error() or "unknown")
        end
        return insert_stmt
    end

    local function ensure_bulk_shift_by_id_stmt()
        if bulk_shift_by_id_stmt then
            return bulk_shift_by_id_stmt
        end
        bulk_shift_by_id_stmt = db:prepare("UPDATE clips SET timeline_start_frame = timeline_start_frame + ?, modified_at = ? WHERE id = ?")
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
	                WHERE track_id = ? AND timeline_start_frame >= ?
	                ORDER BY timeline_start_frame DESC
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
	            WHERE track_id = ? AND timeline_start_frame >= ?
	            ORDER BY timeline_start_frame ASC
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
            if not mut.timeline_start_frame then
                finalize_all_stmts()
                return false, string.format("Mutation for clip %s missing timeline_start_frame", mut.clip_id)
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
            stmt:bind_value(2, mut.timeline_start_frame)
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
            -- V13 INSERT: callers must provide nested_sequence_id (the
            -- referenced sequence) and fps_mismatch_policy. No V8 alias.
            local nested_id = mut.nested_sequence_id
            if not nested_id or nested_id == "" then
                finalize_all_stmts()
                return false, "INSERT mutation missing nested_sequence_id for clip " .. tostring(mut.clip_id)
            end
            local policy = mut.fps_mismatch_policy or "resample"
            if mut.created_at == nil or mut.modified_at == nil then
                finalize_all_stmts()
                return false, "INSERT mutation missing created_at/modified_at for clip " .. tostring(mut.clip_id)
            end
            stmt:bind_value(1, mut.clip_id)
            stmt:bind_value(2, mut.project_id)
            stmt:bind_value(3, mut.name)
            stmt:bind_value(4, mut.track_id)
            stmt:bind_value(5, mut.owner_sequence_id)
            stmt:bind_value(6, nested_id)
            stmt:bind_value(7, mut.timeline_start_frame)
            stmt:bind_value(8, mut.duration_frames)
            stmt:bind_value(9, mut.source_in_frame)
            stmt:bind_value(10, mut.source_out_frame)
            stmt:bind_value(11, mut.master_layer_track_id)  -- nullable
            stmt:bind_value(12, mut.master_audio_track_id)  -- nullable
            stmt:bind_value(13, policy)
            stmt:bind_value(14, mut.enabled)
            stmt:bind_value(15, mut.volume or 1.0)
            if mut.mark_in_frame ~= nil then stmt:bind_value(16, mut.mark_in_frame) end
            if mut.mark_out_frame ~= nil then stmt:bind_value(17, mut.mark_out_frame) end
            stmt:bind_value(18, mut.playhead_frame or 0)
            stmt:bind_value(19, mut.created_at)
            stmt:bind_value(20, mut.modified_at)
            local ok = stmt:exec()
            local err = db:last_error()
            reset_stmt(stmt)
            if not ok then
                finalize_all_stmts()
                return false, "Failed to execute INSERT for clip " .. tostring(mut.clip_id) .. ": " .. tostring(err or "unknown")
            end
        elseif mut.type == "bulk_shift" then
            -- Canonical shape: { type, track_id, shift_frames, start_frame }.
            -- Every clip on `track_id` with timeline_start_frame >= start_frame
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

function M.revert_mutations(db, mutations, command, sequence_id)
    if not db then return false, "No database connection" end
    if not mutations or #mutations == 0 then return true end

    local updates = {}
    local restore_deletes = {}
    local preserve_strict_order = command and command.type == "BatchRippleEdit"

    local function val_frames(v, label)
        assert(type(v) == "number", string.format("undo %s: %s must be integer, got %s", command and command.type or "update", label or "value", type(v)))
        return v
    end

    local function require_rate(prev, context)
        assert(prev and prev.frame_rate
            and prev.frame_rate.fps_numerator
            and prev.frame_rate.fps_denominator,
            string.format("%s: clip %s missing frame_rate table",
                context or "undo", tostring(prev and prev.id)))
        return prev.frame_rate.fps_numerator, prev.frame_rate.fps_denominator
    end

    local function apply_update(mut)
        local prev = mut.previous
        if not prev then return false, "Cannot undo update: missing previous state" end
        local now = os.time()

        local stmt = db:prepare([[
            UPDATE clips
            SET track_id = ?, timeline_start_frame = ?, duration_frames = ?, source_in_frame = ?, source_out_frame = ?, enabled = ?, modified_at = ?
            WHERE id = ?
        ]])
        if not stmt then return false, "Failed to prepare undo update: " .. tostring(db:last_error()) end

        stmt:bind_value(1, prev.track_id)
        stmt:bind_value(2, val_frames(prev.timeline_start or prev.start_value, "timeline_start"))
        stmt:bind_value(3, val_frames(prev.duration, "duration"))
        stmt:bind_value(4, val_frames(prev.source_in, "source_in"))
        stmt:bind_value(5, val_frames(prev.source_out, "source_out"))
        stmt:bind_value(6, prev.enabled and 1 or 0)
        stmt:bind_value(7, now)
        stmt:bind_value(8, prev.id)

        local ok = stmt:exec()
        local err = db:last_error()
        stmt:finalize()
        if not ok then
            return false, "Failed to execute undo update: " .. tostring(err)
        end

        if command then
            -- Include full clip state for UI cache update (not just clip_id)
            local fps_num, fps_den = require_rate(prev, "undo update")
            M.add_update_mutation(command, sequence_id, {
                clip_id = prev.id,
                track_id = prev.track_id,
                start_value = val_frames(prev.timeline_start or prev.start_value, "timeline_start"),
                duration_value = val_frames(prev.duration, "duration"),
                source_in_value = val_frames(prev.source_in, "source_in"),
                source_out_value = val_frames(prev.source_out, "source_out"),
                fps_numerator = fps_num,
                fps_denominator = fps_den,
                enabled = prev.enabled,
                volume = prev.volume,
            })
        end
        return true
    end

    local function restore_deleted_clip(mut)
        local prev = mut.previous
        if not prev then return false, "Cannot undo delete: missing previous state" end
        if prev.created_at == nil or prev.modified_at == nil then
            return false, "undo delete: missing created_at/modified_at for clip " .. tostring(prev.id)
        end
        local nested_id = prev.nested_sequence_id
        if not nested_id or nested_id == "" then
            return false, "undo delete: missing nested_sequence_id for clip " .. tostring(prev.id)
        end
        local policy = prev.fps_mismatch_policy or "resample"

        local stmt = db:prepare([[
            INSERT INTO clips (
                id, project_id, name, track_id,
                owner_sequence_id, nested_sequence_id,
                timeline_start_frame, duration_frames,
                source_in_frame, source_out_frame,
                master_layer_track_id, master_audio_track_id,
                fps_mismatch_policy,
                enabled, volume, mark_in_frame, mark_out_frame, playhead_frame,
                created_at, modified_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])
        if not stmt then return false, "Failed to prepare undo delete: " .. tostring(db:last_error()) end

        stmt:bind_value(1, prev.id)
        stmt:bind_value(2, prev.project_id)
        stmt:bind_value(3, prev.name)
        stmt:bind_value(4, prev.track_id)
        stmt:bind_value(5, prev.owner_sequence_id or prev.track_sequence_id)
        stmt:bind_value(6, nested_id)
        stmt:bind_value(7, val_frames(prev.timeline_start or prev.start_value, "timeline_start"))
        stmt:bind_value(8, val_frames(prev.duration, "duration"))
        stmt:bind_value(9, val_frames(prev.source_in, "source_in"))
        stmt:bind_value(10, val_frames(prev.source_out, "source_out"))
        stmt:bind_value(11, prev.master_layer_track_id)  -- nullable
        stmt:bind_value(12, prev.master_audio_track_id)  -- nullable
        stmt:bind_value(13, policy)
        stmt:bind_value(14, prev.enabled and 1 or 0)
        stmt:bind_value(15, prev.volume or 1.0)
        if prev.mark_in ~= nil then stmt:bind_value(16, prev.mark_in) end
        if prev.mark_out ~= nil then stmt:bind_value(17, prev.mark_out) end
        stmt:bind_value(18, prev.playhead or 0)
        stmt:bind_value(19, prev.created_at)
        stmt:bind_value(20, prev.modified_at)

        local ok = stmt:exec()
        stmt:finalize()
        if not ok then
            return false, "Failed to execute undo delete: " .. (db:last_error() or "")
        end

        if command then
            -- Include full clip payload for UI cache insert (not just id)
            M.add_insert_mutation(command, sequence_id, {
                id = prev.id,
                track_id = prev.track_id,
                nested_sequence_id = nested_id,
                start_value = val_frames(prev.timeline_start or prev.start_value, "timeline_start"),
                duration_value = val_frames(prev.duration, "duration"),
                source_in_value = val_frames(prev.source_in, "source_in"),
                source_out_value = val_frames(prev.source_out, "source_out"),
                enabled = prev.enabled,
                name = prev.name,
                volume = prev.volume,
            })
        end
        return true
    end

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
                local ok, err = restore_deleted_clip(mut)
                if not ok then return false, err end
            else
                table.insert(restore_deletes, mut)
            end
        elseif mut.type == "update" then
            if preserve_strict_order then
                local ok, err = apply_update(mut)
                if not ok then return false, err end
            else
                table.insert(updates, mut)
            end
        elseif mut.type == "bulk_shift" then
            -- Reverse a canonical bulk_shift: { track_id, shift_frames, start_frame }.
            --
            -- The forward shift moved every clip on `track_id` with
            -- timeline_start_frame >= start_frame by +shift_frames, so the
            -- clips now sit at positions >= (start_frame + shift_frames).
            -- To undo, we enumerate from that post-shift position and move
            -- each clip back by -shift_frames.
            --
            -- Ordering matters on video tracks to avoid transient
            -- VIDEO_OVERLAP trigger fires: the undo delta (-shift_frames)
            -- determines direction, so positive undo delta processes DESC,
            -- negative undo delta processes ASC. Same rule as the forward
            -- path in apply_mutations.
            local shift_frames = mut.shift_frames
            if type(shift_frames) ~= "number" then
                return false, "bulk_shift undo: missing numeric shift_frames"
            end
            if not mut.track_id or mut.track_id == "" then
                return false, "bulk_shift undo: missing track_id"
            end
            if type(mut.start_frame) ~= "number" then
                return false, "bulk_shift undo: missing numeric start_frame"
            end

            local undo_delta = -shift_frames
            if undo_delta ~= 0 then
                local post_shift_start = mut.start_frame + shift_frames
                local order_desc = undo_delta > 0
                local select_sql = order_desc
                    and "SELECT id FROM clips WHERE track_id = ? AND timeline_start_frame >= ? ORDER BY timeline_start_frame DESC"
                    or  "SELECT id FROM clips WHERE track_id = ? AND timeline_start_frame >= ? ORDER BY timeline_start_frame ASC"
                local select_stmt = db:prepare(select_sql)
                if not select_stmt then
                    return false, "bulk_shift undo: failed to prepare clip enumeration: " .. tostring(db:last_error())
                end
                select_stmt:bind_value(1, mut.track_id)
                select_stmt:bind_value(2, post_shift_start)
                local ok_select = select_stmt:exec()
                if not ok_select then
                    local select_err = db:last_error()
                    select_stmt:finalize()
                    return false, "bulk_shift undo: failed to enumerate clips: " .. tostring(select_err)
                end

                -- Drain the cursor before issuing UPDATEs (SQLite prepared
                -- statements can't overlap read and write on the same table).
                local clip_ids = {}
                while select_stmt:next() do
                    local clip_id = select_stmt:value(0)
                    if clip_id then
                        table.insert(clip_ids, clip_id)
                    end
                end
                select_stmt:finalize()

                -- Output invariant: the forward shift moved at least one
                -- clip (apply_mutations asserts that); reverting must find
                -- the same set at the post-shift position. Zero here means
                -- the DB state diverged between forward and reverse, or
                -- a concurrent mutation removed the clips out from under
                -- the undo — either way it's a bug we want to see loudly.
                if #clip_ids == 0 then
                    return false, string.format(
                        "bulk_shift undo: no clips on track %s at or past "
                        .. "post_shift_start %d (DB diverged from forward mutation)",
                        tostring(mut.track_id), post_shift_start)
                end

                local update_stmt = db:prepare("UPDATE clips SET timeline_start_frame = timeline_start_frame + ?, modified_at = ? WHERE id = ?")
                if not update_stmt then
                    return false, "bulk_shift undo: failed to prepare clip update: " .. tostring(db:last_error())
                end
                local now = os.time()
                for _, clip_id in ipairs(clip_ids) do
                    update_stmt:bind_value(1, undo_delta)
                    update_stmt:bind_value(2, now)
                    update_stmt:bind_value(3, clip_id)
                    local ok = update_stmt:exec()
                    local err = db:last_error()
                    update_stmt:reset()
                    update_stmt:clear_bindings()
                    if not ok then
                        update_stmt:finalize()
                        return false, "bulk_shift undo: failed to shift clip " .. tostring(clip_id) .. ": " .. tostring(err)
                    end
                end
                update_stmt:finalize()
            end

            if command and sequence_id then
                -- Record the reverse mutation on the undo command so that
                -- apply_command_mutations can sync in-memory clip_state
                -- after the SQL reversal above. clip_state is still at
                -- post-forward positions (>= mut.start_frame + shift_frames)
                -- when this mutation is applied, so the reverse's
                -- start_frame must match that post-shift boundary.
                M.add_bulk_shift_mutation(command, sequence_id, {
                    track_id = mut.track_id,
                    shift_frames = undo_delta,
                    start_frame = mut.start_frame + shift_frames,
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
                local ts = prev.timeline_start or prev.start_value
                assert(ts == nil or type(ts) == "number", string.format("undo AddClipsToSequence: timeline_start must be integer for clip %s", tostring(prev.id)))
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
                local ts = prev.timeline_start or prev.start_value
                assert(type(ts) == "number", string.format("undo Nudge: timeline_start must be integer for clip %s", tostring(prev.id)))
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
            local ok, err = apply_update(mut)
            if not ok then return false, err end
        end
    end

    for _, mut in ipairs(restore_deletes) do
        local ok, err = restore_deleted_clip(mut)
        if not ok then return false, err end
    end
    return true
end

return M
