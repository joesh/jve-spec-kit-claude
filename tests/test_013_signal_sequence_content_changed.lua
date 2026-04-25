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
-- Extended after Phase 3.5/3.6/3.7 landed: also drives SetClipLayer,
-- ToggleClipChannel, SetClipChannelGain, ClearClipOverride,
-- SetMasterDefaultLayer, SetMasterChannelState, SetSequenceStartTC,
-- Nest, Unnest. GrowMasterMedium remains a follow-up.

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

-- Variant for commands that legitimately emit on multiple sequence ids
-- (Nest/Unnest emit on both parent and the nested sequence). Asserts
-- the expected seq_id is among the events; doesn't require uniqueness.
local function assert_emit_includes(label, seq_id, fn)
    local events, conn = make_spy()
    fn()
    Signals.disconnect(conn)
    assert(#events >= 1, string.format(
        "%s: expected at least one sequence_content_changed emit; got 0",
        label))
    local found = false
    for _, sid in ipairs(events) do
        if sid == seq_id then found = true; break end
    end
    assert(found, string.format(
        "%s: expected seq_id=%s among emits; got [%s]",
        label, seq_id, table.concat(events, ",")))
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

-- -------------------------------------------------------------------------
-- Phase 3.5: per-clip override commands.
--
-- These mutate clip_channel_override / clip.master_layer_track_id and
-- emit on the parent (edit) sequence's id.
-- -------------------------------------------------------------------------

-- Augment the master with V2 + an audio track + media so the override
-- commands have a domain to operate on.
local function override_fixture()
    local db = base_fixture()
    -- V2 on master + an audio track with a 2-channel media file.
    assert(db:exec([[
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v2', 'm', 'V2', 'VIDEO', 2),
               ('m-a1', 'm', 'A1', 'AUDIO', 1),
               ('e-a1', 'e', 'A1', 'AUDIO', 1);
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels,
            created_at, modified_at)
        VALUES ('a-med', 'p1', 'a.wav', '/tmp/a.wav', 48000, 48000, 1, 2, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            timeline_start_frame, duration_frames, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('mr-a', 'p1', 'm', 'm-a1', 'a-med', 0, 48000, 0, 48000,
                1, 1.0, 0, 0, 0);
    ]]))
    return db
end

do  -- SetClipLayer (T053)
    local db = override_fixture()
    seed_clip(db, "c", "e-v1", 0, 100, 0, 100)
    local SetClipLayer = require("core.commands.set_clip_layer")
    assert_emit_for("SetClipLayer", "e", function()
        drive(SetClipLayer, "SetClipLayer", {
            sequence_id = "e", clip_id = "c", track_id = "m-v2",
        })
    end)
end

do  -- ToggleClipChannel (T054)
    local db = override_fixture()
    -- Audio clip in `e` referencing the master.
    assert(db:exec([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            nested_sequence_id, name,
            timeline_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('ca', 'p1', 'e', 'e-a1', 'm', 'ca',
                0, 48000, 0, 48000, NULL, 'resample', 1, 1.0, 0, 0, 0);
    ]]))
    local ToggleClipChannel = require("core.commands.toggle_clip_channel")
    assert_emit_for("ToggleClipChannel", "e", function()
        drive(ToggleClipChannel, "ToggleClipChannel", {
            sequence_id = "e", clip_id = "ca", channel_index = 0,
        })
    end)
end

do  -- SetClipChannelGain (T055)
    local db = override_fixture()
    assert(db:exec([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            nested_sequence_id, name,
            timeline_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('ca', 'p1', 'e', 'e-a1', 'm', 'ca',
                0, 48000, 0, 48000, NULL, 'resample', 1, 1.0, 0, 0, 0);
    ]]))
    local SetClipChannelGain = require("core.commands.set_clip_channel_gain")
    assert_emit_for("SetClipChannelGain", "e", function()
        drive(SetClipChannelGain, "SetClipChannelGain", {
            sequence_id = "e", clip_id = "ca",
            channel_index = 0, gain_db = -6.0,
        })
    end)
