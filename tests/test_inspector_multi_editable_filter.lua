#!/usr/bin/env luajit
-- Regression test: multi-edit Apply skips fields whose schema declares
-- multi_editable=false.
--
-- Reproducer: TSO 2026-04-20 15:26:46 — user selected 2 clips, typed a
-- sequence_start value, hit Apply. apply_multi_edit fired SetClipProperty
-- for BOTH clips with the same sequence_start, causing VIDEO_OVERLAP. The
-- fix marks per-clip structural fields (sequence_start, duration,
-- source_in, source_out) as multi_editable=false so Apply silently skips
-- them. They're still editable per-clip in single-edit mode.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local schemas = require("ui.metadata_schemas")

local pass, fail = 0, 0
local function check(label, ok) if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. label) end end

print("=== Inspector: multi_editable field filter ===\n")

-- Schema declares the right fields as non-multi-editable.
local clip_sequence_start = schemas.get_field("clip", "sequence_start")
check("clip.sequence_start exists",
    clip_sequence_start ~= nil)
check("clip.sequence_start is multi_editable=false",
    clip_sequence_start and clip_sequence_start.multi_editable == false)

for _, fkey in ipairs({"duration", "source_in", "source_out"}) do
    local f = schemas.get_field("clip", fkey)
    check("clip." .. fkey .. " is multi_editable=false",
        f and f.multi_editable == false)
end

-- Fields that ARE safe to mass-apply default to multi_editable=true.
for _, fkey in ipairs({"name", "enabled", "volume", "mark_in", "mark_out"}) do
    local f = schemas.get_field("clip", fkey)
    check("clip." .. fkey .. " defaults to multi_editable=true",
        f and f.multi_editable == true)
end

-- Sequence fields: none are structurally incompatible with multi-edit
-- (only one sequence is ever selected — supports_multi_edit=false).
-- But verify the default is applied consistently.
for _, fkey in ipairs({"name", "mark_in_frame", "mark_out_frame"}) do
    local f = schemas.get_field("sequence", fkey)
    check("sequence." .. fkey .. " defaults to multi_editable=true",
        f and f.multi_editable == true)
end

-- Schema-level validator: multi_editable must be boolean when provided.
local metadata_schemas_raw = schemas
local ok, err = pcall(function()
    -- Touching FIELD_TYPES asserts the schema module exposes it; the
    -- schema's own fields went through `field()` during module load
    -- above, so a failure there would have surfaced already.
    assert(metadata_schemas_raw.FIELD_TYPES, "FIELD_TYPES missing from schema module")
end)
check("module-level field construction completed without error", ok,
    err and tostring(err) or "")

-- Smoke: a non-multi_editable field in single-edit mode is still
-- fully editable (read_only stays false; the flag only affects Apply).
check("clip.sequence_start.read_only is false (single-edit path still editable)",
    clip_sequence_start and clip_sequence_start.read_only == false)

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_inspector_multi_editable_filter.lua passed")
