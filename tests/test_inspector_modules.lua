require("test_env")

-- ============================================================
-- Qt stubs for widget_pool
-- ============================================================
local widget_counter = 0
local function make_widget(kind)
    widget_counter = widget_counter + 1
    return {_kind = kind or "widget", _id = widget_counter}
end

package.loaded["core.qt_constants"] = {
    WIDGET = {
        CREATE = function() return make_widget("widget") end,
        CREATE_LABEL = function(text) return make_widget("label") end,
        CREATE_LINE_EDIT = function(placeholder) return make_widget("line_edit") end,
        CREATE_SLIDER = function(orientation) return make_widget("slider") end,
        CREATE_CHECKBOX = function(label) return make_widget("checkbox") end,
        CREATE_COMBOBOX = function() return make_widget("combobox") end,
    },
    LAYOUT = {
        CREATE_VBOX = function() return make_widget("vbox") end,
        CREATE_HBOX = function() return make_widget("hbox") end,
        SET_ON_WIDGET = function() end,
        SET_SPACING = function() end,
        SET_MARGINS = function() end,
        ADD_WIDGET = function() end,
    },
    PROPERTIES = {
        SET_STYLE = function() end,
        SET_TEXT = function() end,
        SET_PLACEHOLDER_TEXT = function() end,
        SET_SLIDER_RANGE = function() end,
        SET_SLIDER_VALUE = function() end,
        SET_CHECKED = function() end,
        CLEAR_COMBOBOX_ITEMS = function() end,
        ADD_COMBOBOX_ITEM = function() end,
    },
    DISPLAY = {
        SET_VISIBLE = function() end,
    },
}

package.loaded["core.ui_constants"] = {
    COLORS = {
        FIELD_BACKGROUND_COLOR = "#1f1f1f",
        FIELD_BORDER_COLOR = "#090909",
        FIELD_TEXT_COLOR = "#e6e6e6",
        FOCUS_BORDER_COLOR = "#0078d4",
        FIELD_FOCUS_BACKGROUND_COLOR = "#262626",
    },
    LOGGING = { COMPONENT_NAMES = { UI = "ui" } },
}

package.loaded["core.logger"] = {
    init = function() end,
    info = function() end,
    debug = function() end,
    warn = function() end,
    error = function() end,
}

-- Stub qt_signals for widget_pool
local qt_signal_connections = {}
package.loaded["core.qt_signals"] = {
    connect = function(widget, signal, handler)
        local id = #qt_signal_connections + 1
        qt_signal_connections[id] = {widget = widget, signal = signal, handler = handler}
        return id
    end,
    disconnect = function(widget, signal)
        -- no-op in tests
    end,
    onTextChanged = function(widget, handler)
        return {success = true}
    end,
    onValueChanged = function(widget, handler)
        return {success = true}
    end,
}

local error_system = require("core.error_system")
local adapter = require("ui.inspector.adapter")
local widget_pool = require("ui.inspector.widget_pool")

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
end

print("\n=== Inspector Modules Tests (T25) ===")

-- ============================================================
-- ADAPTER: bind() validation
-- ============================================================
print("\n--- adapter.bind validation ---")
do
    -- nil panel → error
    local r1 = adapter.bind(nil, {})
    check("bind nil panel", error_system.is_error(r1))

    -- non-table fns → throws
    expect_error("bind non-table fns", function()
        adapter.bind("panel", "not_a_table")
    end, "type")

    -- missing functions → error
    local r2 = adapter.bind("panel", {})
    check("bind missing fns", error_system.is_error(r2))

    local r3 = adapter.bind("panel", {applySearchFilter = function() end})
    check("bind missing setSelectedClips", error_system.is_error(r3))

    -- valid bind → success
    local r4 = adapter.bind("panel", {
        applySearchFilter = function() end,
        setSelectedClips = function() end,
    })
    check("bind valid", error_system.is_success(r4))
end

