-- Timeline Panel - Multi-view timeline architecture
-- Assembles ruler, video view, audio view, and scrollbar

local timeline_state = require("ui.timeline.timeline_state")
local timeline_view = require("ui.timeline.timeline_view")
local timeline_ruler = require("ui.timeline.timeline_ruler")
local timeline_scrollbar = require("ui.timeline.timeline_scrollbar")

local M = {}

-- Constants
local SPLITTER_HANDLE_HEIGHT = 7  -- Qt default vertical splitter handle height (pixels)

-- Store references
local state = nil
local inspector_view = nil

function M.set_inspector(view)
    inspector_view = view

    -- If there's already a selection when inspector is wired up, notify it immediately
    -- This handles the case where selection is restored from database before inspector is ready
    if state and view and view.update_selection then
        local selected_clips = state.get_selected_clips()
        if #selected_clips > 0 then
            print(string.format("Notifying newly-wired inspector of %d selected clips", #selected_clips))
            view.update_selection(selected_clips)
        end
    end
end

function M.set_project_browser(browser)
    if state then
        state.set_project_browser(browser)
    end
end

function M.get_state()
    return timeline_state  -- Return the module, not the local state variable
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

                    -- Add handle height to track height so timeline renders track + handle space
                    state.set_track_height(captured_track_id, new_height + SPLITTER_HANDLE_HEIGHT)

                    -- Update splitter minimum height to accommodate new track sizes
                    local total_height = 0
                    for _, track in ipairs(state.get_video_tracks()) do
                        total_height = total_height + state.get_track_height(track.id)
                    end
                    qt_constants.PROPERTIES.SET_MIN_HEIGHT(video_splitter, total_height)
                    print(string.format("  Updated video_splitter min height to %dpx", total_height))
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

    -- Register splitterMoved handler to update minimum height dynamically
    _G["video_splitter_moved"] = function(pos, index)
        print(string.format("video_splitter_moved fired: pos=%d, index=%d", pos, index))
        -- Calculate total height needed for all video tracks
        local total_height = 0
        for _, track in ipairs(state.get_video_tracks()) do
            total_height = total_height + state.get_track_height(track.id)
        end
        print(string.format("  Setting video_splitter min height to %dpx", total_height))
        -- Set splitter minimum height to accommodate all tracks
        qt_constants.PROPERTIES.SET_MIN_HEIGHT(video_splitter, total_height)
    end
    print("Registering video_splitter_moved handler...")
    qt_set_splitter_moved_handler(video_splitter, "video_splitter_moved")
    print("  Handler registered")

    -- Initialize track heights in state (header height + handle height)
    for _, track in ipairs(video_tracks) do
        state.set_track_height(track.id, timeline_state.dimensions.default_track_height + SPLITTER_HANDLE_HEIGHT)
    end

    -- Hide the handle above V3 (between stretch widget and V3) - handle index 0
    qt_hide_splitter_handle(video_splitter, 0)

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

                    -- Add handle height to track height so timeline renders track + handle space
                    state.set_track_height(captured_track_id, new_height + SPLITTER_HANDLE_HEIGHT)
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

    -- Register splitterMoved handler to update minimum height dynamically
    _G["audio_splitter_moved"] = function(pos, index)
        -- Calculate total height needed for all audio tracks
        local total_height = 0
        for _, track in ipairs(state.get_audio_tracks()) do
            total_height = total_height + state.get_track_height(track.id)
        end
        -- Set splitter minimum height to accommodate all tracks
        qt_constants.PROPERTIES.SET_MIN_HEIGHT(audio_splitter, total_height)
    end
    qt_set_splitter_moved_handler(audio_splitter, "audio_splitter_moved")

    -- Initialize track heights in state (header height + handle height)
    for _, track in ipairs(audio_tracks) do
        state.set_track_height(track.id, timeline_state.dimensions.default_track_height + SPLITTER_HANDLE_HEIGHT)
    end

    -- Hide the handle below A3 (between A3 and stretch widget) - last handle index
    qt_hide_splitter_handle(audio_splitter, #audio_tracks)

    return audio_splitter, audio_headers
end

-- Helper function to create headers column with video/audio sections
local function create_headers_column()
    -- Wrapper VBox to add ruler-height spacer at top
    local headers_wrapper = qt_constants.WIDGET.CREATE()
    local headers_wrapper_layout = qt_constants.LAYOUT.CREATE_VBOX()
    qt_constants.CONTROL.SET_LAYOUT_SPACING(headers_wrapper_layout, 0)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(headers_wrapper_layout, 0, 0, 0, 0)

    -- Add 32px spacer at top to match ruler height on timeline side
    local ruler_spacer = qt_constants.WIDGET.CREATE()
    qt_constants.PROPERTIES.SET_MIN_HEIGHT(ruler_spacer, timeline_ruler.RULER_HEIGHT)
    qt_constants.PROPERTIES.SET_MAX_HEIGHT(ruler_spacer, timeline_ruler.RULER_HEIGHT)
    qt_constants.LAYOUT.ADD_WIDGET(headers_wrapper_layout, ruler_spacer)

    -- Main vertical splitter between video and audio header sections
    local headers_main_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")

    -- Video headers section with scroll area
    local video_scroll = qt_constants.WIDGET.CREATE_SCROLL_AREA()
    local video_splitter, video_headers = create_video_headers()
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(video_scroll, video_splitter)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(video_scroll, "Fixed", "Expanding")
    qt_constants.CONTROL.SET_SCROLL_AREA_H_SCROLLBAR_POLICY(video_scroll, "AlwaysOff")
    qt_constants.CONTROL.SET_SCROLL_AREA_V_SCROLLBAR_POLICY(video_scroll, "AlwaysOff")
    qt_constants.PROPERTIES.SET_MIN_WIDTH(video_scroll, timeline_state.dimensions.track_header_width)
    qt_constants.PROPERTIES.SET_MAX_WIDTH(video_scroll, timeline_state.dimensions.track_header_width)
    qt_set_scroll_area_anchor_bottom(video_scroll, true)  -- V1 stays visible when shrinking

    -- Audio headers section with scroll area
    local audio_scroll = qt_constants.WIDGET.CREATE_SCROLL_AREA()
    local audio_splitter, audio_headers = create_audio_headers()
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(audio_scroll, audio_splitter)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(audio_scroll, "Fixed", "Expanding")
    qt_constants.CONTROL.SET_SCROLL_AREA_H_SCROLLBAR_POLICY(audio_scroll, "AlwaysOff")
    qt_constants.CONTROL.SET_SCROLL_AREA_V_SCROLLBAR_POLICY(audio_scroll, "AlwaysOff")
    qt_constants.PROPERTIES.SET_MIN_WIDTH(audio_scroll, timeline_state.dimensions.track_header_width)
    qt_constants.PROPERTIES.SET_MAX_WIDTH(audio_scroll, timeline_state.dimensions.track_header_width)

    -- Add both sections to main splitter
    qt_constants.LAYOUT.ADD_WIDGET(headers_main_splitter, video_scroll)
    qt_constants.LAYOUT.ADD_WIDGET(headers_main_splitter, audio_scroll)

    -- Set initial 50/50 split (will be adjusted dynamically by splitterMoved handlers)
    qt_constants.LAYOUT.SET_SPLITTER_SIZES(headers_main_splitter, {1, 1})

    -- Add splitter to wrapper layout
    qt_constants.LAYOUT.ADD_WIDGET(headers_wrapper_layout, headers_main_splitter)
    qt_set_layout_stretch_factor(headers_wrapper_layout, headers_main_splitter, 1)

    -- Set layout on wrapper
    qt_constants.LAYOUT.SET_ON_WIDGET(headers_wrapper, headers_wrapper_layout)

    -- Constrain wrapper width to match scroll area widths
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(headers_wrapper, "Fixed", "Expanding")
    qt_constants.PROPERTIES.SET_MIN_WIDTH(headers_wrapper, timeline_state.dimensions.track_header_width)
    qt_constants.PROPERTIES.SET_MAX_WIDTH(headers_wrapper, timeline_state.dimensions.track_header_width)

    -- Return wrapper widget, main splitter, and scroll areas for synchronization
    return headers_wrapper, headers_main_splitter, video_scroll, audio_scroll
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
    local headers_column, headers_main_splitter, header_video_scroll, header_audio_scroll = create_headers_column()

    -- RIGHT SIDE: Timeline area column
    local timeline_area = qt_constants.WIDGET.CREATE()
    local timeline_area_layout = qt_constants.LAYOUT.CREATE_VBOX()
    qt_constants.CONTROL.SET_LAYOUT_SPACING(timeline_area_layout, 0)
    qt_constants.CONTROL.SET_LAYOUT_MARGINS(timeline_area_layout, 0, 0, 0, 0)

    -- Ruler widget (fixed height)
    local ruler_widget = qt_constants.WIDGET.CREATE_TIMELINE()
    local ruler = timeline_ruler.create(ruler_widget, state)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(ruler_widget, "Expanding", "Fixed")
    qt_constants.PROPERTIES.SET_MIN_HEIGHT(ruler_widget, timeline_ruler.RULER_HEIGHT)  -- Set 32px height
    qt_constants.PROPERTIES.SET_MAX_HEIGHT(ruler_widget, timeline_ruler.RULER_HEIGHT)  -- Lock to 32px
    qt_constants.LAYOUT.ADD_WIDGET(timeline_area_layout, ruler_widget)

    -- Drag selection coordination state (panel-level, not view-level)
    local drag_state = {
        dragging = false,
        start_widget = nil,       -- Which widget the drag started in
        start_scroll_area = nil,  -- The scroll area containing that widget
        start_x = 0,              -- Start position in that widget's coords
        start_y = 0,
    }

    -- Map widget to its scroll area (will be populated after scroll areas are created)
    local widget_to_scroll_area = {}

    -- Forward declarations - will be set after splitter creation
    local vertical_splitter  -- Needed by on_drag_start for coordinate conversion
    local on_drag_move, on_drag_end

    -- Callback for views to notify panel when drag starts in empty space
    local function on_drag_start(source_widget, x, y, modifiers)
        drag_state.dragging = true
        drag_state.start_widget = source_widget
        drag_state.start_scroll_area = widget_to_scroll_area[source_widget]
        drag_state.start_x = x
        drag_state.start_y = y
        drag_state.modifiers = modifiers  -- Store for use in drag_end

        -- Convert start position to splitter coordinates immediately (not lazily)
        -- This ensures on_drag_end works even if there's no move event
        local global_x, global_y = qt_constants.WIDGET.MAP_TO_GLOBAL(source_widget, x, y)
        local start_x_splitter, start_y_splitter = qt_constants.WIDGET.MAP_FROM_GLOBAL(
            vertical_splitter,
            global_x,
            global_y
        )
        drag_state.splitter_start_x = start_x_splitter
        drag_state.splitter_start_y = start_y_splitter

        -- Return callbacks for view to use during drag
        return on_drag_move, on_drag_end
    end

    -- Create video timeline view
    local video_widget = qt_constants.WIDGET.CREATE_TIMELINE()
    local video_view = timeline_view.create(
        video_widget,
        state,
        function(track) return track.track_type == "VIDEO" end,
        {
            render_bottom_to_top = true,
            on_drag_start = on_drag_start,
        }
    )

    -- Make video widget expand to fill available space
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(video_widget, "Expanding", "Expanding")

    -- Video scroll area
    local timeline_video_scroll = qt_constants.WIDGET.CREATE_SCROLL_AREA()
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(timeline_video_scroll, video_widget)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(timeline_video_scroll, "Expanding", "Expanding")
    qt_set_scroll_area_anchor_bottom(timeline_video_scroll, true)  -- V1 stays visible when shrinking

    -- Register video widget → scroll area mapping for coordinate conversion
    widget_to_scroll_area[video_widget] = timeline_video_scroll

    -- Create audio timeline view
    local audio_widget = qt_constants.WIDGET.CREATE_TIMELINE()
    local audio_view = timeline_view.create(
        audio_widget,
        state,
        function(track) return track.track_type == "AUDIO" end,
        {
            on_drag_start = on_drag_start,
        }
    )

    -- Make audio widget expand to fill available space
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(audio_widget, "Expanding", "Expanding")

    -- Audio scroll area
    local timeline_audio_scroll = qt_constants.WIDGET.CREATE_SCROLL_AREA()
    qt_constants.CONTROL.SET_SCROLL_AREA_WIDGET(timeline_audio_scroll, audio_widget)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(timeline_audio_scroll, "Expanding", "Expanding")

    -- Register audio widget → scroll area mapping for coordinate conversion
    widget_to_scroll_area[audio_widget] = timeline_audio_scroll

    -- Vertical splitter between video and audio scroll areas
    vertical_splitter = qt_constants.LAYOUT.CREATE_SPLITTER("vertical")
    qt_constants.LAYOUT.ADD_WIDGET(vertical_splitter, timeline_video_scroll)
    qt_constants.LAYOUT.ADD_WIDGET(vertical_splitter, timeline_audio_scroll)

    -- Set initial 50/50 split (will be synchronized with headers_main_splitter)
    qt_constants.LAYOUT.SET_SPLITTER_SIZES(vertical_splitter, {1, 1})

    -- Create rubber band for drag selection (parented to splitter so it can span both views)
    -- Note: rubber band starts hidden (QRubberBand::hide() called in C++)
    local rubber_band = qt_constants.WIDGET.CREATE_RUBBER_BAND(vertical_splitter)
    state.set_rubber_band(rubber_band)  -- Store in state for access from timeline views

    -- Panel drag coordination callbacks
    -- Called by view during drag to update rubber band geometry
    -- View passes its local coordinates, panel converts to splitter coords

    -- Show rubber band on first move
    local rubber_band_visible = false
    local function show_rubber_band_if_needed()
        if not rubber_band_visible then
            qt_constants.WIDGET.SET_RUBBER_BAND_GEOMETRY(
                rubber_band,
                drag_state.splitter_start_x,
                drag_state.splitter_start_y,
                0, 0
            )
            qt_constants.DISPLAY.SET_VISIBLE(rubber_band, true)
            rubber_band_visible = true
        end
    end

    on_drag_move = function(source_widget, x, y)
        if not drag_state.dragging then return end

        -- Show rubber band on first move
        show_rubber_band_if_needed()

        -- Convert via global coordinates (always works regardless of hierarchy)
        -- Step 1: Widget-local → Global screen coords
        local global_x, global_y = qt_constants.WIDGET.MAP_TO_GLOBAL(source_widget, x, y)

        -- Step 2: Global screen coords → Splitter-local coords
        local current_x_splitter, current_y_splitter = qt_constants.WIDGET.MAP_FROM_GLOBAL(
            vertical_splitter,
            global_x,
            global_y
        )

        -- Calculate rubber band rectangle in splitter coords
        local rect_x = math.min(drag_state.splitter_start_x, current_x_splitter)
        local rect_y = math.min(drag_state.splitter_start_y, current_y_splitter)
        local rect_width = math.abs(current_x_splitter - drag_state.splitter_start_x)
        local rect_height = math.abs(current_y_splitter - drag_state.splitter_start_y)

        -- Update rubber band geometry
        qt_constants.WIDGET.SET_RUBBER_BAND_GEOMETRY(rubber_band, rect_x, rect_y, rect_width, rect_height)

        -- TODO: Query views for clips in rectangle and update visual feedback
    end

    on_drag_end = function(source_widget, x, y)
        if not drag_state.dragging then return end

        -- Hide rubber band
        qt_constants.DISPLAY.SET_VISIBLE(rubber_band, false)

        -- Convert current mouse position to splitter coordinates
        local global_x, global_y = qt_constants.WIDGET.MAP_TO_GLOBAL(source_widget, x, y)
        local end_x_splitter, end_y_splitter = qt_constants.WIDGET.MAP_FROM_GLOBAL(vertical_splitter, global_x, global_y)

        -- Calculate selection rectangle in splitter coordinates
        local rect_x = math.min(drag_state.splitter_start_x, end_x_splitter)
        local rect_y = math.min(drag_state.splitter_start_y, end_y_splitter)
        local rect_width = math.abs(end_x_splitter - drag_state.splitter_start_x)
        local rect_height = math.abs(end_y_splitter - drag_state.splitter_start_y)

        -- Convert splitter rectangle to time range
        -- We need to map to a timeline view widget to get proper width for time conversion
        local viewport_width, _ = timeline.get_dimensions(video_widget)
        local start_time = state.pixel_to_time(rect_x, viewport_width)
        local end_time = state.pixel_to_time(rect_x + rect_width, viewport_width)

        -- Find all clips that intersect with the selection rectangle
        local selected_clips = {}
        for _, clip in ipairs(state.get_clips()) do
            -- Check time overlap
            local clip_end_time = clip.start_time + clip.duration
            local time_overlaps = not (clip_end_time < start_time or clip.start_time > end_time)

            if time_overlaps then

                -- Determine which view this clip is in
                local track = state.get_track_by_id(clip.track_id)
                if track then
                    local is_video = track.track_type == "VIDEO"
                    local view_widget = is_video and video_widget or audio_widget

                    -- Get widget height for bottom-to-top calculation
                    local widget_width, widget_height = timeline.get_dimensions(view_widget)

                    -- Calculate track Y position using SAME logic as timeline_view.lua rendering
                    local track_y_widget = 0
                    local tracks = is_video and state.get_video_tracks() or state.get_audio_tracks()

                    if is_video then
                        -- Video tracks: render bottom-to-top (same as timeline_view.lua)
                        -- Find track index
                        local track_index = -1
                        for i, t in ipairs(tracks) do
                            if t.id == clip.track_id then
                                track_index = i - 1  -- 0-based
                                break
                            end
                        end

                        -- Calculate Y from bottom upward (matches get_track_y in timeline_view.lua)
                        track_y_widget = widget_height
                        for i = 0, track_index do
                            if tracks[i + 1] then
                                local h = state.get_track_height(tracks[i + 1].id)
                                track_y_widget = track_y_widget - h
                            end
                        end
                    else
                        -- Audio tracks: render top-to-bottom (same as timeline_view.lua)
                        for _, t in ipairs(tracks) do
                            if t.id == clip.track_id then
                                break
                            end
                            track_y_widget = track_y_widget + state.get_track_height(t.id)
                        end
                    end

                    local track_height = state.get_track_height(clip.track_id)

                    -- Convert selection rectangle from splitter coordinates to widget coordinates
                    -- Splitter → global → widget
                    local sel_global_x, sel_global_y = qt_constants.WIDGET.MAP_TO_GLOBAL(vertical_splitter, rect_x, rect_y)
                    local sel_widget_x, sel_widget_y = qt_constants.WIDGET.MAP_FROM_GLOBAL(view_widget, sel_global_x, sel_global_y)

                    local sel_bottom_global_x, sel_bottom_global_y = qt_constants.WIDGET.MAP_TO_GLOBAL(vertical_splitter, rect_x + rect_width, rect_y + rect_height)
                    local sel_bottom_widget_x, sel_bottom_widget_y = qt_constants.WIDGET.MAP_FROM_GLOBAL(view_widget, sel_bottom_global_x, sel_bottom_global_y)

                    -- Check if selection rectangle (in widget coords) overlaps with track (also in widget coords)
                    local track_bottom = track_y_widget + track_height
                    local y_overlaps = not (track_bottom < sel_widget_y or track_y_widget > sel_bottom_widget_y)

                    if y_overlaps then
                        table.insert(selected_clips, clip)
                    end
                end
            end
        end

        -- Update selection state
        -- If Cmd was held during drag, toggle clips in/out of selection instead of replacing
        if drag_state.modifiers and drag_state.modifiers.command then
            local current_selection = state.get_selected_clips()

            -- Toggle: add clips that aren't selected, remove clips that are selected
            for _, dragged_clip in ipairs(selected_clips) do
                local found_index = nil
                for i, existing_clip in ipairs(current_selection) do
                    if existing_clip.id == dragged_clip.id then
                        found_index = i
                        break
                    end
                end

                if found_index then
                    -- Already selected - remove it (toggle off)
                    table.remove(current_selection, found_index)
                else
                    -- Not selected - add it (toggle on)
                    table.insert(current_selection, dragged_clip)
                end
            end

            state.set_selection(current_selection)
        else
            state.set_selection(selected_clips)
        end

        -- Reset drag state
        drag_state.dragging = false
        drag_state.start_widget = nil
        drag_state.start_x = 0
        drag_state.start_y = 0
        drag_state.splitter_start_x = nil
        drag_state.splitter_start_y = nil
        rubber_band_visible = false
    end

    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(vertical_splitter, "Expanding", "Expanding")
    qt_constants.LAYOUT.ADD_WIDGET(timeline_area_layout, vertical_splitter)

    -- Set stretch factor so splitter gets all remaining vertical space
    qt_set_layout_stretch_factor(timeline_area_layout, vertical_splitter, 1)

    -- Set layout on timeline area
    qt_constants.LAYOUT.SET_ON_WIDGET(timeline_area, timeline_area_layout)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(timeline_area, "Expanding", "Expanding")

    -- Add both columns to main horizontal splitter
    qt_constants.LAYOUT.ADD_WIDGET(main_splitter, headers_column)
    qt_constants.LAYOUT.ADD_WIDGET(main_splitter, timeline_area)

    -- Add main splitter to main layout (gets all available vertical space)
    qt_constants.LAYOUT.ADD_WIDGET(main_layout, main_splitter)
    qt_set_layout_stretch_factor(main_layout, main_splitter, 1)

    -- Scrollbar temporarily removed to test portal height allocation
    -- local scrollbar_widget = qt_constants.WIDGET.CREATE_TIMELINE()
    -- local scrollbar = timeline_scrollbar.create(scrollbar_widget, state)
    -- qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(scrollbar_widget, "Expanding", "Fixed")
    -- qt_constants.LAYOUT.ADD_WIDGET(main_layout, scrollbar_widget)

    -- Synchronize the headers splitter with the timeline splitter
    -- When headers video/audio boundary moves, update timeline
    local syncing = false  -- Prevent infinite loop
    _G["headers_splitter_moved"] = function(pos, index)
        print(string.format("headers_splitter_moved fired: pos=%d, index=%d", pos, index))
        if not syncing then
            syncing = true
            local sizes = qt_constants.LAYOUT.GET_SPLITTER_SIZES(headers_main_splitter)
            print(string.format("  Syncing to timeline: sizes = {%d, %d}", sizes[1], sizes[2]))
            qt_constants.LAYOUT.SET_SPLITTER_SIZES(vertical_splitter, sizes)
            syncing = false
        end
    end
    print("Registering headers_splitter_moved handler...")
    qt_set_splitter_moved_handler(headers_main_splitter, "headers_splitter_moved")
    print("  Handler registered")

    -- When timeline video/audio boundary moves, update headers
    _G["timeline_splitter_moved"] = function(pos, index)
        print(string.format("timeline_splitter_moved fired: pos=%d, index=%d", pos, index))
        if not syncing then
            syncing = true
            local sizes = qt_constants.LAYOUT.GET_SPLITTER_SIZES(vertical_splitter)
            print(string.format("  Syncing to headers: sizes = {%d, %d}", sizes[1], sizes[2]))
            qt_constants.LAYOUT.SET_SPLITTER_SIZES(headers_main_splitter, sizes)
            syncing = false
        end
    end
    print("Registering timeline_splitter_moved handler...")
    qt_set_splitter_moved_handler(vertical_splitter, "timeline_splitter_moved")
    print("  Handler registered")

    -- Synchronize vertical scrolling in pairs (video ↔ video, audio ↔ audio)
    local video_scroll_syncing = false  -- Prevent infinite loop
    local audio_scroll_syncing = false

    -- Video scroll sync: header_video_scroll ↔ timeline_video_scroll
    _G["video_scroll_sync_handler"] = function(new_position)
        if not video_scroll_syncing then
            video_scroll_syncing = true
            qt_set_scroll_position(header_video_scroll, new_position)
            qt_set_scroll_position(timeline_video_scroll, new_position)
            video_scroll_syncing = false
        end
    end

    -- Audio scroll sync: header_audio_scroll ↔ timeline_audio_scroll
    _G["audio_scroll_sync_handler"] = function(new_position)
        if not audio_scroll_syncing then
            audio_scroll_syncing = true
            qt_set_scroll_position(header_audio_scroll, new_position)
            qt_set_scroll_position(timeline_audio_scroll, new_position)
            audio_scroll_syncing = false
        end
    end

    -- Connect video scroll areas to video sync handler
    qt_set_scroll_area_scroll_handler(header_video_scroll, "video_scroll_sync_handler")
    qt_set_scroll_area_scroll_handler(timeline_video_scroll, "video_scroll_sync_handler")

    -- Connect audio scroll areas to audio sync handler
    qt_set_scroll_area_scroll_handler(header_audio_scroll, "audio_scroll_sync_handler")
    qt_set_scroll_area_scroll_handler(timeline_audio_scroll, "audio_scroll_sync_handler")

    -- Set initial splitter sizes: 150px for headers, rest for timeline area
    qt_constants.LAYOUT.SET_SPLITTER_SIZES(main_splitter, {timeline_state.dimensions.track_header_width, 1000})

    -- Set layout on container
    qt_constants.LAYOUT.SET_ON_WIDGET(container, main_layout)

    -- Make main container expand to fill available space
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(container, "Expanding", "Expanding")

    print("Multi-view timeline panel created successfully")

    return container
end

return M
