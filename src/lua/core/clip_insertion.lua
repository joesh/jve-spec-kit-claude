--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~61 LOC
-- Volatility: unknown
--
-- @file clip_insertion.lua
local database = require("core.database")
local clip_links = require("core.clip_links")

local function link_clips(left, right)
    local db = assert(database.get_connection(), "link_clips: missing db connection")
    local left_id = assert(left and (left.id or left.clip_id), "link_clips: missing left clip id")
    local right_id = assert(right and (right.id or right.clip_id), "link_clips: missing right clip id")

    local left_group = clip_links.get_link_group_id(left_id, db)
    local right_group = clip_links.get_link_group_id(right_id, db)
    assert(not right_group or right_group == left_group, "link_clips: clip already linked to another group")

    if not left_group then
        local link_group_id, error_msg = clip_links.create_link_group({
            {
                clip_id = left_id,
                role = left.role or "video",
                time_offset = left.time_offset or 0
            },
            {
                clip_id = right_id,
                role = right.role or "audio",
                time_offset = right.time_offset or 0
            }
        }, db)
        assert(link_group_id, error_msg or "link_clips: failed to create link group")
        return
    end

    local insert_query = assert(db:prepare([[
        INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, enabled)
        VALUES (?, ?, ?, ?, 1)
    ]]), "link_clips: failed to prepare insert")
    insert_query:bind_value(1, left_group)
    insert_query:bind_value(2, right_id)
    insert_query:bind_value(3, right.role or "audio")
    insert_query:bind_value(4, right.time_offset or 0)
    local ok = insert_query:exec()
    insert_query:finalize()
    assert(ok, "link_clips: failed to insert clip link")
end

function insert_selected_clip_into_timeline(state)
    local clip = assert(state.selected_clip)
    local seq  = assert(state.sequence)
    local pos  = assert(state.insert_pos)

    local new_clips = {}

    if clip:has_video() then
        local track = seq:target_video_track(0)
        new_clips[#new_clips+1] =
            assert(seq:insert_clip(clip.video, track, pos))
    end

    if clip:has_audio() then
        for ch = 0, clip:audio_channel_count()-1 do
            local track = seq:target_audio_track(ch)
            new_clips[#new_clips+1] =
                assert(seq:insert_clip(clip:audio(ch), track, pos))
        end
    end

    if #new_clips > 1 then
        for i = 2, #new_clips do
            link_clips(new_clips[1], new_clips[i])
        end
    end
end

return insert_selected_clip_into_timeline
