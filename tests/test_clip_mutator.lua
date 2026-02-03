require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Rational = require("core.rational")
local ripple_layout = require("helpers.ripple_layout")

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

local function expect_error(label, fn)
    local ok, err = pcall(fn)
    if not ok then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL (expected error): " .. label)
    end
    return err
end

-- Helper: load the clip_mutator fresh (not cached from prior require)
local ClipMutator = require("core.clip_mutator")

-- ═══════════════════════════════════════════════════════════════
-- 1. plan_insert / plan_update / plan_delete
-- ═══════════════════════════════════════════════════════════════

print("\n--- plan_insert: valid clip ---")
do
    local row = {
        id = "c1", project_id = "p1", clip_kind = "timeline", name = "Clip",
        track_id = "t1", media_id = "m1",
        timeline_start = Rational.new(0, 1000, 1),
        duration = Rational.new(100, 1000, 1),
        source_in = Rational.new(0, 24000, 1001),
        source_out = Rational.new(100, 24000, 1001),
        fps_numerator = 24000, fps_denominator = 1001,
        enabled = true, offline = false,
        created_at = os.time(), modified_at = os.time()
    }
    local mut = ClipMutator.plan_insert(row)
    check("plan_insert type=insert", mut.type == "insert")
    check("plan_insert clip_id", mut.clip_id == "c1")
    check("plan_insert timeline_start_frame", mut.timeline_start_frame == 0)
    check("plan_insert duration_frames", mut.duration_frames == 100)
    check("plan_insert source_in_frame", mut.source_in_frame == 0)
    check("plan_insert source_out_frame", mut.source_out_frame == 100)
    check("plan_insert fps_numerator", mut.fps_numerator == 24000)
    check("plan_insert fps_denominator", mut.fps_denominator == 1001)
    check("plan_insert enabled=1", mut.enabled == 1)
    check("plan_insert offline=0", mut.offline == 0)
end

print("\n--- plan_insert: missing fps asserts ---")
do
    local row = {
        id = "c1", timeline_start = 0, duration = 100,
        source_in = 0, source_out = 100,
        created_at = os.time(), modified_at = os.time()
    }
    expect_error("plan_insert missing fps", function()
        ClipMutator.plan_insert(row)
    end)
end

print("\n--- plan_insert: missing duration asserts ---")
do
    local row = {
        id = "c1", timeline_start = 0,
        source_in = 0, source_out = 100,
        fps_numerator = 1000, fps_denominator = 1,
        created_at = os.time(), modified_at = os.time()
    }
    expect_error("plan_insert missing duration", function()
        ClipMutator.plan_insert(row)
    end)
end

print("\n--- plan_insert: missing source_in asserts ---")
do
    local row = {
        id = "c1", timeline_start = 0, duration = 100,
        source_out = 100,
        fps_numerator = 1000, fps_denominator = 1,
        created_at = os.time(), modified_at = os.time()
    }
    expect_error("plan_insert missing source_in", function()
        ClipMutator.plan_insert(row)
    end)
end

print("\n--- plan_insert: missing source_out asserts ---")
do
    local row = {
        id = "c1", timeline_start = 0, duration = 100,
        source_in = 0,
        fps_numerator = 1000, fps_denominator = 1,
        created_at = os.time(), modified_at = os.time()
    }
    expect_error("plan_insert missing source_out", function()
        ClipMutator.plan_insert(row)
    end)
end

print("\n--- plan_insert: missing created_at asserts ---")
do
    local row = {
        id = "c1", timeline_start = 0, duration = 100,
        source_in = 0, source_out = 100,
        fps_numerator = 1000, fps_denominator = 1,
        modified_at = os.time()
    }
    expect_error("plan_insert missing created_at", function()
        ClipMutator.plan_insert(row)
    end)
end

print("\n--- plan_insert: zero fps asserts ---")
do
    local row = {
        id = "c1", timeline_start = 0, duration = 100,
        source_in = 0, source_out = 100,
        fps_numerator = 0, fps_denominator = 1,
        created_at = os.time(), modified_at = os.time()
    }
    expect_error("plan_insert zero fps_numerator", function()
        ClipMutator.plan_insert(row)
    end)
