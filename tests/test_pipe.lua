require("test_env")

local pipe = require("core.pipe")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

local function expect_error(label, fn, pattern)
    local ok, err = pcall(fn)
    if not ok then
        if pattern and not tostring(err):match(pattern) then
            fail_count = fail_count + 1
            print("FAIL (wrong error): " .. label .. " got: " .. tostring(err))
        else
            pass_count = pass_count + 1
        end
    else
        fail_count = fail_count + 1
        print("FAIL (expected error): " .. label)
    end
end

print("\n=== Pipe Tests (T21) ===")

-- ============================================================
-- pipe() — basic composition
-- ============================================================
print("\n--- pipe ---")
do
    -- Identity: no transforms
    check("pipe identity", pipe.pipe(42) == 42)

    -- Single transform
    check("pipe single fn", pipe.pipe(5, function(x) return x * 2 end) == 10)

    -- Chained transforms
    check("pipe chain", pipe.pipe(3,
        function(x) return x + 1 end,
        function(x) return x * 10 end
    ) == 40)

    -- Three transforms
    check("pipe triple", pipe.pipe("hello",
        function(s) return s .. " " end,
        function(s) return s .. "world" end,
        function(s) return #s end
    ) == 11)

    -- nil value flows through
    check("pipe nil value", pipe.pipe(nil, function(x) return x end) == nil)

    -- Table value
    local t = pipe.pipe({1, 2, 3}, function(list)
        local sum = 0
        for _, v in ipairs(list) do sum = sum + v end
        return sum
    end)
    check("pipe table value", t == 6)
end

