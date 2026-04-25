-- T039a (013): sequence_content_changed signal contract spy.
--
-- Every command class that mutates a sequence's clip set MUST emit
-- "sequence_content_changed" with the affected sequence_id. Without this
-- guard, a single missed emit silently breaks downstream observers
-- (timeline cache, inspector, render preview).
--
-- This test connects a spy and drives one representative of each
-- currently-V13-rewired command class:
--   Insert, Overwrite, TrimHead, TrimTail, Slip, Slide, Roll, SplitClip,
--   Blade, Duplicate, RippleDelete.
--
-- Phase 3.5+ command classes (SetClipLayer, ToggleClipChannel,
-- SetMasterDefaultLayer, SetMasterChannelState, SetSequenceStartTC, Nest,
-- Unnest, GrowMasterMedium) are noted but not yet implemented; this test
-- will be extended when those land.

require("test_env")
local database = require("core.database")
local Signals  = require("core.signals")

local DB_PATH = "/tmp/jve/test_013_signal_sequence_content_changed.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

-- Build: project, master 'm' (with V media_ref 1000 frames), edit 'e' (nested).
local function base_fixture()
    local db = fresh_db()
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('p1', 'p', 'passthrough', 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p1', 'm', 'master', 24, 1, 48000, 1920, 1080, 0, 0),
               ('e', 'p1', 'e', 'nested', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1),
               ('e-v1', 'e', 'V1', 'VIDEO', 1),
               ('e-v2', 'e', 'V2', 'VIDEO', 2);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels, created_at, modified_at)
        VALUES ('med', 'p1', 'v.mov', '/tmp/v.mov', 1000, 24, 1, 0, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            timeline_start_frame, duration_frames, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('mr', 'p1', 'm', 'm-v1', 'med', 0, 1000, 0, 1000, 1, 1.0, 0, 0, 0);
    ]]))
    return db
end

local function seed_clip(db, id, track_id, ts, dur, src_in, src_out)
    assert(db:exec(string.format([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            nested_sequence_id, name,
            timeline_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            fps_mismatch_policy, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('%s', 'p1', 'e', '%s', 'm', '%s', %d, %d, %d, %d,
            'passthrough', 1, 1.0, 0, 0, 0)
    ]], id, track_id, id, ts, dur, src_in, src_out)))
end

