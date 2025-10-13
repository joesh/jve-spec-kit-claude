-- DaVinci Resolve Keyboard Binding Importer
-- Parses Resolve's keyboard.preset.xml files (proprietary binary format)
-- File location: ~/Library/Preferences/Blackmagic Design/DaVinci Resolve/keyboard.preset.xml
--
-- Binary Format Structure (UTF-16 BE encoded):
-- [Header: 12 bytes] [Length: 4B] [Preset Name: UTF-16] [Metadata: 8B]
-- Then repeating: [Length: 4B] [Command: UTF-16] [Count: 4B] [Shortcuts...]

local M = {}

--- Read 32-bit big-endian integer from hex string
-- @param hex_str string 8-character hex string representing 4 bytes
-- @param pos number Starting position (1-indexed)
-- @return number Integer value
local function read_be_int32(hex_str, pos)
    if pos + 7 > #hex_str then return 0 end
    return tonumber(hex_str:sub(pos, pos + 7), 16) or 0
end

--- Extract UTF-16 BE null-terminated string from hex
-- @param blob_hex string Full hex blob
-- @param start_pos number Starting position (1-indexed)
-- @return string Decoded string
-- @return number New position after null terminator
local function extract_utf16_string(blob_hex, start_pos)
    local chars = {}
    local pos = start_pos

    while pos + 3 <= #blob_hex do
        local high_byte = tonumber(blob_hex:sub(pos, pos + 1), 16)
        local low_byte = tonumber(blob_hex:sub(pos + 2, pos + 3), 16)

        if not high_byte or not low_byte then
            break
        end

        local codepoint = high_byte * 256 + low_byte

        if codepoint == 0 then
            -- Null terminator
            return table.concat(chars), pos + 4
        end

        if codepoint < 128 then
            table.insert(chars, string.char(codepoint))
        else
            table.insert(chars, "?")  -- Non-ASCII placeholder
        end

        pos = pos + 4  -- Each UTF-16 char = 4 hex digits
    end

    return table.concat(chars), pos
end

--- Clean up Resolve command name
-- Removes context prefixes: "Viewer..Context_modifyMarker" → "modifyMarker"
-- @param raw_name string Raw command name from binary
-- @return string Cleaned command name
local function clean_command_name(raw_name)
    -- Remove context prefix patterns
    local cleaned = raw_name:match("Context_(.+)$") or raw_name
    cleaned = cleaned:match("fuHotkey_(.+)$") or cleaned
    cleaned = cleaned:match("%.%.(.+)$") or cleaned

    -- Extract camelCase command (last word if multiple)
    cleaned = cleaned:match("([a-z][a-zA-Z0-9]+)$") or cleaned

    return cleaned
end

