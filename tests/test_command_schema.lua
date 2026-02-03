require("test_env")

local command_schema = require("core.command_schema")

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
    return err
end

print("\n=== Command Schema Tests (T10) ===")

-- Disable asserts so we get (false, nil, msg) return instead of Lua errors
local asserts_mod = require("core.asserts")
local was_enabled = asserts_mod.enabled()
asserts_mod._set_enabled_for_tests(false)

-- ============================================================
-- nil spec
-- ============================================================
print("\n--- nil spec ---")
do
    local ok, out, err = command_schema.validate_and_normalize("TestCmd", nil, {})
    check("nil spec fails", ok == false)
    check("nil spec error msg", err:find("No schema registered") ~= nil)
end

-- ============================================================
-- non-table params
-- ============================================================
print("\n--- non-table params ---")
do
    local spec = { args = { name = { kind = "string" } } }
    local ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, "not a table")
    check("string params fails", ok == false)
    check("string params error msg", err:find("params must be a table") ~= nil)

    ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, nil)
    check("nil params fails", ok == false)
end

-- ============================================================
-- Unknown param rejection
-- ============================================================
print("\n--- unknown param rejection ---")
do
    local spec = { args = { name = { kind = "string" } } }
    local ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, { name = "ok", bogus = 42 })
    check("unknown param fails", ok == false)
    check("unknown param msg", err:find("unknown param 'bogus'") ~= nil)
end

-- ============================================================
-- Ephemeral __keys always allowed
-- ============================================================
print("\n--- ephemeral keys ---")
do
    local spec = { args = { name = { kind = "string" } } }
    local ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, { name = "ok", __scratch = true })
    check("ephemeral key allowed", ok == true)
end

-- ============================================================
-- Global allowed keys (sequence_id)
-- ============================================================
print("\n--- global allowed keys ---")
do
    local spec = { args = { name = { kind = "string" } } }
    local ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, { name = "ok", sequence_id = "seq1" })
    check("sequence_id allowed globally", ok == true)
end

-- ============================================================
-- Alias normalization
-- ============================================================
print("\n--- alias normalization ---")
do
    local spec = { args = { clip_name = { kind = "string", aliases = { "name" } } } }
    local params = { name = "test" }
    local ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, params)
    check("alias normalizes", ok == true)
    check("alias canonical set", params.clip_name == "test")
    check("alias original removed", params.name == nil)
end

-- ============================================================
-- Alias + canonical conflict
-- ============================================================
print("\n--- alias + canonical conflict ---")
do
    local spec = { args = { clip_name = { kind = "string", aliases = { "name" } } } }
    local ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, { clip_name = "a", name = "b" })
    check("alias conflict fails", ok == false)
    check("alias conflict msg", err:find("both.*and alias") ~= nil)
end

-- ============================================================
-- Bare spec normalization (no .args wrapper)
-- ============================================================
print("\n--- bare spec normalization ---")
do
    local spec = { clip_id = { kind = "string" } }
    local ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, { clip_id = "c1" })
    check("bare spec normalizes", ok == true)
end

-- ============================================================
-- apply_defaults
-- ============================================================
print("\n--- apply_defaults ---")
do
    local spec = { args = {
        mode = { kind = "string", default = "normal" },
        count = { kind = "number", default = 1 },
    } }
    local ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, {}, { apply_defaults = true })
    check("defaults applied success", ok == true)
    check("default mode", out.mode == "normal")
    check("default count", out.count == 1)

    -- Caller-provided values not overwritten
    ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, { mode = "custom" }, { apply_defaults = true })
    check("caller value preserved", out.mode == "custom")
    check("missing default still applied", out.count == 1)
end

-- ============================================================
-- empty_as_nil
-- ============================================================
print("\n--- empty_as_nil ---")
do
    local spec = { args = {
        name = { kind = "string", empty_as_nil = true },
    } }
    local params = { name = "" }
    local ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, params, { apply_defaults = false })
    check("empty_as_nil success", ok == true)
    check("empty string converted to nil", params.name == nil)
end

-- ============================================================
-- requires_any cross-field constraints
-- ============================================================
print("\n--- requires_any ---")
do
    local spec = {
        args = {
            clip_id = { kind = "string" },
            track_id = { kind = "string" },
            name = { kind = "string" },
        },
        requires_any = { { "clip_id", "track_id" } },
    }

    -- At least one present → success
    local ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, { clip_id = "c1" })
    check("requires_any satisfied", ok == true)

    -- Neither present → failure
    ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, { name = "x" })
    check("requires_any fails", ok == false)
    check("requires_any msg", err:find("requires at least one of") ~= nil)

    -- Empty string not considered present
    ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, { clip_id = "" })
    check("requires_any empty string not present", ok == false)
end

-- ============================================================
-- Persisted fields: allowed but not required by default
-- ============================================================
print("\n--- persisted fields ---")
do
    local spec = {
        args = { clip_id = { kind = "string" } },
        persisted = { original_state = { kind = "table" } },
    }
    -- persisted key allowed (not rejected as unknown)
    local ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, { clip_id = "c1", original_state = {} })
    check("persisted key allowed", ok == true)
end

