#!/usr/bin/env luajit
--- When the source monitor is focused, the Inspector must show the
--- currently-loaded sequence. The Inspector pulls its target from
--- selection_hub keyed by the focused panel; until source_viewer
--- publishes the loaded sequence under panel_id "source_monitor",
--- focusing the source monitor blanks the Inspector. This test pins
--- the publish-on-load / clear-on-unload contract.
---
--- Black-box: asserts only the items selection_hub broadcasts to its
--- listeners. No inspection of source_viewer internals.

require("test_env")

print("=== test_source_viewer_publishes_selection.lua ===")

local selection_hub = require("ui.selection_hub")
selection_hub._reset_for_tests()

-- Stub the panel_manager so source_viewer can resolve a "source_monitor"
-- without a full Qt+SequenceMonitor harness. The stub mimics the public
-- API source_viewer actually calls.
local fake_monitor = {
    _loaded = nil,
    _sequence = nil,
}
function fake_monitor:get_loaded_master_seq_id() return self._loaded end
function fake_monitor:load_sequence(seq_id)
    self._loaded = seq_id
    -- After load_sequence, real SequenceMonitor exposes `.sequence`
    -- (the loaded Sequence model) with project_id available. Mirror
    -- that shape so source_viewer can read project_id off it.
    self._sequence = { id = seq_id, project_id = "proj_under_test" }
    self.sequence = self._sequence
end
function fake_monitor:unload()
    self._loaded = nil
    self._sequence = nil
    self.sequence = nil
end
-- Mirror real SequenceMonitor:_set_title (sequence_monitor.lua:1036).
function fake_monitor:_set_title(text) self.title = text end
function fake_monitor:seek_to_frame(_) end  -- load_clip parks engine at clip.source_in (FR-003)

package.loaded["ui.panel_manager"] = {
    get_sequence_monitor = function(view_id)
        if view_id == "source_monitor" then return fake_monitor end
        return nil
    end,
}

-- Stub focus_manager + transport so load_master_clip doesn't require
-- real Qt focus / playback wiring.
package.loaded["ui.focus_manager"] = {
    focus_panel = function(_) end,
}
package.loaded["core.playback.transport"] = {
    bind_role_to_sequence = function(_role, _seq_id) end,
}

-- Capture the items selection_hub broadcasts under "source_monitor".
local last_items
local last_panel
selection_hub.register_listener(function(items, panel_id)
    if panel_id == "source_monitor" then
        last_items = items
        last_panel = panel_id
    end
end)
-- Inspector subscribes only to the active panel — mirror that so the
-- listener actually fires when source_viewer publishes.
selection_hub.set_active_panel("source_monitor")

local source_viewer = require("ui.source_viewer")

-- =============================================================================
-- Test 1: loading a sequence publishes a selection under panel_id "source_monitor"
-- =============================================================================
last_items, last_panel = nil, nil
source_viewer.load_master_clip("loaded_seq_id", { skip_focus = true })

assert(last_panel == "source_monitor", string.format(
    "load_master_clip must publish under panel_id source_monitor; got %s",
    tostring(last_panel)))
