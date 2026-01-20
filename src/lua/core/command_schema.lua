-- @file command_schema.lua
--
-- Declarative command parameter schemas + validation.
-- This is the choke point: errors here should be early, loud (in dev), and boring.

--
-- Extras:
--   SPEC.requires_any = { { "a", "b" }, { "c", "d" } }
--     Each group requires at least one key present.
--
--   Nested table normalization (single choke point):
--     For params that are tables, a rule can declare:
--       accept_legacy_keys = { canonical = { "alias1", "alias2" } }
--         Copies the first present alias into canonical when canonical is missing.
--         Use this for temporary refactors or schema tidy-ups so executors do NOT need
--         to do shape-compat glue.
--       fields = { field = { required=true, kind=..., one_of=..., default=..., empty_as_nil=true } }
--         Validates/normalizes fields inside the nested table.
--       requires_fields = { "field1", "field2" }
--         Shorthand: nested table must carry these fields (presence-only).
--
local M = {}
local asserts_module = require("core.asserts")


-- Schema conventions (read me before editing SPECs):
--   SPEC.args:
--     Public, caller-provided inputs. These are strict:
--       - unknown keys are rejected (except ephemeral __keys)
--       - required=true is enforced here
--       - defaults are applied here when apply_defaults=true
--
--   SPEC.persisted:
--     Executor-written undo/redo payload that is persisted on the command record.
--     These keys are allowed by strict validation, and lightly type-checked,
--     but are NOT considered caller inputs (required is not enforced by default).
--     Use this for fields like original_* snapshots, executed_* logs, and clamped_* results.
--
--   Ephemeral __keys:
--     Scratch fields that should NOT be persisted (command.lua excludes them from persistence).
--     Schema always allows __keys without listing them.
--
-- Rule fields commonly used:
--   required=true          caller must supply (args only)
--   kind="string|number|boolean|table"
--   default=<value>        applied when apply_defaults=true and key is absent
--   empty_as_nil=true      converts "" to nil before required checks
--   one_of={...} / enum={...}
--   accept_legacy_keys={ dst = { "old1", "old2" }, ... }   (table-valued param only)
--   fields={ ... }         nested table field rules (table-valued param only)

--- @fn is_ephemeral_key
--- @role internal
--- @idiom Only used by command_schema validation to allow ephemeral ("__*") keys in packets.

local function is_ephemeral_key(k)
    return type(k) == "string" and k:sub(1, 2) == "__"
end


--- @fn describe
--- @role internal
--- @idiom Only used for error messages; accepts nil.

local function describe(v)
    if v == nil then
        return "nil"
    end
    return string.format("%s(%s)", type(v), tostring(v))
end


--- @fn is_kind
--- @role internal
--- @idiom Type checking helper for validating parameter kinds.

local function is_kind(expected_kind, value)
    return type(value) == expected_kind
end


--- @fn normalize_spec
--- @role internal
--- @idiom Only called by validate_and_normalize after spec is known non-nil.
--- @notes Enforces rule.kind is always set; normalizes shorthand spec forms.

local function normalize_spec(spec)
    assert(spec ~= nil, "normalize_spec called with nil spec")
    if spec.args == nil then
        spec = { args = spec }
    end

    -- Normalize rules: always provide an explicit kind so schemas are never underspecified.
    local function normalize_rules(rules)
        for _, rule in pairs(rules or {}) do
            if type(rule) == "table" and rule.kind == nil then
                rule.kind = "any"
            end
        end
    end
    normalize_rules(spec.args)
    normalize_rules(spec.persisted)

    return spec
end


--- @fn kind_ok
--- @role internal
--- @idiom Only used by validate_and_normalize.

local function kind_ok(kind, v)
    assert(kind ~= nil, "schema rule missing kind")
    if kind == "any" then
        return true
    end
    return type(v) == kind
end

local function is_present(v)
    if v == nil then
        return false
    end
    if type(v) == "string" and v == "" then
        return false
    end
    return true
end

