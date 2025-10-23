-- Minimal pure-Lua XML parser that supports the subset required by the importers.
-- Exposes xml2.parse() returning a document with :root(), and nodes with
-- :name(), :text(), :children(), and :attr() helpers.

local M = {}

local function trim(text)
    return (text:gsub("^%s*", ""):gsub("%s*$", ""))
end

local function wrap_node(node)
    local wrapper = {}

    function wrapper:name()
        return node.tag
    end

    function wrapper:text()
        return trim(node.text or "")
    end

    function wrapper:attr(name)
        if not node.attrs then
            return nil
        end
        return node.attrs[name]
    end

    function wrapper:attributes()
        local copy = {}
        if node.attrs then
            for key, value in pairs(node.attrs) do
                copy[key] = value
            end
        end
        return copy
    end

    function wrapper:children()
        local index = 0
        local children = node.children or {}
        return function()
            index = index + 1
            local child = children[index]
            if child then
                return wrap_node(child)
            end
        end
    end

    return wrapper
end

local function parse_attributes(attr_str)
    local attrs = {}
    for key, quote, value in attr_str:gmatch("([%w:_%-]+)%s*=%s*(['\"])(.-)%2") do
        attrs[key] = value
    end
    return attrs
end

function M.parse(xml_string)
    if type(xml_string) ~= "string" or xml_string == "" then
        return nil, "XML content is empty"
    end

    local root = {tag = "root", attrs = {}, children = {}, text = ""}
    local stack = {root}
    local pos = 1
    local length = #xml_string

    while pos <= length do
        local lt = xml_string:find("<", pos)
        if not lt then
            local remainder = xml_string:sub(pos)
            stack[#stack].text = stack[#stack].text .. remainder
            break
        end

        if lt > pos then
            local text = xml_string:sub(pos, lt - 1)
            stack[#stack].text = stack[#stack].text .. text
        end

        -- Handle comments
        if xml_string:sub(lt + 1, lt + 3) == "!--" then
            local comment_end = xml_string:find("-->", lt + 4, true)
            if not comment_end then
                return nil, "Unterminated XML comment"
            end
            pos = comment_end + 3
        elseif xml_string:sub(lt + 1, lt + 1) == "!" then
            local gt = xml_string:find(">", lt + 1)
            if not gt then
                return nil, "Malformed declaration"
            end
            pos = gt + 1
        elseif xml_string:sub(lt + 1, lt + 1) == "?" then
            local gt = xml_string:find("?>", lt + 1, true)
            if not gt then
                return nil, "Malformed processing instruction"
            end
            pos = gt + 2
        else
            local gt = xml_string:find(">", lt + 1)
            if not gt then
                return nil, "Malformed tag"
            end

            local tag_content = trim(xml_string:sub(lt + 1, gt - 1))
            local self_closing = false
            if tag_content:sub(-1) == "/" then
                self_closing = true
                tag_content = trim(tag_content:sub(1, -2))
            end

            if tag_content:sub(1, 1) == "/" then
                local tag_name = trim(tag_content:sub(2))
                local current = stack[#stack]
                if not current or current.tag ~= tag_name then
                    return nil, string.format("Mismatched closing tag: %s", tag_name)
                end
                table.remove(stack)
            else
                local space_index = tag_content:find("%s")
                local tag_name, attr_str
                if space_index then
                    tag_name = trim(tag_content:sub(1, space_index - 1))
                    attr_str = tag_content:sub(space_index + 1)
                else
                    tag_name = tag_content
                    attr_str = ""
                end

                local attrs = parse_attributes(attr_str or "")
                local element = {tag = tag_name, attrs = attrs, children = {}, text = ""}
                local parent = stack[#stack]
                table.insert(parent.children, element)

                if not self_closing then
                    table.insert(stack, element)
                end
            end

            pos = gt + 1
        end
    end

    if #stack ~= 1 then
        return nil, "Unclosed tags detected"
    end

    if #root.children == 0 then
        return nil, "XML contains no elements"
    end

    local document = {}
    function document:root()
        return wrap_node(root.children[1])
    end

    return document
end

return M