end

do  -- ClearClipOverride (channel + layer) (T056)
    local db = override_fixture()
    seed_clip(db, "cv", "e-v1", 0, 100, 0, 100)
    -- Pre-set V2 layer override on cv so the layer-clear has something to clear.
    assert(db:exec("UPDATE clips SET master_layer_track_id='m-v2' WHERE id='cv'"))
    local ClearClipOverride = require("core.commands.clear_clip_override")
    assert_emit_for("ClearClipOverride(layer)", "e", function()
        drive(ClearClipOverride, "ClearClipOverride", {
            sequence_id = "e", clip_id = "cv", kind = "layer",
        })
    end)

    -- Channel variant.
    assert(db:exec([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            nested_sequence_id, name,
            timeline_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('ca', 'p1', 'e', 'e-a1', 'm', 'ca',
                0, 48000, 0, 48000, NULL, 'resample', 1, 1.0, 0, 0, 0);
        INSERT INTO clip_channel_override (clip_id, channel_index, enabled, gain_db)
        VALUES ('ca', 0, 0, -3.0);
    ]]))
    assert_emit_for("ClearClipOverride(channel)", "e", function()
        drive(ClearClipOverride, "ClearClipOverride", {
            sequence_id = "e", clip_id = "ca", kind = "channel",
            channel_index = 0,
        })
    end)
end

-- -------------------------------------------------------------------------
-- Phase 3.6: master-level + sequence-level commands.
--
-- These emit on the MASTER (or affected sequence)'s id, which propagates
-- to tracking clips via the resolver. The contract is "fires with the
-- correct sequence_id" — i.e., the sequence whose state changed.
-- -------------------------------------------------------------------------

do  -- SetMasterDefaultLayer (T061)
    override_fixture()
    local SetMasterDefaultLayer = require("core.commands.set_master_default_layer")
    assert_emit_for("SetMasterDefaultLayer", "m", function()
        drive(SetMasterDefaultLayer, "SetMasterDefaultLayer", {
            sequence_id = "m", track_id = "m-v2",
        })
    end)
end

do  -- SetMasterChannelState (T062)
    override_fixture()
    local SetMasterChannelState = require("core.commands.set_master_channel_state")
    assert_emit_for("SetMasterChannelState", "m", function()
        drive(SetMasterChannelState, "SetMasterChannelState", {
            sequence_id = "m", channel_index = 0,
            enabled = true, gain_db = -3.0,
        })
    end)
end

do  -- SetSequenceStartTC (T063)
    base_fixture()
    local SetSequenceStartTC = require("core.commands.set_sequence_start_tc")
    assert_emit_for("SetSequenceStartTC(video)", "m", function()
        drive(SetSequenceStartTC, "SetSequenceStartTC", {
            sequence_id = "m", medium = "video", tc_value = 86400,
        })
    end)
end

do  -- SetFpsMismatchPolicy(sequence) emits sequence_content_changed (T064)
    base_fixture()
    local SetFpsMismatchPolicy = require("core.commands.set_fps_mismatch_policy")
    assert_emit_for("SetFpsMismatchPolicy(sequence)", "e", function()
        drive(SetFpsMismatchPolicy, "SetFpsMismatchPolicy", {
            scope = "sequence", sequence_id = "e", policy = "passthrough",
        })
    end)
end

-- -------------------------------------------------------------------------
-- Phase 3.7: Nest / Unnest emit on BOTH parent and the new/old nested.
-- The contract test asserts the parent emit ("affected sequence_id");
-- the second emit (on S) is also observable but not under separate
-- assertion here.
-- -------------------------------------------------------------------------

do  -- Nest (T068) — emits on parent AND new sequence; we assert parent.
    local db = base_fixture()
    seed_clip(db, "c1", "e-v1", 100, 100, 0, 100)
    local Nest = require("core.commands.nest")
    assert_emit_includes("Nest(parent)", "e", function()
        drive(Nest, "Nest", {
            sequence_id        = "e",
            selected_clip_ids  = { "c1" },
        })
    end)
