local M = {}

local function split_camel_case(text)
    if type(text) ~= "string" or text == "" then
        return ""
    end

    local result = {}
    local token = ""
    local last_class = nil

    local function class_of(ch)
        if ch:match("%d") then
            return "digit"
        end
        if ch:match("%u") then
            return "upper"
        end
        if ch:match("%l") then
            return "lower"
        end
        return "other"
    end

    for i = 1, #text do
        local ch = text:sub(i, i)
        local cls = class_of(ch)
        local next_ch = (i < #text) and text:sub(i + 1, i + 1) or ""
        local next_cls = next_ch ~= "" and class_of(next_ch) or nil

        if token == "" then
            token = ch
            last_class = cls
        else
            local boundary = false
            if (last_class ~= cls) then
                boundary = true
            end
            if last_class == "upper" and cls == "upper" and next_cls == "lower" then
                boundary = true
            end
            if boundary then
                table.insert(result, token)
                token = ch
            else
                token = token .. ch
            end
            last_class = cls
        end
    end

    if token ~= "" then
        table.insert(result, token)
    end

    return table.concat(result, " ")
end

local overrides = {
    BatchRippleEdit = "Ripple Edit",
    RippleDeleteSelection = "Ripple Delete",
    ImportFCP7XML = "Import FCP7 XML",
}

function M.label_for_type(command_type)
    local label = overrides[command_type]
    if label then
        return label
    end
    return split_camel_case(command_type)
end

function M.label_for_command(command)
    if not command or not command.type then
        return ""
    end
    return M.label_for_type(command.type)
end

return M

