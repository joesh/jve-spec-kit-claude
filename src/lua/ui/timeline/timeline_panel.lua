-- Timeline Panel - Multi-view timeline architecture
-- Assembles ruler, video view, audio view, and scrollbar

local timeline_state = require("ui.timeline.timeline_state")
local timeline_view = require("ui.timeline.timeline_view")
local timeline_ruler = require("ui.timeline.timeline_ruler")
local timeline_scrollbar = require("ui.timeline.timeline_scrollbar")

local M = {}

-- Store references
local state = nil
local inspector_view = nil

function M.set_inspector(view)
    inspector_view = view
end

function M.set_project_browser(browser)
    if state then
        state.set_project_browser(browser)
    end
end

-- Helper function to create video headers with splitters
local function create_video_headers()
    local video_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")
    local video_tracks = state.get_video_tracks()

    print("DEBUG: Video tracks from state:")
    for i, track in ipairs(video_tracks) do
        print(string.format("  video_tracks[%d] = %s (id=%s)", i, track.name, track.id))
    end

    -- Add stretchable spacer at TOP (far from anchor) so video tracks anchor to bottom
    local top_spacer = qt_constants.WIDGET.CREATE()
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(top_spacer, "Expanding", "Expanding")
    qt_constants.LAYOUT.ADD_WIDGET(video_splitter, top_spacer)

    local video_headers = {}
    local current_track = nil
    local handler_name = "video_splitter_event_" .. tostring(video_splitter):gsub("[^%w]", "_")

    -- Add tracks in REVERSE order so V1 is at bottom (nearest anchor)
    for i = #video_tracks, 1, -1 do
        local track = video_tracks[i]
        local header = qt_constants.WIDGET.CREATE_LABEL(track.name)
        qt_constants.PROPERTIES.SET_STYLE(header, [[
            QLabel {
                background: #3a3a5a;
                color: #cccccc;
                padding-left: 10px;
                border: 1px solid #222222;
            }
        ]])
        qt_constants.PROPERTIES.SET_MIN_WIDTH(header, timeline_state.dimensions.track_header_width)
        qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(header, "Fixed", "Expanding")
        qt_constants.PROPERTIES.SET_MIN_HEIGHT(header, timeline_state.dimensions.track_height)
        qt_constants.PROPERTIES.SET_MAX_HEIGHT(header, timeline_state.dimensions.track_height)

        qt_constants.LAYOUT.ADD_WIDGET(video_splitter, header)
        video_headers[i] = header
    end

    -- NOW install all event handlers AFTER all widgets have been added
    -- Video splitter layout (top to bottom): spacer, V3, V2, V1
    -- Handle 0: between spacer and V3 → controls V3
    -- Handle 1: between V3 and V2 → controls V2
    -- Handle 2: between V2 and V1 → controls V1
    for handle_index = 0, #video_tracks - 1 do
        local handle = qt_get_splitter_handle(video_splitter, handle_index)
        print(string.format("DEBUG: Video handle %d = %s", handle_index, tostring(handle)))
        if handle then
            local track_num = #video_tracks - handle_index  -- handle 0→V3, handle 1→V2, handle 2→V1
            local captured_handle_index = handle_index  -- Capture by value, not reference
            local this_handler_name = handler_name .. "_handle_" .. handle_index
            _G[this_handler_name] = function(event_type, y)
                if event_type == "press" then
                    current_track = track_num
                    print(string.format("Video handle_index=%d track_num=%d press: unlocking V%d", captured_handle_index, track_num, track_num))
                    qt_constants.PROPERTIES.SET_MIN_HEIGHT(video_headers[track_num], 0)
                    qt_constants.PROPERTIES.SET_MAX_HEIGHT(video_headers[track_num], 16777215)
                elseif event_type == "release" and current_track then
                    local sizes = qt_constants.LAYOUT.GET_SPLITTER_SIZES(video_splitter)
                    local size_index = #video_tracks - track_num + 2
                    local new_height = sizes[size_index]
                    print(string.format("Video handle_index=%d track_num=%d release: locking V%d at %dpx", captured_handle_index, track_num, track_num, new_height))
                    qt_constants.PROPERTIES.SET_MIN_HEIGHT(video_headers[track_num], new_height)
                    qt_constants.PROPERTIES.SET_MAX_HEIGHT(video_headers[track_num], new_height)
                    current_track = nil
                end
            end
            qt_set_widget_click_handler(handle, this_handler_name)
        end
    end

    -- Set initial sizes: spacer gets 100px (for testing handle visibility), tracks get their natural height
    local initial_sizes = {100}  -- Spacer at start (increased from 1 to make handle 0 clickable)
    for i = 1, #video_tracks do
        table.insert(initial_sizes, timeline_state.dimensions.track_height)
    end
    qt_constants.LAYOUT.SET_SPLITTER_SIZES(video_splitter, initial_sizes)

    -- Set stretch factors: ONLY spacer stretches, all tracks stay fixed during main boundary drag
    qt_constants.LAYOUT.SET_SPLITTER_STRETCH_FACTOR(video_splitter, 0, 1)  -- Spacer stretches
    for i = 1, #video_tracks do
        qt_constants.LAYOUT.SET_SPLITTER_STRETCH_FACTOR(video_splitter, i, 0)  -- All tracks: no stretch
    end

    return video_splitter, video_headers
