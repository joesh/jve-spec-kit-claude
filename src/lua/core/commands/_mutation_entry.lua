--- Shared helper: build an insert/placement entry for a __timeline_mutations
--- bucket by re-reading the DB row of `clip_id`. The bucket consumer
--- (TimelineTab.apply_mutations → apply_inserts → normalize_clip_integers)
--- requires the full canonical clip-row shape; an `{id=...}` stub causes a
--- producer-bug assert (pre-audit-pass-5 silent-skipped, leaving the cache
--- stale relative to the DB until the next reload).
---
--- Use Clip.load (not load_v13_row) so the entry carries the joined
--- frame_rate from the nested sequence row — consumers that read
--- clip.frame_rate (batch_ripple_edit.fetch_base_clip,
--- clipboard_actions.copy_mark_range) require it.

local database = require("core.database")

local M = {}

--- Build the timeline-cache insert entry for a clip that is already in the
--- DB (callers report post-apply). Returns the canonical cache-clip shape —
--- the SAME builder db.load_clips uses — so a re-inserted clip is identical
--- to a freshly-loaded one (carries media_path/offline/label/etc.). Hand-
--- projecting a field subset here drifts: it was the root of the "undo
--- cleared offline" bug and a latent missing-label bug.
--- @param clip_id string
--- @param command_label string label embedded in the assert error message
--- @return table mutation-bucket entry
function M.build_insert_entry(clip_id, command_label)
    local clip = database.load_clip_entry(clip_id)
    assert(clip, string.format(
        "%s: could not re-read clip %s for insert mutation entry",
        tostring(command_label), tostring(clip_id)))
    return clip
end

return M
