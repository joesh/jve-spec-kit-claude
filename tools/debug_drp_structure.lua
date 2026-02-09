#!/usr/bin/env luajit
--- Debug script to examine .drp file structure
-- Usage: luajit debug_drp_structure.lua /path/to/file.drp

package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua"

local xml2 = require("xml2")

local function extract_drp(drp_path)
    local tmp_dir = os.tmpname()
    os.remove(tmp_dir)
    os.execute("mkdir -p " .. tmp_dir)
    local cmd = string.format('unzip -q "%s" -d "%s"', drp_path, tmp_dir)
    local result = os.execute(cmd)
    if result ~= 0 then
        return nil, "Failed to extract .drp archive"
    end
    return tmp_dir
end

local function print_tree(node, indent, max_depth)
    indent = indent or 0
    max_depth = max_depth or 4
    if indent > max_depth then return end

    local prefix = string.rep("  ", indent)

    if node.tag then
        local attrs_str = ""
        if node.attrs then
            for k, v in pairs(node.attrs) do
                attrs_str = attrs_str .. string.format(' %s="%s"', k, tostring(v):sub(1,30))
            end
        end

        local text_preview = ""
        if node.text and node.text:match("%S") then
            text_preview = " = \"" .. node.text:gsub("%s+", " "):sub(1, 50) .. "\""
        end

        print(string.format("%s<%s%s>%s", prefix, node.tag, attrs_str, text_preview))

        if node.children then
            for _, child in ipairs(node.children) do
                print_tree(child, indent + 1, max_depth)
            end
        end
    end
end

local function convert_node(node)
    if not node then return nil end
    local element = {
        tag = node:name(),
        attrs = node:attributes(),
        children = {},
        text = node:text() or ""
    }
    for child in node:children() do
        local converted = convert_node(child)
        if converted then
            table.insert(element.children, converted)
        end
    end
    return element
end

local function parse_xml_file(path)
    local file = io.open(path, "r")
    if not file then return nil end
    local content = file:read("*all")
    file:close()
    local doc = xml2.parse(content)
    if not doc then return nil end
    return convert_node(doc:root())
end

-- Main
local drp_path = arg[1]
if not drp_path then
    print("Usage: luajit debug_drp_structure.lua /path/to/file.drp")
    os.exit(1)
end

print("Extracting: " .. drp_path)
local tmp_dir = extract_drp(drp_path)
if not tmp_dir then
    print("Failed to extract")
    os.exit(1)
end

print("\n=== ARCHIVE CONTENTS ===")
os.execute("find " .. tmp_dir .. " -type f -name '*.xml' | head -20")

print("\n=== PROJECT.XML STRUCTURE (depth=3) ===")
local project_xml = parse_xml_file(tmp_dir .. "/project.xml")
if project_xml then
    print_tree(project_xml, 0, 3)
else
    print("No project.xml found")
end

print("\n=== FIRST SEQUENCE XML STRUCTURE (depth=4) ===")
local seq_files = io.popen("ls " .. tmp_dir .. "/SeqContainer/*.xml 2>/dev/null | head -1")
if seq_files then
    local first_seq = seq_files:read("*l")
    seq_files:close()
    if first_seq then
        print("File: " .. first_seq)
        local seq_xml = parse_xml_file(first_seq)
        if seq_xml then
            print_tree(seq_xml, 0, 4)
        end
    else
        print("No sequence files found in SeqContainer/")
        -- Try alternative locations
        print("\nLooking for sequence-like XML files...")
        os.execute("find " .. tmp_dir .. " -name '*.xml' -exec grep -l 'Sequence\\|Timeline\\|Track' {} \\; 2>/dev/null | head -5")
    end
end

print("\n=== MEDIAPOOL STRUCTURE (depth=3) ===")
local mp_xml = parse_xml_file(tmp_dir .. "/MediaPool/Master/MpFolder.xml")
if mp_xml then
    print_tree(mp_xml, 0, 3)
else
    print("No MediaPool/Master/MpFolder.xml found")
    print("Looking for MediaPool...")
    os.execute("find " .. tmp_dir .. " -path '*MediaPool*' -name '*.xml' 2>/dev/null | head -5")
end

-- Cleanup
os.execute("rm -rf " .. tmp_dir)
print("\n=== DONE ===")
