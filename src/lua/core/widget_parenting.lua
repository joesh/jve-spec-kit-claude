-- Smart widget parenting system. NOTE: smart_add_child is a stub —
-- widget parenting is currently handled at the bindings layer; this
-- module exists for future centralization.
local error_system = require("core.error_system")
local log = require("core.logger").for_area("ui")

local M = {}

function M.debug_widget_info(widget, name)
    log.detail("widget_parenting: '%s' type=%s", name or "unknown", type(widget))
end

function M.smart_add_child(parent, child)
    log.detail("widget_parenting.smart_add_child: parent=%s child=%s",
        type(parent), type(child))
    return error_system.create_success({
        message = "Widget parenting simulated successfully"
    })
end

return M