-- ============================================================
-- map() — transform each element
-- ============================================================
print("\n--- map ---")
do
    -- Basic mapping
    local doubled = pipe.map(function(x) return x * 2 end)({1, 2, 3})
    check("map basic length", #doubled == 3)
    check("map basic [1]", doubled[1] == 2)
    check("map basic [2]", doubled[2] == 4)
    check("map basic [3]", doubled[3] == 6)

    -- Index passed as second arg
    local indices = pipe.map(function(v, i) return i end)({10, 20, 30})
    check("map index arg", indices[1] == 1 and indices[2] == 2 and indices[3] == 3)

    -- List passed as third arg
    local got_list = false
    pipe.map(function(v, i, list)
        if list and #list == 2 then got_list = true end
        return v
    end)({7, 8})
    check("map list arg", got_list)

    -- Empty list → empty
    check("map empty", #pipe.map(function(x) return x end)({}) == 0)

    -- nil list → empty
    check("map nil list", #pipe.map(function(x) return x end)(nil) == 0)

    -- Non-function → error
    expect_error("map non-function", function() pipe.map("not a fn") end, "requires a function")
end

-- ============================================================
-- filter() — keep matching elements
-- ============================================================
print("\n--- filter ---")
do
    -- Basic filtering
    local evens = pipe.filter(function(x) return x % 2 == 0 end)({1, 2, 3, 4, 5, 6})
    check("filter basic length", #evens == 3)
    check("filter basic values", evens[1] == 2 and evens[2] == 4 and evens[3] == 6)

    -- Filter all → empty
    check("filter all out", #pipe.filter(function() return false end)({1, 2, 3}) == 0)

    -- Filter none → same
    local all = pipe.filter(function() return true end)({1, 2, 3})
    check("filter none out", #all == 3 and all[1] == 1)

    -- Empty list → empty
    check("filter empty", #pipe.filter(function() return true end)({}) == 0)

    -- nil list → empty
    check("filter nil list", #pipe.filter(function() return true end)(nil) == 0)

    -- Non-function → error
    expect_error("filter non-function", function() pipe.filter(42) end, "requires a function")
end

-- ============================================================
-- flat_map() — map then flatten
-- ============================================================
print("\n--- flat_map ---")
do
    -- Return table → flattened
    local result = pipe.flat_map(function(x) return {x, x * 10} end)({1, 2, 3})
    check("flat_map table length", #result == 6)
    check("flat_map table values", result[1] == 1 and result[2] == 10
        and result[3] == 2 and result[4] == 20
        and result[5] == 3 and result[6] == 30)

    -- Return scalar → collected
    local scalars = pipe.flat_map(function(x) return x * 2 end)({5, 6})
    check("flat_map scalar length", #scalars == 2)
    check("flat_map scalar values", scalars[1] == 10 and scalars[2] == 12)

    -- Return nil → skipped
    local sparse = pipe.flat_map(function(x)
        if x % 2 == 0 then return nil end
        return x
    end)({1, 2, 3, 4, 5})
    check("flat_map nil skip", #sparse == 3)
    check("flat_map nil values", sparse[1] == 1 and sparse[2] == 3 and sparse[3] == 5)

    -- Mixed: some tables, some scalars, some nil
    local mixed = pipe.flat_map(function(x)
        if x == 1 then return {10, 11} end
        if x == 2 then return nil end
        return x * 100
    end)({1, 2, 3})
    check("flat_map mixed length", #mixed == 3)
    check("flat_map mixed values", mixed[1] == 10 and mixed[2] == 11 and mixed[3] == 300)

    -- Empty list → empty
    check("flat_map empty", #pipe.flat_map(function(x) return x end)({}) == 0)

    -- nil list → empty
    check("flat_map nil list", #pipe.flat_map(function(x) return x end)(nil) == 0)

    -- Index and list args passed
    local got_args = false
    pipe.flat_map(function(v, i, list)
        if i == 2 and #list == 2 then got_args = true end
        return v
    end)({7, 8})
    check("flat_map index+list args", got_args)

    -- Non-function → error
    expect_error("flat_map non-function", function() pipe.flat_map({}) end, "requires a function")
end

-- ============================================================
-- each() — side-effect iteration, returns original list
-- ============================================================
print("\n--- each ---")
do
    -- Iterates all elements
    local seen = {}
    local returned = pipe.each(function(v) seen[#seen+1] = v end)({10, 20, 30})
    check("each visits all", #seen == 3 and seen[1] == 10 and seen[2] == 20 and seen[3] == 30)

    -- Returns original list reference
    local original = {1, 2, 3}
    check("each returns original", pipe.each(function() end)(original) == original)

    -- Index and list args passed
    local got_i, got_list = false, false
    pipe.each(function(v, i, list)
        if i == 1 then got_i = true end
        if list and #list == 1 then got_list = true end
    end)({42})
    check("each index arg", got_i)
    check("each list arg", got_list)

    -- nil list → returns nil (no crash)
    check("each nil list", pipe.each(function() end)(nil) == nil)

    -- Empty list → returns empty
    local empty = {}
    check("each empty", pipe.each(function() end)(empty) == empty)

    -- Non-function → error
    expect_error("each non-function", function() pipe.each(nil) end, "requires a function")
end

-- ============================================================
-- reduce() — fold with initial value
-- ============================================================
print("\n--- reduce ---")
do
    -- Sum
    local sum = pipe.reduce(0, function(acc, v) return acc + v end)({1, 2, 3, 4})
    check("reduce sum", sum == 10)

    -- String concat
    local joined = pipe.reduce("", function(acc, v) return acc .. v end)({"a", "b", "c"})
    check("reduce concat", joined == "abc")

    -- Index and list args passed
    local last_i, got_list2 = 0, false
    pipe.reduce(0, function(acc, v, i, list)
        last_i = i
        if list and #list == 3 then got_list2 = true end
        return acc + v
    end)({10, 20, 30})
    check("reduce index arg", last_i == 3)
    check("reduce list arg", got_list2)

    -- Empty list → returns initial
    check("reduce empty", pipe.reduce(99, function(acc, v) return acc + v end)({}) == 99)

    -- nil list → returns initial
    check("reduce nil list", pipe.reduce(99, function(acc, v) return acc + v end)(nil) == 99)

    -- Non-function → error
    expect_error("reduce non-function", function() pipe.reduce(0, "bad") end, "requires a function")
end

-- ============================================================
-- pipe() + combinators — full pipeline composition
-- ============================================================
print("\n--- pipe integration ---")
do
    -- Filter evens → double → sum
    local result = pipe.pipe({1, 2, 3, 4, 5, 6},
        pipe.filter(function(x) return x % 2 == 0 end),
        pipe.map(function(x) return x * 2 end),
        pipe.reduce(0, function(acc, v) return acc + v end)
    )
    check("full pipeline", result == 24)  -- (2+4+6)*2 = 24

    -- flat_map in pipeline
    local expanded = pipe.pipe({1, 2},
        pipe.flat_map(function(x) return {x, x + 10} end),
        pipe.filter(function(x) return x > 5 end)
    )
    check("pipeline with flat_map", #expanded == 2 and expanded[1] == 11 and expanded[2] == 12)

    -- each in pipeline (passthrough)
    local log = {}
    local out = pipe.pipe({3, 6, 9},
        pipe.each(function(v) log[#log+1] = v end),
        pipe.map(function(x) return x / 3 end)
    )
    check("pipeline each passthrough", #log == 3 and out[1] == 1 and out[2] == 2 and out[3] == 3)
end

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n=== Pipe: %d passed, %d failed ===", pass_count, fail_count))
if fail_count > 0 then
    os.exit(1)
end
print("✅ test_pipe.lua passed")
