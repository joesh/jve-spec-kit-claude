--- progress_panel: reusable progress bar + status + log area for modal dialogs
--
-- Responsibilities:
-- - Create progress bar, status label, log/results area widgets
-- - Provide update(pct, status_text, log_line) that pumps Qt events
-- - Show/hide the panel, reset between runs
--
-- Non-goals:
-- - Dialog chrome (buttons, layout) — caller owns that
-- - Business logic — caller provides the work function
--
-- Invariants:
-- - Requires qt_constants from C++
-- - update() calls PROCESS_EVENTS to keep UI responsive
--
-- @file progress_panel.lua
local M = {}

--- Create a progress panel and add its widgets to the given layout.
-- @param layout widget: parent layout to add widgets into
-- @param opts table|nil: optional {log_height=number, width=number}
-- @return table: panel handle with :update(), :show(), :hide(), :reset(), :get_log_lines()
function M.create(layout, opts)
    local qt = require("core.qt_constants")
    opts = opts or {}
    local log_height = opts.log_height or 120
    local width = opts.width or 560

    -- Progress bar
    local progress_bar = qt.WIDGET.CREATE_PROGRESS_BAR()
    qt.DISPLAY.SET_VISIBLE(progress_bar, false)
    qt.LAYOUT.ADD_WIDGET(layout, progress_bar)

    -- Status label
    local status_label = qt.WIDGET.CREATE_LABEL("")
    qt.DISPLAY.SET_VISIBLE(status_label, false)
    qt.LAYOUT.ADD_WIDGET(layout, status_label)

    -- Log/results area (read-only, scrolling)
    local log_area = qt.WIDGET.CREATE_TEXT_EDIT("")
    qt.CONTROL.SET_TEXT_EDIT_READ_ONLY(log_area, true)
    qt.DISPLAY.SET_VISIBLE(log_area, false)
    qt.PROPERTIES.SET_SIZE(log_area, width, log_height)
    qt.LAYOUT.ADD_WIDGET(layout, log_area)

    local log_lines = {}

    local panel = {}
    local cancelled = false

    --- Request cancellation. Next update() will return "cancel".
    function panel.cancel()
        cancelled = true
    end

    --- Check if cancellation was requested.
    function panel.is_cancelled()
        return cancelled
    end

    --- Update progress. Pumps Qt events to keep UI responsive.
    -- @return "cancel" if cancellation was requested, nil otherwise
    -- @param pct number: 0-100 progress percentage
    -- @param text string|nil: status text (e.g. "Processing 42 of 100")
    -- @param log_line string|nil: append a line to the log/results area
    local log_dirty = false
    local last_pump_time = 0
    local PUMP_INTERVAL_S = 0.05  -- 50ms — responsive without excessive overhead
    -- Only show last N log lines in the widget to avoid O(n) render on large logs
    local MAX_DISPLAY_LINES = 500

    function panel.update(pct, text, log_line)
        if log_line then
            log_lines[#log_lines + 1] = log_line
            log_dirty = true
        end
        -- Throttle by wall-clock time: pump Qt events every 50ms.
        -- Works for both high-frequency (120K clips) and low-frequency (parse milestones).
        local now = os.clock()
        if now - last_pump_time >= PUMP_INTERVAL_S then
            last_pump_time = now
            qt.CONTROL.SET_PROGRESS_BAR_VALUE(progress_bar, pct or 0)
            if text then qt.PROPERTIES.SET_TEXT(status_label, text) end
            if log_dirty then
                qt.DISPLAY.SET_VISIBLE(log_area, true)
                local start = math.max(1, #log_lines - MAX_DISPLAY_LINES + 1)
                local display = {}
                for i = start, #log_lines do
                    display[#display + 1] = log_lines[i]
                end
                qt.PROPERTIES.SET_TEXT(log_area, table.concat(display, "\n"))
                log_dirty = false
            end
            qt.CONTROL.PROCESS_EVENTS()
            if cancelled then return "cancel" end
        end
        if cancelled then return "cancel" end
    end

    --- Flush any pending log lines to the widget.
    function panel.flush()
        -- Final update: progress bar, status, and log
        qt.CONTROL.SET_PROGRESS_BAR_VALUE(progress_bar, 100)
        -- Only reveal the log area if lines were actually appended. A flow that
        -- reports progress via status text only (e.g. media relink) appends no
        -- log lines, so revealing the widget just parks an empty box — the
        -- relink dialog's blank gap. The prior `or true` force-showed it.
        if log_dirty then
            qt.DISPLAY.SET_VISIBLE(log_area, true)
            local start = math.max(1, #log_lines - MAX_DISPLAY_LINES + 1)
            local display = {}
            for i = start, #log_lines do
                display[#display + 1] = log_lines[i]
            end
            qt.PROPERTIES.SET_TEXT(log_area, table.concat(display, "\n"))
            log_dirty = false
        end
        qt.CONTROL.PROCESS_EVENTS()
    end

    --- Show the progress panel (progress bar + status label).
    function panel.show()
        qt.DISPLAY.SET_VISIBLE(progress_bar, true)
        qt.DISPLAY.SET_VISIBLE(status_label, true)
    end

    --- Hide the progress panel.
    function panel.hide()
        qt.DISPLAY.SET_VISIBLE(progress_bar, false)
        qt.DISPLAY.SET_VISIBLE(status_label, false)
    end

    --- Reset state for a new run.
    function panel.reset()
        log_lines = {}
        cancelled = false
        qt.CONTROL.SET_PROGRESS_BAR_VALUE(progress_bar, 0)
        qt.PROPERTIES.SET_TEXT(status_label, "")
        qt.PROPERTIES.SET_TEXT(log_area, "")
        qt.DISPLAY.SET_VISIBLE(log_area, false)
    end

    --- Get accumulated log lines.
    function panel.get_log_lines()
        return log_lines
    end

    return panel
end

return M
