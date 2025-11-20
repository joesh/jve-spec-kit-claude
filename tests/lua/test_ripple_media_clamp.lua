#!/usr/bin/env luajit

-- Regression tests for media-boundary clamping in BatchRippleEdit.

package.path = 'src/lua/?.lua;src/lua/?/init.lua;' .. package.path

local mock_db = {
    clips = {},
    media = {}
}

function mock_db:reset()
    self.clips = {}
    self.media = {}
end

function mock_db:store_clip(clip)
    local stored = {}
    for k, v in pairs(clip) do
        stored[k] = v
    end
    self.clips[clip.id] = stored
end

function mock_db:store_media(media)
    local stored = {}
    for k, v in pairs(media) do
        stored[k] = v
    end
    self.media[media.id] = stored
end

local function make_stmt()
    return {
        exec = function() return true end,
        next = function() return false end,
        value = function() return nil end,
        bind_value = function() return true end
    }
end

function mock_db:prepare()
    return make_stmt()
end

function mock_db:begin_transaction()
    return true
end

function mock_db:commit()
    return true
end

function mock_db:rollback()
    return true
end

_G.db = mock_db

package.loaded['core.database'] = {
    load_clips = function()
        local list = {}
        for _, clip in pairs(mock_db.clips) do
            table.insert(list, clip)
        end
        table.sort(list, function(a, b)
            if a.start_value == b.start_value then
                return a.id < b.id
            end
            return a.start_value < b.start_value
        end)
        return list
    end
}

package.loaded['models.media'] = {
    load = function(id)
        return mock_db.media[id]
    end
}

package.loaded['models.clip'] = {
    load = function(id)
        local stored = mock_db.clips[id]
        if not stored then return nil end
        local clip = {}
        for k, v in pairs(stored) do
            clip[k] = v
        end
        function clip:save()
            mock_db:store_clip(self)
            return true
        end
        return clip
    end
}

package.loaded['command'] = {
    create = function()
        return {
            parameters = {},
            get_parameter = function(self, key) return self.parameters[key] end,
            set_parameter = function(self, key, value) self.parameters[key] = value end
        }
    end
}

-- Stub unrelated dependencies.
local empty_stub = {}
package.loaded['core.session_state'] = empty_stub
package.loaded['core.event_store'] = empty_stub
package.loaded['core.command_recorder'] = empty_stub
package.loaded['core.snapshot_manager'] = empty_stub
package.loaded['core.undo_tree'] = empty_stub
package.loaded['core.timeline_state'] = empty_stub
package.loaded['core.timeline_selection'] = empty_stub
package.loaded['core.command_replay'] = empty_stub
package.loaded['core.playhead'] = empty_stub
package.loaded['core.media_library'] = empty_stub
package.loaded['core.notifications'] = empty_stub
package.loaded['core.analytics'] = empty_stub
package.loaded['core.solo_manager'] = empty_stub
package.loaded['core.metadata'] = empty_stub
package.loaded['core.zmq_server'] = empty_stub
package.loaded['core.command_history'] = empty_stub
package.loaded['core.color_labels'] = empty_stub
package.loaded['core.keyframe_manager'] = empty_stub
package.loaded['core.playback'] = empty_stub
package.loaded['core.track_manager'] = empty_stub
package.loaded['core.timeline_cache'] = empty_stub
package.loaded['core.autosave'] = empty_stub
package.loaded['models.keyframe'] = empty_stub
package.loaded['models.marker'] = empty_stub
package.loaded['models.track'] = empty_stub
package.loaded['models.project'] = empty_stub
package.loaded['models.clip_marker'] = empty_stub
package.loaded['models.snapshot'] = empty_stub
package.loaded['models.command'] = empty_stub
package.loaded['models.event'] = empty_stub

local command_manager = require('core.command_manager')
command_manager.init(mock_db)

local function assert_eq(name, actual, expected)
    if actual ~= expected then
        io.stderr:write(string.format('%s failed: expected %s, got %s\n', name, tostring(expected), tostring(actual)))
        os.exit(1)
    end
end

local function new_cmd()
    return {
        get_parameter = function(self, key) return self[key] end,
        set_parameter = function(self, key, value) self[key] = value end
    }
end

local executor = command_manager.get_executor('BatchRippleEdit')
local ripple_executor = command_manager.get_executor('RippleEdit')

