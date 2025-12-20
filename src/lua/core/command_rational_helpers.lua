--- Command Rational Helpers
-- Shared utilities for commands that work with Rational time values and sequence/media frame rates.
-- Extracted from insert.lua and overwrite.lua to eliminate code duplication.
-- Uses assertions for fail-fast debugging during development.

local M = {}
local Rational = require("core.rational")

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

--- Hydrate and rescale a value to specified frame rate (required value)
-- @param value Rational|table|number Value to convert
-- @param fps_num number Target fps numerator
-- @param fps_den number Target fps denominator
-- @param label string Optional label for error messages
-- @return Rational Hydrated and rescaled rational
function M.require_rational_in_rate(value, fps_num, fps_den, label)
    assert(fps_num and fps_num > 0, "require_rational_in_rate: invalid fps numerator: " .. tostring(fps_num))
    assert(fps_den and fps_den > 0, "require_rational_in_rate: invalid fps denominator: " .. tostring(fps_den))

    local hydrated = Rational.hydrate(value, fps_num, fps_den)
    assert(hydrated, "require_rational_in_rate: missing " .. tostring(label or "time") .. " value")

    if hydrated.fps_numerator ~= fps_num or hydrated.fps_denominator ~= fps_den then
        local rescaled = hydrated:rescale(fps_num, fps_den)
        assert(rescaled, "require_rational_in_rate: failed to rescale " .. tostring(label or "time") .. " to target frame rate")
        return rescaled
    end

    return hydrated
end

--- Hydrate and rescale a value to specified frame rate (optional value)
-- @param value Rational|table|number|nil Value to convert
-- @param fps_num number Target fps numerator
-- @param fps_den number Target fps denominator
-- @return Rational|nil Hydrated and rescaled rational, or nil if input was nil
function M.optional_rational_in_rate(value, fps_num, fps_den)
    if not value then
        return nil
    end

    assert(fps_num and fps_num > 0, "optional_rational_in_rate: invalid fps numerator: " .. tostring(fps_num))
    assert(fps_den and fps_den > 0, "optional_rational_in_rate: invalid fps denominator: " .. tostring(fps_den))

    local hydrated = Rational.hydrate(value, fps_num, fps_den)
    if not hydrated then
        return nil
    end

    if hydrated.fps_numerator ~= fps_num or hydrated.fps_denominator ~= fps_den then
        local rescaled = hydrated:rescale(fps_num, fps_den)
        assert(rescaled, "optional_rational_in_rate: failed to rescale optional value to target frame rate")
        return rescaled
    end

    return hydrated
end

return M