-- ============================================================
-- apply_rules validation (fixed: return values now checked)
-- ============================================================
print("\n--- apply_rules validation ---")
do
    -- Required field missing → fails
    local spec = { args = { clip_id = { kind = "string", required = true } } }
    local ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, {})
    check("required field missing fails", ok == false)

    -- Wrong kind → fails
    spec = { args = { count = { kind = "number" } } }
    ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, { count = "not_a_number" })
    check("wrong kind fails", ok == false)

    -- one_of violation → fails
    spec = { args = { mode = { kind = "string", one_of = { "a", "b" } } } }
    ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, { mode = "c" })
    check("one_of violation fails", ok == false)

    -- Nested required field missing → fails
    spec = { args = { data = { kind = "table", fields = { id = { required = true, kind = "string" } } } } }
    ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, { data = {} })
    check("nested required missing fails", ok == false)
end

-- ============================================================
-- Nested table: accept_legacy_keys
-- ============================================================
print("\n--- nested: accept_legacy_keys ---")
do
    local spec = { args = {
        data = {
            kind = "table",
            accept_legacy_keys = { clip_name = { "name", "old_name" } },
        },
    } }
    local params = { data = { name = "legacy" } }
    local ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, params)
    check("legacy key success", ok == true)
    check("legacy key copied to canonical", params.data.clip_name == "legacy")

    -- canonical already present → not overwritten
    params = { data = { clip_name = "canonical", name = "legacy" } }
    ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, params)
    check("canonical preserved", params.data.clip_name == "canonical")
end

-- ============================================================
-- Nested table: requires_fields
-- ============================================================
print("\n--- nested: requires_fields ---")
do
    local spec = { args = {
        data = { kind = "table", requires_fields = { "id", "name" } },
    } }
    local ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, { data = { id = "x" } })
    check("requires_fields missing fails", ok == false)

    -- When all fields present → obviously passes
    ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, { data = { id = "x", name = "y" } })
    check("requires_fields all present", ok == true)
end

-- ============================================================
-- Nested table: requires_methods
-- ============================================================
print("\n--- nested: requires_methods ---")
do
    local spec = { args = {
        obj = { kind = "table", requires_methods = { "execute" } },
    } }
    -- With method → passes
    local ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, { obj = { execute = function() end } })
    check("requires_methods present", ok == true)

    -- Missing method → fails
    ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, { obj = {} })
    check("requires_methods missing fails", ok == false)
end

-- ============================================================
-- Nested table: fields with defaults
-- ============================================================
print("\n--- nested: fields with defaults ---")
do
    local spec = { args = {
        data = {
            kind = "table",
            fields = {
                mode = { kind = "string", default = "auto" },
                count = { kind = "number", default = 0 },
            },
        },
    } }
    local params = { data = {} }
    local ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, params, { apply_defaults = true })
    check("nested defaults success", ok == true)
    check("nested default mode", out.data.mode == "auto")
    check("nested default count", out.data.count == 0)
end

-- ============================================================
-- Nested table: fields with empty_as_nil
-- ============================================================
print("\n--- nested: fields with empty_as_nil ---")
do
    local spec = { args = {
        data = {
            kind = "table",
            fields = {
                tag = { kind = "string", empty_as_nil = true },
            },
        },
    } }
    local params = { data = { tag = "" } }
    local ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, params)
    check("nested empty_as_nil", ok == true)
    check("nested tag converted to nil", params.data.tag == nil)
end

-- ============================================================
-- required_outside_ui_context
-- ============================================================
print("\n--- required_outside_ui_context ---")
do
    local spec = { args = {
        track_id = { kind = "string", required_outside_ui_context = true },
    } }

    -- Non-UI context: required → fails when missing
    local ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, {}, { is_ui_context = false })
    check("required_outside_ui_context missing fails", ok == false)

    -- UI context: not required → passes
    ok, out, err = command_schema.validate_and_normalize("TestCmd", spec, {}, { is_ui_context = true })
    check("ui context not required", ok == true)
end

-- ============================================================
-- asserts_enabled: nil spec triggers assert when enabled
-- ============================================================
print("\n--- asserts_enabled behavior ---")
do
    -- Explicitly enable asserts via opts
    expect_error("nil spec with asserts_enabled=true", function()
        command_schema.validate_and_normalize("TestCmd", nil, {}, { asserts_enabled = true })
    end, "No schema registered")

    expect_error("unknown param with asserts_enabled=true", function()
        local spec = { args = { name = { kind = "string" } } }
        command_schema.validate_and_normalize("TestCmd", spec, { bogus = 1 }, { asserts_enabled = true })
    end, "unknown param 'bogus'")
end

-- ============================================================
-- Multiple alias keys
-- ============================================================
print("\n--- multiple aliases ---")
do
    local spec = { args = {
        clip_id = { kind = "string", aliases = { "id", "cid" } },
    } }
    local params = { cid = "c1" }
    local ok = command_schema.validate_and_normalize("TestCmd", spec, params)
    check("second alias normalizes", ok == true)
    check("second alias canonical set", params.clip_id == "c1")
end

-- ============================================================
-- Persisted + args: both allowed
-- ============================================================
print("\n--- args + persisted combined ---")
do
    local spec = {
        args = { clip_id = { kind = "string" } },
        persisted = { snapshot = { kind = "table" } },
    }
    local ok, out, err = command_schema.validate_and_normalize(
        "TestCmd", spec,
        { clip_id = "c1", snapshot = { x = 1 } }
    )
    check("args+persisted both accepted", ok == true)
end

-- Restore asserts
asserts_mod._set_enabled_for_tests(was_enabled)

-- ============================================================
-- Summary
-- ============================================================
print("")
print(string.format("Passed: %d  Failed: %d  Total: %d", pass_count, fail_count, pass_count + fail_count))
if fail_count > 0 then
    print("SOME TESTS FAILED")
    os.exit(1)
else
    print("✅ test_command_schema.lua passed")
end
