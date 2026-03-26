--- View: base class for navigable views.
--
-- Subclasses implement navigate_to_clip() and get_clips().
-- The active view is queried via focus_manager.get_active_view(),
-- so the Find dialog calls view:navigate_to_clip(clip_id) without
-- knowing which view it is.
--
-- @file view.lua

local View = {}
View.__index = View

function View.new(view_id)
    assert(view_id and view_id ~= "", "View.new: view_id required")
    local self = setmetatable({}, View)
    self.view_id = view_id
    return self
end

--- Navigate to a clip by ID. Subclass must implement.
function View:navigate_to_clip(_clip_id)
    assert(false, "View:navigate_to_clip must be implemented by " .. self.view_id)
end

--- Select multiple clips by ID. Subclass must implement.
function View:select_clips(_clip_ids)
    assert(false, "View:select_clips must be implemented by " .. self.view_id)
end

--- Get all navigable clips. Subclass must implement.
-- Returns array of clip_data tables suitable for query_engine.
function View:get_clips()
    assert(false, "View:get_clips must be implemented by " .. self.view_id)
end

return View
