--- grade_badge — pure mapping from a clip's grade `reproduction` state to
--- its FR-015 badge (text, short label, colour, visibility).
---
--- The sequence-monitor overlay and the timeline clip indicator render the
--- SAME meaning, so the presentation lives here once. A grade JVE can fully
--- reproduce ('full') — and an ungraded clip (nil) — carry NO badge: the
--- viewer already shows the truth. Only ONE state carries a badge:
---   not_shown   — JVE shows passthrough (an identity bake — a spatial grade
---                 like a power window — or no carrier).
--- 'approximate' (a non-identity baked LUT — the look is mostly there, missing
--- only windows/qualifiers) is NOT flagged: it sits on nearly every clip in a
--- real project (1016/1043 on Anamnesis), so a badge there is noise, not
--- signal (Joe 2026-06-19). The reproduction VALUE is still recorded; it just
--- earns no visible flag.
---
--- Colour is a hex string so both consumers share one format: the timeline
--- renderer's `timeline.add_rect`/`color_utils.dim_hex` take hex, and a Qt
--- stylesheet accepts `#RRGGBB` directly.

local ui_constants = require("core.ui_constants")
local M = {}

-- Red-orange = "not shown at all" — the one flagged state.
local RED_ORANGE = ui_constants.COLORS.GRADE_BADGE_RED_ORANGE

-- `text` is a full, plain-language sentence (no codes/abbreviations) — it
-- reads as the monitor caption AND the timeline hover tooltip. Phrased for an
-- editor who has never read a manual: what they're seeing, and where the real
-- look lives.
local BADGES = {
    full = { visible = false },
    -- 'approximate' is recorded but never flagged — see header. The look is
    -- mostly right and it covers nearly every clip, so a badge is noise.
    approximate = { visible = false },
    not_shown = {
        visible   = true,
        text      = "Ungraded here — this shot is graded in Resolve only",
        color_hex = RED_ORANGE,
    },
}

--- Badge descriptor for a clip's reproduction state.
--- @param reproduction string|nil  'full'|'approximate'|'not_shown', or nil
---                     (ungraded clip — no grade row).
--- @return table  { visible=bool, text?, short?, color_hex? }. When not
---                visible only `visible=false` is set (check it first).
function M.for_reproduction(reproduction)
    if reproduction == nil then
        return { visible = false }
    end
    local badge = BADGES[reproduction]
    assert(badge, string.format(
        "grade_badge.for_reproduction: unknown reproduction %q "
        .. "(expected 'full'|'approximate'|'not_shown' or nil)",
        tostring(reproduction)))
    return badge
end

-- Hover tooltip is a SEPARATE affordance from the always-on stripe: the stripe
-- only flags `not_shown` (the one state worth an at-a-glance warning), but a
-- deliberate hover is never noise, so it describes EVERY graded clip — incl.
-- the 'approximate' look that earns no stripe. Ungraded clips (nil) get no
-- tooltip (nothing to say).
local TOOLTIPS = {
    full        = "Graded — JVE shows the full Resolve look.",
    approximate = "Graded — JVE shows the colour; power windows and "
                .. "qualifiers render in Resolve only.",
    not_shown   = "Ungraded here — this shot is graded in Resolve only.",
}

--- Plain-language hover tooltip for a clip's reproduction state.
--- @param reproduction string|nil  'full'|'approximate'|'not_shown', or nil.
--- @return string|nil  the sentence, or nil for an ungraded clip.
function M.tooltip_for_reproduction(reproduction)
    if reproduction == nil then
        return nil
    end
    local tip = TOOLTIPS[reproduction]
    assert(tip, string.format(
        "grade_badge.tooltip_for_reproduction: unknown reproduction %q "
        .. "(expected 'full'|'approximate'|'not_shown' or nil)",
        tostring(reproduction)))
    return tip
end

return M

