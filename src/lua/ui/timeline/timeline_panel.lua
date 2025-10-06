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

    local video_headers = {}  -- Store references for later manipulation
    -- Add tracks in REVERSE order so V1 is at bottom (nearest anchor)
    for i = #video_tracks, 1, -1 do
        local track = video_tracks[i]
        print(string.format("  Creating header for video_tracks[%d] = %s, storing in video_headers[%d]", i, track.name, i))
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

        -- Make ALL tracks non-resizable by default
        qt_constants.PROPERTIES.SET_MIN_HEIGHT(header, timeline_state.dimensions.track_height)
        qt_constants.PROPERTIES.SET_MAX_HEIGHT(header, timeline_state.dimensions.track_height)

        qt_constants.LAYOUT.ADD_WIDGET(video_splitter, header)
        video_headers[i] = header
        print(string.format("    Added to splitter: %s header -> video_headers[%d]", track.name, i))
    end
    print("DEBUG: Final video_headers mapping:")
    for i = 1, #video_headers do
        local label_text = qt_constants.PROPERTIES.GET_TEXT(video_headers[i])
        print(string.format("  video_headers[%d] = label '%s'", i, label_text))
    end
    print("DEBUG: Visual layout in splitter (top to bottom):")
    print("  Widget 0: spacer")
    print("  Widget 1: " .. qt_constants.PROPERTIES.GET_TEXT(video_headers[3]))
    print("  [Handle 1 - should control widget below it]")
    print("  Widget 2: " .. qt_constants.PROPERTIES.GET_TEXT(video_headers[2]))
    print("  [Handle 2 - should control widget below it]")
    print("  Widget 3: " .. qt_constants.PROPERTIES.GET_TEXT(video_headers[1]))

    -- Set initial sizes: spacer gets 1px (will expand), tracks get their natural height
    local initial_sizes = {1}  -- Spacer at start
    for i = 1, #video_tracks do
        table.insert(initial_sizes, timeline_state.dimensions.track_height)
    end
    qt_constants.LAYOUT.SET_SPLITTER_SIZES(video_splitter, initial_sizes)

    -- Set stretch factors: ONLY spacer stretches, all tracks stay fixed during main boundary drag
    qt_constants.LAYOUT.SET_SPLITTER_STRETCH_FACTOR(video_splitter, 0, 1)  -- Spacer stretches
    for i = 1, #video_tracks do
        qt_constants.LAYOUT.SET_SPLITTER_STRETCH_FACTOR(video_splitter, i, 0)  -- All tracks: no stretch
    end

    -- Install event filter for press/release to unlock/lock tracks
    local current_track = nil
    local handler_name = "video_splitter_event_" .. tostring(video_splitter):gsub("[^%w]", "_")

    -- Video splitter N unlocks track N (counting from anchor at bottom)
    for track_num = 1, #video_tracks - 1 do
        local qt_handle_index = #video_tracks - track_num
        local handle = qt_get_splitter_handle(video_splitter, qt_handle_index)
        if handle then
            -- Handler name must match the Qt handle index it's installed on
            local this_handler_name = handler_name .. "_handle_" .. qt_handle_index
            -- Capture track_num in closure
            local captured_track_num = track_num
            _G[this_handler_name] = function(event_type, y)
                if event_type == "press" then
                    current_track = captured_track_num
                    print(string.format("Splitter %d press: unlocking V%d", captured_track_num, captured_track_num))
                    qt_constants.PROPERTIES.SET_MIN_HEIGHT(video_headers[captured_track_num], 0)
                    qt_constants.PROPERTIES.SET_MAX_HEIGHT(video_headers[captured_track_num], 16777215)
                elseif event_type == "release" and current_track then
                    local sizes = qt_constants.LAYOUT.GET_SPLITTER_SIZES(video_splitter)
                    local new_height = sizes[#video_tracks - captured_track_num + 2]
                    print(string.format("Splitter %d release: locking V%d at %dpx", captured_track_num, captured_track_num, new_height))
                    qt_constants.PROPERTIES.SET_MIN_HEIGHT(video_headers[captured_track_num], new_height)
                    qt_constants.PROPERTIES.SET_MAX_HEIGHT(video_headers[captured_track_num], new_height)
                    current_track = nil
                end
            end
            qt_set_widget_click_handler(handle, this_handler_name)
        end
    end

    return video_splitter, video_headers
end

-- Helper function to create audio headers with splitters
local function create_audio_headers()
    local audio_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")
    local audio_tracks = state.get_audio_tracks()

    local audio_headers = {}  -- Store references for later manipulation
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

        -- Make ALL tracks non-resizable by default
        qt_constants.PROPERTIES.SET_MIN_HEIGHT(header, timeline_state.dimensions.track_height)
        qt_constants.PROPERTIES.SET_MAX_HEIGHT(header, timeline_state.dimensions.track_height)

        qt_constants.LAYOUT.ADD_WIDGET(audio_splitter, header)
        audio_headers[i] = header
    end

    -- Add stretchable spacer at bottom so audio tracks anchor to top
    local bottom_spacer = qt_constants.WIDGET.CREATE()
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(bottom_spacer, "Expanding", "Expanding")
    qt_constants.LAYOUT.ADD_WIDGET(audio_splitter, bottom_spacer)

    -- Set initial sizes: tracks get their natural height, spacer gets 1px (will expand)
    local initial_sizes = {}
    for i = 1, #audio_tracks do
        table.insert(initial_sizes, timeline_state.dimensions.track_height)
    end
    table.insert(initial_sizes, 1)  -- Spacer starts at 1px
    qt_constants.LAYOUT.SET_SPLITTER_SIZES(audio_splitter, initial_sizes)

    -- Set stretch factors: ONLY spacer stretches, all tracks stay fixed during main boundary drag
    for i = 0, #audio_tracks - 1 do
        qt_constants.LAYOUT.SET_SPLITTER_STRETCH_FACTOR(audio_splitter, i, 0)  -- All tracks: no stretch
    end
    qt_constants.LAYOUT.SET_SPLITTER_STRETCH_FACTOR(audio_splitter, #audio_tracks, 1)  -- Spacer stretches

    -- Install event filter for press/release to unlock/lock tracks
    local current_track = nil
    local handler_name = "audio_splitter_event_" .. tostring(audio_splitter):gsub("[^%w]", "_")

    -- Audio splitter N unlocks track N (counting from anchor at top)
    for track_num = 1, #audio_tracks - 1 do
        local qt_handle_index = track_num - 1
        local handle = qt_get_splitter_handle(audio_splitter, qt_handle_index)
        if handle then
            -- Handler name must match the Qt handle index it's installed on
            local this_handler_name = handler_name .. "_handle_" .. qt_handle_index
            -- Capture track_num in closure
            local captured_track_num = track_num
            _G[this_handler_name] = function(event_type, y)
                if event_type == "press" then
                    current_track = captured_track_num
                    print(string.format("Splitter %d press: unlocking A%d", captured_track_num, captured_track_num))
                    qt_constants.PROPERTIES.SET_MIN_HEIGHT(audio_headers[captured_track_num], 0)
                    qt_constants.PROPERTIES.SET_MAX_HEIGHT(audio_headers[captured_track_num], 16777215)
                elseif event_type == "release" and current_track then
                    local sizes = qt_constants.LAYOUT.GET_SPLITTER_SIZES(audio_splitter)
                    local new_height = sizes[captured_track_num]
                    print(string.format("Splitter %d release: locking A%d at %dpx", captured_track_num, captured_track_num, new_height))
                    qt_constants.PROPERTIES.SET_MIN_HEIGHT(audio_headers[captured_track_num], new_height)
                    qt_constants.PROPERTIES.SET_MAX_HEIGHT(audio_headers[captured_track_num], new_height)
                    current_track = nil
                end
            end
            qt_set_widget_click_handler(handle, this_handler_name)
        end
    end

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