--- Map Resolve command names to JVE command names
-- @param resolve_cmd string Resolve internal command name (cleaned)
-- @return string|nil JVE command name, or nil if no mapping exists
local function map_resolve_command(resolve_cmd)
    local mappings = {
        -- Editing commands
        editUndo = "Undo",
        editRedo = "Redo",
        editCut = "Cut",
        editCopy = "Copy",
        editPaste = "Paste",
        editDelete = "Delete",
        editSelectAll = "SelectAll",
        editDeselectAll = "DeselectAll",
        editDuplicate = "Duplicate",
        editDuplicateTimelineOrClips = "Duplicate",
        editSelectClipsSelectAll = "SelectAll",
        editSelectClipsSelectAllBefore = "SelectAllBefore",
        editSelectClipsSelectAllAfter = "SelectAllAfter",
        editSelectSubBelow = "SelectTrackBelow",
        editSelectSubAbove = "SelectTrackAbove",
        editRippleCut = "RippleCut",
        editRippleDelete = "RippleDelete",
        editBlade = "Blade",
        editBladeRazor = "RazorBlade",
        editTrim = "Trim",
        editSnapping = "ToggleSnapping",

        -- Playback commands
        controlPlay = "Play",
        controlPlayToggle = "PlayToggle",
        controlPlayForward = "PlayForward",
        controlPlayReverse = "PlayReverse",
        controlPlaySlow = "PlaySlow",
        controlStop = "Stop",
        controlGapPrev = "PreviousGap",
        controlGapNext = "NextGap",

        -- Timeline navigation
        controlTimecode = "GoToTimecode",
        controlTimecodeEnd = "GoToEnd",
        controlTimecodeStart = "GoToStart",
        controlMarkersNext = "NextMarker",
        controlMarkersPrev = "PreviousMarker",
        controlLargeStepForward = "LargeStepForward",
        controlLargeStepBackward = "LargeStepBackward",
        controlFastReverse = "FastReverse",

        -- Mark commands
        markIn = "MarkIn",
        markOut = "MarkOut",
        markClip = "MarkClip",
        markResetInOut = "ClearInOut",
        markFlagAdd = "AddFlag",
        modifyMarker = "ModifyMarker",

        -- Clip operations
        clipRetimeControls = "RetimeControls",
        clipChangeClipSpeed = "ChangeClipSpeed",
        clipAudioIncreaseAudioLevel1dB = "IncreaseAudioLevel",

        -- Track operations
        editTrackLockToggleV = "ToggleLockVideoTrack",
        editTrackLockToggleA = "ToggleLockAudioTrack",
        editTrackLockToggleV1 = "ToggleLockV1",
        editTrackLockToggleV2 = "ToggleLockV2",
        editTrackLockToggleV3 = "ToggleLockV3",
        editAutoSelectToggleVideoAll = "ToggleAutoSelectAllVideo",
        editAutoSelectToggleAudioAll = "ToggleAutoSelectAllAudio",
        editEnableDisableToggleVideoTrackAll = "ToggleEnableAllVideo",
        editMoveClipsDown = "MoveClipsDown",
        editMoveClipsUp = "MoveClipsUp",

        -- Trim operations
        trimRippleStartToPlayhead = "RippleTrimStartToPlayhead",
        trimFadeOutToPlayhead = "FadeOutToPlayhead",
        trimSelectAudioEditPoint = "SelectAudioEditPoint",
        trimSelectVideoEditPoint = "SelectVideoEditPoint",
        trimMoveEditSelectionToNextEdit = "NextEditPoint",
        trimMoveEditSelectionToPreviousEdit = "PreviousEditPoint",

        -- Insert/Overwrite
        editInsertOverwriteActionInsert = "Insert",
        editInsertOverwriteActionReplace = "Replace",
        editInsertOverwriteActionRippleOverwrite = "RippleOverwrite",

        -- Nudge operations
        editNudgeTrimStepExtendEdit = "NudgeTrimExtend",
        editNudgeTrimStepTrimMultiFrameLeft = "NudgeTrimLeft",
        editNudgeTrimStepNudgeForward = "NudgeForward",
        editNudgeTrimStepNudgeBackward = "NudgeBackward",
        editNudgeSwapEditForward = "SwapEditForward",
        editNudgeSwapEditReverse = "SwapEditBackward",

        -- Slip/Slide
        editSlipAudioOneFrameForward = "SlipAudioForward",
        editSlipAudioOneFrameReverse = "SlipAudioBackward",
        editSlipEyeOppositeEyeOneFrameForward = "SlipEyeForward",

        -- View commands
        viewZoomIn = "ZoomIn",
        viewZoomOut = "ZoomOut",
        viewZoomToFit = "ZoomToFit",
        viewZoomSubZoomToFit = "ZoomToFit",
        viewZoomSubZoomOut = "ZoomOut",
        viewSafeAreaToggle = "ToggleSafeArea",
        viewShowViewerOverlay = "ShowViewerOverlay",
        viewReferenceWipeStyleCycle = "CycleWipeStyle",
        viewReferenceWipeModeCycle = "CycleWipeMode",
        viewReferenceWipeInvert = "InvertWipe",
        viewStillsStillNext = "NextStill",
        viewWindowOutlineCycle = "CycleOutline",
        viewStereoSwitchEyeCycle = "CycleStereoEye",
        viewToggleSourceTimeline = "ToggleSourceTimeline",

        -- Workspace/View
        workspacePrimaryWorkspaceColor = "WorkspaceColor",
        workspacePrimaryWorkspaceEdit = "WorkspaceEdit",
        workspacePrimaryWorkspaceMedia = "WorkspaceMedia",
        workspacePrimaryWorkspaceDeliver = "WorkspaceDeliver",
        workspaceRemoteGrading = "RemoteGrading",
        workspaceVideoScopesToggle = "ToggleVideoScopes",

        -- File operations
        fileImportProject = "ImportProject",
        fileSave = "SaveProject",
        fileExport = "ExportProject",
        fileImportMedia = "ImportMedia",
        fileEasyDCPExportSignerCertificate = "ExportDCP",
        fileReconformFromMediaStorage = "Reconform",
        resolveQuit = "Quit",

        -- Media Pool
        MediaPool = "MediaPool",
        clipAttributes = "ClipAttributes",
        setPosterFrame = "SetPosterFrame",
        clearPosterFrame = "ClearPosterFrame",

        -- Nodes (Color/Fusion)
        nodesAddSerial = "AddSerialNode",
        nodesAddPCW = "AddParallelNode",
        nodesNext = "NextNode",
        nodesPrevious = "PreviousNode",

        -- Session/Grading
        sessionGrabLiveGradeFrame = "GrabGradeFrame",
        sessionGradeFromTwoClipsPrior = "GradeFromPrior",
        sessionPrinterLightsYelMinus = "PrinterLightsYelMinus",
        sessionPrinterLightsCyanMinus = "PrinterLightsCyanMinus",
        sessionPrinterLightsBlueMinus = "PrinterLightsBlueMinus",
        sessionPrinterLightsMasterMinus = "PrinterLightsMasterMinus",
        sessionPrinterLightsBlueQuarterPlus = "PrinterLightsBlueQuarterPlus",

        -- Fairlight (Audio)
        FairlightTimeline = "FairlightTimeline",
        viewTrackWaveformResetZoomAllTracks = "ResetAudioZoom",
        trimExtendEditSelectionToNextTrack = "ExtendEditToNextTrack",
        trimMoveEditSelectionToPreviousEdit = "PreviousAudioEdit",
        trimTrimToSelection = "TrimToSelection",
        ClipAttributes = "ClipAttributes",
        addTransition = "AddTransition",

        -- Viewer/Context
        Viewer = "Viewer",
        modifyMarker = "ModifyMarker",
        nextClipOrTimeline = "NextClip",
        toggleMarkerOverlayShowMarker = "ToggleMarkerOverlay",
        toggleMarkerOverlayShowDuringPlayback = "ToggleMarkerDuringPlayback",
        toggleMarkerOverlayShowTimecode = "ToggleMarkerTimecode",

        -- Fusion Widget
        FusionWidget = "FusionWidget"
    }

    return mappings[resolve_cmd]
