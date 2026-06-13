require("test_env")

local selection_hub = require("ui.selection_hub")

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

local function fresh()
    selection_hub._reset_for_tests()
end

print("\n=== Selection Hub Tests (T17) ===")

-- ============================================================
-- get_active_selection — no active panel
-- ============================================================
print("\n--- initial state ---")
do
    fresh()
    local items, panel = selection_hub.get_active_selection()
    check("initial items empty", #items == 0)
    check("initial panel nil", panel == nil)
end

-- ============================================================
-- update_selection + get_selection
-- ============================================================
print("\n--- update_selection ---")
do
    fresh()
    selection_hub.update_selection("timeline", {"clip_a", "clip_b"})
    local items = selection_hub.get_selection("timeline")
    check("timeline has 2 items", #items == 2)
    check("item[1]", items[1] == "clip_a")
    check("item[2]", items[2] == "clip_b")

    -- Different panel
    selection_hub.update_selection("browser", {"media_1"})
    local b_items = selection_hub.get_selection("browser")
    check("browser has 1 item", #b_items == 1)

    -- Timeline unaffected
    local t_items = selection_hub.get_selection("timeline")
    check("timeline still 2", #t_items == 2)

    -- Nonexistent panel
    local none = selection_hub.get_selection("viewer")
    check("viewer empty", #none == 0)
end

-- ============================================================
-- update_selection — nil panel no-op
-- ============================================================
print("\n--- update nil panel ---")
do
    fresh()
    selection_hub.update_selection(nil, {"stuff"})
    -- Should not crash, no effect
    check("nil panel no-op", true)
end

-- ============================================================
-- update_selection — nil items → empty
-- ============================================================
print("\n--- update nil items ---")
do
    fresh()
    selection_hub.update_selection("p1", nil)
    local items = selection_hub.get_selection("p1")
    check("nil items → empty table", #items == 0)
end

-- ============================================================
-- clear_selection
-- ============================================================
print("\n--- clear_selection ---")
do
    fresh()
    selection_hub.update_selection("timeline", {"clip_a"})
    selection_hub.clear_selection("timeline")
    local items = selection_hub.get_selection("timeline")
    check("cleared → empty", #items == 0)

    -- nil panel no-op
    selection_hub.clear_selection(nil)
    check("clear nil panel no-op", true)
end

-- ============================================================
-- set_active_panel + get_active_selection
-- ============================================================
print("\n--- set_active_panel ---")
do
    fresh()
    selection_hub.update_selection("timeline", {"clip_x"})
    selection_hub.update_selection("browser", {"media_y"})

    selection_hub.set_active_panel("timeline")
    local items, panel = selection_hub.get_active_selection()
    check("active = timeline", panel == "timeline")
    check("active items = timeline's", #items == 1 and items[1] == "clip_x")

    selection_hub.set_active_panel("browser")
    local items2, panel2 = selection_hub.get_active_selection()
    check("switched to browser", panel2 == "browser")
    check("browser items", #items2 == 1 and items2[1] == "media_y")
end

-- ============================================================
-- listeners — registration and notification
-- ============================================================
print("\n--- listeners ---")
do
    fresh()
    local received_items = nil
    local call_count = 0

    local token = selection_hub.register_listener(function(items, _panel_id)
        received_items = items
        call_count = call_count + 1
    end)

    check("register returns token", type(token) == "number")
    -- Listener called immediately on registration with current state
    check("immediate callback on register", call_count == 1)
    check("initial items empty", received_items and #received_items == 0)
end

-- ============================================================
-- listeners — notified on active panel update
-- ============================================================
print("\n--- listener notification ---")
do
    fresh()
    local notifications = {}

    selection_hub.register_listener(function(items, panel_id)
        table.insert(notifications, {items = items, panel = panel_id})
    end)

    -- 1st notification: immediate on register
    check("1 notification after register", #notifications == 1)

    -- Set active panel
    selection_hub.set_active_panel("timeline")
    check("2 notifications after set_active_panel", #notifications == 2)
    check("notified with timeline", notifications[2].panel == "timeline")

    -- Update active panel's selection
    selection_hub.update_selection("timeline", {"new_clip"})
    check("3 notifications after update", #notifications == 3)
    check("notified with items", #notifications[3].items == 1)
    check("item = new_clip", notifications[3].items[1] == "new_clip")
end

-- ============================================================
-- listeners — NOT notified on inactive panel update
-- ============================================================
print("\n--- inactive panel no notify ---")
do
    fresh()
    local call_count = 0

    selection_hub.set_active_panel("timeline")
    selection_hub.register_listener(function()
        call_count = call_count + 1
    end)

    local before = call_count
    selection_hub.update_selection("browser", {"ignored"})
    check("inactive update no notify", call_count == before)

    selection_hub.clear_selection("browser")
    check("inactive clear no notify", call_count == before)
end

-- ============================================================
-- listeners — fail-fast (no error isolation)
-- ============================================================
print("\n--- listener fail-fast ---")
do
    fresh()
    selection_hub.set_active_panel("timeline")

    -- Register a listener that crashes
    local should_crash = false
    selection_hub.register_listener(function()
        if should_crash then error("listener crash") end
    end)

    -- Enable crash - should propagate up (fail-fast policy)
    should_crash = true
    local ok, err = pcall(function()
        selection_hub.update_selection("timeline", {"test"})
    end)
    check("listener errors propagate (fail-fast)", not ok and err:find("listener crash"))
end

-- ============================================================
-- unregister_listener
-- ============================================================
print("\n--- unregister ---")
do
    fresh()
    selection_hub.set_active_panel("timeline")

    local call_count = 0
    local token = selection_hub.register_listener(function()
        call_count = call_count + 1
    end)

    local before = call_count
    selection_hub.update_selection("timeline", {"a"})
    check("listener called before unregister", call_count > before)

    selection_hub.unregister_listener(token)
    local after_unreg = call_count
    selection_hub.update_selection("timeline", {"b"})
    check("listener NOT called after unregister", call_count == after_unreg)
end

-- ============================================================
-- register_listener — non-function error
-- ============================================================
print("\n--- register non-function ---")
do
    fresh()
    expect_error("string callback", function()
        selection_hub.register_listener("not_a_function")
    end, "requires a callback function")

    expect_error("nil callback", function()
        selection_hub.register_listener(nil)
    end, "requires a callback function")
end

-- ============================================================
-- multiple listeners
-- ============================================================
print("\n--- multiple listeners ---")
do
    fresh()
    selection_hub.set_active_panel("panel")

    local results = {}
    selection_hub.register_listener(function(items) table.insert(results, "A") end)
    selection_hub.register_listener(function(items) table.insert(results, "B") end)

    -- Clear initial registration calls
    local initial = #results
    selection_hub.update_selection("panel", {"x"})
    check("both listeners called", #results == initial + 2)
end

-- ============================================================
-- set_active_panel — nil
-- ============================================================
print("\n--- set_active_panel nil ---")
do
    fresh()
    selection_hub.update_selection("timeline", {"clip"})
    selection_hub.set_active_panel("timeline")
    selection_hub.set_active_panel(nil)

    local items, panel = selection_hub.get_active_selection()
    check("nil active panel", panel == nil)
    check("nil panel → empty items", #items == 0)
end

-- ============================================================
-- Dedup: redundant notifications must not fire
-- ============================================================
-- TSO 2026-05-12: inspector.update_selection fired 4-5x per focus toggle
-- (Browser↔Timeline) even when the selection itself hadn't changed.
-- Root structural issue: set_active_panel + update_selection paths each
-- fire notify unconditionally, so a click in an already-active panel +
-- the immediately-following focus event each retrigger the listener
-- with the exact same payload. Hub must dedup by (panel_id, items
-- signature) and skip listener calls when nothing changed.
do
    fresh()
    local calls = 0
    local last_panel, last_items
    selection_hub.register_listener(function(items, panel)
        calls = calls + 1
        last_panel = panel
        last_items = items
    end)
    -- register_listener fires once for the active panel (which is nil at
    -- this point) — that's a documented setup notify; reset the counter.
    calls = 0

    selection_hub.set_active_panel("project_browser")
    local clip = { type = "clip", id = "c1" }
    selection_hub.update_selection("project_browser", { clip })
    local after_initial = calls
    assert(after_initial >= 1, "FAIL: listener must fire at least once on real change")
    -- Now: 4 redundant events that change nothing. Hub must dedup all.
    selection_hub.set_active_panel("project_browser")       -- same panel
    selection_hub.update_selection("project_browser", { clip })  -- same items
    selection_hub.set_active_panel("project_browser")       -- same again
    selection_hub.update_selection("project_browser", { { type = "clip", id = "c1" } })  -- equivalent items
    check("dedup: redundant set_active_panel + update_selection no-op", calls == after_initial)

    -- A real change MUST still fire.
    selection_hub.update_selection("project_browser", { { type = "clip", id = "c2" } })
    check("real selection change fires listener", calls == after_initial + 1)
    check("real change carries the new items", last_items[1].id == "c2")
    check("real change carries the panel", last_panel == "project_browser")
end

-- ============================================================
-- Dedup: timeline-format items use item_type + clip.id, not type + id.
-- Bug: items_signature used it.type and it.id, both nil for timeline items,
-- making every timeline clip look identical → dedup fired on every navigation
-- → inspector never updated after first find-navigate.
-- ============================================================
print("\n--- dedup: timeline item_type format ---")
do
    fresh()
    local calls = 0
    local last_items

    selection_hub.set_active_panel("timeline")
    selection_hub.register_listener(function(items, _)
        calls = calls + 1
        last_items = items
    end)
    calls = 0  -- reset after register-time notify

    local mk_clip_item = function(clip_id)
        return { item_type = "timeline_clip", clip = { id = clip_id } }
    end

    -- Navigate to clip A
    selection_hub.update_selection("timeline", { mk_clip_item("clip_A") })
    local after_A = calls
    check("timeline clip_A selection fires listener", after_A >= 1)

    -- Navigate to clip B — must fire (different clip)
    selection_hub.update_selection("timeline", { mk_clip_item("clip_B") })
    check("timeline clip_B selection fires listener", calls == after_A + 1)
    check("listener receives clip_B item", last_items and last_items[1].clip.id == "clip_B")

    -- Same clip again — must NOT fire (dedup)
    selection_hub.update_selection("timeline", { mk_clip_item("clip_B") })
    check("timeline same clip dedup no-op", calls == after_A + 1)

    -- Navigate to sequence item
    local seq_item = { item_type = "timeline_sequence", sequence_id = "seq_1" }
    selection_hub.update_selection("timeline", { seq_item })
    check("timeline sequence item fires listener", calls == after_A + 2)

    -- Same sequence again — dedup
    selection_hub.update_selection("timeline", { { item_type = "timeline_sequence", sequence_id = "seq_1" } })
    check("timeline same sequence dedup no-op", calls == after_A + 2)
end

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n=== Selection Hub: %d passed, %d failed ===", pass_count, fail_count))
if fail_count > 0 then
    os.exit(1)
end
print("✅ test_selection_hub.lua passed")
