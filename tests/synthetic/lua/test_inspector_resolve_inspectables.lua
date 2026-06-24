#!/usr/bin/env luajit
-- Unit test T012b: resolve_inspectables helper (/analyze U1).
-- Black-box: exercises the items → {inspectables_by_schema, schema_counts} mapping.
-- Uses items that carry a pre-built `inspectable` (avoids needing a real DB).

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local sb = require("ui.inspector.selection_binding")

local pass, fail = 0, 0
local function check(label, ok, msg) if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. label .. (msg and (": " .. msg) or "")) end end

print("=== Inspector: resolve_inspectables unit test ===\n")

local function fake_inspectable(schema_id, name)
    return {
        schema_id = schema_id,
        get_schema_id = function(self) return self.schema_id end,
        get_display_name = function(self) return name end,
        supports_multi_edit = function() return true end,
    }
end

-- Mixed selection of clips + a sequence via pre-built inspectables.
do
    local clip1 = fake_inspectable("clip", "C1")
    local clip2 = fake_inspectable("clip", "C2")
    local seq1  = fake_inspectable("sequence", "Main")
    local items = {
        { item_type = "timeline_clip",     clip_id = "c1",     inspectable = clip1 },
        { item_type = "timeline_clip",     clip_id = "c2",     inspectable = clip2 },
        { item_type = "timeline_sequence", sequence_id = "s1", inspectable = seq1  },
    }
    local result = sb._resolve_inspectables(items)
    check("schema_counts.clip = 2",     result.schema_counts.clip == 2)
    check("schema_counts.sequence = 1", result.schema_counts.sequence == 1)
    check("clip group has 2 members",   #result.inspectables_by_schema.clip == 2)
    check("sequence group has 1 member",#result.inspectables_by_schema.sequence == 1)
    check("clip[1] display = C1",       result.names_by_schema.clip[1] == "C1")
    check("clip[2] display = C2",       result.names_by_schema.clip[2] == "C2")
    check("sequence display = Main",    result.names_by_schema.sequence[1] == "Main")
end

-- master_clip carries a pre-built master_clip inspectable through.
do
    local mc = fake_inspectable("master_clip", "Boom")
    local items = {
        { item_type = "master_clip", sequence_id = "ms1", inspectable = mc },
    }
    local result = sb._resolve_inspectables(items)
    check("schema_counts.master_clip = 1",     result.schema_counts.master_clip == 1)
    check("master_clip group has 1 member",
        #result.inspectables_by_schema.master_clip == 1)
    check("master_clip display = Boom",
        result.names_by_schema.master_clip[1] == "Boom")
end

-- Heterogeneous: a clip + a master_clip live in DIFFERENT schema buckets
-- (the bug being fixed — both used to map to schema_id="clip").
do
    local c  = fake_inspectable("clip",        "C")
    local mc = fake_inspectable("master_clip", "M")
    local items = {
        { item_type = "timeline_clip", clip_id = "c", inspectable = c  },
        { item_type = "master_clip",   sequence_id = "ms", inspectable = mc },
    }
    local result = sb._resolve_inspectables(items)
    check("clip and master_clip do not collide: clip=1",
        result.schema_counts.clip == 1)
    check("clip and master_clip do not collide: master_clip=1",
        result.schema_counts.master_clip == 1)
end

-- Unknown item_type is silently dropped (selection hub is opaque).
do
    local keep = fake_inspectable("clip", "kept")
    local items = {
        { item_type = "timeline_clip", clip_id = "c", inspectable = keep },
        { item_type = "bogus_item",    id = "xyz" },
    }
    local result = sb._resolve_inspectables(items)
    check("unknown item_type dropped: count=1", result.schema_counts.clip == 1)
    check("unknown item_type: no bogus entry", result.schema_counts.bogus_item == nil)
end

-- Empty items → empty result.
do
    local result = sb._resolve_inspectables({})
    local count = 0; for _ in pairs(result.schema_counts) do count = count + 1 end
    check("empty items → no schemas counted", count == 0)
end

-- Item with display_name overrides inspectable:get_display_name.
do
    local insp = fake_inspectable("clip", "InspName")
    local items = {
        { item_type = "timeline_clip", clip_id = "c1", inspectable = insp, display_name = "ItemName" }
    }
    local result = sb._resolve_inspectables(items)
    check("item display_name wins over inspectable's", result.names_by_schema.clip[1] == "ItemName")
end

-- Item keying: clip_id path.
check("item_key uses clip_id",
    sb._item_key({ clip_id = "abc", item_type = "timeline_clip" }) == "clip:abc",
    "")
check("item_key falls back to sequence_id",
    sb._item_key({ sequence_id = "s", item_type = "timeline_sequence" }) == "seq:s",
    "")

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_inspector_resolve_inspectables.lua passed")
