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

    -- Debug: Video tracks from state
    -- for i, track in ipairs(video_tracks) do
    --     print(string.format("  video_tracks[%d] = %s (id=%s)", i, track.name, track.id))
    -- end

    local video_headers = {}
    local current_track = nil
    local handler_name = "video_splitter_event_" .. tostring(video_splitter):gsub("[^%w]", "_")

    -- Add stretch widget at top to push tracks down (V1 is anchor at bottom)
    local stretch_widget = qt_constants.WIDGET.CREATE()
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(stretch_widget, "Expanding", "Expanding")
    qt_constants.LAYOUT.ADD_WIDGET(video_splitter, stretch_widget)

    -- Add tracks in REVERSE order (V3, V2, V1)
    for i = #video_tracks, 1, -1 do
        local track = video_tracks[i]
        local header = qt_constants.WIDGET.CREATE_LABEL(track.name)
        qt_constants.PROPERTIES.SET_STYLE(header, [[
            QLabel {
                background: #3a3a5a;
                color: #cccccc;
                padding-left: 10px;
                border: 1px solid #222232;
            }
        ]])
        qt_constants.PROPERTIES.SET_MIN_WIDTH(header, timeline_state.dimensions.track_header_width)
        qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(header, "Fixed", "Expanding")
        qt_constants.PROPERTIES.SET_MIN_HEIGHT(header, timeline_state.dimensions.default_track_height)
        qt_constants.PROPERTIES.SET_MAX_HEIGHT(header, timeline_state.dimensions.default_track_height)

        qt_constants.LAYOUT.ADD_WIDGET(video_splitter, header)
        video_headers[i] = header
    end

    -- Install handlers: Handle N resizes Track N
    -- Physical layout (top to bottom): Stretch → V3 → V2 → V1 → [MIDLINE ANCHOR]
    -- Tracks grow upward from midline anchor
    --
    -- CRITICAL DISCOVERY: Qt splitter handle indices don't start at 0!
    -- Working indices are 1, 2, 3 (empirically discovered by trying handle 0 which didn't fire)
    --
    -- Qt handle mapping (empirically discovered):
    --   qt_handle 1: between V3 and V2 → Handle 3 → resizes V3 (track 3)
    --   qt_handle 2: between V2 and V1 → Handle 2 → resizes V2 (track 2)
    --   qt_handle 3: below V1 → Handle 1 → resizes V1 (track 1)
    --
    -- We renumber from bottom to top: handle_num = (#video_tracks + 1) - qt_handle_index
    print(string.format("Installing video handles for %d tracks", #video_tracks))
    print(string.format("Checking which Qt handles exist..."))
    for test_index = 0, #video_tracks + 1 do
        local test_handle = qt_get_splitter_handle(video_splitter, test_index)
        print(string.format("  qt_handle %d: %s", test_index, test_handle and "EXISTS" or "nil"))
    end

    for qt_handle_index = 1, #video_tracks do
        local handle = qt_get_splitter_handle(video_splitter, qt_handle_index)
        print(string.format("  qt_handle %d: got handle = %s", qt_handle_index, tostring(handle)))
        if handle then
            -- Renumber from bottom to top: qt_handle 1→Handle 3, qt_handle 2→Handle 2, qt_handle 3→Handle 1
            local handle_num = (#video_tracks + 1) - qt_handle_index

            -- Handle N resizes track N
            local track_num = handle_num
            local track_id = video_tracks[track_num].id
            local track_name = video_tracks[track_num].name

            -- Qt positions: Stretch=0, V3=1, V2=2, V1=3
            -- Handle N is between widget (N-1) and widget N
            local qt_pos_above = qt_handle_index - 1  -- Widget above the handle
            local qt_pos_below = qt_handle_index      -- Widget below the handle (what we want to resize)

            print(string.format("    Installing: qt_handle %d → Handle %d → resizes %s (qt_pos %d)",
                qt_handle_index, handle_num, track_name, qt_pos_below))

            local this_handler_name = handler_name .. "_handle_" .. qt_handle_index
            print(string.format("    Handler name: %s", this_handler_name))

            -- Create local copies for the closure to capture
            local captured_handle_num = handle_num
            local captured_track_num = track_num
            local captured_track_id = track_id
            local captured_track_name = track_name
            local captured_qt_pos_above = qt_pos_above
            local captured_qt_pos_below = qt_pos_below

            _G[this_handler_name] = function(event_type, y)
                print(string.format("Handler %s called: event_type=%s", this_handler_name, event_type))
                if event_type == "press" then
                    print(string.format("Handle %d pressed → resizing %s", captured_handle_num, captured_track_name))
                    qt_constants.PROPERTIES.SET_MIN_HEIGHT(video_headers[captured_track_num], 20)
                    qt_constants.PROPERTIES.SET_MAX_HEIGHT(video_headers[captured_track_num], 16777215)
                elseif event_type == "release" then
                    local sizes = qt_constants.LAYOUT.GET_SPLITTER_SIZES(video_splitter)
                    local new_height = sizes[captured_qt_pos_below + 1]  -- Lua arrays are 1-indexed

                    print(string.format("Handle %d → %s = %dpx", captured_handle_num, captured_track_name, new_height))

                    -- Lock at exact height to prevent unwanted resizing during main boundary drag
                    qt_constants.PROPERTIES.SET_MIN_HEIGHT(video_headers[captured_track_num], new_height)
                    qt_constants.PROPERTIES.SET_MAX_HEIGHT(video_headers[captured_track_num], new_height)
                    -- Reset: stretch widget absorbs space, tracks fixed
                    qt_constants.LAYOUT.SET_SPLITTER_STRETCH_FACTOR(video_splitter, 0, 1)
                    qt_constants.LAYOUT.SET_SPLITTER_STRETCH_FACTOR(video_splitter, captured_qt_pos_below, 0)

                    state.set_track_height(captured_track_id, new_height)
                end
            end
            print(string.format("    Calling qt_set_widget_click_handler for %s", this_handler_name))
            qt_set_widget_click_handler(handle, this_handler_name)
            print(string.format("    Handler installed successfully"))
        end
    end

    -- Set initial sizes: stretch widget gets 0, tracks get their natural height
    local initial_sizes = {0}  -- Stretch widget starts at 0
    for i = 1, #video_tracks do
        table.insert(initial_sizes, timeline_state.dimensions.default_track_height)
    end
    qt_constants.LAYOUT.SET_SPLITTER_SIZES(video_splitter, initial_sizes)

    -- Set stretch factors: stretch widget absorbs space, tracks stay fixed
    qt_constants.LAYOUT.SET_SPLITTER_STRETCH_FACTOR(video_splitter, 0, 1)  -- Stretch widget
    for i = 1, #video_tracks do
        qt_constants.LAYOUT.SET_SPLITTER_STRETCH_FACTOR(video_splitter, i, 0)  -- Tracks stay fixed
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

    -- Add tracks in normal order (A1, A2, A3)
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
        qt_constants.PROPERTIES.SET_MIN_HEIGHT(header, timeline_state.dimensions.default_track_height)
        qt_constants.PROPERTIES.SET_MAX_HEIGHT(header, timeline_state.dimensions.default_track_height)

        qt_constants.LAYOUT.ADD_WIDGET(audio_splitter, header)
        audio_headers[i] = header
    end

    -- Add stretch widget at bottom to push tracks up (A1 is anchor at top)
    local stretch_widget = qt_constants.WIDGET.CREATE()
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(stretch_widget, "Expanding", "Expanding")
    qt_constants.LAYOUT.ADD_WIDGET(audio_splitter, stretch_widget)

    -- Install handlers: Handle N resizes Track N
    -- Physical layout (top to bottom): A1 → A2 → A3 → Stretch
    -- A1 is anchor at top, tracks grow downward
    --
    -- CRITICAL DISCOVERY: Qt splitter handle indices don't start at 0!
    -- Working indices are 1, 2, 3 (just like video tracks)
    --
    -- Qt handle mapping - NO RENUMBERING NEEDED (both go 1-3 top to bottom):
    --   qt_handle 1: between A1 and A2 → Handle 1 → resizes A1 (track 1)
    --   qt_handle 2: between A2 and A3 → Handle 2 → resizes A2 (track 2)
    --   qt_handle 3: between A3 and Stretch → Handle 3 → resizes A3 (track 3)
    print(string.format("Installing audio handles for %d tracks", #audio_tracks))
    print(string.format("Checking which Qt handles exist..."))
    for test_index = 0, #audio_tracks + 1 do
        local test_handle = qt_get_splitter_handle(audio_splitter, test_index)
        print(string.format("  qt_handle %d: %s", test_index, test_handle and "EXISTS" or "nil"))
    end

    for qt_handle_index = 1, #audio_tracks do
        local handle = qt_get_splitter_handle(audio_splitter, qt_handle_index)
        print(string.format("  qt_handle %d: got handle = %s", qt_handle_index, tostring(handle)))
        if handle then
            -- Direct mapping: qt_handle N → Handle N → resizes Track N (no renumbering!)
            local handle_num = qt_handle_index
            local track_num = qt_handle_index  -- Direct 1:1 mapping
            local track_id = audio_tracks[track_num].id
            local track_name = audio_tracks[track_num].name

            -- Qt positions: A1=0, A2=1, A3=2, Stretch=3
            -- Each handle resizes the widget ABOVE it
            local qt_pos_to_resize = qt_handle_index - 1

            print(string.format("    Installing: qt_handle %d → Handle %d → resizes %s (qt_pos %d)",
                qt_handle_index, handle_num, track_name, qt_pos_to_resize))

            local this_handler_name = handler_name .. "_handle_" .. qt_handle_index

            -- Create local copies for the closure to capture
            local captured_handle_num = handle_num
            local captured_track_num = track_num
            local captured_track_id = track_id
            local captured_track_name = track_name
            local captured_qt_pos_to_resize = qt_pos_to_resize

            _G[this_handler_name] = function(event_type, y)
                if event_type == "press" then
                    print(string.format("Handle %d pressed → resizing %s", captured_handle_num, captured_track_name))
                    qt_constants.PROPERTIES.SET_MIN_HEIGHT(audio_headers[captured_track_num], 20)
                    qt_constants.PROPERTIES.SET_MAX_HEIGHT(audio_headers[captured_track_num], 16777215)
                elseif event_type == "release" then
                    local sizes = qt_constants.LAYOUT.GET_SPLITTER_SIZES(audio_splitter)
                    local new_height = sizes[captured_qt_pos_to_resize + 1]  -- Lua arrays are 1-indexed

                    print(string.format("Handle %d → %s = %dpx", captured_handle_num, captured_track_name, new_height))

                    -- Lock at exact height to prevent unwanted resizing during main boundary drag
                    qt_constants.PROPERTIES.SET_MIN_HEIGHT(audio_headers[captured_track_num], new_height)
                    qt_constants.PROPERTIES.SET_MAX_HEIGHT(audio_headers[captured_track_num], new_height)
                    -- Reset stretch factors: stretch widget absorbs, tracks fixed
                    qt_constants.LAYOUT.SET_SPLITTER_STRETCH_FACTOR(audio_splitter, #audio_tracks, 1)  -- Stretch widget
                    for i = 0, #audio_tracks - 1 do
                        qt_constants.LAYOUT.SET_SPLITTER_STRETCH_FACTOR(audio_splitter, i, 0)  -- Tracks fixed
                    end

                    state.set_track_height(captured_track_id, new_height)
                end
            end
            print(string.format("    Calling qt_set_widget_click_handler for %s", this_handler_name))
            qt_set_widget_click_handler(handle, this_handler_name)
            print(string.format("    Handler installed successfully"))
        end
    end

    -- Set initial sizes: tracks get their natural height, stretch widget gets 0
    local initial_sizes = {}
    for i = 1, #audio_tracks do
        table.insert(initial_sizes, timeline_state.dimensions.default_track_height)
    end
    table.insert(initial_sizes, 0)  -- Stretch widget starts at 0
    qt_constants.LAYOUT.SET_SPLITTER_SIZES(audio_splitter, initial_sizes)

    -- Set stretch factors: stretch widget absorbs space, tracks stay fixed
    for i = 0, #audio_tracks - 1 do
        qt_constants.LAYOUT.SET_SPLITTER_STRETCH_FACTOR(audio_splitter, i, 0)  -- Tracks stay fixed
    end
    qt_constants.LAYOUT.SET_SPLITTER_STRETCH_FACTOR(audio_splitter, #audio_tracks, 1)  -- Stretch widget

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
    qt_constants.PROPERTIES.SET_MIN_WIDTH(video_scroll, timeline_state.dimensions.track_header_width)
    qt_constants.PROPERTIES.SET_MAX_WIDTH(video_scroll, timeline_state.dimensions.track_header_width)

    -- Audio headers section with scroll area
    local audio_scroll = qt_constants.WIDGET.CREATE_SCROLL_AREA()
    local audio_splitter, audio_headers = create_audio_headers()
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(audio_scroll, audio_splitter)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(audio_scroll, "Fixed", "Expanding")
    qt_constants.PROPERTIES.SET_MIN_WIDTH(audio_scroll, timeline_state.dimensions.track_header_width)
    qt_constants.PROPERTIES.SET_MAX_WIDTH(audio_scroll, timeline_state.dimensions.track_header_width)

    -- Add both sections to main splitter
    qt_constants.LAYOUT.ADD_WIDGET(headers_main_splitter, video_scroll)
    qt_constants.LAYOUT.ADD_WIDGET(headers_main_splitter, audio_scroll)

    -- Set initial sizes based on track counts
    local video_tracks = state.get_video_tracks()
    local audio_tracks = state.get_audio_tracks()
    local video_height = #video_tracks * timeline_state.dimensions.default_track_height
    local audio_height = #audio_tracks * timeline_state.dimensions.default_track_height
    qt_constants.LAYOUT.SET_SPLITTER_SIZES(headers_main_splitter, {video_height, audio_height})

    -- Return splitter and scroll areas for synchronization
    return headers_main_splitter, video_scroll, audio_scroll
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
        -- if #selected_clips == 1 then
        --     print("Selected clip: " .. selected_clips[1].name .. " (" .. selected_clips[1].id .. ")")
        -- elseif #selected_clips > 1 then
        --     print("Selected " .. #selected_clips .. " clips")
        -- else
        --     print("No clips selected")
        -- end
    end)

    -- Main container
    local container = qt_constants.WIDGET.CREATE()
    local main_layout = qt_constants.LAYOUT.CREATE_VBOX()
    qt_constants.CONTROL.SET_LAYOUT_SPACING(main_layout, 0)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(main_layout, 0, 0, 0, 0)

    -- Create main horizontal splitter: Headers Column | Timeline Area Column
    local main_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("horizontal")

    -- LEFT SIDE: Headers column (all headers stacked vertically)
    local headers_column, header_video_scroll, header_audio_scroll = create_headers_column()

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
    local timeline_video_scroll = qt_constants.WIDGET.CREATE_SCROLL_AREA()
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(timeline_video_scroll, video_widget)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(timeline_video_scroll, "Expanding", "Expanding")

    -- Create audio timeline view
    local audio_widget = qt_constants.WIDGET.CREATE_TIMELINE()
    local audio_view = timeline_view.create(
        audio_widget,
        state,
        function(track) return track.track_type == "AUDIO" end,
        {}
    )

    -- Audio scroll area
    local timeline_audio_scroll = qt_constants.WIDGET.CREATE_SCROLL_AREA()
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(timeline_audio_scroll, audio_widget)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(timeline_audio_scroll, "Expanding", "Expanding")

    -- Vertical splitter between video and audio scroll areas
    local vertical_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")
    qt_constants.LAYOUT.ADD_WIDGET(vertical_splitter, timeline_video_scroll)
    qt_constants.LAYOUT.ADD_WIDGET(vertical_splitter, timeline_audio_scroll)

    -- Set initial splitter sizes based on track counts
    local video_tracks = state.get_video_tracks()
    local audio_tracks = state.get_audio_tracks()
    local video_height = #video_tracks * timeline_state.dimensions.default_track_height
    local audio_height = #audio_tracks * timeline_state.dimensions.default_track_height
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

    -- Synchronize vertical scrolling across all scroll areas
    local scroll_syncing = false  -- Prevent infinite loop
    local all_scroll_areas = {
        header_video_scroll,
        header_audio_scroll,
        timeline_video_scroll,
        timeline_audio_scroll
    }

    -- Create a global handler that propagates scroll to all areas
    _G["timeline_scroll_sync_handler"] = function(new_position)
        if not scroll_syncing then
            scroll_syncing = true
            -- Set the same scroll position on all scroll areas
            for _, scroll_area in ipairs(all_scroll_areas) do
                qt_set_scroll_position(scroll_area, new_position)
            end
            scroll_syncing = false
        end
    end

    -- Connect all scroll areas to the sync handler
    for _, scroll_area in ipairs(all_scroll_areas) do
        qt_set_scroll_area_scroll_handler(scroll_area, "timeline_scroll_sync_handler")
    end

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
