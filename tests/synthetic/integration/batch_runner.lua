--- Batch runner for integration tests.
-- Executes multiple test scripts sequentially in a single JVEEditor process.
-- Each test runs via pcall(dofile) so failures don't abort the suite.
--
-- @file batch_runner.lua

local M = {}

--- Resolve test paths relative to a given directory.
-- @param dir string Directory containing the test files
-- @param names table Array of test filenames
-- @return table Array of absolute paths
function M.resolve_paths(dir, names)
    local paths = {}
    for _, name in ipairs(names) do
        table.insert(paths, dir .. "/" .. name)
    end
    return paths
end

--- Run a list of test scripts, report results.
-- @param batch_name string Name for reporting
-- @param test_paths table Array of absolute paths to test scripts
-- @return number passed, number failed
function M.run(batch_name, test_paths)
    local passed = 0
    local failed = 0
    local failures = {}

    print(string.format("[batch:%s] Running %d test(s)...", batch_name, #test_paths))

    for _, path in ipairs(test_paths) do
        local basename = path:match("([^/]+)$") or path
        local ok, err = pcall(dofile, path)
        if ok then
            passed = passed + 1
        else
            failed = failed + 1
            table.insert(failures, {name = basename, error = tostring(err)})
            io.stderr:write(string.format("[batch:%s] FAIL: %s\n  %s\n",
                batch_name, basename, tostring(err)))
        end
    end

    print(string.format("[batch:%s] %d/%d passed, %d failed",
        batch_name, passed, #test_paths, failed))

    if failed > 0 then
        print(string.format("\n[batch:%s] Failed tests:", batch_name))
        for _, f in ipairs(failures) do
            print(string.format("  %s: %s", f.name, f.error))
        end
    end

    return passed, failed
end

return M
