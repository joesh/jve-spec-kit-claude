-- T027 — helper read_grades contract
--           (spec 023, contracts/helper-protocol.md §read_grades).
--
-- read_grades pulls per-clip grade state from Resolve back into JVE
-- (FR-013/FR-014/FR-015). Args: `{ item_ids?: [string] }` (omit ⇒ all).
-- Result: `{ grades: [{ jve_guid, cdl?, lut?, fidelity }] }`.
--
-- Per-row fields:
--   • `jve_guid` — non-empty string (matches the JVE clip id; recovered
--     via the same marker/content channels as §read_identities — NOT
--     raw id equality with `clip.id`, per the T047 spike correction).
--   • `cdl?` — present only when the node graph is representable as
--     primary CDL. Shape: `{slope:[r,g,b], offset:[r,g,b], power:[r,g,b],
--     sat}` (helper-protocol.md). Absent when fidelity is `partial`
--     (LUT) or `unrepresentable`.
--   • `lut?` — `{ref: <local path>}` when a LUT is bound.
--   • `fidelity` — closed-set enum `primary | partial | unrepresentable`,
--     MANDATORY and honest (FR-015): a node graph exceeding CDL/LUT is
--     downgraded, NEVER approximated. Drives the staleness contract for
--     SyncGradesFromResolve.
--
-- This is the RED test that drives T029. The helper-side implementation
-- must:
--   1. Validate args at the wire boundary (bad_request for malformed
--      item_ids — wrong outer type or non-string element). Mirrors
--      §read_timeline arg shape.
--   2. Honour the "omit ⇒ all" vs "empty list ⇒ zero" distinction.
--   3. Return the documented per-row shape with fidelity always present
--      and `cdl` strictly gated on `fidelity == "primary"`.
--   4. `cdl` shape: slope/offset/power are 3-element number arrays;
--      `sat` is a single number.
--
-- Helper read-only contract: read_grades inspects per-clip color state
-- and never mutates the Resolve project, so this test can run against
-- a live Studio without modal popups. Until T029 lands the verb is
-- wired to `_unimplemented` (returns `not_implemented`), so every
-- assertion below is RED. That is the intended TDD state.
--
-- Run via `jve --test`.

local fixture  = require("binding.helper_fixture")
local protocol = require("core.resolve_bridge.protocol")

local fix = fixture.start("/tmp/jve-contract-read-grades.sock")

local function assert_structured_error(parsed, expected_code, label)
    assert(parsed.ok == false, label .. ": expected ok=false")
    assert(type(parsed.error) == "table", label .. ": missing error table")
    assert(type(parsed.error.code) == "string"
        and parsed.error.code ~= "",
        label .. ": error.code must be non-empty string")
    assert(type(parsed.error.message) == "string"
        and parsed.error.message ~= "",
        label .. ": error.message must be non-empty string (never bare)")
    assert(protocol.is_known_error_code(parsed.error.code), string.format(
        "%s: error code %q is not in the closed set",
        label, parsed.error.code))
    assert(parsed.error.code == expected_code, string.format(
        "%s: expected code %q, got %q (%s)",
        label, expected_code, parsed.error.code, parsed.error.message))
end

local FIDELITY_VALUES = {
    primary         = true,
    partial         = true,
    unrepresentable = true,
}

