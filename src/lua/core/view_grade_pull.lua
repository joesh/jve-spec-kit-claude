--- view_grade_pull — MVC pull rule for the per-clip display grade
--- (T032 CDL + Piece 3 LUT).
---
--- The viewer (SequenceMonitor, SourceViewer) calls this on every frame
--- show. Given a clip_id, it returns either a stage table `{cdl,
--- lut_ref}` (one or both fields set) describing what to push to the
--- surface, or nil meaning "passthrough" (surface shows the ungraded
--- image).
---
--- Rule (FR-014 / FR-015 / FR-016 / data-model.md):
---
---   • primary + CDL                  → return {cdl = ...}
---     The full grade fits CDL. Display it directly.
---
---   • primary + CDL + LUT (rare)     → return {cdl = ..., lut_ref = ...}
---     User had an item-LUT bound to a primary-only graph.
---     FR-016: "apply CDL, then LUT if present" — the surface stacks
---     them in series; either stage is a no-op when its flag is 0.
---
---   • partial + lut_ref              → return {lut_ref = ...}
---     The bake captured primaries + curves + CST/ACES nodes; secondary
---     tools (qualifiers, windows, blurs) dropped. Honest partial
---     approximation (FR-015 — the badge UX flags it).
---
---   • unrepresentable + lut_ref      → return {lut_ref = ...}
---     The bake still preserves what CDL+LUT can carry; even more of
---     the graph is silently dropped than `partial`. Same display
---     route, distinct badge.
---
---   • partial / unrepresentable without lut_ref → return nil
---     Bake should always produce one when fidelity is partial/
---     unrepresentable (helper-protocol.md §read_grades). Reaching
---     here means the bake failed and the helper surfaced the row
---     anyway. Caller sees ungraded; the fidelity badge still tells
---     the user the grade exists but couldn't load.
---
---   • fidelity == 'none' OR no row   → return nil
---     Ungraded clip — pass through.
---
---   • stale = 1 PRIMARY still applies (FR-013a — "retained, marked
---     stale, never silently cleared"). Badge UX communicates the
---     staleness.
---
--- Pure pull: takes a clip_id + open DB connection, returns or nils.
--- No caching here AND none in the View either (per FR-016: the View
--- pulls every show-frame; see SequenceMonitor._apply_clip_grade and
--- the rationale captured in commit a480c891 — a clip-id-keyed View
--- cache hid SyncGradesFromResolve mutations because the key didn't
--- change when the underlying row did). Per-frame indexed SELECT is
--- intentional; decode cost dwarfs it. If a profile ever shows it,
--- the correct optimization is a cache invalidated on the wired
--- `grades_changed` signal — not a key-only cache.
---
--- The DB connection is supplied by the caller so this module stays
--- inside the SQL-isolation policy (commands and pull helpers receive
--- their connection from the caller; they never reach `database.get_connection()`).

local ClipGrade = require("models.clip_grade")

local M = {}

--- Pull the display grade stages for a clip.
--- @param clip_id string         clip id — must be a non-empty string. The
---                                gap/no-active-clip case is the view layer's
---                                responsibility: when there's no clip on the
---                                show-frame metadata or the renderer is in
---                                gap state, callers MUST clear the grade
---                                stages on the surface directly rather than
---                                routing nil through this function (rule
---                                2.13: no silent-nil swallow at the model
---                                layer; render policy belongs in the view).
--- @param db      table|nil      optional open SQLite connection; when nil
---                                the model layer grabs the active connection
---                                (the model layer is the only place allowed
---                                to call `database.get_connection()` under
---                                the SQL-isolation policy).
--- @return table|nil  stage table `{cdl?, lut_ref?}`, or nil when this clip
---                    has no grade row at all (a real model answer, not a
---                    swallow of bad input).
function M.pull_for_clip(clip_id, db)
    assert(type(clip_id) == "string" and clip_id ~= "", string.format(
        "view_grade_pull.pull_for_clip: clip_id must be a non-empty "
        .. "string (got %s) — gap/no-clip frames must clear grade at the "
        .. "render path, not call pull_for_clip(nil)", type(clip_id)))

    local grade = ClipGrade.load(clip_id, db)
    if not grade then return nil end

    if grade.fidelity == "primary" then
        if not grade.cdl then
            -- A 'primary' row must always have a complete CDL (the
            -- model's all-or-none invariant). Unreachable if invariant
            -- holds; if reached, schema invariant is broken.
            error(string.format(
                "view_grade_pull.pull_for_clip: clip %s has "
                .. "fidelity='primary' but no CDL row — model invariant "
                .. "violated", clip_id))
        end
        -- LUT may co-exist with primary CDL when the user had an
        -- item-level LUT bound; FR-016 stacks them: CDL then LUT.
        return { cdl = grade.cdl, lut_ref = grade.lut_ref }
    end

    if grade.fidelity == "partial" or grade.fidelity == "unrepresentable" then
        -- Honest partial approximation via the baked LUT (FR-015).
        -- A missing lut_ref means the bake failed; surface as
        -- passthrough (the fidelity badge still tells the user the
        -- grade exists but couldn't load).
        if grade.lut_ref then
            return { lut_ref = grade.lut_ref }
        end
        return nil
    end

    -- fidelity == 'none' (or unknown enum value the schema CHECK would
    -- have rejected): pass through.
    return nil
end

return M