function M.validate_and_normalize(command_name, spec, params, opts)
    opts = opts or {}
    if opts.is_ui_context == nil then
        opts.is_ui_context = false
    end

    local asserts_enabled = opts.asserts_enabled
    if asserts_enabled == nil then
        asserts_enabled = asserts_module.enabled()
    end

    local function fail(msg)
        if asserts_enabled then
            assert(false, msg)
        end
        return false, nil, msg
    end

    if spec == nil then
        return fail(string.format("No schema registered for command '%s'", tostring(command_name)))
    end
    spec = normalize_spec(spec)
    if type(params) ~= "table" then
        return fail(string.format("Command '%s' params must be a table (got %s)", tostring(command_name), type(params)))
    end

    local args = spec.args or {}
    local persisted = spec.persisted or {}
    local out
    if opts.apply_defaults then
        -- When applying defaults, start from caller-provided params and fill missing keys.
        -- (Do not start from an empty table, or we silently drop caller inputs.)
        out = {}
        for k, v in pairs(params) do
            out[k] = v
        end
    else
        out = params
    end

    -- Aliases: allow alternate key names that normalize into a canonical param.
    local allowed_keys = {}
    local alias_to_canonical = {}

    local function register_keys(rules)
        for k, rule in pairs(rules) do
            allowed_keys[k] = true
            if type(rule) == "table" and rule.aliases ~= nil then
                assert(type(rule.aliases) == "table", "schema aliases must be a table")
                for _, a in ipairs(rule.aliases) do
                    assert(type(a) == "string", "schema alias must be a string")
                    assert(alias_to_canonical[a] == nil, string.format("schema alias '%s' duplicated", tostring(a)))
                    alias_to_canonical[a] = k
                    allowed_keys[a] = true
                end
            end
        end
    end

    register_keys(args)
    register_keys(persisted)

    -- Unknown keys (except ephemeral)
    for k, _ in pairs(params) do
        if (not is_ephemeral_key(k)) and (not allowed_keys[k]) then
            return fail(string.format("Command '%s' has unknown param '%s'", tostring(command_name), tostring(k)))
        end
    end

    -- Normalize aliases into canonical keys (in-place).
    for alias, canonical in pairs(alias_to_canonical) do
        if params[alias] ~= nil then
            if params[canonical] ~= nil then
                return fail(string.format("Command '%s' has both '%s' and alias '%s'", tostring(command_name), tostring(canonical), tostring(alias)))
            end
            params[canonical] = params[alias]
            params[alias] = nil
        end
    end
    -- Required keys, defaults, kind checks, and nested-table normalization.
    local function apply_rules(rules, enforce_required)
        for k, rule in pairs(rules or {}) do
            local v = out[k]

            if v == "" and rule.empty_as_nil then
                v = nil
                out[k] = nil
            end

            if v == nil and opts.apply_defaults and rule.default ~= nil then
                v = rule.default
                out[k] = v
            end

            local required = rule.required
            -- Readability-oriented rule:
            --   required_outside_ui_context = true
            -- means: the arg may be omitted for UI-origin commands, but is required for
            -- non-UI origins.
            if rule.required_outside_ui_context and (not opts.is_ui_context) then
                required = true
            end

            if enforce_required and required and v == nil then
                return false, string.format("Command '%s' missing required param '%s'", command_name, k)
            end

            if v ~= nil and rule.kind then
                if type(v) ~= rule.kind then
                    return false, string.format("Command '%s' param '%s' must be a %s", command_name, k, rule.kind)
                end
            end

            if v ~= nil and rule.one_of then
                local ok = false
                for _, allowed in ipairs(rule.one_of) do
                    if v == allowed then
                        ok = true
                        break
                    end
                end
                if not ok then
                    return false, string.format(
                        "Command '%s' param '%s' must be one of: %s",
                        command_name,
                        k,
                        table.concat(rule.one_of, ", ")
                    )
                end
            end

            -- Nested-table validation/normalization.
            -- This is where we keep the command schemas strict without forcing every executor
            -- to hand-normalize shapes before calling Command.set_parameter().
            if v ~= nil and type(v) == "table" then
                if rule.accept_legacy_keys then
                    for canonical, alternates in pairs(rule.accept_legacy_keys) do
                        if v[canonical] == nil then
                            for _, alt in ipairs(alternates) do
                                if v[alt] ~= nil then
                                    v[canonical] = v[alt]
                                    break
                                end
                            end
                        end
                    end
                end

                if rule.fields then
                    for field_key, field_rule in pairs(rule.fields) do
                        local field_val = v[field_key]

                        if field_val == "" and field_rule.empty_as_nil then
                            field_val = nil
                            v[field_key] = nil
                        end

                        if field_val == nil and opts.apply_defaults and field_rule.default ~= nil then
                            field_val = field_rule.default
                            v[field_key] = field_val
                        end

                        if enforce_required and field_rule.required and field_val == nil then
                            return false, string.format(
                                "Command '%s' param '%s.%s' missing required field",
                                command_name,
                                k,
                                field_key
                            )
                        end

                        if field_val ~= nil and field_rule.kind then
                            if type(field_val) ~= field_rule.kind then
                                return false, string.format(
                                    "Command '%s' param '%s.%s' must be a %s",
                                    command_name,
                                    k,
                                    field_key,
                                    field_rule.kind
                                )
                            end
                        end

                        if field_val ~= nil and field_rule.one_of then
                            local ok_field = false
                            for _, allowed in ipairs(field_rule.one_of) do
                                if field_val == allowed then
                                    ok_field = true
                                    break
                                end
                            end
                            if not ok_field then
                                return false, string.format(
                                    "Command '%s' param '%s.%s' must be one of: %s",
                                    command_name,
                                    k,
                                    field_key,
                                    table.concat(field_rule.one_of, ", ")
                                )
                            end
                        end
                    end
                end

                if rule.requires_fields then
                    for _, required_field in ipairs(rule.requires_fields) do
                        if v[required_field] == nil then
                            return false, string.format(
                                "Command '%s' param '%s' missing required field '%s'",
                                command_name,
                                k,
                                required_field
                            )
                        end
                    end
                end

                if rule.requires_methods then
                    for _, required_method in ipairs(rule.requires_methods) do
                        if type(v[required_method]) ~= "function" then
                            return false, string.format(
                                "Command '%s' param '%s' missing required method '%s'",
                                command_name,
                                k,
                                required_method
                            )
                        end
                    end
                end
            end
        end

        return true, nil
    end

    apply_rules(args, true)
    apply_rules(persisted, opts.require_persisted == true)

    -- Cross-field constraints: requires_any groups
    if spec.requires_any ~= nil then
        for _, group in ipairs(spec.requires_any) do
            local ok = false
            for _, key in ipairs(group) do
                if is_present(params[key]) then
                    ok = true
                    break
                end
            end
            if not ok then
                return fail(string.format(
                    "Command '%s' requires at least one of: %s",
                    tostring(command_name),
                    table.concat(group, ", ")
                ))
            end
        end
    end

    return true, out, nil
end

return M
