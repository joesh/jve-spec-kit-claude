#!/usr/bin/env luajit

require('test_env')

local browser_state = require('ui.project_browser.browser_state')
local selection_hub = require('ui.selection_hub')

-- Ensure clean slate
selection_hub._reset_for_tests()
browser_state.clear_selection()

local last_selection = nil
selection_hub.register_listener(function(items, panel_id)
    if panel_id == "project_browser" then
        last_selection = items
    end
end)

selection_hub.set_active_panel("project_browser")

local media_lookup = {
    media_a = {
        id = "media_a",
        name = "Clip A",
        file_name = "clip_a.mov",
        file_path = "/tmp/clip_a.mov",
        duration = 1500,
        frame_rate = 24,
        width = 1920,
        height = 1080,
        codec = "ProRes",
        metadata = '{"camera:make":"Arri"}',
    },
    media_b = {
        id = "media_b",
        name = "Clip B",
        file_name = "clip_b.mov",
        file_path = "/tmp/clip_b.mov",
        duration = 3200,
        frame_rate = 23.976,
        width = 3840,
        height = 2160,
        codec = "H.264",
        metadata = { ["camera:make"] = "Sony" },
    },
}

local master_lookup = {
    clip_a = {
        clip_id = "clip_a",
        media_id = "media_a",
        name = "Clip A",
        duration = 1500,
        project_id = "default_project",
        metadata = {},
        media = media_lookup.media_a
    },
    clip_b = {
        clip_id = "clip_b",
        media_id = "media_b",
        name = "Clip B",
        duration = 3200,
        project_id = "default_project",
        metadata = {},
        media = media_lookup.media_b
    }
}

local sequence_lookup = {
    timeline_1 = {
        id = "timeline_1",
        name = "Main Timeline",
        duration = 9000,
        frame_rate = 29.97,
        width = 1920,
        height = 1080,
    }
}

-- Multi-select two master clips
local normalized = browser_state.update_selection({
    {type = "master_clip", clip_id = "clip_a"},
    {type = "master_clip", clip_id = "clip_b"},
}, { media_lookup = media_lookup, master_lookup = master_lookup, project_id = "default_project" })

assert(#normalized == 2, "Expected two master clip entries after normalization")
assert(normalized[1].item_type == "master_clip", "Selection should normalize to item_type=master_clip")
assert(normalized[1].metadata["camera:make"] == "Arri", "Metadata JSON should decode for media")
assert(normalized[2].metadata["camera:make"] == "Sony", "Table metadata should pass through for media")
assert(last_selection == normalized, "Selection hub listener should receive the same table instance")

-- Switch to timeline selection (should replace previous entries)
local timeline_selection = browser_state.update_selection({
    {type = "timeline", id = "timeline_1"},
}, { sequence_lookup = sequence_lookup })

assert(#timeline_selection == 1, "Expected single timeline entry")
assert(timeline_selection[1].item_type == "timeline", "Timeline entry should normalize to item_type=timeline")
assert(timeline_selection[1].duration == 9000, "Timeline duration should come from sequence lookup")

-- Selecting unsupported types (e.g., bins) should clear inspector selection
local cleared = browser_state.update_selection({
    {type = "bin", id = "bin_1"},
}, { media_lookup = media_lookup })

assert(#cleared == 0, "Unsupported selection types should not surface to inspector")
assert(last_selection == cleared, "Callback should receive cleared selection")

print("✅ Project browser selection normalization tests passed")
