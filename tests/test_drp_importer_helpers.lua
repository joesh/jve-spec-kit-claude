#!/usr/bin/env luajit
--- Tests for drp_importer.derive_project_settings and
--- drp_importer.extract_tab_state — pure transforms on parse_result /
--- import_result tables; no DB, no Qt, no JVE process needed.

require("test_env")
local drp_importer = require("importers.drp_importer")

print("=== test_drp_importer_helpers.lua ===")

-- ─── derive_project_settings ───────────────────────────────────────────────

local function fake_parse_result(frame_rate, width, height)
    return {
        project = {
            settings = {
                frame_rate = frame_rate,
                width      = width,
                height     = height,
            },
        },
    }
end

do
    local s = drp_importer.derive_project_settings(fake_parse_result(24, 1920, 1080), 48000)
    assert(s.frame_rate == 24,        "frame_rate carried through")
    assert(s.width == 1920,           "width carried through")
    assert(s.height == 1080,          "height carried through")
    assert(s.audio_sample_rate == 48000, "audio rate from caller")
    assert(type(s.master_clock_hz) == "number" and s.master_clock_hz > 0,
        "master_clock_hz populated from JVE default")
    assert(s.default_fps.num == 24 and s.default_fps.den == 1,
        "default_fps populated from JVE default (018 FR-036a)")
    print("  ✓ happy path: settings mirror parse_result + JVE defaults")
end

do
    -- Different rates flow through unchanged (no clamping / fabrication).
    local s = drp_importer.derive_project_settings(fake_parse_result(23.976, 3840, 2160), 96000)
    assert(s.frame_rate == 23.976,    "fractional frame_rate preserved")
    assert(s.audio_sample_rate == 96000, "non-default audio rate preserved")
    print("  ✓ different rates pass through")
end

-- Missing parse_result.project.settings → loud fail.
do
    local ok, err = pcall(drp_importer.derive_project_settings, {}, 48000)
    assert(not ok, "should refuse parse_result without project.settings")
    assert(tostring(err):find("parse_result.project.settings", 1, true),
        "error names what was missing; got: " .. tostring(err))
    print("  ✓ asserts on missing parse_result.project.settings")
end

-- Non-number audio rate → loud fail.
do
    local ok, err = pcall(drp_importer.derive_project_settings,
        fake_parse_result(24, 1920, 1080), nil)
    assert(not ok, "should refuse nil audio rate")
    assert(tostring(err):find("audio_sample_rate", 1, true),
        "error names audio_sample_rate; got: " .. tostring(err))
    print("  ✓ asserts on non-number audio_sample_rate")
end

-- Zero / negative audio rate → loud fail (NSF: must be positive).
do
    for _, bad in ipairs({0, -1, -48000}) do
        local ok, err = pcall(drp_importer.derive_project_settings,
            fake_parse_result(24, 1920, 1080), bad)
        assert(not ok, "should refuse non-positive audio rate " .. tostring(bad))
        assert(tostring(err):find("audio_sample_rate", 1, true),
            "error names audio_sample_rate; got: " .. tostring(err))
    end
    print("  ✓ asserts on non-positive audio_sample_rate")
end

-- Non-positive frame_rate / width / height → loud fail (NSF: every
-- field consumed from parse_result.project.settings must be sane).
do
    for _, bad_fr in ipairs({0, -24, "24"}) do
        local ok = pcall(drp_importer.derive_project_settings,
            fake_parse_result(bad_fr, 1920, 1080), 48000)
        assert(not ok, "should refuse frame_rate " .. tostring(bad_fr))
    end
    for _, bad_w in ipairs({0, -1920, nil}) do
        local ok = pcall(drp_importer.derive_project_settings,
            fake_parse_result(24, bad_w, 1080), 48000)
        assert(not ok, "should refuse width " .. tostring(bad_w))
    end
    for _, bad_h in ipairs({0, -1080, nil}) do
        local ok = pcall(drp_importer.derive_project_settings,
            fake_parse_result(24, 1920, bad_h), 48000)
        assert(not ok, "should refuse height " .. tostring(bad_h))
    end
    print("  ✓ asserts on non-positive frame_rate/width/height")
end

-- ─── extract_tab_state ─────────────────────────────────────────────────────

