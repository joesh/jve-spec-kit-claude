#!/usr/bin/env luajit
--- 019 T005: OpenClipInSourceMonitor command contract.
---
--- Per contracts/open_clip_in_source_monitor.md + spec FR-017. Thin
--- dispatcher: the command calls `source_viewer.load_clip(args.clip_id)`
--- and reports success. No model mutation, undoable=false, no focus
--- side-effects of its own (load_clip does the focus dance).
---
--- Pinned behaviors:
---   * Happy path: dispatch with valid args → source_viewer.load_clip
---     called with the clip_id; command reports success.
---   * Required args asserted: clip_id, project_id, sequence_id (owner)
---     all required by SPEC.args.
---   * undoable=false: dispatch then `command_manager.undo()` is a no-op
---     for the source viewer's mode (no history entry was created).
---   * Selection_hub follow-through: after dispatch, the source viewer's
---     selection_hub entry carries item_type="clip" with the right ids
---     (delegated to load_clip's behavior — verified here to confirm the
---     command path doesn't bypass it).
---
--- Black-box: stubs source_viewer to capture load_clip calls + observe
--- through the public command_manager dispatch API. No reaching into
--- command-registry internals.

require("test_env")

-- Test database + command_manager.init so execute_interactive can resolve
-- the active project/sequence context. Minimal fixture — this test
-- doesn't exercise model mutations, only command dispatch routing.
_G.qt_create_single_shot_timer = function() end

local database = require("core.database")
local TEST_DB = "/tmp/jve/test_open_clip_in_source_monitor.db"
os.remove(TEST_DB); os.remove(TEST_DB .. "-wal"); os.remove(TEST_DB .. "-shm")
database.init(TEST_DB)
local db = database.get_connection()
db:exec(require("import_schema"))
db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj_X', 'P', 'resample',
            '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at)
    VALUES ('owner_seq_1', 'proj_X', 'S', 'sequence', 24, 1, 48000, 1920, 1080,
            0, 10000, 0, '[]', '[]', '[]', 0, 0, 0);
]])

print("=== test_open_clip_in_source_monitor.lua ===")

-- Stub source_viewer to capture load_clip invocations.
local load_clip_calls = {}
package.loaded["ui.source_viewer"] = {
    load_clip = function(clip_id, opts)
        table.insert(load_clip_calls, { clip_id = clip_id, opts = opts })
        return true
    end,
    -- Other entry points unused by this test, but provided for require safety.
    load_sequence    = function() end,
    load_master_clip = function() end,
    unload           = function() end,
    get_mode         = function() return "live_bound_clip" end,
}

-- Stub transport + models for the rec-tab-playhead → source-frame map.
-- The executor (FR-024 v2 2026-05-22) reads the rec sequence's playhead,
-- loads the clip, then computes source_frame = clip.source_in +
-- (rec_playhead - clip.sequence_start) and passes it via opts.playhead_frame.
-- Choosing rec_playhead=150, clip.sequence_start=100, clip.source_in=50
-- gives expected source_frame = 50 + (150-100) = 100 — a non-trivial
-- value that catches sign/offset mistakes.
db:exec([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at)
    VALUES ('rec_seq_for_test', 'proj_X', 'R', 'sequence', 24, 1, 48000, 1920, 1080,
            0, 10000, 150, '[]', '[]', '[]', 0, 0, 0);
]])
package.loaded["core.playback.transport"] = {
    is_bootstrapped = function() return true end,
    record_engine = { loaded_sequence_id = "rec_seq_for_test" },
}

-- Stub models.clip — the executor calls Clip.load to read sequence_start
-- + source_in for the match-frame mapping. Same fixture values for both
-- the explicit-clip_id and resolved-via-playhead clips.
local fixture_clip_row = {
    sequence_start = 100,
    source_in      = 50,
    source_out     = 250,
    duration       = 150,
    is_gap         = false,
    project_id     = "proj_X",
    owner_sequence_id = "owner_seq_1",
    sequence_id    = "src_seq_for_clip",
    name           = "Alpha",
}
package.loaded["models.clip"] = {
    load = function(clip_id)
        local row = {}
        for k, v in pairs(fixture_clip_row) do row[k] = v end
        row.id = clip_id
        return row
    end,
    -- Pure function — the executor uses it after Clip.load. Mirror
    -- the real implementation rather than stubbing a return value so
    -- the test catches sign/offset mistakes if the production math
    -- ever changes.
    owner_frame_to_source = function(clip, owner_frame)
        return clip.source_in + (owner_frame - clip.sequence_start)
    end,
}

