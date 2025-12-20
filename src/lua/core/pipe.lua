-- pipe.lua
-- Minimal, composable data-flow helpers (pipe-style).
--
-- Intended use:
--   local pipe = require("core.pipe")
--   local out = pipe.pipe(items,
--       pipe.filter(function(x) return x.enabled end),
--       pipe.map(function(x) return x.id end)
--   )

local M = {}

function M.pipe(value, ...)
    local out = value
    for i = 1, select("#", ...) do
        local fn = select(i, ...)
        out = fn(out)
    end
    return out
end

function M.map(fn)
    if type(fn) ~= "function" then
        error("pipe.map requires a function", 2)
    end
    return function(list)
        local out = {}
        if not list then
            return out
        end
        for i, v in ipairs(list) do
            out[i] = fn(v, i, list)
        end
        return out
    end
end

function M.filter(pred)
    if type(pred) ~= "function" then
        error("pipe.filter requires a function", 2)
    end
    return function(list)
        local out = {}
        if not list then
            return out
        end
        for _, v in ipairs(list) do
            if pred(v) then
                out[#out + 1] = v
            end
        end
        return out
    end
end

function M.flat_map(fn)
    if type(fn) ~= "function" then
        error("pipe.flat_map requires a function", 2)
    end
    return function(list)
        local out = {}
        if not list then
            return out
        end
        for i, v in ipairs(list) do
            local produced = fn(v, i, list)
            if type(produced) == "table" then
                for _, inner in ipairs(produced) do
                    out[#out + 1] = inner
                end
            elseif produced ~= nil then
                out[#out + 1] = produced
            end
        end
        return out
    end
end

function M.each(fn)
    if type(fn) ~= "function" then
        error("pipe.each requires a function", 2)
    end
    return function(list)
        if list then
            for i, v in ipairs(list) do
                fn(v, i, list)
            end
        end
        return list
    end
end

function M.reduce(initial, fn)
    if type(fn) ~= "function" then
        error("pipe.reduce requires a function", 2)
    end
    return function(list)
        local acc = initial
        if not list then
            return acc
        end
        for i, v in ipairs(list) do
            acc = fn(acc, v, i, list)
        end
        return acc
    end
end

return M