-- Test 1: Out-point extend clamps to media duration_value.
mock_db:reset()
mock_db:store_media({ id = 'media_short', duration_value = 10000, timebase_type = 'video_frames', timebase_rate = 30 })
mock_db:store_clip({
    id = 'clip_out',
    track_id = 'track_v1',
    media_id = 'media_short',
    start_value = 1000,
    duration_value = 9500,
    source_in_value_value = 0,
    source_out_value_value = 9500,
    timebase_type = 'video_frames',
    timebase_rate = 30
})
mock_db:store_clip({
    id = 'clip_downstream',
    track_id = 'track_v1',
    media_id = 'media_short',
    start_value = 12000,
    duration_value = 2000,
    source_in_value_value = 0,
    source_out_value = 2000,
    timebase_type = 'video_frames',
    timebase_rate = 30
})

local cmd = new_cmd()
cmd:set_parameter('edge_infos', {
    { clip_id = 'clip_out', edge_type = 'out', track_id = 'track_v1' }
})
cmd:set_parameter('delta_ms', 1000)
cmd:set_parameter('sequence_id', 'test_sequence')

assert_eq('execute media clamp out', executor(cmd), true)
assert_eq('media clamp out duration_value', mock_db.clips['clip_out'].duration_value, 10000)
assert_eq('media clamp out source_out_value', mock_db.clips['clip_out'].source_out_value_value, 10000)
assert_eq('media clamp out downstream shift', mock_db.clips['clip_downstream'].start_value, 12500)

-- Test 2: In-point extend clamps to media start.
mock_db:reset()
mock_db:store_media({ id = 'media_short', duration_value = 12000, timebase_type = 'video_frames', timebase_rate = 30 })
mock_db:store_clip({
    id = 'clip_in',
    track_id = 'track_v1',
    media_id = 'media_short',
    start_value = 1000,
    duration_value = 3000,
    source_in_value_value = 500,
    source_out_value_value = 3500,
    timebase_type = 'video_frames',
    timebase_rate = 30
})
mock_db:store_clip({
    id = 'clip_in_downstream',
    track_id = 'track_v1',
    media_id = 'media_short',
    start_value = 4500,
    duration_value = 2000,
    source_in_value_value = 0,
    source_out_value_value = 2000,
    timebase_type = 'video_frames',
    timebase_rate = 30
})

cmd = new_cmd()
cmd:set_parameter('edge_infos', {
    { clip_id = 'clip_in', edge_type = 'in', track_id = 'track_v1' }
})
cmd:set_parameter('delta_ms', -1000)
cmd:set_parameter('sequence_id', 'test_sequence')

assert_eq('execute media clamp in', executor(cmd), true)
assert_eq('media clamp in duration_value', mock_db.clips['clip_in'].duration_value, 3500)
assert_eq('media clamp in source_in_value', mock_db.clips['clip_in'].source_in_value, 0)
assert_eq('media clamp in downstream shift', mock_db.clips['clip_in_downstream'].start_value, 5000)

-- Test 3: RippleEdit also clamps to media limits.
mock_db:reset()
mock_db:store_media({ id = 'media_short', duration_value = 8000, timebase_type = 'video_frames', timebase_rate = 30 })
mock_db:store_clip({
    id = 'ripple_clip',
    track_id = 'track_v1',
    media_id = 'media_short',
    start_value = 1000,
    duration_value = 7000,
    source_in_value = 0,
    source_out_value = 7000,
    timebase_type = 'video_frames',
    timebase_rate = 30
})
mock_db:store_clip({
    id = 'ripple_downstream',
    track_id = 'track_v1',
    media_id = 'media_short',
    start_value = 9000,
    duration_value = 2000,
    source_in_value = 0,
    source_out_value = 2000,
    timebase_type = 'video_frames',
    timebase_rate = 30
})

cmd = new_cmd()
cmd:set_parameter('edge_info', { clip_id = 'ripple_clip', edge_type = 'out', track_id = 'track_v1' })
cmd:set_parameter('delta_ms', 2000)
cmd:set_parameter('sequence_id', 'test_sequence')

assert_eq('execute ripple clamp out', ripple_executor(cmd), true)
assert_eq('ripple clamp out duration_value', mock_db.clips['ripple_clip'].duration_value, 8000)
assert_eq('ripple clamp out source_out_value', mock_db.clips['ripple_clip'].source_out_value, 8000)
assert_eq('ripple clamp out downstream shift', mock_db.clips['ripple_downstream'].start_value, 10000)

print('✅ Ripple media clamp tests passed')