assert(type(last_items) == "table" and #last_items == 1, string.format(
    "expected exactly one selection item published; got %s",
    last_items and tostring(#last_items) or "nil"))

local item = last_items[1]
-- The published item must carry enough for inspector to build a
-- sequence inspectable: a sequence_id + project_id, tagged with a
-- sequence-schema item_type.
assert(item.sequence_id == "loaded_seq_id", string.format(
    "published item must carry sequence_id of the loaded sequence; got %s",
    tostring(item.sequence_id)))
assert(item.project_id == "proj_under_test", string.format(
    "published item must carry project_id of the loaded sequence; got %s",
    tostring(item.project_id)))
-- Pin the published item_type to the value the source viewer actually
-- emits for a staged sequence. The Inspector's resolve_inspectables
-- accepts both "timeline" and "timeline_sequence" as routes to the
-- sequence schema, but staged-mode publish is canonical "timeline" —
-- this test pins that contract so a silent flip would be caught.
assert(item.item_type == "timeline", string.format(
    "staged-mode publish must emit item_type='timeline'; got %s",
    tostring(item.item_type)))
print("  ✓ load_master_clip publishes sequence selection under source_monitor")

-- =============================================================================
-- Test 2: unload clears the published selection
-- =============================================================================
source_viewer.unload()

-- After unload the hub's stored selection for source_monitor must be empty,
-- so a fresh active-panel switch broadcasts no items.
local current = selection_hub.get_selection("source_monitor")
assert(type(current) == "table" and #current == 0, string.format(
    "after unload, source_monitor selection must be empty; got %d items",
    type(current) == "table" and #current or -1))
print("  ✓ unload clears source_monitor selection")

-- =============================================================================
-- Test 3: loading a different sequence replaces the prior selection
-- =============================================================================
source_viewer.load_master_clip("first_seq", { skip_focus = true })
local first = selection_hub.get_selection("source_monitor")
assert(#first == 1 and first[1].sequence_id == "first_seq",
    "fixture: first load must publish first_seq")

source_viewer.load_master_clip("second_seq", { skip_focus = true })
local second = selection_hub.get_selection("source_monitor")
assert(#second == 1, string.format(
    "second load must publish exactly one item; got %d", #second))
assert(second[1].sequence_id == "second_seq", string.format(
    "second load must replace prior selection with new sequence_id; "
    .. "got %s", tostring(second[1].sequence_id)))
print("  ✓ subsequent load replaces selection (no accumulation)")

-- =============================================================================
-- Test 4 (019 T008): live-bound mode publishes item_type="clip" (FR-028)
-- =============================================================================
-- Per spec FR-028 + contracts/source_viewer_load_clip.md, source_viewer in
-- live-bound mode publishes a clip-typed selection (NOT sequence-typed), so
-- the Inspector renders clip-schema fields for the loaded clip.
--
-- Stub Clip.load + Sequence.load so the load_clip path resolves without a
-- real DB. The publish shape (item_type="clip" with clip_id + project_id +
-- owner sequence_id) is the assertion target.

package.loaded["models.clip"] = {
    load = function(id)
        if id == "clip_live" then
            return {
                id                = "clip_live",
                name              = "LiveClip",
                project_id        = "proj_under_test",
                owner_sequence_id = "owner_seq_live",
                sequence_id       = "src_seq_for_clip",  -- the clip's source
                track_id          = "track_v1",
                -- Model-field names (no _frame suffix) — matches what
                -- real models/clip.lua build_clip_from_load_row returns.
                source_in         = 30,
                source_out        = 180,
                duration          = 150,
            }
        end
        return nil
    end,
}
package.loaded["models.sequence"] = {
    load = function(id)
        if id == "src_seq_for_clip" then
            return {
                id              = "src_seq_for_clip",
                project_id      = "proj_under_test",
                name            = "SourceMaster",
                kind            = "master",
                fps_numerator   = 24,
                fps_denominator = 1,
            }
        end
        if id == "owner_seq_live" then
            return {
                id   = "owner_seq_live",
                project_id = "proj_under_test",
                name = "OwnerTimeline",
                kind = "sequence",
            }
        end
        return nil
    end,
}

source_viewer.load_clip("clip_live", { skip_focus = true })

local published = selection_hub.get_selection("source_monitor")
assert(#published == 1, string.format(
    "live-bound load_clip must publish exactly one item; got %d", #published))
local live_item = published[1]
assert(live_item.item_type == "clip", string.format(
    "live-bound publish item_type must be 'clip' (FR-028); got %q",
    tostring(live_item.item_type)))
assert(live_item.clip_id == "clip_live",
    "published item must carry clip_id")
assert(live_item.project_id == "proj_under_test",
    "published item must carry project_id")
assert(live_item.sequence_id == "owner_seq_live", string.format(
    "published sequence_id must be the OWNER sequence (where the clip lives), "
    .. "not the source sequence; got %q", tostring(live_item.sequence_id)))
print("  ✓ live-bound mode publishes item_type='clip' with owner sequence_id")

print("\n✅ test_source_viewer_publishes_selection.lua passed")
