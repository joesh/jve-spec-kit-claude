#!/usr/bin/env luajit
-- 017: the routing this test originally pinned ("source-tab displayed →
-- transport drives source_monitor.engine") is now structural:
--   transport.engine_for_target() == transport.engine_for_role(transport.get_target())
-- and the user's tab click writes the target via
--   timeline_state.switch_to_source_tab → require("helpers.transport_target_sim").target_source()
-- The legacy pick_playback_monitor heuristic this test exercised is DELETED.
--
-- This file is preserved (rather than rm-ed) so any sibling Claude session
-- holding a stale checkout doesn't trip over a missing path. The current
-- expected behavior is verified by:
--   tests/test_space_acts_on_the_side_user_just_clicked.lua (T030)
--   tests/test_pressing_space_on_source_tab_makes_sound.lua (T004)
--   tests/test_contract_transport.lua (T007)
-- Those tests cover the same user invariant on the new code path.

require("test_env")

print("=== test_playback_routes_to_displayed_tab.lua ===")
print("  (017: behavior moved to T004/T007/T030)")
print("✅ test_playback_routes_to_displayed_tab.lua passed")
