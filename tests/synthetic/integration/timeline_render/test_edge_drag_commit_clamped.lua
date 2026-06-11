--- Domain rule: when an edge drag is released after being clamped during
-- preview, the committed result must reflect the fully-clamped position —
-- the released edit applies as far as constraints allow, not the raw
-- unclamped delta and not less than what the preview showed.
--
-- The bug this guards: the drag handler previously passed the preview-clamped
-- delta (not the original delta) to BatchRippleEdit. BatchRippleEdit then
-- applied ITS OWN clamping on top of the already-clamped value, producing a
-- double-clamped result (move = less than the preview promised).
--
-- Observable proof: after releasing a drag that exceeded the media boundary,
-- the clip lands at the boundary, not partway between the original position
-- and the boundary.
--
-- Replaces: tests/synthetic/lua/test_timeline_edge_drag_clamped_delta.lua
-- (that test stubbed command_manager.execute to intercept BatchRippleEdit
-- params; this version checks the committed model position).

local env = require("synthetic.integration.timeline_render.render_env")

print("=== test_edge_drag_commit_clamped ===")

env.boot()
local state = env.context().state
local widget = env.video_widget()

local function find_band(left_frame, right_frame)
    local lx = env.x_of(left_frame)
    local rx = env.x_of(right_frame)
    for _, r in ipairs(env.rects(widget)) do
        if r.height > 10
            and math.abs(r.x - lx) < 10
            and math.abs((r.x + r.width) - rx) < 10 then
            return r
        end
    end
    error(string.format(
        "band rect not found for [%d,%d] (lx=%.1f rx=%.1f) in %d cmds",
        left_frame, right_frame, lx, rx, #env.draw_commands(widget)))
end

-- ── Scenario A: out-edge drag past media boundary commits at the boundary ──
-- Clip [0,700) on V1. The fixture is 30s of media (~720 frames at the
-- sequence's 24fps); source_out=700 leaves only a few dozen frames of
-- headroom at the out-edge. Drag out-edge by +2000 frames (far past the
-- media end). After release the clip's out-edge should be at the media
-- boundary, not at its original position and not 2000 frames beyond it.
-- The preview clamp and the BatchRippleEdit clamp agree on the boundary;
-- double-clamping would produce a smaller move than the preview promised.
print("  A: clamped out-edge drag commits at media boundary (no double-clamp)")
do
    local seq = env.fresh_sequence("EdgeDragCommit A")
    local tracks = env.tracks()
    assert(tracks.V1, "need V1")

    env.place_clips(seq, {
        { track_id = tracks.V1.id, position = 0, duration = 700 },
    })
    env.view_frames(2200, 0)

    local tab = state.get_tab_strip()
    local v1_clips = tab:track_clip_index(tracks.V1.id)
    local clip_a = nil
    for _, c in ipairs(v1_clips) do
        if not c.is_gap and c.sequence_start == 0 then clip_a = c; break end
    end
    assert(clip_a, "A: no clip at frame 0 on V1")

    local orig_duration = clip_a.duration  -- 700

    local band = find_band(0, 700)
    local mid_y = band.y + band.height / 2
    local h = env.mouse_handler(widget)

    -- Ripple-grab the out-edge (5px inside clip body, left of boundary at 700).
    local bx = env.x_of(700)
    local px = bx - 5
    local delta_frames_req = 2000  -- far past media end; must clamp
    local target_x = env.x_of(700 + delta_frames_req)

    -- During drag: verify preview_clamped_delta_frames is set and < 2000.
    h({ type = "press", x = px, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "move",  x = px + 6, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "move",  x = px + (target_x - bx), y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(120)

    local ds = state.get_active_edge_drag_state()
    assert(ds, "A: no active edge drag state during drag")
    assert(ds.preview_clamped_delta_frames ~= nil,
        "A: preview_clamped_delta_frames not set during drag")
    local clamped_preview = ds.preview_clamped_delta_frames
    assert(clamped_preview < delta_frames_req, string.format(
        "A: expected preview_clamped_delta < %d (media boundary hit); got %s",
        delta_frames_req, tostring(clamped_preview)))

    -- Release to commit.
    h({ type = "release", x = px + (target_x - bx), y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(200)

    -- Committed result: clip's new duration should equal orig_duration + clamped_preview
    -- (the boundary the preview showed). Double-clamping would produce a smaller gain.
    local tab2 = state.get_tab_strip()
    local v1_after = tab2:track_clip_index(tracks.V1.id)
    local clip_a_after = nil
    for _, c in ipairs(v1_after) do
        if not c.is_gap and c.sequence_start == 0 then clip_a_after = c; break end
    end
    assert(clip_a_after, "A: clip at frame 0 disappeared after release")

    local committed_delta = clip_a_after.duration - orig_duration
    assert(committed_delta > 0, string.format(
        "A: out-edge drag committed no change (duration %d → %d)",
        orig_duration, clip_a_after.duration))
    -- The committed delta must match the preview-clamped delta. Less = a
    -- double-clamp (clamped value clamped again on commit); more = the
    -- commit moved further than the preview promised.
    assert(math.abs(committed_delta - clamped_preview) <= 1, string.format(
        "A: committed delta (%d) ~= preview_clamped_delta (%d) — the "
        .. "released edit must land exactly where the preview showed",
        committed_delta, clamped_preview))

    -- source_out is in media-file frames and accumulates TC-origin offsets;
    -- its exact value depends on tc_origin math and is not a useful proxy
    -- for the double-clamp bug.  The committed_delta check above is sufficient.

    print("    OK")
end

-- ── Scenario B: clamped ripple keeps downstream layout intact ───────────────
-- V1: clip_a [0,300) — gap [300,600) — clip_b [600,900).
-- Drag clip_a's out-edge (frame 300) RIGHT to frame 800: +500 requested, but
-- the fixture media (~720 frames at 24fps, source_out=300) only has ~430
-- frames of headroom, so the move clamps at the media boundary.
-- Ripple semantics: the downstream gap and clip_b shift right by exactly the
-- committed amount — the gap keeps its 300-frame width and clip_b keeps its
-- duration. A clamp bug that under-shifts downstream would either shrink the
-- gap or desync clip_b's position from clip_a's new out-edge.
print("  B: clamped ripple shifts downstream exactly; gap width preserved")
do
    local seq = env.fresh_sequence("EdgeDragCommit B")
    local tracks = env.tracks()
    assert(tracks.V1, "need V1")

    env.place_clips(seq, {
        { track_id = tracks.V1.id, position = 0,   duration = 300 },
        { track_id = tracks.V1.id, position = 600,  duration = 300 },
    })
    env.view_frames(1100, 0)

    local tab = state.get_tab_strip()
    local v1_clips = tab:track_clip_index(tracks.V1.id)
    local clip_a = nil
    for _, c in ipairs(v1_clips) do
        if not c.is_gap and c.sequence_start == 0 then clip_a = c; break end
    end
    assert(clip_a, "B: no clip at frame 0 on V1")

    local orig_duration_a = clip_a.duration  -- 300

    local band = find_band(0, 300)
    local mid_y = band.y + band.height / 2
    local h = env.mouse_handler(widget)

    -- Ripple-grab clip_a's out-edge (frame 300, 5px to the left inside the clip body).
    local bx = env.x_of(300)
    local px = bx - 5
    -- Drag right to frame 800 — requests +500 frames, more than the media
    -- headroom (~430), so the clamp fires below the request.
    -- Frame 800 stays on-screen (viewport 0..1100).
    local target_x = env.x_of(800)

    h({ type = "press", x = px, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "move",  x = px + 6, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "move",  x = target_x, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(120)

    local ds = state.get_active_edge_drag_state()
    assert(ds, "B: no active edge drag state during drag")
    assert(ds.preview_clamped_delta_frames ~= nil,
        "B: preview_clamped_delta_frames not set")
    local clamped_preview = ds.preview_clamped_delta_frames
    -- Media headroom is ~430 frames; the +500 request must clamp strictly
    -- below it but remain a real extension.
    assert(clamped_preview > 0 and clamped_preview < 500, string.format(
        "B: expected 0 < clamped_delta < 500 (media boundary); got %s",
        tostring(clamped_preview)))

    h({ type = "release", x = target_x, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(200)

    local tab2 = state.get_tab_strip()
    local v1_after = tab2:track_clip_index(tracks.V1.id)
    local clip_a_after, clip_b_after, gap_after = nil, nil, nil
    for _, c in ipairs(v1_after) do
        if c.id == clip_a.id then
            clip_a_after = c
        elseif c.is_gap then
            gap_after = c
        elseif c.sequence_start > 0 then
            clip_b_after = c
        end
    end
    assert(clip_a_after, "B: clip_a disappeared after release")
    assert(gap_after,    "B: gap between the clips disappeared after release")
    assert(clip_b_after, "B: downstream clip disappeared after release")

    local committed_delta = clip_a_after.duration - orig_duration_a
    assert(committed_delta > 0, string.format(
        "B: out-edge drag committed no change (duration %d → %d)",
        orig_duration_a, clip_a_after.duration))
    -- Committed extension must land exactly where the preview promised.
    assert(math.abs(committed_delta - clamped_preview) <= 1, string.format(
        "B: committed delta (%d) ~= preview_clamped_delta (%d) — the "
        .. "released edit must land exactly where the preview showed",
        committed_delta, clamped_preview))
    -- Ripple integrity: the gap keeps its width and the downstream clip
    -- shifts by exactly the committed amount.
    assert(gap_after.duration == 300, string.format(
        "B: ripple must preserve the 300-frame gap; gap is now %d frames",
        gap_after.duration))
    assert(clip_b_after.sequence_start == 600 + committed_delta, string.format(
        "B: downstream clip must shift by the committed delta (+%d): "
        .. "expected start %d, got %d",
        committed_delta, 600 + committed_delta, clip_b_after.sequence_start))
    assert(clip_b_after.duration == 300, string.format(
        "B: downstream clip duration must be untouched (300); got %d",
        clip_b_after.duration))

    print("    OK")
end

print("✅ test_edge_drag_commit_clamped.lua passed")
