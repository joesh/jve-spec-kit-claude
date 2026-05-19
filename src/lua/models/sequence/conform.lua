--- models/sequence/conform.lua — ConformSequence's transactional rewrite +
--- the read-only capture pass that feeds it (018 FR-035).
---
--- Pure helpers extracted from models/sequence.lua (2.6: keep that file
--- focused on the model surface). Callers pass the open SQLite connection
--- and any model-level lookups so this module has no `require("models.*")`
--- dependency cycle.
---
--- See specs/018-uniform-clip-source/contracts/conform_sequence.md.

local M = {}

--- 018 FR-035: ConformSequence's transactional rewrite. Caller passes the
--- target fps, the pre-captured row snapshots that need rescaling, and a
--- rescaler closure (built around the FR-008 rounding rule). This function
--- does the SAVEPOINT + conform-single-writer flag + UPDATE choreography
--- and delegates the actual scaled values to the rescaler.
---
--- @param conn           userdata — open SQLite connection
--- @param sequence_id    string   — the sequence whose fps is changing
--- @param new_fps_num    integer  — new fps numerator
--- @param new_fps_den    integer  — new fps denominator
--- @param captured       table    — { mrefs = {{id, seq_start, dur}, ...},
---                                    inner_clips = {{id, seq_start, dur}, ...},
---                                    outer_clips = {{id, src_in, src_out}, ...} }
--- @param rescaler       fn(old)->new — integer→integer using FR-008
---                                       rounding and (new_fps_num,
---                                       old_fps_num, new_fps_den, old_fps_den)
function M.conform_fps(conn, sequence_id, new_fps_num, new_fps_den, captured, rescaler)
    assert(conn, "conform.conform_fps: db connection required")
    assert(sequence_id and sequence_id ~= "",
        "conform.conform_fps: sequence_id required")
    assert(type(new_fps_num) == "number" and new_fps_num > 0,
        "conform.conform_fps: new_fps_num must be positive number")
    assert(type(new_fps_den) == "number" and new_fps_den > 0,
        "conform.conform_fps: new_fps_den must be positive number")
    assert(type(captured) == "table",
        "conform.conform_fps: captured table required")
    assert(type(rescaler) == "function",
        "conform.conform_fps: rescaler injector required")

    local SAVEPOINT = "sequence_conform_fps"
    local SESSION_FLAG = "_conform_sequence_in_progress"

    local db_mod = require("core.database")
    assert(db_mod.savepoint(SAVEPOINT),
        "conform.conform_fps: savepoint failed")

    local ok, result_or_err = pcall(function()
        local flag_ins = conn:prepare(
            "INSERT INTO db_session_flags (name) VALUES (?)")
        flag_ins:bind_value(1, SESSION_FLAG)
        assert(flag_ins:exec(), "ConformSequence: set conform-single-writer flag failed")
        flag_ins:finalize()

        -- Sequence fps first (with the flag in place, the fps single-writer trigger passes).
        local upd_seq = conn:prepare(
            "UPDATE sequences SET fps_numerator = ?, fps_denominator = ?, modified_at = ? WHERE id = ?")
        upd_seq:bind_value(1, new_fps_num)
        upd_seq:bind_value(2, new_fps_den)
        upd_seq:bind_value(3, os.time())
        upd_seq:bind_value(4, sequence_id)
        local seq_ok = upd_seq:exec()
        local seq_err
        if not seq_ok then seq_err = conn:last_error() end
        upd_seq:finalize()
        assert(seq_ok, "sequence fps UPDATE failed: " .. tostring(seq_err))

        -- media_refs in master: rescale (sequence_start_frame, duration_frames).
        local post_mrefs = {}
        if captured.mrefs and #captured.mrefs > 0 then
            local upd_mr = conn:prepare(
                "UPDATE media_refs SET sequence_start_frame = ?, duration_frames = ?, modified_at = ? WHERE id = ?")
            for _, m in ipairs(captured.mrefs) do
                local new_start = rescaler(m.seq_start)
                local new_dur   = rescaler(m.dur)
                upd_mr:bind_value(1, new_start)
                upd_mr:bind_value(2, new_dur)
                upd_mr:bind_value(3, os.time())
                upd_mr:bind_value(4, m.id)
                local mr_ok = upd_mr:exec()
                local mr_err
                if not mr_ok then mr_err = conn:last_error() end
                upd_mr:reset(); upd_mr:clear_bindings()
                assert(mr_ok, string.format(
                    "media_ref %s UPDATE failed: %s", tostring(m.id), tostring(mr_err)))
                post_mrefs[#post_mrefs + 1] = {
                    id = m.id, seq_start = new_start, dur = new_dur,
                }
            end
            upd_mr:finalize()
        end

        -- Contained clips (kind='sequence'): rescale (seq_start, dur).
        local post_inner = {}
        if captured.inner_clips and #captured.inner_clips > 0 then
            local upd_in = conn:prepare(
                "UPDATE clips SET sequence_start_frame = ?, duration_frames = ?, modified_at = ? WHERE id = ?")
            for _, c in ipairs(captured.inner_clips) do
                local new_start = rescaler(c.seq_start)
                local new_dur   = rescaler(c.dur)
                upd_in:bind_value(1, new_start)
                upd_in:bind_value(2, new_dur)
                upd_in:bind_value(3, os.time())
                upd_in:bind_value(4, c.id)
                local cin_ok = upd_in:exec()
                local cin_err
                if not cin_ok then cin_err = conn:last_error() end
                upd_in:reset(); upd_in:clear_bindings()
                assert(cin_ok, string.format(
                    "inner clip %s UPDATE failed: %s", tostring(c.id), tostring(cin_err)))
                post_inner[#post_inner + 1] = {
                    id = c.id, seq_start = new_start, dur = new_dur,
                }
            end
            upd_in:finalize()
        end

        -- Outer clips pointing at this sequence: rescale (src_in, src_out).
        local post_outer = {}
        if captured.outer_clips and #captured.outer_clips > 0 then
            local upd_out = conn:prepare(
                "UPDATE clips SET source_in_frame = ?, source_out_frame = ?, modified_at = ? WHERE id = ?")
            for _, c in ipairs(captured.outer_clips) do
                local new_in  = rescaler(c.src_in)
                local new_out = rescaler(c.src_out)
                upd_out:bind_value(1, new_in)
                upd_out:bind_value(2, new_out)
                upd_out:bind_value(3, os.time())
                upd_out:bind_value(4, c.id)
                local cout_ok = upd_out:exec()
                local cout_err
                if not cout_ok then cout_err = conn:last_error() end
                upd_out:reset(); upd_out:clear_bindings()
                assert(cout_ok, string.format(
                    "outer clip %s UPDATE failed: %s", tostring(c.id), tostring(cout_err)))
                post_outer[#post_outer + 1] = {
                    id = c.id, src_in = new_in, src_out = new_out,
                }
            end
            upd_out:finalize()
        end

        local flag_del = conn:prepare("DELETE FROM db_session_flags WHERE name = ?")
        flag_del:bind_value(1, SESSION_FLAG)
        assert(flag_del:exec(), "ConformSequence: clear conform-single-writer flag failed")
        flag_del:finalize()

        return { mrefs = post_mrefs, inner_clips = post_inner, outer_clips = post_outer }
    end)

    if not ok then
        db_mod.rollback_to_savepoint(SAVEPOINT)
        db_mod.release_savepoint(SAVEPOINT)
        error(result_or_err, 0)
    end
    assert(db_mod.release_savepoint(SAVEPOINT),
        "conform.conform_fps: release savepoint failed")
    return result_or_err
