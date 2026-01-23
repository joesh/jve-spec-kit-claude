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
local clip_link = require("models.clip_link")

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
            clip_link.link_two_clips(new_clips[1], new_clips[i])
        end
    end
end

return insert_selected_clip_into_timeline