end

print("\n--- plan_insert: negative fps asserts ---")
do
    local row = {
        id = "c1", timeline_start = 0, duration = 100,
        source_in = 0, source_out = 100,
        fps_numerator = -1000, fps_denominator = 1,
        created_at = os.time(), modified_at = os.time()
    }
    expect_error("plan_insert negative fps", function()
        ClipMutator.plan_insert(row)
    end)
end

print("\n--- plan_update: valid ---")
do
    local row = {
        id = "c1", track_id = "t1",
        timeline_start = Rational.new(10, 1000, 1),
        duration = Rational.new(50, 1000, 1),
        source_in = Rational.new(5, 1000, 1),
        source_out = Rational.new(55, 1000, 1),
        enabled = true
    }
    local original = {id = "c1", start_value = 0, duration = 100}
    local mut = ClipMutator.plan_update(row, original)
    check("plan_update type=update", mut.type == "update")
    check("plan_update clip_id", mut.clip_id == "c1")
    check("plan_update timeline_start_frame", mut.timeline_start_frame == 10)
    check("plan_update previous", mut.previous == original)
end

print("\n--- plan_delete: valid ---")
do
    local row = {id = "c1", start_value = 0, duration = 100}
    local mut = ClipMutator.plan_delete(row)
    check("plan_delete type=delete", mut.type == "delete")
    check("plan_delete clip_id", mut.clip_id == "c1")
    check("plan_delete previous", mut.previous == row)
end

-- ═══════════════════════════════════════════════════════════════
-- 2. resolve_occlusions (DB-backed tests)
-- ═══════════════════════════════════════════════════════════════

print("\n--- resolve_occlusions: nil params → noop ---")
do
    local ok, err, actions = ClipMutator.resolve_occlusions(nil, nil)
    check("nil params returns true", ok == true)
end

print("\n--- resolve_occlusions: missing track_id → noop ---")
do
    local ok = ClipMutator.resolve_occlusions(nil, {timeline_start = 0, duration = 10})
    check("missing track_id returns true", ok == true)
end

