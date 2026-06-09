#!/usr/bin/env luajit
-- Regression test for audit pass 19f architectural follow-up.
--
-- Before this commit, a producer that emitted legacy `_value`-suffixed
-- field names on an insert mutation (`start_value`/`duration_value`)
-- would PASS the `add_insert_mutation` validator and only fail
-- DOWNSTREAM in `clip_geometry.normalize_clip_integers` — which runs
-- AFTER `db_module.commit()`. The UI assert orphaned committed DB rows
-- (audit pass 19f: clip d73cd0fc-... contaminated run=15 of the
-- property harness).
--
-- The fix shifts that validation upstream: `add_insert_mutation` now
-- asserts canonical shape (id + track_id + numeric sequence_start +
-- positive numeric duration) and rejects legacy `_value`-suffixed
-- names. The assert fires inside the active transaction, so the
-- command_manager rollback path runs and the DB stays clean.
--
-- Test contract (domain behavior, no implementation tracing):
--   1. A mutation payload using the legacy `_value` field shape MUST
--      be rejected at add_insert_mutation time — not silently accepted
--      and not propagated to UI.
--   2. A mutation payload missing the canonical `sequence_start` field
--      MUST be rejected.
--   3. A mutation payload missing the canonical `duration` field MUST
--      be rejected.
--   4. A complete canonical payload MUST be accepted.

require("test_env")

local command_helper = require("core.command_helper")

-- Minimal command stub: stores parameters in a table, returns them via
-- get_parameter. command_helper.add_insert_mutation needs set_parameter
-- and get_parameter; that's the whole surface area.
local function make_command(seq_id)
    local params = { project_id = "proj", sequence_id = seq_id }
    return {
        type = "TestCommand",
        sequence_id = seq_id,
        get_parameter = function(self, name) return params[name] end,
        set_parameter = function(self, name, value) params[name] = value end,
        get_all_parameters = function(self) return params end,
        params = params,  -- direct peek for assertions
    }
end

local SEQ = "seq_test"

-- (1) Legacy `_value`-suffixed shape — must be rejected loudly.
do
    local cmd = make_command(SEQ)
    local ok, err = pcall(function()
        command_helper.add_insert_mutation(cmd, SEQ, {
            id = "clip_legacy",
            track_id = "track_v1",
            -- the bug shape — these are NOT the canonical names
            start_value     = 100,
            duration_value  = 50,
            source_in_value = 0,
            source_out_value = 50,
            enabled = true,
        })
    end)
    assert(not ok,
        "expected legacy `_value`-suffixed insert mutation to be rejected, but it was accepted")
    assert(type(err) == "string" and err:find("legacy") ~= nil,
        "expected rejection message to call out the legacy shape, got: " .. tostring(err))
    print("✅ legacy `_value`-suffixed shape rejected")
end

-- (2) Canonical shape missing `sequence_start` — must be rejected.
do
    local cmd = make_command(SEQ)
    local ok, err = pcall(function()
        command_helper.add_insert_mutation(cmd, SEQ, {
            id = "clip_nostart",
            track_id = "track_v1",
            duration = 50,
            source_in = 0,
            source_out = 50,
        })
    end)
    assert(not ok,
        "expected insert payload missing sequence_start to be rejected")
    assert(type(err) == "string" and err:find("sequence_start") ~= nil,
        "expected rejection message to mention sequence_start, got: " .. tostring(err))
    print("✅ missing sequence_start rejected")
end

-- (3) Canonical shape missing `duration` — must be rejected.
do
    local cmd = make_command(SEQ)
    local ok, err = pcall(function()
        command_helper.add_insert_mutation(cmd, SEQ, {
            id = "clip_nodur",
            track_id = "track_v1",
            sequence_start = 100,
            source_in = 0,
            source_out = 50,
        })
    end)
    assert(not ok,
        "expected insert payload missing duration to be rejected")
    assert(type(err) == "string" and err:find("duration") ~= nil,
        "expected rejection message to mention duration, got: " .. tostring(err))
    print("✅ missing duration rejected")
end

-- (4) Complete canonical shape — must be accepted, stored in bucket.
do
    local cmd = make_command(SEQ)
    command_helper.add_insert_mutation(cmd, SEQ, {
        id             = "clip_good",
        track_id       = "track_v1",
        sequence_start = 100,
        duration       = 50,
        source_in      = 0,
        source_out     = 50,
        enabled        = true,
    })
    local muts = cmd:get_parameter("__timeline_mutations")
    assert(type(muts) == "table", "expected mutation bucket to be set")
    -- Single-bucket and multi-bucket shapes both expose an inserts list
    -- somewhere; locate the entry by id (no implementation tracing).
    local found
    local function scan(bucket)
        if type(bucket) ~= "table" then return end
        if type(bucket.inserts) == "table" then
            for _, e in ipairs(bucket.inserts) do
                if e.id == "clip_good" then found = e; return end
            end
        end
        for _, sub in pairs(bucket) do scan(sub) end
    end
    scan(muts)
    assert(found, "expected canonical insert to land in __timeline_mutations")
    assert(found.sequence_start == 100, "canonical sequence_start preserved")
    assert(found.duration == 50, "canonical duration preserved")
    print("✅ complete canonical shape accepted")
end

print("✅ test_mutation_shape_caught_at_executor passed")
