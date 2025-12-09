-- Shim to make `require("test_env")` work when running tests from repository root.
-- Delegates to the real helper under tests/test_env.lua.
return require("tests.test_env")
