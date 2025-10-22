-- Timeline Renderer - Lua-controlled timeline graphics
-- This demonstrates the drawing command API where Lua defines timeline appearance

local TimelineRenderer = {}
local ui_constants = require("core.ui_constants")
local timeline_state = require("ui.timeline.timeline_state")

-- Configuration constants
local RULER_HEIGHT = ui_constants.TIMELINE.RULER_HEIGHT
local TRACK_HEIGHT = ui_constants.TIMELINE.TRACK_HEIGHT
local TRACK_HEADER_WIDTH = ui_constants.TIMELINE.TRACK_HEADER_WIDTH
local PLAYHEAD_COLOR = timeline_state.colors.playhead
local RULER_COLOR = "#444444"
local TRACK_COLOR = "#333333"
local TEXT_COLOR = timeline_state.colors.text
local CLIP_COLOR = timeline_state.colors.clip
local CLIP_BORDER_COLOR = "#6bb6ff"
local SELECTED_CLIP_COLOR = timeline_state.colors.clip_selected

function TimelineRenderer.new(timeline_widget)
    local self = {
        timeline = timeline_widget,
        playhead_time = 0,
        zoom_level = 1.0,
        tracks = {"Video 1", "Audio 1", "Audio 2"}
    }
    setmetatable(self, {__index = TimelineRenderer})
    return self
end

function TimelineRenderer:set_playhead_time(time)
    self.playhead_time = time
end

function TimelineRenderer:set_zoom_level(zoom)
    self.zoom_level = zoom
end

function TimelineRenderer:time_to_pixel(time_seconds)
    local pixels_per_second = 100 * self.zoom_level
    return TRACK_HEADER_WIDTH + (time_seconds * pixels_per_second)
end

function TimelineRenderer:pixel_to_time(pixel_x)
    local pixels_per_second = 100 * self.zoom_level
    return (pixel_x - TRACK_HEADER_WIDTH) / pixels_per_second
end

function TimelineRenderer:draw_ruler(width)
    -- Draw ruler background
    timeline_add_rect(self.timeline, 0, 0, width, RULER_HEIGHT, RULER_COLOR)
    
    -- Draw time markers
    local seconds_per_marker = 1
    local start_time = 0
    local end_time = (width - TRACK_HEADER_WIDTH) / (100 * self.zoom_level)
    
    for time = start_time, end_time, seconds_per_marker do
        local x = self:time_to_pixel(time)
        if x < width then
            -- Draw marker line
            timeline_add_line(self.timeline, x, 20, x, RULER_HEIGHT, TEXT_COLOR, 1)
            -- Draw time label
            timeline_add_text(self.timeline, x + 2, 15, string.format("%.1fs", time), TEXT_COLOR)
        end
    end
end

function TimelineRenderer:draw_track_headers(height)
    for i, track_name in ipairs(self.tracks) do
        local y = RULER_HEIGHT + (i - 1) * TRACK_HEIGHT
        
        -- Draw track header background
        timeline_add_rect(self.timeline, 0, y, TRACK_HEADER_WIDTH, TRACK_HEIGHT, TRACK_COLOR)
        
        -- Draw track border
        timeline_add_line(self.timeline, 0, y, TRACK_HEADER_WIDTH, y, TEXT_COLOR, 1)
        
        -- Draw track label
        timeline_add_text(self.timeline, 10, y + 25, track_name, TEXT_COLOR)
    end
end

function TimelineRenderer:draw_tracks(width, height)
    for i = 1, #self.tracks do
        local y = RULER_HEIGHT + (i - 1) * TRACK_HEIGHT
        
        -- Draw track background
        local track_bg_color = (i % 2 == 0) and "#2a2a2a" or "#252525"
        timeline_add_rect(self.timeline, TRACK_HEADER_WIDTH, y, width - TRACK_HEADER_WIDTH, TRACK_HEIGHT, track_bg_color)
        
        -- Draw track border
        timeline_add_line(self.timeline, TRACK_HEADER_WIDTH, y, width, y, "#444444", 1)
    end
end

function TimelineRenderer:draw_clips(instances, selection)
    if not instances then return end
    
    -- Track name to index mapping
    local track_indices = {}
    for i, track in ipairs(self.tracks) do
        track_indices[track] = i
    end
    
    -- Draw clips for each instance
    for instance_id, instance in pairs(instances) do
        if instance.track_id and instance.timeline_in and instance.timeline_out then
            -- Find track index
            local track_index = track_indices[instance.track_id] or track_indices["Video 1"]
            if track_index then
                local y = RULER_HEIGHT + (track_index - 1) * TRACK_HEIGHT + 5
                local x1 = self:time_to_pixel(instance.timeline_in)
                local x2 = self:time_to_pixel(instance.timeline_out)
                local clip_width = x2 - x1
                local clip_height = TRACK_HEIGHT - 10
                
                -- Choose color based on selection
                local clip_color = CLIP_COLOR
                if selection and selection.instances then
                    for _, selected_id in ipairs(selection.instances) do
                        if selected_id == instance_id then
                            clip_color = SELECTED_CLIP_COLOR
                            break
                        end
                    end
                end
                
                -- Draw clip rectangle
                timeline_add_rect(self.timeline, x1, y, clip_width, clip_height, clip_color)
                
                -- Draw clip border
                timeline_add_line(self.timeline, x1, y, x1 + clip_width, y, CLIP_BORDER_COLOR, 1) -- top
                timeline_add_line(self.timeline, x1, y + clip_height, x1 + clip_width, y + clip_height, CLIP_BORDER_COLOR, 1) -- bottom
                timeline_add_line(self.timeline, x1, y, x1, y + clip_height, CLIP_BORDER_COLOR, 1) -- left
                timeline_add_line(self.timeline, x1 + clip_width, y, x1 + clip_width, y + clip_height, CLIP_BORDER_COLOR, 1) -- right
                
                -- Draw clip label
                if clip_width > 50 then -- Only show label if clip is wide enough
                    local label = instance.clip_id or "Clip"
                    timeline_add_text(self.timeline, x1 + 5, y + 15, label, TEXT_COLOR)
                end
            end
        end
    end
end

function TimelineRenderer:draw_playhead(height)
    local x = self:time_to_pixel(self.playhead_time)
    
    -- Draw playhead line
    timeline_add_line(self.timeline, x, 0, x, height, PLAYHEAD_COLOR, 2)
    
    -- Draw playhead handle (triangle)
    -- For now, just draw a small rect at the top
    timeline_add_rect(self.timeline, x - 5, 0, 10, 10, PLAYHEAD_COLOR)
end

function TimelineRenderer:render(width, height)
    -- Clear previous drawing commands
    timeline_clear_commands(self.timeline)
    
    -- Draw timeline components in order
    self:draw_ruler(width)
    self:draw_track_headers(height)
    self:draw_tracks(width, height)
    self:draw_playhead(height)
    
    -- Trigger repaint
    timeline_update(self.timeline)
end

return TimelineRenderer