local function fake_parse_with_tabs(open_uuids, active_uuid)
    return {
        project = {
            open_timeline_ids   = open_uuids,
            active_timeline_id  = active_uuid,
        },
    }
end

local function fake_import_result(uuid_to_seq_id)
    return { tab_uuid_to_sequence_id = uuid_to_seq_id }
end

-- Happy path: 2 open tabs, 1 active.
do
    local parse = fake_parse_with_tabs({ "uuid-A", "uuid-B" }, "uuid-B")
    local imp = fake_import_result({ ["uuid-A"] = "seq-a", ["uuid-B"] = "seq-b" })
    local tabs = drp_importer.extract_tab_state(parse, imp)
    assert(type(tabs) == "table", "returns a table when tabs present")
    assert(#tabs.open_sequence_ids == 2, "open_sequence_ids has both")
    assert(tabs.open_sequence_ids[1] == "seq-a", "preserves open order [1]")
    assert(tabs.open_sequence_ids[2] == "seq-b", "preserves open order [2]")
    assert(tabs.active_sequence_id == "seq-b", "active resolves to seq-b")
    print("  ✓ happy path: open + active resolved through UUID map")
end

-- DRP has no open tabs → nil (this is the documented "nothing to persist"
-- contract that lets callers branch with a clean guard clause).
do
    local parse = fake_parse_with_tabs({}, nil)
    local imp   = fake_import_result({})
    local tabs  = drp_importer.extract_tab_state(parse, imp)
    assert(tabs == nil, "empty open_timeline_ids → nil return")
    print("  ✓ returns nil when DRP has no open tabs (optional-data contract)")
end

-- import_result missing tab_uuid_to_sequence_id → loud fail (NSF Half 2:
-- import_into_project must populate this; if it's nil/wrong-type the
-- caller's open-tabs would silently come back empty).
do
    local parse = fake_parse_with_tabs({ "uuid-A" }, "uuid-A")
    local ok, err = pcall(drp_importer.extract_tab_state, parse, { })
    assert(not ok, "missing tab_uuid_to_sequence_id must raise")
    assert(tostring(err):find("tab_uuid_to_sequence_id", 1, true),
        "error names the missing field; got: " .. tostring(err))
    print("  ✓ asserts on missing import_result.tab_uuid_to_sequence_id")
end

-- UUID mapping missing for an open tab → loud fail (silent drop would
-- mask a real importer bug: a timeline DRP marked open but never created).
do
    local parse = fake_parse_with_tabs({ "uuid-A", "uuid-MISSING" }, "uuid-A")
    local imp   = fake_import_result({ ["uuid-A"] = "seq-a" })
    local ok, err = pcall(drp_importer.extract_tab_state, parse, imp)
    assert(not ok, "missing UUID mapping must raise")
    assert(tostring(err):find("uuid-MISSING", 1, true),
        "error names the unresolved UUID; got: " .. tostring(err))
    print("  ✓ asserts on unresolved open-tab UUID (no silent drop)")
end

-- active_tab_uuid nil while open_tab_uuids non-empty → inconsistent
-- parser state, loud fail (this can't happen via the production
-- parser today, but the assert pins the invariant).
do
    local parse = fake_parse_with_tabs({ "uuid-A" }, nil)
    local imp   = fake_import_result({ ["uuid-A"] = "seq-a" })
    local ok, err = pcall(drp_importer.extract_tab_state, parse, imp)
    assert(not ok, "missing active_tab_uuid must raise")
    assert(tostring(err):find("active_tab_uuid is nil", 1, true),
        "error names the inconsistency; got: " .. tostring(err))
    print("  ✓ asserts when active_tab_uuid is nil but open list is non-empty")
end

-- active_tab_uuid points outside the open-list → inconsistency, loud fail.
do
    local parse = fake_parse_with_tabs({ "uuid-A" }, "uuid-NOT-OPEN")
    local imp   = fake_import_result({ ["uuid-A"] = "seq-a" })
    local ok, err = pcall(drp_importer.extract_tab_state, parse, imp)
    assert(not ok, "active outside open list must raise")
    assert(tostring(err):find("not.+in the open%-tab list", 1, false),
        "error names the inconsistency; got: " .. tostring(err))
    print("  ✓ asserts when active UUID is not in the open list")
end

print("✅ test_drp_importer_helpers.lua passed")
