#!/usr/bin/env luajit

-- Regression: relinking with a missing search directory must surface
-- an actionable error mentioning the bad path, not a cryptic
-- "command failed (exit 256)" from the shelled-out `find`.
--
-- Domain: user picks (or has persisted) a Reconnect-Media search
-- folder that doesn't exist at scan time. Either the user typo'd it
-- or the folder was deleted/renamed between sessions. The relinker
-- must fail fast with the missing path in the message so the user
-- can act, not bury it under shell exit-code arithmetic.

require('test_env')

local media_relinker = require("core.media_relinker")

local BAD_PATH = "/tmp/jve_test_definitely_does_not_exist_" .. tostring(os.time())

local ok, err = pcall(function()
    media_relinker.relink_media_batch(
        { { media_id = "m1", media_name = "x.mov", media_path = "/tmp/x.mov" } },
        {
            search_paths = { BAD_PATH },
            matching_rules = { filename = true },
            clip_loader = function() return {} end,
        },
        function() end
    )
end)

assert(not ok, "expected relink_media_batch to fail on missing search dir")
assert(type(err) == "string",
    "expected string error, got " .. type(err))
assert(err:find(BAD_PATH, 1, true),
    string.format("error must name the bad path; got: %q", err))
assert(err:find("does not exist", 1, true)
    or err:find("doesn't exist", 1, true),
    string.format("error must say the path doesn't exist; got: %q", err))
assert(not err:find("exit 256", 1, true),
    string.format("error must not leak the raw 'exit 256' shell wrapping; got: %q", err))

print("✅ test_relink_missing_search_dir.lua passed")