-- A spy that captures every emit of sequence_content_changed.
local function make_spy()
    local events = {}
    local conn_id = Signals.connect("sequence_content_changed", function(seq_id)
        events[#events + 1] = seq_id
    end, 100)
    return events, conn_id
end

local function assert_emit_for(label, seq_id, fn)
    local events, conn = make_spy()
    fn()
    Signals.disconnect(conn)
    assert(#events >= 1, string.format(
        "%s: expected at least one sequence_content_changed emit; got 0",
        label))
    for _, sid in ipairs(events) do
        assert(sid == seq_id, string.format(
            "%s: emit had sequence_id=%s; expected %s",
            label, tostring(sid), seq_id))
    end
    print(string.format("  %s ok (%d emit(s))", label, #events))
end

-- -------------------------------------------------------------------------
-- Insert (T040)
-- -------------------------------------------------------------------------
print("-- sequence_content_changed signal contract --")
do
    base_fixture()
    local Insert = require("core.commands.insert")
    assert_emit_for("Insert", "e", function()
        -- Insert is wired only via M.register's executor (which is what
        -- emits the signal). Call execute through a stub command shim.
        -- For T039a we just exercise execute and the executor wrapping
        -- behavior — but since execute is the function emitting, drive
        -- it through register's executor.
        local executors, undoers, last_err = {}, {}, nil
        Insert.register(executors, undoers, nil,
            function(e) last_err = e end)
        local cmd = {
            params = {
                sequence_id           = "e",
                nested_sequence_id    = "m",
                timeline_start_frame  = 0,
                target_video_track_id = "e-v1",
            },
            get_all_parameters = function(self) return self.params end,
            set_parameter      = function(self, k, v) self.params[k] = v end,
            set_parameters     = function(self, t)
                for k, v in pairs(t) do self.params[k] = v end
            end,
        }
        local ok = executors["Insert"](cmd)
        assert(ok, "Insert executor failed: " .. tostring(last_err))
    end)
end

-- A reusable mini command shim that supplies just enough Command interface
-- for the executors registered by each command module.
local function make_cmd(params)
    return {
        params = params,
        get_all_parameters = function(self) return self.params end,
        set_parameter      = function(self, k, v) self.params[k] = v end,
        set_parameters     = function(self, t)
            for k, v in pairs(t) do self.params[k] = v end
        end,
    }
end

-- Helper: register a command module and drive its executor for a given
-- command name with given params; assert the executor returned truthy.
local function drive(module, name, params)
    local executors, undoers, last_err = {}, {}, nil
    module.register(executors, undoers, nil, function(e) last_err = e end)
    local exec = executors[name]
    assert(exec, name .. ": executor not registered")
    local ok = exec(make_cmd(params))
    assert(ok, name .. " executor failed: " .. tostring(last_err))
end

-- -------------------------------------------------------------------------
-- Overwrite (T041)
-- -------------------------------------------------------------------------
do
    base_fixture()
    local Overwrite = require("core.commands.overwrite")
    assert_emit_for("Overwrite", "e", function()
        drive(Overwrite, "Overwrite", {
            sequence_id           = "e",
            nested_sequence_id    = "m",
            timeline_start_frame  = 0,
            target_video_track_id = "e-v1",
        })
    end)
end

-- -------------------------------------------------------------------------
-- TrimHead, TrimTail (T043)
-- -------------------------------------------------------------------------
do
    local db = base_fixture()
    seed_clip(db, "c", "e-v1", 100, 100, 0, 100)
    local TrimHead = require("core.commands.trim_head")
    assert_emit_for("TrimHead", "e", function()
        drive(TrimHead, "TrimHead", {
            sequence_id = "e", clip_id = "c", trim_amount_frames = 5,
        })
    end)
end
do
    local db = base_fixture()
    seed_clip(db, "c", "e-v1", 100, 100, 0, 100)
    local TrimTail = require("core.commands.trim_tail")
    assert_emit_for("TrimTail", "e", function()
        drive(TrimTail, "TrimTail", {
            sequence_id = "e", clip_id = "c", trim_amount_frames = 5,
        })
    end)
end

-- -------------------------------------------------------------------------
-- Slip, Slide, Roll (T044)
-- -------------------------------------------------------------------------
do
    local db = base_fixture()
    seed_clip(db, "c", "e-v1", 100, 100, 50, 150)
    local Slip = require("core.commands.slip")
    assert_emit_for("Slip", "e", function()
        drive(Slip, "Slip", {
            sequence_id = "e", clip_id = "c", delta_source_frames = 5,
        })
    end)
end
do
    local db = base_fixture()
    seed_clip(db, "c", "e-v1", 100, 100, 50, 150)
    local Slide = require("core.commands.slide")
    assert_emit_for("Slide", "e", function()
        drive(Slide, "Slide", {
            sequence_id = "e", clip_id = "c", delta_timeline_frames = 5,
        })
    end)
end
do
    local db = base_fixture()
    seed_clip(db, "a", "e-v1",   0, 100,   0, 100)
    seed_clip(db, "b", "e-v1", 100, 100, 200, 300)
    local Roll = require("core.commands.roll")
    assert_emit_for("Roll", "e", function()
        drive(Roll, "Roll", {
            sequence_id           = "e",
            outgoing_clip_id      = "a",
            incoming_clip_id      = "b",
            delta_timeline_frames = 5,
        })
    end)
end

-- -------------------------------------------------------------------------
-- SplitClip (T045)
-- -------------------------------------------------------------------------
do
    local db = base_fixture()
    seed_clip(db, "c", "e-v1", 100, 100, 0, 100)
    local SplitClip = require("core.commands.split_clip")
    assert_emit_for("SplitClip", "e", function()
        drive(SplitClip, "SplitClip", {
            sequence_id = "e", clip_id = "c", split_frame = 150,
        })
    end)
end

-- -------------------------------------------------------------------------
-- Blade (T045a)
-- -------------------------------------------------------------------------
do
    local db = base_fixture()
    seed_clip(db, "c", "e-v1", 0, 100, 0, 100)
    local Blade = require("core.commands.blade")
    assert_emit_for("Blade", "e", function()
        drive(Blade, "Blade", {
            sequence_id = "e", blade_frame = 50, track_ids = { "e-v1" },
        })
    end)
end

-- -------------------------------------------------------------------------
-- Duplicate (T047)
-- -------------------------------------------------------------------------
do
    local db = base_fixture()
    seed_clip(db, "c", "e-v1", 100, 50, 0, 50)
    local Duplicate = require("core.commands.duplicate")
    assert_emit_for("Duplicate", "e", function()
        drive(Duplicate, "Duplicate", {
            sequence_id     = "e",
            clip_id         = "c",
            target_track_id = "e-v2",
            delta_frames    = 100,
        })
    end)
end

-- -------------------------------------------------------------------------
-- RippleDelete (T046 partial)
-- -------------------------------------------------------------------------
do
    local db = base_fixture()
    seed_clip(db, "c", "e-v1", 0, 100, 0, 100)
    local RippleDelete = require("core.commands.ripple_delete")
    assert_emit_for("RippleDelete", "e", function()
        drive(RippleDelete, "RippleDelete", {
            sequence_id = "e", clip_id = "c",
        })
    end)
end

print("✅ test_013_signal_sequence_content_changed.lua passed")
