--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~69 LOC
-- Volatility: unknown
--
-- @file command_rational_helpers.lua
-- FPS metadata query helpers for commands.
-- All coordinates are integers now - these just fetch fps_numerator/fps_denominator for clip metadata.
local M = {}

--- Query sequence frame rate from database
-- @param db Database connection
-- @param sequence_id string Sequence identifier
-- @return number, number fps_numerator, fps_denominator
function M.require_sequence_rate(db, sequence_id)
    assert(db, "require_sequence_rate: db is nil")
    assert(sequence_id and sequence_id ~= "", "require_sequence_rate: sequence_id required")

    local stmt = db:prepare("SELECT fps_numerator, fps_denominator FROM sequences WHERE id = ?")
    assert(stmt, "require_sequence_rate: failed to prepare sequence fps query")

    stmt:bind_value(1, sequence_id)
    local fps_num, fps_den
    if stmt:exec() and stmt:next() then
        fps_num = stmt:value(0)
        fps_den = stmt:value(1)
    end
    stmt:finalize()

    assert(fps_num and fps_den, string.format("require_sequence_rate: missing fps metadata for sequence %s", tostring(sequence_id)))
    return fps_num, fps_den
end

--- Query media frame rate from database
-- @param db Database connection
-- @param media_id string Media identifier
-- @return number, number fps_numerator, fps_denominator
function M.require_media_rate(db, media_id)
    assert(db, "require_media_rate: db is nil")
    assert(media_id and media_id ~= "", "require_media_rate: media_id required")

    local stmt = db:prepare("SELECT fps_numerator, fps_denominator FROM media WHERE id = ?")
    assert(stmt, "require_media_rate: failed to prepare media fps query")

    stmt:bind_value(1, media_id)
    local fps_num, fps_den
    if stmt:exec() and stmt:next() then
        fps_num = stmt:value(0)
        fps_den = stmt:value(1)
    end
    stmt:finalize()

    assert(fps_num and fps_den, string.format("require_media_rate: missing fps metadata for media %s", tostring(media_id)))
    return fps_num, fps_den
end

--- Extract frame rate from master clip
-- @param master_clip table Master clip object with rate field
-- @return number, number fps_numerator, fps_denominator
function M.require_master_clip_rate(master_clip)
    assert(master_clip and master_clip.rate, "require_master_clip_rate: master clip missing rate field")

    local fps_num = master_clip.rate.fps_numerator
    local fps_den = master_clip.rate.fps_denominator

    assert(fps_num and fps_den, "require_master_clip_rate: master clip missing fps metadata")
    return fps_num, fps_den
end

return M

