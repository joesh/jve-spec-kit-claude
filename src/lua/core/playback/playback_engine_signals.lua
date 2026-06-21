--- core/playback/playback_engine_signals.lua — signal handlers wired
--- into PlaybackEngine for: track preferences changing,
--- timeline-edit content_changed, in-place media bytes rewritten,
--- and offline/online file-status flips.
---
--- Extracted from playback_engine.lua (2.6: keep the engine file
--- focused on transport/state/lifecycle). Methods are installed onto
--- the PlaybackEngine class via M.install(PlaybackEngine).
---
--- Each handler is conservative: it filters on
--- self:_path_is_active_in_tmb / self.loaded_sequence_id so background
--- bg-probe storms and edits on other sequences are no-ops.

local qt_constants = require("core.qt_constants")
local log = require("core.logger").for_area("ticks")

local M = {}

function M.install(PlaybackEngine)

--- Handler: a track's muted/soloed/locked/enabled flag changed.
-- For VIDEO: recomputes _effective_video_track_indices and re-renders the
-- current monitor frame so mute takes effect immediately in park mode.
-- For AUDIO: pushes updated mix params so mute takes effect in the running
-- audio pipeline without waiting for a clip change.
function PlaybackEngine:_on_track_preference_changed_signal(track_id, property, _new_val, _prev_val)
    assert(type(track_id) == "string" and track_id ~= "", string.format(
        "PlaybackEngine:_on_track_preference_changed_signal: track_id must be non-empty string, got %s",
        type(track_id)))
    if property ~= "muted" and property ~= "soloed" then return end
    if not self.loaded_sequence_id then return end
    local Track = require("models.track")
    local track = Track.load(track_id)
    assert(track, string.format(
        "PlaybackEngine:_on_track_preference_changed_signal: track %s not found", track_id))
    if track.sequence_id ~= self.loaded_sequence_id then return end
    if track.track_type == "VIDEO" then
        self:_refresh_video_track_states()
        -- Re-render current frame so mute is visible immediately in park mode.
        -- During playback the next CVDisplayLink tick re-renders anyway.
        if self._tmb and not self:is_playing() then
            self:_display_frame_from_renderer(math.floor(self._position))
        end
    elseif track.track_type == "AUDIO" then
        self:_refresh_audio_mix()
        -- Mute/solo is a discrete toggle: drop the ~2.6s of already-mixed PCM
        -- queued downstream so the change is heard at the playhead, not after the
        -- stale tail drains. (Volume/pan go through track_mix_changed and must
        -- NOT flush — they'd click on every fader delta.)
        -- Skip the flush when a solo is active and only a mute toggled: solo
        -- trumps mute, so the audible output is unchanged — flushing would click
        -- for nothing. A solo toggle always changes the audible set → flush.
        if not (property == "muted" and self:_any_audio_track_soloed()) then
            self:_flush_audio_pipeline_for_mix_change()
        end
    else
        assert(false, string.format(
            "PlaybackEngine:_on_track_preference_changed_signal: unknown track_type %q for track %s",
            tostring(track.track_type), track_id))
    end
    log.event("track %s %s changed: refreshed %s playback state",
        track_id, property, track.track_type)
end

--- Handler: timeline edit touched `seq_id`. Only react when it's our
--- sequence — other sequences' edits are none of our business.
function PlaybackEngine:_on_content_changed_signal(seq_id)
    assert(type(seq_id) == "string" and seq_id ~= "", string.format(
        "PlaybackEngine:_on_content_changed_signal: seq_id must be non-empty string, got %s",
        type(seq_id)))
    if seq_id ~= self.loaded_sequence_id then return end
    self:notify_content_changed()
    log.event("Edit detected: invalidated clip windows")
end

--- Handler: media file at `path` had its bytes rewritten in place.
--- Status didn't flip (still online), so the clip list is still valid —
--- we just need TMB to drop decoder state keyed on this path.
function PlaybackEngine:_on_media_content_changed_signal(path)
    assert(type(path) == "string" and path ~= "", string.format(
        "PlaybackEngine:_on_media_content_changed_signal: path must be non-empty string, got %s",
        type(path)))
    if not self._tmb then return end
    qt_constants.EMP.TMB_INVALIDATE_PATH(self._tmb, path)
    log.event("TMB invalidated for rewritten path: %s", path)
end

--- Handler: media_status flipped for `path`. Drop every cache keyed on
--- this path (InvalidatePath) and, when returning online, also drop
--- TMB's permanent FileNotFound blacklist (ClearOffline). Then force a
--- clip rebuild so ClipInfo.offline — baked in at build time — picks
--- up the new state; without this, an offline→online flip leaves
--- clip.offline stuck at true and GetTrackAudio keeps beeping. Filter
--- by _path_is_active_in_tmb so the startup bg-probe storm doesn't
--- reload for paths we never decoded.
function PlaybackEngine:_on_media_status_changed_signal(path, status)
    assert(type(path) == "string" and path ~= "", string.format(
        "PlaybackEngine:_on_media_status_changed_signal: path must be non-empty string, got %s",
        type(path)))
    assert(type(status) == "table", string.format(
        "PlaybackEngine:_on_media_status_changed_signal: status must be table, got %s",
        type(status)))
    assert(type(status.offline) == "boolean", string.format(
        "PlaybackEngine:_on_media_status_changed_signal: status.offline must be boolean, got %s",
        type(status.offline)))
    if not self._tmb then return end
    if not self:_path_is_active_in_tmb(path) then return end
    local EMP = qt_constants.EMP
    EMP.TMB_INVALIDATE_PATH(self._tmb, path)
    if not status.offline then
        EMP.TMB_CLEAR_OFFLINE(self._tmb, path)
    end
    if self._playback_controller then
        self:_reset_clip_snapshots()
        qt_constants.PLAYBACK.RELOAD_ALL_CLIPS(self._playback_controller)
    end
    log.event("TMB reacted to status change: %s offline=%s",
        path, tostring(status.offline))
end

end -- M.install

return M
