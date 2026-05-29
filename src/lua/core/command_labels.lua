--- Human-readable labels and parameter summaries for commands.
--
-- Responsibilities:
-- - Convert CamelCase command types to spaced labels
-- - Extract user-meaningful parameter summaries for history display
--
-- @file command_labels.lua
local M = {}

local function split_camel_case(text)
    if type(text) ~= "string" or text == "" then
        return ""
    end

    local spaced = text
    spaced = spaced:gsub("(%l)(%u)", "%1 %2")        -- "fooBar" -> "foo Bar"
    spaced = spaced:gsub("(%u)(%u%l)", "%1 %2")      -- "FCP7XML" -> "FCP7 XML"
    spaced = spaced:gsub("(%d)(%a)", "%1 %2")        -- "7XML" -> "7 XML"
    spaced = spaced:gsub("(%a)(%d)", "%1 %2")        -- "XML7" -> "XML 7"
    spaced = spaced:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return spaced
end

local overrides = {
    AddClipsToSequence = "Add Clips",
    BatchRippleEdit = "Ripple Edit",
    RippleDeleteSelection = "Ripple Delete",
    ImportFCP7XML = "Import FCP7 XML",
    ImportResolveProject = "Import Resolve Project",
    ImportResolveTimeline = "Import Resolve Timeline",
    ImportResolveDatabase = "Import Resolve Database",
    ImportPremiereProject = "Import Premiere Project",
    SetMarkIn = "Set Mark In",
    SetMarkOut = "Set Mark Out",
    SetMark = "Set Mark",
    ClearMarks = "Clear Marks",
    DeleteMasterClip = "Delete Master Clip",
    ReplaceAllClipProperties = "Replace All",
    ReplaceClipProperty = "Replace",
    SetClipProperty = "Set Property",
    ToggleClipEnabled = "Toggle Enabled",
    DuplicateMasterClip = "Duplicate Master Clip",
    DuplicateClips = "Duplicate Clips",
    MoveClipToTrack = "Move to Track",
    GoToStart = "Go to Start",
    GoToEnd = "Go to End",
    GoToNextEdit = "Go to Next Edit",
    GoToPrevEdit = "Go to Previous Edit",
    SetPlayhead = "Set Playhead",
    TrimHead = "Trim Head",
    TrimTail = "Trim Tail",
    SplitClip = "Split Clip",
    ExtractRange = "Extract Range",
    LiftRange = "Lift Range",
    InsertGap = "Insert Gap",
    LinkClips = "Link Clips",
}

function M.label_for_type(command_type)
    local label = overrides[command_type]
    if label then
        return label
    end
    return split_camel_case(command_type)
end

--- Extract a short filename from a path.
local function basename(path)
    if type(path) ~= "string" then return nil end
    return path:match("([^/]+)$") or path
end

--- Extract user-meaningful detail string from command parameters.
-- Returns nil if no useful detail can be extracted.
-- @param command_type string
-- @param params table: command parameters (decoded JSON)
-- @return string|nil
function M.detail_for_params(command_type, params)
    if not params or type(params) ~= "table" then return nil end

    if command_type == "RenameItem" then
        local prev = params.previous_name
        local new = params.final_name or params.new_name
        if prev and new then return prev .. " → " .. new end
        if new then return "→ " .. new end

    elseif command_type == "ImportMedia" then
        local paths = params.file_paths
        if type(paths) == "table" and #paths > 0 then
            local first = basename(paths[1])
            if #paths == 1 then return first end
            return first .. " + " .. (#paths - 1) .. " more"
        end

    elseif command_type == "ImportResolveProject" then
        local name = params.source_name
        local path = params.drp_path
        if name then return name end
        if path then return basename(path) end

    elseif command_type == "ImportPremiereProject" then
        local name = params.source_name
        local path = params.prproj_path
        if name then return name end
        if path then return basename(path) end

    elseif command_type == "ImportResolveTimeline" then
        local path = params.drt_path
        if path then return basename(path) end

    elseif command_type == "ImportResolveDatabase" then
        local path = params.db_path
        if path then return basename(path) end

    elseif command_type == "DeleteMasterClip" then
        local snap = params.master_clip_snapshot
        if type(snap) == "table" and type(snap.sequence) == "table" then
            return snap.sequence.name
        end

    elseif command_type == "DeleteSequence" then
        local snap = params.sequence_snapshot
        if type(snap) == "table" and type(snap.sequence) == "table" then
            return snap.sequence.name
        end

    elseif command_type == "SetMark" then
        local which = params._which or (params._positional and params._positional[1])
        if which then return which end

    elseif command_type == "SetMarkIn" or command_type == "SetMarkOut" then
        return nil  -- type name is sufficient

    elseif command_type == "Overwrite" or command_type == "Insert" then
        local clip_name = params.clip_name
        if clip_name then return clip_name end

    elseif command_type == "SplitClip" then
        local clip_name = params.clip_name or params.clip_id
        if clip_name then
            -- Truncate UUID to 8 chars
            if #clip_name > 20 then clip_name = clip_name:sub(1, 8) .. "…" end
            return clip_name
        end

    elseif command_type == "ReplaceAllClipProperties"
        or command_type == "ReplaceClipProperty" then
        local field = params.field
        local find = params.find_text or params.find
        local replace = params.replace_text or params.replace
        if field and find and replace then
            return field .. ": " .. find .. " → " .. replace
        elseif find and replace then
            return find .. " → " .. replace
        end

    elseif command_type == "SetClipProperty" then
        -- SetClipProperty stores the field as params.property_name (per its
        -- SPEC); prior lookups for params.field / params.property always
        -- returned nil so history just showed "Set Property" with no detail.
        local field = params.property_name or params.field or params.property
        -- Explicit nil-check: a legitimate BOOLEAN `false` value must render,
        -- not get dropped by `or`.
        local value = params.value
        if value == nil then value = params.new_value end
        if field and value ~= nil then return field .. " = " .. tostring(value) end

    elseif command_type == "DeleteClip" then
        local name = params.clip_name
        if name then return name end

    elseif command_type == "Nudge" then
        local delta = params.delta or params.frames
        if delta then return tostring(delta) .. " frames" end

    elseif command_type == "AddTrack" then
        local track_type = params.track_type
        local name = params.name
        if name then return name end
        if track_type then return track_type end

    elseif command_type == "RelinkClips" then
        local count = params.clip_ids and #params.clip_ids
        if count then return count .. " clip" .. (count == 1 and "" or "s") end
    end

    return nil
end

function M.label_for_command(command)
    if not command or not command.type then
        return ""
    end
    local base = M.label_for_type(command.type)
    local detail = M.detail_for_params(command.type, command.parameters)
    if detail then
        return base .. " — " .. detail
    end
    return base
end

return M
