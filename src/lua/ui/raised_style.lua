--- raised_style: subtle 3D "keycap" styling for dialog surfaces.
--
-- Two ingredients make a flat Qt widget read as raised, matching the
-- Claude-design keycap mockup:
--   1. A top-lighter → bottom-darker vertical gradient (qlineargradient) with
--      rounded corners and a thin rim border — pure QSS, applied via SET_STYLE.
--   2. A soft outer drop shadow — Qt QSS has no box-shadow, so this needs
--      QGraphicsDropShadowEffect via PROPERTIES.SET_DROP_SHADOW (one effect per
--      widget; re-applying replaces it).
--
-- All visual constants live at the top so they are easy to tune. The numbers
-- here are a first cut; expect to dial them in visually.
--
-- @file raised_style.lua
local ui_constants = require("core.ui_constants")
local M = {}

-- Palette / geometry — tweak these. Colors are dark-theme keycaps.
M.PANEL_TOP     = ui_constants.COLORS.RAISED_PANEL_TOP     -- gradient top (lit)
M.PANEL_BOTTOM  = ui_constants.COLORS.RAISED_PANEL_BOTTOM  -- gradient bottom (shadowed)
M.PANEL_BORDER  = ui_constants.COLORS.RAISED_PANEL_BORDER  -- thin rim
M.PANEL_RADIUS  = 8

M.BUTTON_TOP        = ui_constants.COLORS.RAISED_BUTTON_TOP
M.BUTTON_BOTTOM     = ui_constants.COLORS.RAISED_BUTTON_BOTTOM
M.BUTTON_TOP_HOVER  = ui_constants.COLORS.RAISED_BUTTON_TOP_HOVER
M.BUTTON_BOT_HOVER  = ui_constants.COLORS.RAISED_BUTTON_BOT_HOVER
M.BUTTON_TOP_DOWN   = ui_constants.COLORS.RAISED_BUTTON_TOP_DOWN  -- pressed: invert (darker top)
M.BUTTON_BOT_DOWN   = ui_constants.COLORS.RAISED_BUTTON_BOT_DOWN
M.BUTTON_BORDER     = ui_constants.COLORS.RAISED_BUTTON_BORDER
M.BUTTON_TEXT       = ui_constants.COLORS.RAISED_BUTTON_TEXT  -- amber, like the mockup labels
M.BUTTON_RADIUS     = 7

-- Shadow — soft, mostly-down, low alpha.
M.SHADOW_BLUR   = 16
M.SHADOW_DX     = 0
M.SHADOW_DY     = 3
M.SHADOW_COLOR  = ui_constants.COLORS.RAISED_SHADOW  -- #aarrggbb: 50% black

local function vgrad(top, bottom)
    return string.format(
        "qlineargradient(x1:0, y1:0, x2:0, y2:1, stop:0 %s, stop:1 %s)",
        top, bottom)
end

--- QSS for a raised card surface (a panel/container or read-only text area).
-- @return string stylesheet
function M.panel_qss()
    return string.format(
        "background: %s; border: 1px solid %s; border-radius: %dpx; padding: 8px;",
        vgrad(M.PANEL_TOP, M.PANEL_BOTTOM), M.PANEL_BORDER, M.PANEL_RADIUS)
end

--- QSS for a raised keycap button, with hover and pressed states.
-- @return string stylesheet
function M.button_qss()
    return string.format(
        "QPushButton {"
        .. " background: %s; border: 1px solid %s; border-radius: %dpx;"
        .. " color: %s; padding: 6px 16px; font-weight: bold; }"
        .. "QPushButton:hover { background: %s; }"
        .. "QPushButton:pressed { background: %s; }"
        .. "QPushButton:disabled { color: " .. ui_constants.COLORS.RAISED_BUTTON_TEXT_DISABLED .. "; }",
        vgrad(M.BUTTON_TOP, M.BUTTON_BOTTOM), M.BUTTON_BORDER, M.BUTTON_RADIUS,
        M.BUTTON_TEXT,
        vgrad(M.BUTTON_TOP_HOVER, M.BUTTON_BOT_HOVER),
        vgrad(M.BUTTON_TOP_DOWN, M.BUTTON_BOT_DOWN))
end

--- Apply the soft outer shadow to a widget (the part QSS can't do).
-- @param widget userdata Qt widget
function M.apply_shadow(widget)
    local qt = require("core.qt_constants")
    qt.PROPERTIES.SET_DROP_SHADOW(widget, M.SHADOW_BLUR, M.SHADOW_DX, M.SHADOW_DY, M.SHADOW_COLOR)
end

--- Style a widget as a raised card (gradient panel + shadow).
-- @param widget userdata Qt widget
function M.apply_panel(widget)
    local qt = require("core.qt_constants")
    qt.PROPERTIES.SET_STYLE(widget, M.panel_qss())
    M.apply_shadow(widget)
end

--- Style a button as a raised keycap (gradient + states + shadow).
-- @param widget userdata Qt push button
function M.apply_button(widget)
    local qt = require("core.qt_constants")
    qt.PROPERTIES.SET_STYLE(widget, M.button_qss())
    M.apply_shadow(widget)
end

return M