local function assert_rgb_triple(t, label)
    assert(type(t) == "table", label .. ": must be a JSON array")
    assert(#t == 3, string.format("%s: must have 3 elements, got %d",
        label, #t))
    for i = 1, 3 do
        assert(type(t[i]) == "number", string.format(
            "%s[%d] must be a number, got %s",
            label, i, type(t[i])))
    end
end

local function assert_grade_row(row, i)
    assert(type(row.jve_guid) == "string" and row.jve_guid ~= "",
        string.format("grades[%d].jve_guid must be non-empty string", i))
    assert(type(row.fidelity) == "string",
        string.format("grades[%d].fidelity must be string", i))
    assert(FIDELITY_VALUES[row.fidelity], string.format(
        "grades[%d].fidelity %q not in closed set "
        .. "{primary, partial, unrepresentable}", i, row.fidelity))

    if row.fidelity == "primary" then
        assert(type(row.cdl) == "table", string.format(
            "grades[%d].cdl must be present when fidelity=primary", i))
        assert_rgb_triple(row.cdl.slope,  string.format(
            "grades[%d].cdl.slope", i))
        assert_rgb_triple(row.cdl.offset, string.format(
            "grades[%d].cdl.offset", i))
        assert_rgb_triple(row.cdl.power,  string.format(
            "grades[%d].cdl.power", i))
        assert(type(row.cdl.sat) == "number", string.format(
            "grades[%d].cdl.sat must be a number", i))
    else
        assert(row.cdl == nil, string.format(
            "grades[%d].cdl must be absent when fidelity=%q (FR-015 "
            .. "honest downgrade, never approximated)", i, row.fidelity))
    end

    if row.lut ~= nil then
        assert(type(row.lut) == "table" and type(row.lut.ref) == "string"
            and row.lut.ref ~= "", string.format(
            "grades[%d].lut must be {ref: <non-empty path>} when present",
            i))
    end
end

-- ─── bad_request: item_ids wrong outer type ────────────────────────
-- Wire-discipline paths first — these don't need a live Resolve handle
-- and don't depend on the read_grades verb being implemented.
do
    local r = fixture.request(fix, "read_grades", {
        item_ids = "not-a-list",
    })
    assert_structured_error(r, "bad_request",
        "item_ids wrong outer type")
    assert(r.error.message:find("item_ids", 1, true),
        "bad_request should name the wrong-typed arg: "
        .. r.error.message)
    print("  ✓ item_ids wrong outer type → bad_request")
end

-- ─── bad_request: item_ids list with non-string element ────────────
do
    local r = fixture.request(fix, "read_grades", {
        item_ids = { "valid-id", 42 },
    })
    assert_structured_error(r, "bad_request",
        "item_ids non-string element")
    assert(r.error.message:find("item_ids", 1, true),
        "bad_request should name the wrong-typed arg: "
        .. r.error.message)
    print("  ✓ item_ids non-string element → bad_request")
end

-- Live-Resolve + verb-implemented gates. The ok-path sections below
-- require both a connected Resolve handle AND a real read_grades
-- implementation (verb is wired to _unimplemented → returns
-- not_implemented until T029b lands the CDL extraction; see tasks.md).
fixture.skip_unless_resolve(fix, "test_helper_read_grades.lua")
fixture.skip_if_verb_unimplemented(fix, "read_grades",
    "test_helper_read_grades.lua")

-- ─── omit item_ids ⇒ ok with grades array of documented shape ──────
do
    local r = fixture.request(fix, "read_grades", {})
    assert(r.ok == true, string.format(
        "omit item_ids: expected ok=true, got %s/%s",
        r.error and r.error.code, r.error and r.error.message))
    assert(type(r.result) == "table",
        "omit item_ids: result must be a JSON object")
    assert(type(r.result.grades) == "table",
        "result.grades must be an array")
    for i, row in ipairs(r.result.grades) do assert_grade_row(row, i) end
    print(string.format("  ✓ omit item_ids → ok, %d grade(s) of valid shape",
        #r.result.grades))
end

-- ─── empty item_ids list ⇒ zero grades (distinct from omission) ────
do
    local r = fixture.request(fix, "read_grades", { item_ids = {} })
    assert(r.ok == true, string.format(
        "empty item_ids: expected ok=true, got %s/%s",
        r.error and r.error.code, r.error and r.error.message))
    assert(type(r.result.grades) == "table",
        "empty item_ids: result.grades must still be a table")
    assert(#r.result.grades == 0, string.format(
        "empty item_ids must return zero grades, got %d",
        #r.result.grades))
    print("  ✓ empty item_ids → 0 grades")
end

fixture.stop(fix)

print("✅ test_helper_read_grades.lua passed")
