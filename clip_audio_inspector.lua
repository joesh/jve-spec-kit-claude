-- Golden Test 3: Micro-Cluster Acceptance
-- This file should be ACCEPTED by the analyzer (clear nucleus, no leverage point)
-- Reason: Small (2-4 functions), tight semantic cohesion, well-factored

local M = {}

-- Domain: Media inspection
-- Responsibility: Audio presence & properties
-- Scope: Narrow and correct

-- Public API: Check if clip has audio track
function M.clip_has_audio(clip)
    local channel_count = M.clip_audio_channel_count(clip)
    return channel_count > 0
end

-- Internal: Get audio channel count for clip
function M.clip_audio_channel_count(clip)
    if not clip or not clip.media_id then
        return 0
    end

    -- Query media metadata for audio channels
    local media = database.get_media(clip.media_id)
    if not media then
        return 0
    end

    return media.audio_channels or 0
end

return M
