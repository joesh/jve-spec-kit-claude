--- view_grade_pull — MVC pull rule for the per-clip display grade (T032).
---
--- The viewer (SequenceMonitor, SourceViewer) calls this on every frame
--- show. Given a clip_id, it returns either a CDL params table to apply
--- in the surface's CDL stage, or nil meaning "passthrough" (the surface
--- shows the ungraded image).
---
--- Rule (FR-016 / data-model.md):
---   • clip.id with a `clip_grade` row of fidelity == 'primary' AND a
---     non-nil CDL  → return the CDL table.
---   • fidelity == 'partial' or 'unrepresentable'                   → nil
---     The grade exceeds CDL/LUT — applying a fragment of it would be
---     dishonest (FR-015 — "never approximated").
---   • No `clip_grade` row                                          → nil
---   • stale=1 PRIMARY still applies (FR-013a — "retained, marked stale,
---     never silently cleared"). The fidelity badge UX (spec §5.5)
---     communicates staleness to the user; display keeps the last-known
---     graded look.
---
--- Pure pull: takes a clip_id + open DB connection, returns or nils.
--- No side effects, no caching here — caching by clip_id is the View's
--- concern (it knows when the clip at the playhead changes).
---
--- The DB connection is supplied by the caller so this module stays
--- inside the SQL-isolation policy (commands and pull helpers receive
--- their connection from the caller; they never reach `database.get_connection()`).

local ClipGrade = require("models.clip_grade")

local M = {}

--- Pull the display CDL for a clip, or nil if no graded display.
--- @param clip_id string|nil   clip id (nil/empty ⇒ no clip, returns nil)
--- @param db      table|nil    optional open SQLite connection; when nil
---                              the model layer grabs the active connection
---                              (the model layer is the only place allowed
---                              to call `database.get_connection()` under
---                              the SQL-isolation policy).
--- @return table|nil  the CDL params table, or nil for passthrough
function M.pull_for_clip(clip_id, db)
    if clip_id == nil or clip_id == "" then return nil end
    assert(type(clip_id) == "string",
        string.format("view_grade_pull.pull_for_clip: clip_id must be string, got %s",
            type(clip_id)))

    local grade = ClipGrade.load(clip_id, db)
    if not grade then return nil end
    if grade.fidelity ~= "primary" then return nil end
    if not grade.cdl then
        -- Defensive: a 'primary' row should always have a complete CDL
        -- (the model's all-or-none invariant). If both hold, this branch
        -- is unreachable; if we ever reach it, the schema invariant is
        -- broken and the caller should know.
        error(string.format(
            "view_grade_pull.pull_for_clip: clip %s has fidelity='primary' "
            .. "but no CDL row — model invariant violated", clip_id))
    end
    return grade.cdl
end

return M