print("\n--- resolve_occlusions: no overlap ---")
do
    local layout = ripple_layout.create({
        clips = {
            order = {"v1_left"},
            v1_left = {timeline_start = 0, duration = 500, source_in = 0}
        }
    })

    local ok, err, actions = ClipMutator.resolve_occlusions(layout.db, {
        track_id = layout.tracks.v1.id,
        timeline_start = Rational.new(1000, 1000, 1),
        duration = Rational.new(200, 1000, 1),
        sequence_frame_rate = {fps_numerator = 1000, fps_denominator = 1}
    })
    check("no overlap ok", ok == true)
    check("no overlap 0 actions", #(actions or {}) == 0)

    layout:cleanup()
end

print("\n--- resolve_occlusions: full cover → delete ---")
do
    local layout = ripple_layout.create({
        clips = {
            order = {"v1_left"},
            v1_left = {
                timeline_start = 100, duration = 200, source_in = 0
            }
        }
    })

    local ok, err, actions = ClipMutator.resolve_occlusions(layout.db, {
        track_id = layout.tracks.v1.id,
        timeline_start = Rational.new(0, 1000, 1),
        duration = Rational.new(500, 1000, 1),
        sequence_frame_rate = {fps_numerator = 1000, fps_denominator = 1}
    })
    check("full cover ok", ok == true)
    check("full cover 1 action", #actions == 1)
    check("full cover action=delete", actions[1].type == "delete")
    check("full cover correct clip", actions[1].clip_id == "clip_v1_left")

    layout:cleanup()
end

print("\n--- resolve_occlusions: tail trim ---")
do
    -- Clip at [0,500), new clip at [300,800) → trim existing to [0,300)
    local layout = ripple_layout.create({
        clips = {
            order = {"v1_left"},
            v1_left = {
                timeline_start = 0, duration = 500, source_in = 0
            }
        }
    })

    local ok, err, actions = ClipMutator.resolve_occlusions(layout.db, {
        track_id = layout.tracks.v1.id,
        timeline_start = Rational.new(300, 1000, 1),
        duration = Rational.new(500, 1000, 1),
        sequence_frame_rate = {fps_numerator = 1000, fps_denominator = 1}
    })
    check("tail trim ok", ok == true)
    check("tail trim 1 action", #actions == 1)
    check("tail trim action=update", actions[1].type == "update")
    check("tail trim new duration=300", actions[1].duration_frames == 300)

    layout:cleanup()
end

print("\n--- resolve_occlusions: head trim ---")
do
    -- Clip at [200,700), new clip at [0,400) → trim existing to [400,700)
    local layout = ripple_layout.create({
        clips = {
            order = {"v1_left"},
            v1_left = {
                timeline_start = 200, duration = 500, source_in = 0
            }
        }
    })

    local ok, err, actions = ClipMutator.resolve_occlusions(layout.db, {
        track_id = layout.tracks.v1.id,
        timeline_start = Rational.new(0, 1000, 1),
        duration = Rational.new(400, 1000, 1),
        sequence_frame_rate = {fps_numerator = 1000, fps_denominator = 1}
    })
    check("head trim ok", ok == true)
    check("head trim 1 action", #actions == 1)
    check("head trim action=update", actions[1].type == "update")
    check("head trim new start=400", actions[1].timeline_start_frame == 400)
    check("head trim new duration=300", actions[1].duration_frames == 300)

    layout:cleanup()
end

print("\n--- resolve_occlusions: straddle split ---")
do
    -- Clip at [0,1000), new clip at [300,600) → left [0,300) + right [600,1000)
    local layout = ripple_layout.create({
        clips = {
            order = {"v1_left"},
            v1_left = {
                timeline_start = 0, duration = 1000, source_in = 0
            }
        }
    })

    local ok, err, actions = ClipMutator.resolve_occlusions(layout.db, {
        track_id = layout.tracks.v1.id,
        timeline_start = Rational.new(300, 1000, 1),
        duration = Rational.new(300, 1000, 1),
        sequence_frame_rate = {fps_numerator = 1000, fps_denominator = 1}
    })
    check("straddle ok", ok == true)
    check("straddle 2 actions", #actions == 2)
    check("straddle first=update (left part)", actions[1].type == "update")
    check("straddle left duration=300", actions[1].duration_frames == 300)
    check("straddle second=insert (right part)", actions[2].type == "insert")
    check("straddle right start=600", actions[2].timeline_start_frame == 600)
    check("straddle right duration=400", actions[2].duration_frames == 400)

    layout:cleanup()
end

print("\n--- resolve_occlusions: exclude_clip_id skips self ---")
do
    local layout = ripple_layout.create({
        clips = {
            order = {"v1_left"},
            v1_left = {
                timeline_start = 0, duration = 500, source_in = 0
            }
        }
    })

    local ok, err, actions = ClipMutator.resolve_occlusions(layout.db, {
        track_id = layout.tracks.v1.id,
        timeline_start = Rational.new(0, 1000, 1),
        duration = Rational.new(500, 1000, 1),
        exclude_clip_id = "clip_v1_left",
        sequence_frame_rate = {fps_numerator = 1000, fps_denominator = 1}
    })
    check("exclude self ok", ok == true)
    check("exclude self 0 actions", #(actions or {}) == 0)

    layout:cleanup()
end

print("\n--- resolve_occlusions: multiple clips ---")
do
    -- Two clips: [0,300) and [500,800). New clip at [100,700) → delete first, head-trim second
    local layout = ripple_layout.create({
        clips = {
            order = {"v1_left", "v1_right"},
            v1_left = {
                timeline_start = 0, duration = 300, source_in = 0
            },
            v1_right = {
                timeline_start = 500, duration = 300, source_in = 0
            }
        }
    })

    local ok, err, actions = ClipMutator.resolve_occlusions(layout.db, {
        track_id = layout.tracks.v1.id,
        timeline_start = Rational.new(100, 1000, 1),
        duration = Rational.new(600, 1000, 1),
        sequence_frame_rate = {fps_numerator = 1000, fps_denominator = 1}
    })
    check("multi ok", ok == true)
    check("multi 2 actions", #actions == 2)
    -- First clip [0,300) with new [100,700): tail trim to [0,100)
    check("multi first=update (tail trim)", actions[1].type == "update")
    check("multi first duration=100", actions[1].duration_frames == 100)
    -- Second clip [500,800) with new [100,700): head trim to [700,800)
    check("multi second=update (head trim)", actions[2].type == "update")
    check("multi second start=700", actions[2].timeline_start_frame == 700)

    layout:cleanup()
end

print("\n--- resolve_occlusions: tail trim to zero → delete ---")
do
    -- Clip at [100,200), new clip at [100,500) → fully covered → delete
    local layout = ripple_layout.create({
        clips = {
            order = {"v1_left"},
            v1_left = {
                timeline_start = 100, duration = 100, source_in = 0
            }
        }
    })

    local ok, err, actions = ClipMutator.resolve_occlusions(layout.db, {
        track_id = layout.tracks.v1.id,
        timeline_start = Rational.new(100, 1000, 1),
        duration = Rational.new(400, 1000, 1),
        sequence_frame_rate = {fps_numerator = 1000, fps_denominator = 1}
    })
    check("zero trim ok", ok == true)
    check("zero trim delete", actions[1].type == "delete")

    layout:cleanup()
end

-- ═══════════════════════════════════════════════════════════════
-- 3. resolve_ripple (DB-backed tests)
-- ═══════════════════════════════════════════════════════════════

print("\n--- resolve_ripple: nil params → noop ---")
do
    local ok = ClipMutator.resolve_ripple(nil, nil)
    check("ripple nil params ok", ok == true)
end

print("\n--- resolve_ripple: missing insert_time → noop ---")
do
    local ok = ClipMutator.resolve_ripple(nil, {track_id = "t1", shift_amount = 10})
    check("ripple missing insert_time ok", ok == true)
end

print("\n--- resolve_ripple: shift clips after insert point ---")
do
    -- Clips: [0,500) and [500,1000). Insert at 500, shift 200.
    -- First clip unaffected, second shifts to [700,1200).
    local layout = ripple_layout.create({
        clips = {
            order = {"v1_left", "v1_right"},
            v1_left = {
                timeline_start = 0, duration = 500, source_in = 0
            },
            v1_right = {
                timeline_start = 500, duration = 500, source_in = 0
            }
        }
    })

    local ok, err, actions = ClipMutator.resolve_ripple(layout.db, {
        track_id = layout.tracks.v1.id,
        insert_time = Rational.new(500, 1000, 1),
        shift_amount = Rational.new(200, 1000, 1),
        sequence_frame_rate = {fps_numerator = 1000, fps_denominator = 1}
    })
    check("ripple shift ok", ok == true)
    check("ripple shift 1 action", #actions == 1)
    check("ripple shift action=update", actions[1].type == "update")
    check("ripple shift new start=700", actions[1].timeline_start_frame == 700)

    layout:cleanup()
end

print("\n--- resolve_ripple: split clip at insert point ---")
do
    -- Clip at [0,1000). Insert at 400, shift 300.
    -- Left part [0,400), right part [700,1300) (shifted by 300)
    local layout = ripple_layout.create({
        clips = {
            order = {"v1_left"},
            v1_left = {
                timeline_start = 0, duration = 1000, source_in = 0
            }
        }
    })

    local ok, err, actions = ClipMutator.resolve_ripple(layout.db, {
        track_id = layout.tracks.v1.id,
        insert_time = Rational.new(400, 1000, 1),
        shift_amount = Rational.new(300, 1000, 1),
        sequence_frame_rate = {fps_numerator = 1000, fps_denominator = 1}
    })
    check("ripple split ok", ok == true)
    check("ripple split 2 actions", #actions == 2)
    -- First: update left part (trimmed to 400 frames)
    check("ripple split first=update", actions[1].type == "update")
    check("ripple split left duration=400", actions[1].duration_frames == 400)
    -- Second: insert right part at 700
    check("ripple split second=insert", actions[2].type == "insert")
    check("ripple split right start=700", actions[2].timeline_start_frame == 700)
    check("ripple split right duration=600", actions[2].duration_frames == 600)

    layout:cleanup()
end

print("\n--- resolve_ripple: positive shift reverses update order ---")
do
    -- Clips: [0,300), [300,600), [600,900). Shift at 0 by +100.
    -- All three shift right. Updates should be in REVERSE order to prevent overlap.
    local layout = ripple_layout.create({
        clips = {
            order = {"v1_left", "v1_mid", "v1_right"},
            v1_left = {
                timeline_start = 0, duration = 300, source_in = 0
            },
            v1_mid = {
                id = "clip_v1_mid",
                track_key = "v1", media_key = "main",
                timeline_start = 300, duration = 300, source_in = 0,
                fps_numerator = 1000, fps_denominator = 1
            },
            v1_right = {
                timeline_start = 600, duration = 300, source_in = 0
            }
        }
    })

    local ok, err, actions = ClipMutator.resolve_ripple(layout.db, {
        track_id = layout.tracks.v1.id,
        insert_time = Rational.new(0, 1000, 1),
        shift_amount = Rational.new(100, 1000, 1),
        sequence_frame_rate = {fps_numerator = 1000, fps_denominator = 1}
    })
    check("ripple reverse ok", ok == true)
    check("ripple reverse 3 actions", #actions == 3)
    -- Reversed: rightmost clip first
    check("ripple reverse first start=700", actions[1].timeline_start_frame == 700)
    check("ripple reverse second start=400", actions[2].timeline_start_frame == 400)
    check("ripple reverse third start=100", actions[3].timeline_start_frame == 100)

    layout:cleanup()
end

print("\n--- resolve_ripple: no clips after insert point → no actions ---")
do
    local layout = ripple_layout.create({
        clips = {
            order = {"v1_left"},
            v1_left = {
                timeline_start = 0, duration = 500, source_in = 0
            }
        }
    })

    local ok, err, actions = ClipMutator.resolve_ripple(layout.db, {
        track_id = layout.tracks.v1.id,
        insert_time = Rational.new(1000, 1000, 1),
        shift_amount = Rational.new(200, 1000, 1),
        sequence_frame_rate = {fps_numerator = 1000, fps_denominator = 1}
    })
    check("ripple no clips ok", ok == true)
    check("ripple no clips 0 actions", #(actions or {}) == 0)

    layout:cleanup()
end

-- ═══════════════════════════════════════════════════════════════
-- 4. plan_duplicate_block (DB-backed tests)
-- ═══════════════════════════════════════════════════════════════

print("\n--- plan_duplicate_block: missing db asserts ---")
do
    expect_error("plan_duplicate_block nil db", function()
        ClipMutator.plan_duplicate_block(nil, {})
    end)
end

print("\n--- plan_duplicate_block: missing params asserts ---")
do
    local layout = ripple_layout.create()
    expect_error("plan_duplicate_block nil params", function()
        ClipMutator.plan_duplicate_block(layout.db, nil)
    end)
    layout:cleanup()
end

print("\n--- plan_duplicate_block: missing sequence_id asserts ---")
do
    local layout = ripple_layout.create()
    expect_error("plan_duplicate_block missing sequence_id", function()
        ClipMutator.plan_duplicate_block(layout.db, {
            clip_ids = {"clip_v1_left"},
            target_track_id = layout.tracks.v1.id
        })
    end)
    layout:cleanup()
end

print("\n--- plan_duplicate_block: missing clip_ids asserts ---")
do
    local layout = ripple_layout.create()
    expect_error("plan_duplicate_block missing clip_ids", function()
        ClipMutator.plan_duplicate_block(layout.db, {
            sequence_id = layout.sequence_id,
            target_track_id = layout.tracks.v1.id
        })
    end)
    layout:cleanup()
end

print("\n--- plan_duplicate_block: empty clip_ids asserts ---")
do
    local layout = ripple_layout.create()
    expect_error("plan_duplicate_block empty clip_ids", function()
        ClipMutator.plan_duplicate_block(layout.db, {
            sequence_id = layout.sequence_id,
            clip_ids = {},
            target_track_id = layout.tracks.v1.id
        })
    end)
    layout:cleanup()
end

print("\n--- plan_duplicate_block: zero delta same track → noop ---")
do
    local layout = ripple_layout.create({
        clips = {
            order = {"v1_left"},
            v1_left = {
                timeline_start = 0, duration = 500, source_in = 0
            }
        }
    })

    local ok, err, result = ClipMutator.plan_duplicate_block(layout.db, {
        sequence_id = layout.sequence_id,
        clip_ids = {"clip_v1_left"},
        target_track_id = layout.tracks.v1.id,
        anchor_clip_id = "clip_v1_left",
        delta_rat = Rational.new(0, 1000, 1)
    })
    check("dup zero delta ok", ok == true)
    check("dup zero delta 0 mutations", #result.planned_mutations == 0)
    check("dup zero delta 0 new ids", #result.new_clip_ids == 0)

    layout:cleanup()
end

print("\n--- plan_duplicate_block: positive delta duplicates clip ---")
do
    local layout = ripple_layout.create({
        clips = {
            order = {"v1_left"},
            v1_left = {
                timeline_start = 0, duration = 500, source_in = 0
            }
        }
    })

    local ok, err, result = ClipMutator.plan_duplicate_block(layout.db, {
        sequence_id = layout.sequence_id,
        clip_ids = {"clip_v1_left"},
        target_track_id = layout.tracks.v1.id,
        anchor_clip_id = "clip_v1_left",
        delta_rat = Rational.new(1000, 1000, 1)
    })
    check("dup positive ok", ok == true)
    check("dup positive has mutations", #result.planned_mutations > 0)
    check("dup positive 1 new id", #result.new_clip_ids == 1)

    -- Find the insert mutation
    local insert_mut = nil
    for _, mut in ipairs(result.planned_mutations) do
        if mut.type == "insert" then
            insert_mut = mut
        end
    end
    check("dup positive insert found", insert_mut ~= nil)
    check("dup positive insert start=1000", insert_mut and insert_mut.timeline_start_frame == 1000)
    check("dup positive insert duration=500", insert_mut and insert_mut.duration_frames == 500)

    layout:cleanup()
end

print("\n--- plan_duplicate_block: cross-track duplicate ---")
do
    local layout = ripple_layout.create({
        clips = {
            order = {"v1_left"},
            v1_left = {
                timeline_start = 0, duration = 500, source_in = 0
            }
        }
    })

    local ok, err, result = ClipMutator.plan_duplicate_block(layout.db, {
        sequence_id = layout.sequence_id,
        clip_ids = {"clip_v1_left"},
        target_track_id = layout.tracks.v2.id,
        anchor_clip_id = "clip_v1_left",
        delta_rat = Rational.new(0, 1000, 1)
    })
    check("dup cross-track ok", ok == true)
    check("dup cross-track 1 new id", #result.new_clip_ids == 1)

    local insert_mut = nil
    for _, mut in ipairs(result.planned_mutations) do
        if mut.type == "insert" then
            insert_mut = mut
        end
    end
    check("dup cross-track insert found", insert_mut ~= nil)
    check("dup cross-track insert track=v2", insert_mut and insert_mut.track_id == layout.tracks.v2.id)

    layout:cleanup()
end

print("\n--- plan_duplicate_block: duplicate with occlusion ---")
do
    -- Clip A at [0,500) on V1. Clip B at [0,500) on V2.
    -- Duplicate A to V2 at delta=0 → should occlude B
    local layout = ripple_layout.create({
        clips = {
            order = {"v1_left", "v2"},
            v1_left = {
                timeline_start = 0, duration = 500, source_in = 0
            },
            v2 = {
                timeline_start = 0, duration = 500, source_in = 0
            }
        }
    })

    local ok, err, result = ClipMutator.plan_duplicate_block(layout.db, {
        sequence_id = layout.sequence_id,
        clip_ids = {"clip_v1_left"},
        target_track_id = layout.tracks.v2.id,
        anchor_clip_id = "clip_v1_left",
        delta_rat = Rational.new(0, 1000, 1)
    })
    check("dup occlusion ok", ok == true)
    check("dup occlusion has mutations", #result.planned_mutations > 0)

    -- Should have both a delete (occlude B) and an insert (new clip)
    local has_delete = false
    local has_insert = false
    for _, mut in ipairs(result.planned_mutations) do
        if mut.type == "delete" then has_delete = true end
        if mut.type == "insert" then has_insert = true end
    end
    check("dup occlusion has delete", has_delete)
    check("dup occlusion has insert", has_insert)

    layout:cleanup()
end

print("\n--- plan_duplicate_block: nonexistent anchor clip asserts ---")
do
    local layout = ripple_layout.create({
        clips = {
            order = {"v1_left"},
            v1_left = {
                timeline_start = 0, duration = 500, source_in = 0
            }
        }
    })

    -- Anchor clip not found → hard assert (invariant: anchor must exist)
    expect_error("dup nonexistent anchor asserts", function()
        ClipMutator.plan_duplicate_block(layout.db, {
            sequence_id = layout.sequence_id,
            clip_ids = {"nonexistent_clip_id"},
            target_track_id = layout.tracks.v1.id,
            delta_rat = Rational.new(100, 1000, 1)
        })
    end)

    layout:cleanup()
end

print("\n--- plan_duplicate_block: nonexistent source clip returns error ---")
do
    local layout = ripple_layout.create({
        clips = {
            order = {"v1_left"},
            v1_left = {
                timeline_start = 0, duration = 500, source_in = 0
            }
        }
    })

    -- anchor exists but a second clip_id doesn't → soft error return
    local ok, err = ClipMutator.plan_duplicate_block(layout.db, {
        sequence_id = layout.sequence_id,
        clip_ids = {"clip_v1_left", "nonexistent_clip_id"},
        target_track_id = layout.tracks.v1.id,
        anchor_clip_id = "clip_v1_left",
        delta_rat = Rational.new(1000, 1000, 1)
    })
    check("dup nonexistent source not ok", ok == false)
    check("dup nonexistent source has error", err ~= nil and err:find("not found") ~= nil)

    layout:cleanup()
end

print("\n--- plan_duplicate_block: track type mismatch asserts ---")
do
    -- Create layout, then manually add an audio track via SQL
    local layout = ripple_layout.create({
        clips = {
            order = {"v1_left"},
            v1_left = {
                timeline_start = 0, duration = 500, source_in = 0
            }
        }
    })
    -- Add audio track directly
    local Track = require("models.track")
    local a_track = Track.create_audio("A1", layout.sequence_id, {id = "track_a1", index = 1})
    assert(a_track and a_track:save(), "Failed to create audio track")

    expect_error("dup track type mismatch", function()
        ClipMutator.plan_duplicate_block(layout.db, {
            sequence_id = layout.sequence_id,
            clip_ids = {"clip_v1_left"},
            target_track_id = "track_a1",
            anchor_clip_id = "clip_v1_left",
            delta_rat = Rational.new(0, 1000, 1)
        })
    end)

    layout:cleanup()
end

-- ═══════════════════════════════════════════════════════════════
-- Summary
-- ═══════════════════════════════════════════════════════════════

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
    print("FAILURES DETECTED")
    os.exit(1)
end
print("✅ test_clip_mutator.lua passed")
