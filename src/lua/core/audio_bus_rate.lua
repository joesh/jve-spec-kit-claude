-- 018 FR-005: resolve the audio-bus output rate for a sequence loaded into
-- a monitor. Pure model-layer helper; no Qt or view-layer deps. Both
-- monitors share one audio device, so the rate must be deterministic
-- regardless of which sequence is loaded where.
--
-- Resolution order (no fallbacks — every step reads authoritative data):
--   1. seq.audio_sample_rate is set (record sequence, or master that
--      explicitly carries one). Use it.
--   2. seq is a video-only master and an ACTIVE record sequence is set in
--      timeline_state. Use the active record's rate (FR-005 happy path).
--   3. seq is a video-only master and NO active record is set. Look up
--      ANY record sequence in the same project and use its rate. (FR-005
--      relaxation: a project always has at least one record sequence by
--      the welcome flow; loading a master before clicking a record tab
--      is a legitimate UI state.)
--   4. Project has no record sequence at all → assert. The user cannot
--      meaningfully monitor against silence.

local M = {}

-- @param seq                   Sequence model (loaded)
-- @param active_id             active record sequence id (from timeline_state); may be nil
-- @param load_seq              function(id) → Sequence (injected for testability)
-- @param find_first_record     function(project_id) → rate or nil (injected; model-layer)
function M.resolve_for_monitor(seq, active_id, load_seq, find_first_record)
    assert(seq and seq.id and seq.id ~= "",
        "audio_bus_rate.resolve_for_monitor: seq required")
    assert(type(load_seq) == "function",
        "audio_bus_rate.resolve_for_monitor: load_seq injector required")
    assert(type(find_first_record) == "function",
        "audio_bus_rate.resolve_for_monitor: find_first_record injector required")

    -- Case 1: sequence carries its own rate (record sequence, INV-7-exempt master).
    if seq.audio_sample_rate then
        assert(type(seq.audio_sample_rate) == "number" and seq.audio_sample_rate > 0,
            string.format(
                "audio_bus_rate: sequence %s has invalid audio_sample_rate=%s",
                tostring(seq.id), tostring(seq.audio_sample_rate)))
        return seq.audio_sample_rate
    end

    -- audio_sample_rate=NULL is permitted only on video-only masters.
    assert(seq:is_master(), string.format(
        "audio_bus_rate: sequence %s has no audio_sample_rate but is not a "
        .. "master — record/nested sequences must carry the bus rate "
        .. "(schema NOT NULL)", tostring(seq.id)))

    -- Case 2: active record sequence is set — use its rate.
    if active_id and active_id ~= "" then
        local active_seq = load_seq(active_id)
        assert(active_seq, string.format(
            "audio_bus_rate: active_sequence_id=%s does not resolve",
            tostring(active_id)))
        assert(not active_seq:is_master(), string.format(
            "audio_bus_rate: active_sequence_id=%s resolves to a master "
            .. "(name=%s) — masters must NEVER be the active sequence (FR-005)",
            tostring(active_id), tostring(active_seq.name)))
        assert(active_seq.audio_sample_rate
            and type(active_seq.audio_sample_rate) == "number"
            and active_seq.audio_sample_rate > 0, string.format(
            "audio_bus_rate: active record sequence %s has invalid "
            .. "audio_sample_rate=%s", tostring(active_id),
            tostring(active_seq.audio_sample_rate)))
        return active_seq.audio_sample_rate
    end

    -- Case 3: no active record set — find any record sequence in the project.
    assert(seq.project_id and seq.project_id ~= "", string.format(
        "audio_bus_rate: master %s missing project_id", tostring(seq.id)))
    local rate = find_first_record(seq.project_id)
    assert(rate, string.format(
        "audio_bus_rate: project %s has no record sequence with a "
        .. "valid audio_sample_rate; cannot resolve bus rate for "
        .. "video-only master %s. Create a record sequence first.",
        tostring(seq.project_id), tostring(seq.id)))
    return rate
end

return M
