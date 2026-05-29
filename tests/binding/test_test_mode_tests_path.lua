-- Regression: --test mode must put the source tests/ tree on package.path.
--
-- Under the .app bundle layout the application directory resolves to
-- Contents/Resources, where tests/ is never bundled. If --test derives the
-- tests dir from appDir it points at a nonexistent Resources/tests, and any
-- binding/integration test that require()s a sibling module under tests/
-- (e.g. integration.ui_test_env, import_schema) dies with "module not found".
--
-- These modules live directly under tests/ and tests/integration/ and require
-- nothing but the source tree, so loading them proves the tests/ tree is on
-- package.path regardless of bundle vs bare-binary layout.

local ok_schema, schema = pcall(require, "import_schema")
assert(ok_schema, "require('import_schema') failed — tests/ not on package.path: " .. tostring(schema))
assert(schema ~= nil, "import_schema loaded but returned nil")

local ok_env, env = pcall(require, "integration.ui_test_env")
assert(ok_env, "require('integration.ui_test_env') failed — tests/ not on package.path: " .. tostring(env))
assert(env ~= nil, "integration.ui_test_env loaded but returned nil")

print("✅ test_test_mode_tests_path.lua passed")
