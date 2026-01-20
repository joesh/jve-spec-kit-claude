#!/usr/bin/env luajit

-- Regression: DeleteClip undo must repopulate timeline cache (apply_mutations receives insert).

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";../tests/?.lua"

require("test_env")

local database = require("core.database")
local Command = require("command")

-- Stub timeline_state to track cache mutations
local timeline_state = {
    clips = {},
    reloaded = false,
    apply_called = false,
    last_mutations = nil
}

local function has_clip(id)
    for _, c in ipairs(timeline_state.clips) do
        if c.id == id then return true end
    end
    return false
end

local function add_clip(clip)
    for _, c in ipairs(timeline_state.clips) do
        if c.id == clip.id then return end
    end
    table.insert(timeline_state.clips, clip)
end

local function remove_clip(id)
    for i, c in ipairs(timeline_state.clips) do
        if c.id == id then
            table.remove(timeline_state.clips, i)
            return
        end
    end
end

function timeline_state.apply_mutations(sequence_or_mutations, maybe_mutations)
    local mutations = maybe_mutations or sequence_or_mutations
    if not mutations then return false end
    timeline_state.apply_called = true
    timeline_state.last_mutations = mutations

    local function apply_bucket(bucket)
        if bucket.deletes then
            for _, cid in ipairs(bucket.deletes) do
                remove_clip(cid)
            end
        end
        if bucket.inserts then
            for _, clip in ipairs(bucket.inserts) do
                add_clip({id = clip.clip_id or clip.id})
            end
        end
    end

    if mutations.sequence_id or mutations.inserts or mutations.updates or mutations.deletes then
        apply_bucket(mutations)
    else
        for _, bucket in pairs(mutations) do
            apply_bucket(bucket)
        end
    end
    return true
end

function timeline_state.reload_clips(seq_id)
    timeline_state.reloaded = seq_id
    -- Mimic minimal reload by reading clip ids from DB
    local db = database.get_connection()
    if db then
        local stmt = db:prepare([[
            SELECT id FROM clips WHERE owner_sequence_id = ?
        ]])
        if stmt then
            stmt:bind_value(1, seq_id)
            if stmt:exec() then
                timeline_state.clips = {}
                while stmt:next() do
                    add_clip({id = stmt:value(0)})
                end
            end
            stmt:finalize()
        end
    end
    return true
end

function timeline_state.get_selected_clips() return {} end
function timeline_state.get_selected_edges() return {} end
function timeline_state.get_selected_gaps() return {} end
function timeline_state.set_selection() end
function timeline_state.set_edge_selection() end
function timeline_state.set_gap_selection() end
function timeline_state.set_playhead_position() end
function timeline_state.get_playhead_position() return 0 end
function timeline_state.get_sequence_id() return "default_sequence" end
function timeline_state.get_sequence_frame_rate() return {fps_numerator = 30, fps_denominator = 1} end
function timeline_state.get_viewport_start_time() return 0 end
function timeline_state.get_viewport_duration() return 0 end

package.loaded["ui.timeline.timeline_state"] = timeline_state

local DB_PATH = "/tmp/jve/test_delete_clip_undo_restore_cache.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH))
local db = database.get_connection()
db:exec(require("import_schema"))

db:exec([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));
    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    )
    VALUES (
        'default_sequence', 'default_project', 'Default Sequence', 'timeline',
        30, 1, 48000,
        1920, 1080,
        0, 300, 0,
        '[]', '[]', '[]',
        0, strftime('%s','now'), strftime('%s','now')
    );
    INSERT INTO tracks (
        id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan
    )
    VALUES (
        'track_v1', 'default_sequence', 'V1', 'VIDEO', 1,
        1, 0, 0, 0, 1.0, 0.0
    );
    INSERT INTO clips (
        id, project_id, clip_kind, source_sequence_id, parent_clip_id, owner_sequence_id,
        track_id, media_id, name,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline,
        created_at, modified_at
    )
    VALUES (
        'clip_delete_test', 'default_project', 'timeline', NULL, NULL, 'default_sequence',
        'track_v1', NULL, 'Test Clip',
        0, 30, 0, 30,
        30, 1, 1, 0,
        strftime('%s','now'), strftime('%s','now')
    );
]])

-- Seed timeline cache with the clip that exists in DB
add_clip({id = "clip_delete_test"})

-- Initialize command manager with stub timeline state
package.loaded["core.command_manager"] = nil
local command_manager = require("core.command_manager")
command_manager.init(db, "default_sequence", "default_project")
command_manager.begin_command_event("script")

local delete_cmd = Command.create("DeleteClip", "default_project")
delete_cmd:set_parameter("clip_id", "clip_delete_test")
delete_cmd:set_parameter("sequence_id", "default_sequence")

local delete_result = command_manager.execute(delete_cmd)
assert(delete_result.success, delete_result.error_message or "DeleteClip execute failed")
assert(not has_clip("clip_delete_test"), "Clip should be removed from timeline cache after delete")

-- Reset mutation tracking for undo path
timeline_state.apply_called = false
timeline_state.last_mutations = nil
timeline_state.reloaded = false

local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "Undo failed")
assert(timeline_state.apply_called, "Undo should call timeline_state.apply_mutations (reloaded=" .. tostring(timeline_state.reloaded) .. ")")
local applied_bucket = timeline_state.last_mutations
if applied_bucket and not applied_bucket.sequence_id and not applied_bucket.inserts and not applied_bucket.deletes then
    -- If map keyed by sequence, pick the first bucket
    for _, bucket in pairs(applied_bucket) do
        applied_bucket = bucket
        break
    end
end
local encoded_bucket = require("dkjson").encode(applied_bucket)
assert(applied_bucket and applied_bucket.inserts and #applied_bucket.inserts > 0,
    "__timeline_mutations for undo should contain insert payloads; got " .. tostring(encoded_bucket))
assert(has_clip("clip_delete_test"), "Undo should restore clip into timeline cache (insert mutation)")
assert(timeline_state.reloaded == false or timeline_state.reloaded == nil or timeline_state.reloaded == "default_sequence",
    "Undo should not fail to refresh timeline; reload may happen but cache must contain clip")

command_manager.end_command_event()
print("✅ DeleteClip undo restores timeline cache insert mutation")