end

-- Helper function to create audio headers with splitters
local function create_audio_headers()
    local audio_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")
    local audio_tracks = state.get_audio_tracks()

    local audio_headers = {}
    local current_track = nil
    local handler_name = "audio_splitter_event_" .. tostring(audio_splitter):gsub("[^%w]", "_")

    for i, track in ipairs(audio_tracks) do
        local header = qt_constants.WIDGET.CREATE_LABEL(track.name)
        qt_constants.PROPERTIES.SET_STYLE(header, [[
            QLabel {
                background: #3a4a3a;
                color: #cccccc;
                padding-left: 10px;
                border: 1px solid #222222;
            }
        ]])
        qt_constants.PROPERTIES.SET_MIN_WIDTH(header, timeline_state.dimensions.track_header_width)
        qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(header, "Fixed", "Expanding")
        qt_constants.PROPERTIES.SET_MIN_HEIGHT(header, timeline_state.dimensions.track_height)
        qt_constants.PROPERTIES.SET_MAX_HEIGHT(header, timeline_state.dimensions.track_height)

        qt_constants.LAYOUT.ADD_WIDGET(audio_splitter, header)
        audio_headers[i] = header
    end

    -- Add stretchable spacer at bottom so audio tracks anchor to top
    local bottom_spacer = qt_constants.WIDGET.CREATE()
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(bottom_spacer, "Expanding", "Expanding")
    qt_constants.LAYOUT.ADD_WIDGET(audio_splitter, bottom_spacer)

    -- NOW install all event handlers AFTER all widgets have been added
    -- Audio layout: A1(0), A2(1), A3(2), spacer(3)
    -- handle 0: between A1 and A2 -> controls A1
    -- handle 1: between A2 and A3 -> controls A2
    -- handle 2: between A3 and spacer -> controls A3
    for handle_index = 0, #audio_tracks - 1 do
        local handle = qt_get_splitter_handle(audio_splitter, handle_index)
        print(string.format("DEBUG: Audio handle %d = %s", handle_index, tostring(handle)))
        if handle then
            local track_num = handle_index + 1  -- handle 0 -> A1, handle 1 -> A2, etc.
            local captured_handle_index = handle_index  -- Capture by value, not reference
            local this_handler_name = handler_name .. "_handle_" .. handle_index
            _G[this_handler_name] = function(event_type, y)
                if event_type == "press" then
                    current_track = track_num
                    print(string.format("Audio handle_index=%d track_num=%d press: unlocking A%d", captured_handle_index, track_num, track_num))
                    qt_constants.PROPERTIES.SET_MIN_HEIGHT(audio_headers[track_num], 0)
                    qt_constants.PROPERTIES.SET_MAX_HEIGHT(audio_headers[track_num], 16777215)
                elseif event_type == "release" and current_track then
                    local sizes = qt_constants.LAYOUT.GET_SPLITTER_SIZES(audio_splitter)
                    local new_height = sizes[track_num]
                    print(string.format("Audio handle_index=%d track_num=%d release: locking A%d at %dpx", captured_handle_index, track_num, track_num, new_height))
                    qt_constants.PROPERTIES.SET_MIN_HEIGHT(audio_headers[track_num], new_height)
                    qt_constants.PROPERTIES.SET_MAX_HEIGHT(audio_headers[track_num], new_height)
                    current_track = nil
                end
            end
            qt_set_widget_click_handler(handle, this_handler_name)
        end
    end

    -- Set initial sizes: tracks get their natural height, spacer gets 100px (for testing handle visibility)
    local initial_sizes = {}
    for i = 1, #audio_tracks do
        table.insert(initial_sizes, timeline_state.dimensions.track_height)
    end
    table.insert(initial_sizes, 100)  -- Spacer starts at 100px (increased from 1 to make handle 2 clickable)
    qt_constants.LAYOUT.SET_SPLITTER_SIZES(audio_splitter, initial_sizes)

    -- Set stretch factors: ONLY spacer stretches, all tracks stay fixed during main boundary drag
    for i = 0, #audio_tracks - 1 do
        qt_constants.LAYOUT.SET_SPLITTER_STRETCH_FACTOR(audio_splitter, i, 0)  -- All tracks: no stretch
    end
    qt_constants.LAYOUT.SET_SPLITTER_STRETCH_FACTOR(audio_splitter, #audio_tracks, 1)  -- Spacer stretches

    return audio_splitter, audio_headers
end

-- Helper function to create headers column with video/audio sections
local function create_headers_column()
    -- Main vertical splitter between video and audio header sections
    local headers_main_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")

    -- Video headers section with scroll area
    local video_scroll = qt_constants.WIDGET.CREATE_SCROLL_AREA()
    local video_splitter, video_headers = create_video_headers()
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(video_scroll, video_splitter)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(video_scroll, "Fixed", "Expanding")

    -- Audio headers section with scroll area
    local audio_scroll = qt_constants.WIDGET.CREATE_SCROLL_AREA()
    local audio_splitter, audio_headers = create_audio_headers()
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(audio_scroll, audio_splitter)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(audio_scroll, "Fixed", "Expanding")

    -- Add both sections to main splitter
    qt_constants.LAYOUT.ADD_WIDGET(headers_main_splitter, video_scroll)
    qt_constants.LAYOUT.ADD_WIDGET(headers_main_splitter, audio_scroll)

    -- Set initial sizes based on track counts
    local video_tracks = state.get_video_tracks()
    local audio_tracks = state.get_audio_tracks()
    local video_height = #video_tracks * timeline_state.dimensions.track_height
    local audio_height = #audio_tracks * timeline_state.dimensions.track_height
    qt_constants.LAYOUT.SET_SPLITTER_SIZES(headers_main_splitter, {video_height, audio_height})

    return headers_main_splitter
end

function M.create()
    print("Creating multi-view timeline panel...")

    -- Initialize state
    state = timeline_state
    state.init("default_sequence")

    -- Set up selection callback for inspector
    state.set_on_selection_changed(function(selected_clips)
        if inspector_view and inspector_view.update_selection then
            inspector_view.update_selection(selected_clips)
        end

        -- Log selection for debugging
        if #selected_clips == 1 then
            print("Selected clip: " .. selected_clips[1].name .. " (" .. selected_clips[1].id .. ")")
        elseif #selected_clips > 1 then
            print("Selected " .. #selected_clips .. " clips")
        else
            print("No clips selected")
        end
    end)

    -- Main container
    local container = qt_constants.WIDGET.CREATE()
    local main_layout = qt_constants.LAYOUT.CREATE_VBOX()
    qt_constants.CONTROL.SET_LAYOUT_SPACING(main_layout, 0)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(main_layout, 0, 0, 0, 0)

    -- Create main horizontal splitter: Headers Column | Timeline Area Column
    local main_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("horizontal")

    -- LEFT SIDE: Headers column (all headers stacked vertically)
    local headers_column = create_headers_column()

    -- RIGHT SIDE: Timeline area column
    local timeline_area = qt_constants.WIDGET.CREATE()
    local timeline_area_layout = qt_constants.LAYOUT.CREATE_VBOX()
    qt_constants.CONTROL.SET_LAYOUT_SPACING(timeline_area_layout, 0)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(timeline_area_layout, 0, 0, 0, 0)

    -- Ruler widget (fixed height)
    local ruler_widget = qt_constants.WIDGET.CREATE_TIMELINE()
    local ruler = timeline_ruler.create(ruler_widget, state)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(ruler_widget, "Expanding", "Fixed")
    qt_constants.LAYOUT.ADD_WIDGET(timeline_area_layout, ruler_widget)

    -- Create video timeline view
    local video_widget = qt_constants.WIDGET.CREATE_TIMELINE()
    local video_view = timeline_view.create(
        video_widget,
        state,
        function(track) return track.track_type == "VIDEO" end,
        {}
    )

    -- Video scroll area
    local video_scroll = qt_constants.WIDGET.CREATE_SCROLL_AREA()
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(video_scroll, video_widget)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(video_scroll, "Expanding", "Expanding")

    -- Create audio timeline view
    local audio_widget = qt_constants.WIDGET.CREATE_TIMELINE()
    local audio_view = timeline_view.create(
        audio_widget,
        state,
        function(track) return track.track_type == "AUDIO" end,
        {}
    )

    -- Audio scroll area
    local audio_scroll = qt_constants.WIDGET.CREATE_SCROLL_AREA()
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(audio_scroll, audio_widget)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(audio_scroll, "Expanding", "Expanding")

    -- Vertical splitter between video and audio scroll areas
    local vertical_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")
    qt_constants.LAYOUT.ADD_WIDGET(vertical_splitter, video_scroll)
    qt_constants.LAYOUT.ADD_WIDGET(vertical_splitter, audio_scroll)

    -- Set initial splitter sizes based on track counts
    local video_tracks = state.get_video_tracks()
    local audio_tracks = state.get_audio_tracks()
    local video_height = #video_tracks * timeline_state.dimensions.track_height
    local audio_height = #audio_tracks * timeline_state.dimensions.track_height
    qt_constants.LAYOUT.SET_SPLITTER_SIZES(vertical_splitter, {video_height, audio_height})

    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(vertical_splitter, "Expanding", "Expanding")
    qt_constants.LAYOUT.ADD_WIDGET(timeline_area_layout, vertical_splitter)

    -- Set stretch factor so splitter gets all remaining vertical space
    qt_set_layout_stretch_factor(timeline_area_layout, vertical_splitter, 1)

    -- Horizontal scrollbar widget (fixed height)
    local scrollbar_widget = qt_constants.WIDGET.CREATE_TIMELINE()
    local scrollbar = timeline_scrollbar.create(scrollbar_widget, state)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(scrollbar_widget, "Expanding", "Fixed")
    qt_constants.LAYOUT.ADD_WIDGET(timeline_area_layout, scrollbar_widget)

    -- Set layout on timeline area
    qt_constants.LAYOUT.SET_ON_WIDGET(timeline_area, timeline_area_layout)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(timeline_area, "Expanding", "Expanding")

    -- Add both columns to main horizontal splitter
    qt_constants.LAYOUT.ADD_WIDGET(main_splitter, headers_column)
    qt_constants.LAYOUT.ADD_WIDGET(main_splitter, timeline_area)

    -- Synchronize the headers splitter with the timeline splitter
    -- When headers video/audio boundary moves, update timeline
    local syncing = false  -- Prevent infinite loop
    _G["headers_splitter_moved"] = function(pos, index)
        if not syncing then
            syncing = true
            local sizes = qt_constants.LAYOUT.GET_SPLITTER_SIZES(headers_column)
            qt_constants.LAYOUT.SET_SPLITTER_SIZES(vertical_splitter, sizes)
            syncing = false
        end
    end
    qt_set_splitter_moved_handler(headers_column, "headers_splitter_moved")

    -- When timeline video/audio boundary moves, update headers
    _G["timeline_splitter_moved"] = function(pos, index)
        if not syncing then
            syncing = true
            local sizes = qt_constants.LAYOUT.GET_SPLITTER_SIZES(vertical_splitter)
            qt_constants.LAYOUT.SET_SPLITTER_SIZES(headers_column, sizes)
            syncing = false
        end
    end
    qt_set_splitter_moved_handler(vertical_splitter, "timeline_splitter_moved")

    -- Set initial splitter sizes: 150px for headers, rest for timeline area
    qt_constants.LAYOUT.SET_SPLITTER_SIZES(main_splitter, {timeline_state.dimensions.track_header_width, 1000})

    -- Add main splitter to container
    qt_constants.LAYOUT.ADD_WIDGET(main_layout, main_splitter)
    qt_constants.LAYOUT.SET_ON_WIDGET(container, main_layout)

    -- Make main container expand to fill available space
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(container, "Expanding", "Expanding")

    print("Multi-view timeline panel created successfully")

    return container
end

return M