end

--- 018 FR-035 helpers — collect the row snapshots ConformSequence must
--- rewrite. Read-only; safe outside a savepoint.
---
--- @param conn          userdata
--- @param find_seq      fn(id) -> seq | nil — caller provides Sequence.find
---                      (kept out of this module to avoid the
---                      models.sequence ↔ models.sequence.conform cycle)
--- @param sequence_id   string
--- @return string kind, integer fps_num, integer fps_den, table captured
function M.collect_conform_captured(conn, find_seq, sequence_id)
    assert(conn, "conform.collect_conform_captured: db connection required")
    assert(type(find_seq) == "function",
        "conform.collect_conform_captured: find_seq injector required")
    assert(sequence_id and sequence_id ~= "",
        "conform.collect_conform_captured: sequence_id required")
    local seq = find_seq(sequence_id)
    assert(seq, "conform.collect_conform_captured: sequence " .. sequence_id .. " not found")

    local mrefs, inner_clips, outer_clips = {}, {}, {}

    if seq.kind == "master" then
        local s = conn:prepare([[
            SELECT id, sequence_start_frame, duration_frames
            FROM media_refs WHERE owner_sequence_id = ? ORDER BY id ASC
        ]])
        s:bind_value(1, sequence_id)
        assert(s:exec(), "collect_conform_captured: mrefs exec failed")
        while s:next() do
            mrefs[#mrefs + 1] = {
                id = s:value(0), seq_start = s:value(1), dur = s:value(2),
            }
        end
        s:finalize()
    elseif seq.kind == "sequence" then
        local s = conn:prepare([[
            SELECT id, sequence_start_frame, duration_frames
            FROM clips WHERE owner_sequence_id = ? ORDER BY id ASC
        ]])
        s:bind_value(1, sequence_id)
        assert(s:exec(), "collect_conform_captured: inner clips exec failed")
        while s:next() do
            inner_clips[#inner_clips + 1] = {
                id = s:value(0), seq_start = s:value(1), dur = s:value(2),
            }
        end
        s:finalize()
    else
        error(string.format(
            "conform.collect_conform_captured: unsupported kind=%s on %s",
            tostring(seq.kind), sequence_id))
    end

    -- BOTH kinds: clips pointing AT this sequence as their source.
    local s = conn:prepare([[
        SELECT id, source_in_frame, source_out_frame
        FROM clips WHERE sequence_id = ? ORDER BY id ASC
    ]])
    s:bind_value(1, sequence_id)
    assert(s:exec(), "collect_conform_captured: outer clips exec failed")
    while s:next() do
        outer_clips[#outer_clips + 1] = {
            id = s:value(0), src_in = s:value(1), src_out = s:value(2),
        }
    end
    s:finalize()

    return seq.kind, seq.fps_numerator, seq.fps_denominator,
        { mrefs = mrefs, inner_clips = inner_clips, outer_clips = outer_clips }
end

return M