end

--- Parse keyboard shortcut from binary representation
-- Resolve stores shortcuts as 32-bit integers with modifier flags
-- @param shortcut_int number Integer encoding of shortcut
-- @return string|nil Human-readable shortcut (e.g. "Cmd+Shift+K")
local function parse_shortcut(shortcut_int)
    if not shortcut_int or shortcut_int == 0 then
        return nil
    end

    -- Modifier bit flags (observed from testing)
    local META = 0x100000   -- Cmd/Win key
    local SHIFT = 0x020000
    local ALT = 0x080000
    local CTRL = 0x040000

    local modifiers = {}
    local key_code = shortcut_int

    -- Extract modifiers (order matters for consistent display)
    if key_code >= META then
        table.insert(modifiers, "Cmd")
        key_code = key_code - META
    end
    if key_code >= ALT then
        table.insert(modifiers, "Alt")
        key_code = key_code - ALT
    end
    if key_code >= CTRL then
        table.insert(modifiers, "Ctrl")
        key_code = key_code - CTRL
    end
    if key_code >= SHIFT then
        table.insert(modifiers, "Shift")
        key_code = key_code - SHIFT
    end

    -- Map key codes to key names
    local key_name
    if key_code >= 32 and key_code <= 126 then
        -- Printable ASCII
        key_name = string.char(key_code)
    else
        -- Special keys (Qt key codes)
        local special_keys = {
            [0x01000000] = "Escape",
            [0x01000001] = "Tab",
            [0x01000003] = "Backspace",
            [0x01000004] = "Enter",
            [0x01000005] = "Enter",
            [0x01000006] = "Insert",
            [0x01000007] = "Delete",
            [0x01000010] = "Home",
            [0x01000011] = "End",
            [0x01000012] = "Left",
            [0x01000013] = "Up",
            [0x01000014] = "Right",
            [0x01000015] = "Down",
            [0x01000016] = "PageUp",
            [0x01000017] = "PageDown",
            [0x20] = "Space",
            [0x01] = "Enter",
            [0x03] = "Enter",
            [0x09] = "Tab",
            [0x7F] = "Delete",
            [0x08] = "Backspace",
            [0x0D] = "Enter",
            [0x20] = "Space",
            [0x1B] = "Escape"
        }
        key_name = special_keys[key_code]

        -- Function keys (F1-F12)
        if not key_name and key_code >= 0x01000030 and key_code <= 0x0100003B then
            key_name = string.format("F%d", key_code - 0x01000030 + 1)
        end

        if not key_name then
            key_name = string.format("Key%d", key_code)
        end
    end

    -- Build shortcut string
    if #modifiers > 0 then
        return table.concat(modifiers, "+") .. "+" .. key_name
    else
        return key_name
    end
end