-- ============================================================
-- ADAPTER: filterClipMetadata (tested via applySearchFilter)
-- ============================================================
print("\n--- adapter filtering ---")
do
    -- Reset adapter state
    adapter._selected_clips = {}
    adapter._filtered_clips = {}
    adapter._current_filter = ""

    -- Set clips with various metadata
    adapter.setSelectedClips({
        {id = "clip1", name = "Interview_01.mov", src = "/media/interview.mov"},
        {id = "clip2", name = "B-Roll_Harbor.mp4", src = "/media/harbor.mp4"},
        {id = "clip3", name = "Titles_Intro.mov", src = "/media/titles.mov",
         metadata = {camera = "Sony A7", location = "studio"}},
        {id = "clip4", name = "AudioTrack.wav"},
    })

    -- No filter → all clips
    adapter.applySearchFilter("")
    check("no filter: all clips", #adapter.getFilteredClips() == 4)
    check("getCurrentFilter empty", adapter.getCurrentFilter() == "")

    -- Filter by name
    adapter.applySearchFilter("Interview")
    check("name filter", #adapter.getFilteredClips() == 1)
    check("name filter match", adapter.getFilteredClips()[1].id == "clip1")

    -- Case insensitive
    adapter.applySearchFilter("interview")
    check("case insensitive", #adapter.getFilteredClips() == 1)

    -- Filter by ID
    adapter.applySearchFilter("clip3")
    check("id filter", #adapter.getFilteredClips() == 1)
    check("id filter match", adapter.getFilteredClips()[1].name == "Titles_Intro.mov")

    -- Filter by src path
    adapter.applySearchFilter("harbor")
    check("src filter", #adapter.getFilteredClips() == 1)
    check("src filter match", adapter.getFilteredClips()[1].id == "clip2")

    -- Filter by metadata value
    adapter.applySearchFilter("Sony")
    check("metadata value filter", #adapter.getFilteredClips() == 1)
    check("metadata filter match", adapter.getFilteredClips()[1].id == "clip3")

    -- Filter by metadata key
    adapter.applySearchFilter("camera")
    check("metadata key filter", #adapter.getFilteredClips() == 1)

    -- No matches
    adapter.applySearchFilter("nonexistent_query_xyz")
    check("no matches", #adapter.getFilteredClips() == 0)

    -- nil query → all clips (treated as empty)
    adapter.applySearchFilter(nil)
    check("nil query: all clips", #adapter.getFilteredClips() == 4)

    -- Multiple matches
    adapter.applySearchFilter(".mov")
    check("multi match", #adapter.getFilteredClips() == 2)
end

-- ============================================================
-- ADAPTER: setSelectedClips — reapplies filter
-- ============================================================
print("\n--- adapter.setSelectedClips ---")
do
    -- Set filter first
    adapter.applySearchFilter("special")

    -- Set new clips that match
    adapter.setSelectedClips({
        {id = "c1", name = "special_clip"},
        {id = "c2", name = "normal_clip"},
    })

    -- Filter should be reapplied to new clips
    check("reapply filter after setSelectedClips", #adapter.getFilteredClips() == 1)
    check("correct clip after reapply", adapter.getFilteredClips()[1].id == "c1")

    -- nil clips → empty
    adapter.setSelectedClips(nil)
    check("nil clips: empty filtered", #adapter.getFilteredClips() == 0)
end

-- ============================================================
-- ADAPTER: legacy aliases
-- ============================================================
print("\n--- adapter legacy aliases ---")
do
    check("apply_filter exists", type(adapter.apply_filter) == "function")
    check("set_selected_clips exists", type(adapter.set_selected_clips) == "function")

    -- Verify they work
    adapter.set_selected_clips({{id = "x", name = "test"}})
    adapter.apply_filter("test")
    check("legacy alias works", #adapter.getFilteredClips() == 1)
end

-- ============================================================
-- WIDGET_POOL: rent — creates and configures widgets
-- ============================================================
print("\n--- widget_pool.rent ---")
do
    widget_pool.clear()

    local le = widget_pool.rent("line_edit", {text = "hello", placeholder = "type..."})
    check("rent line_edit", le ~= nil)
    check("line_edit is table", type(le) == "table")

    local cb = widget_pool.rent("checkbox", {label = "Enable", checked = true})
    check("rent checkbox", cb ~= nil)

    local lbl = widget_pool.rent("label", {text = "Title"})
    check("rent label", lbl ~= nil)

    local sl = widget_pool.rent("slider", {min = 0, max = 100, value = 50})
    check("rent slider", sl ~= nil)

    local combo = widget_pool.rent("combobox", {options = {"a", "b", "c"}, selected = "b"})
    check("rent combobox", combo ~= nil)

    -- Unknown type → nil
    local unknown = widget_pool.rent("unknown_type")
    check("rent unknown type nil", unknown == nil)

    -- Default config
    local le2 = widget_pool.rent("line_edit")
    check("rent default config", le2 ~= nil)
end

-- ============================================================
-- WIDGET_POOL: return_widget — returns to pool for reuse
-- ============================================================
print("\n--- widget_pool.return_widget ---")
do
    widget_pool.clear()

    local w1 = widget_pool.rent("line_edit", {text = "temp"})
    local stats_before = widget_pool.get_stats()
    check("active before return", stats_before.active_count >= 1)

    widget_pool.return_widget(w1)

    local stats_after = widget_pool.get_stats()
    check("pool has widget after return", stats_after.pools.line_edit >= 1)

    -- Rent again → reuses from pool (pool decrements)
    local w2 = widget_pool.rent("line_edit")
    check("reused from pool", w2 ~= nil)

    -- Return nil → no crash
    widget_pool.return_widget(nil)
    check("return nil no crash", true)

    -- Return non-rented widget → logged warning, no crash
    widget_pool.return_widget({_kind = "fake"})
    check("return non-rented no crash", true)
end

-- ============================================================
-- WIDGET_POOL: get_stats
-- ============================================================
print("\n--- widget_pool.get_stats ---")
do
    widget_pool.clear()

    local stats = widget_pool.get_stats()
    check("stats has pools", type(stats.pools) == "table")
    check("stats active_count 0", stats.active_count == 0)
    check("stats pools line_edit 0", stats.pools.line_edit == 0)

    widget_pool.rent("line_edit")
    widget_pool.rent("checkbox")

    local stats2 = widget_pool.get_stats()
    check("stats active after rent", stats2.active_count == 2)
end

-- ============================================================
-- WIDGET_POOL: clear — resets all state
-- ============================================================
print("\n--- widget_pool.clear ---")
do
    widget_pool.rent("line_edit")
    widget_pool.rent("label")

    widget_pool.clear()

    local stats = widget_pool.get_stats()
    check("clear: active 0", stats.active_count == 0)
    check("clear: pools empty", stats.pools.line_edit == 0)
    check("clear: all pool types reset",
        stats.pools.slider == 0 and
        stats.pools.checkbox == 0 and
        stats.pools.combobox == 0 and
        stats.pools.label == 0)
end

-- ============================================================
-- WIDGET_POOL: connect_signal
-- ============================================================
print("\n--- widget_pool.connect_signal ---")
do
    widget_pool.clear()
    local w = widget_pool.rent("line_edit")

    -- Known signals
    local r1 = widget_pool.connect_signal(w, "editingFinished", function() end)
    check("connect editingFinished", r1 ~= nil)

    local r2 = widget_pool.connect_signal(w, "clicked", function() end)
    check("connect clicked", r2 ~= nil)

    local r3 = widget_pool.connect_signal(w, "textChanged", function() end)
    check("connect textChanged", r3 ~= nil)

    local r4 = widget_pool.connect_signal(w, "valueChanged", function() end)
    check("connect valueChanged", r4 ~= nil)

    -- Unknown signal → false
    local r5 = widget_pool.connect_signal(w, "bogusSignal", function() end)
    check("connect unknown signal", r5 == false)
end

-- ============================================================
-- WIDGET_POOL: signal cleanup on return
-- ============================================================
print("\n--- widget_pool signal cleanup ---")
do
    widget_pool.clear()
    local w = widget_pool.rent("checkbox")
    widget_pool.connect_signal(w, "clicked", function() end)

    -- Widget has tracked connections
    check("connections tracked", widget_pool._signal_connections[w] ~= nil)

    -- Return widget → connections cleaned
    widget_pool.return_widget(w)
    check("connections cleaned on return", widget_pool._signal_connections[w] == nil)
end

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n=== Inspector Modules: %d passed, %d failed ===", pass_count, fail_count))
if fail_count > 0 then
    os.exit(1)
end
print("✅ test_inspector_modules.lua passed")