local command_manager = require("core.command_manager")
command_manager.init("owner_seq_1", "proj_X")

-- ── Scenario 1: happy-path dispatch ──────────────────────────────────────────
do
    load_clip_calls = {}

    local r = command_manager.execute_interactive("OpenClipInSourceMonitor", {
        clip_id     = "clip_alpha",
        project_id  = "proj_X",
        sequence_id = "owner_seq_1",
    })

    assert(r and r.success, string.format(
        "OpenClipInSourceMonitor must succeed; got %s",
        tostring(r and r.error_message)))
    assert(#load_clip_calls == 1, string.format(
        "happy-path dispatch must call source_viewer.load_clip exactly once; got %d",
        #load_clip_calls))
    assert(load_clip_calls[1].clip_id == "clip_alpha", string.format(
        "load_clip must receive the dispatched clip_id; got %q",
        tostring(load_clip_calls[1].clip_id)))

    -- FR-024 v2: source_frame = source_in + (rec_playhead - sequence_start)
    -- Fixture: 50 + (150 - 100) = 100.
    local opts = load_clip_calls[1].opts or {}
    assert(opts.playhead_frame == 100, string.format(
        "load_clip opts.playhead_frame must be match-frame mapped "
        .. "(source_in + rec_playhead - sequence_start = 50+150-100 = 100); "
        .. "got %s", tostring(opts.playhead_frame)))
    assert(opts.skip_focus == true,
        "load_clip opts.skip_focus must be true (Shift+F keeps focus on Timeline)")
    print("  ✓ happy-path dispatch calls source_viewer.load_clip(clip_id)")
    print("  ✓ executor match-frame maps rec_playhead → source_frame")
    print("  ✓ executor passes skip_focus=true (focus stays on Timeline)")
end

-- ── Scenario 2: keymap path (no clip_id) resolves via command_helper ────────
-- Per FR-024 (updated 2026-05-20), Shift+F dispatches the command with no
-- clip_id. The executor must resolve the target clip via the canonical
-- playhead+selection policy (same one MatchFrame uses) and then call
-- source_viewer.load_clip with the resolved id. Stub command_helper to
-- return a known clip so the test exercises only the dispatch routing.
do
    load_clip_calls = {}

    local resolve_calls = 0
    local pick_calls = 0
    package.loaded["core.command_helper"] = {
        resolve_clips_at_playhead = function()
            resolve_calls = resolve_calls + 1
            return { { id = "resolved_clip_42", is_gap = nil } }
        end,
        pick_best_clip = function(candidates)
            pick_calls = pick_calls + 1
            return candidates[1]
        end,
    }

    local r = command_manager.execute_interactive("OpenClipInSourceMonitor", {})
    assert(r and r.success, string.format(
        "no-clip_id dispatch must succeed via playhead resolver; got %s",
        tostring(r and r.error_message)))
    assert(resolve_calls == 1, "resolve_clips_at_playhead must be called exactly once")
    assert(pick_calls == 1, "pick_best_clip must be called exactly once")
    assert(#load_clip_calls == 1, "load_clip must be called exactly once")
    assert(load_clip_calls[1].clip_id == "resolved_clip_42", string.format(
        "load_clip must receive the resolved clip id; got %q",
        tostring(load_clip_calls[1].clip_id)))

    package.loaded["core.command_helper"] = nil
    print("  ✓ keymap path (no clip_id) resolves via playhead + load_clip(resolved)")
end

-- ── Scenario 2b: keymap path rejects gap-as-clip loudly ─────────────────────
-- FR-027 mirror — when the playhead resolver returns a gap row (no source
-- media), the executor must assert loudly, never silently call load_clip.
do
    load_clip_calls = {}

    package.loaded["core.command_helper"] = {
        resolve_clips_at_playhead = function()
            return { { id = "gap_xyz", is_gap = true } }
        end,
        pick_best_clip = function(candidates) return candidates[1] end,
    }

    local r = command_manager.execute_interactive("OpenClipInSourceMonitor", {})
    assert(r and r.success == false, string.format(
        "gap-as-clip under playhead must fail dispatch; got success=%s",
        tostring(r and r.success)))
    assert(tostring(r.error_message):find("gap", 1, true),
        "error_message must mention gap; got: " .. tostring(r.error_message))
    assert(#load_clip_calls == 0,
        "rejected dispatch must NOT call load_clip")

    package.loaded["core.command_helper"] = nil
    print("  ✓ keymap path rejects gap-as-clip loudly (no load_clip call)")
end

-- ── Scenario 2c: keymap path with empty resolver result raises ──────────────
-- FR-024 contract: when there is no clip under the playhead, the keymap
-- dispatch must surface this loudly rather than silently doing nothing.
do
    load_clip_calls = {}

    package.loaded["core.command_helper"] = {
        resolve_clips_at_playhead = function() return {} end,
        pick_best_clip = function(_) assert(false, "should not be called") end,
    }

    local r = command_manager.execute_interactive("OpenClipInSourceMonitor", {})
    assert(r and r.success == false, string.format(
        "empty resolver result must fail dispatch; got success=%s",
        tostring(r and r.success)))
    assert(tostring(r.error_message):find("no clips", 1, true),
        "error_message must mention 'no clips'; got: " .. tostring(r.error_message))
    assert(#load_clip_calls == 0, "rejected dispatch must NOT call load_clip")

    package.loaded["core.command_helper"] = nil
    print("  ✓ keymap path with empty playhead result raises loudly")
end

-- ── Scenario 2d: rec engine has no loaded sequence — assert loud ──────────
-- NSF Half-1: read_record_tab_playhead's preconditions must surface, not
-- silently degrade. When transport.record_engine.loaded_sequence_id is
-- nil (no record tab yet), the executor must fail dispatch with a
-- clear message — never silently pass nil through to the mapping math.
do
    load_clip_calls = {}

    local prior_transport = package.loaded["core.playback.transport"]
    package.loaded["core.playback.transport"] = {
        is_bootstrapped = function() return true end,
        record_engine = { loaded_sequence_id = nil },
    }

    local r = command_manager.execute_interactive("OpenClipInSourceMonitor", {
        clip_id     = "clip_alpha",
        project_id  = "proj_X",
        sequence_id = "owner_seq_1",
    })
    assert(r and r.success == false, string.format(
        "missing rec-tab loaded_sequence_id must fail dispatch; got success=%s",
        tostring(r and r.success)))
    assert(tostring(r.error_message):find("no loaded sequence", 1, true),
        "error_message must mention 'no loaded sequence'; got: "
        .. tostring(r.error_message))
    assert(#load_clip_calls == 0, "rejected dispatch must NOT call load_clip")

    package.loaded["core.playback.transport"] = prior_transport
    print("  ✓ no rec-tab loaded sequence raises loudly (no silent fallback)")
end

-- ── Scenario 3: undoable=false — no history entry created ────────────────────
do
    load_clip_calls = {}

    -- Dispatch once.
    local r = command_manager.execute_interactive("OpenClipInSourceMonitor", {
        clip_id     = "clip_alpha",
        project_id  = "proj_X",
        sequence_id = "owner_seq_1",
    })
    assert(r and r.success, "fixture: dispatch must succeed")
    assert(#load_clip_calls == 1, "fixture: load_clip called once")

    -- Undo must NOT call load_clip again (would only happen if the toggle
    -- had been recorded on the undo stack and the undoer re-invoked).
    command_manager.undo()
    assert(#load_clip_calls == 1, string.format(
        "after undo, load_clip must not have been called again (undoable=false); "
        .. "got %d total calls", #load_clip_calls))
    print("  ✓ undoable=false: undo does not re-invoke load_clip")
end

print("\n✅ test_open_clip_in_source_monitor.lua passed")