--- Parse binary blob containing keyboard shortcuts
-- @param blob_hex string Hex-encoded binary data from PresetListBA
-- @return table Array of {resolve_command, shortcut, jve_command} tables
local function parse_preset_blob(blob_hex)
    local shortcuts = {}
    local pos = 1

    -- Skip header (12 bytes = 24 hex chars)
    pos = pos + 24

    -- Read preset name length (4 bytes big-endian)
    local name_length = read_be_int32(blob_hex, pos)
    pos = pos + 8

    -- Extract preset name (UTF-16 BE, null-terminated)
    local preset_name, name_end_pos = extract_utf16_string(blob_hex, pos)
    pos = name_end_pos

    -- Skip metadata bytes (varies, scan for next length field)
    -- Look for pattern: reasonable length value (< 1000) followed by UTF-16 string
    local scan_limit = math.min(pos + 100, #blob_hex - 8)
    for scan_pos = pos, scan_limit, 8 do
        local test_length = read_be_int32(blob_hex, scan_pos)
        if test_length > 0 and test_length < 500 then
            -- Check if followed by valid UTF-16 (0x00 followed by printable ASCII)
            local test_pos = scan_pos + 8
            if test_pos + 3 <= #blob_hex then
                local high = tonumber(blob_hex:sub(test_pos, test_pos + 1), 16)
                local low = tonumber(blob_hex:sub(test_pos + 2, test_pos + 3), 16)
                if high == 0 and low >= 32 and low < 127 then
                    pos = scan_pos
                    break
                end
            end
        end
    end

    -- Parse command entries
    local max_entries = 2000
    local entry_count = 0

    while pos + 8 <= #blob_hex and entry_count < max_entries do
        entry_count = entry_count + 1

        -- Read command name length (4 bytes)
        local cmd_length = read_be_int32(blob_hex, pos)
        pos = pos + 8

        if cmd_length == 0 or cmd_length > 1000 then
            -- End of data or invalid - try to skip forward
            if entry_count < 3 then
                -- Early in parsing, might just be metadata - skip ahead
                pos = pos + 8
                if pos > #blob_hex then break end
            else
                break
            end
        else
            -- Extract command name (UTF-16 BE)
            local raw_command_name, cmd_end_pos = extract_utf16_string(blob_hex, pos)
            local command_name = clean_command_name(raw_command_name)
            pos = cmd_end_pos

            -- Read shortcut count
            if pos + 8 > #blob_hex then break end
            local shortcut_count = read_be_int32(blob_hex, pos)
            pos = pos + 8

            -- Read shortcuts (max 10 per command)
            if shortcut_count > 0 and shortcut_count <= 10 then
                for i = 1, shortcut_count do
                    if pos + 16 > #blob_hex then break end

                    -- Read shortcut integer (4 bytes)
                    local shortcut_int = read_be_int32(blob_hex, pos)
                    pos = pos + 8

                    -- Skip metadata (4 bytes)
                    pos = pos + 8

                    if shortcut_int > 0 then
                        local shortcut_str = parse_shortcut(shortcut_int)
                        if shortcut_str and not shortcut_str:match("^Key%d+$") then
                            table.insert(shortcuts, {
                                resolve_command = command_name,
                                raw_command = raw_command_name,
                                shortcut = shortcut_str,
                                jve_command = map_resolve_command(command_name)
                            })
                        end
                    end
                end
            end
        end
    end

    return shortcuts
end

--- Parse Resolve keyboard.preset.xml file
-- @param file_path string Path to keyboard.preset.xml
-- @return table|nil Array of keyboard shortcuts, or nil on error
-- @return string|nil Error message
function M.parse_file(file_path)
    local file = io.open(file_path, "r")
    if not file then
        return nil, "Failed to open file: " .. file_path
    end

    local content = file:read("*a")
    file:close()

    -- Extract PresetListBA blob
    local blob_start = content:find("<PresetListBA>")
    local blob_end = content:find("</PresetListBA>")

    if not blob_start or not blob_end then
        return nil, "Invalid Resolve keyboard preset file - missing PresetListBA tag"
    end

    local blob_hex = content:sub(blob_start + 14, blob_end - 1)

    -- Parse shortcuts
    local shortcuts = parse_preset_blob(blob_hex)

    if #shortcuts == 0 then
        return nil, "No keyboard shortcuts found in preset file"
    end

    return shortcuts, nil
end

--- Import Resolve keyboard bindings into JVE shortcut registry
-- @param file_path string Path to keyboard.preset.xml
-- @param registry table Keyboard shortcut registry module
-- @return number Count of successfully imported shortcuts
-- @return number Count of unmapped shortcuts
-- @return string|nil Error message
function M.import_to_registry(file_path, registry)
    local shortcuts, err = M.parse_file(file_path)
    if not shortcuts then
        return 0, 0, err
    end

    local imported_count = 0
    local unmapped_count = 0

    for _, entry in ipairs(shortcuts) do
        if entry.jve_command then
            local success = registry.assign_shortcut(entry.jve_command, entry.shortcut)
            if success then
                imported_count = imported_count + 1
            end
        else
            unmapped_count = unmapped_count + 1
            if M.debug then
                print(string.format("Unmapped: %s (%s) → %s",
                    entry.resolve_command, entry.raw_command, entry.shortcut))
            end
        end
    end

    return imported_count, unmapped_count, nil
end

-- Debug flag
M.debug = false

return M