end

do  -- ExpandAudio (T056i) — emits on parent.
    local db = base_fixture()
    -- Add a 2nd master A track + edit A track + composite A clip.
    assert(db:exec([[
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-a1', 'm', 'A1', 'AUDIO', 1),
               ('m-a2', 'm', 'A2', 'AUDIO', 2),
               ('e-a1', 'e', 'A1', 'AUDIO', 1);
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels,
            created_at, modified_at)
        VALUES ('a-med', 'p1', 'a.wav', '/tmp/a.wav', 200000, 48000, 1, 1, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            timeline_start_frame, duration_frames, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('mr-a1', 'p1', 'm', 'm-a1', 'a-med', 0, 200000, 0, 200000, 1, 1.0, 0, 0, 0),
               ('mr-a2', 'p1', 'm', 'm-a2', 'a-med', 0, 200000, 0, 200000, 1, 1.0, 0, 0, 0);
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            nested_sequence_id, name,
            timeline_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('ca', 'p1', 'e', 'e-a1', 'm', 'ca',
                0, 100, 0, 200000, NULL, NULL, 'passthrough', 1, 1.0, 0, 0, 0);
    ]]))
    require("test_env").touch_media_fixtures()
    local ExpandAudio = require("core.commands.expand_audio")
    assert_emit_for("ExpandAudio", "e", function()
        drive(ExpandAudio, "ExpandAudio", {
            sequence_id = "e", clip_id = "ca",
        })
    end)
end

do  -- CollapseAudio (T056j) — emits on parent.
    local db = base_fixture()
    assert(db:exec([[
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-a1', 'm', 'A1', 'AUDIO', 1),
               ('m-a2', 'm', 'A2', 'AUDIO', 2),
               ('e-a1', 'e', 'A1', 'AUDIO', 1),
               ('e-a2', 'e', 'A2', 'AUDIO', 2);
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels,
            created_at, modified_at)
        VALUES ('a-med', 'p1', 'a.wav', '/tmp/a.wav', 200000, 48000, 1, 1, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            timeline_start_frame, duration_frames, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('mr-a1', 'p1', 'm', 'm-a1', 'a-med', 0, 200000, 0, 200000, 1, 1.0, 0, 0, 0),
               ('mr-a2', 'p1', 'm', 'm-a2', 'a-med', 0, 200000, 0, 200000, 1, 1.0, 0, 0, 0);
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            nested_sequence_id, name,
            timeline_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('ca1', 'p1', 'e', 'e-a1', 'm', 'ca1',
                0, 100, 0, 200000, NULL, 'm-a1', 'passthrough', 1, 1.0, 0, 0, 0),
               ('ca2', 'p1', 'e', 'e-a2', 'm', 'ca2',
                0, 100, 0, 200000, NULL, 'm-a2', 'passthrough', 1, 1.0, 0, 0, 0);
        INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, enabled)
        VALUES ('lg', 'ca1', 'audio', 0, 1),
               ('lg', 'ca2', 'audio', 0, 1);
    ]]))
    require("test_env").touch_media_fixtures()
    local CollapseAudio = require("core.commands.collapse_audio")
    assert_emit_for("CollapseAudio", "e", function()
        drive(CollapseAudio, "CollapseAudio", {
            sequence_id = "e", clip_ids = { "ca1", "ca2" },
        })
    end)
end

do  -- Unnest (T069) — emits parent + sequence_deleted/sequence_resurrected.
    local db = base_fixture()
    seed_clip(db, "c1", "e-v1", 100, 100, 0, 100)
    local Nest = require("core.commands.nest")
    local nest_cap = Nest.execute({
        sequence_id        = "e",
        selected_clip_ids  = { "c1" },
    })
    local Unnest = require("core.commands.unnest")
    assert_emit_includes("Unnest(parent)", "e", function()
        drive(Unnest, "Unnest", {
            sequence_id = "e", clip_id = nest_cap.new_clip_id,
        })
    end)
end

print("✅ test_013_signal_sequence_content_changed.lua passed")
