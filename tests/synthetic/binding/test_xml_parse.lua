--- Tests for qt_xml_parse / qt_xml_parse_string XML parser (C++ QXmlStreamReader).

require("test_env")

print("=== test_xml_parse.lua ===")

-- ===========================================================================
-- TEST 1: Basic element with text
-- ===========================================================================
print("TEST 1: basic element with text")
local root = assert(qt_xml_parse_string("<Name>Hello</Name>"))
assert(root.tag == "Name", "tag mismatch: " .. tostring(root.tag))
assert(root.text == "Hello", "text mismatch: " .. tostring(root.text))
assert(type(root.children) == "table", "children not a table")
assert(#root.children == 0, "expected no children")
assert(type(root.attrs) == "table", "attrs not a table")
print("  PASS")

-- ===========================================================================
-- TEST 2: Nested elements
-- ===========================================================================
print("TEST 2: nested elements")
local xml = [[<Root><Child1>A</Child1><Child2>B</Child2></Root>]]
root = assert(qt_xml_parse_string(xml))
assert(root.tag == "Root")
assert(#root.children == 2)
assert(root.children[1].tag == "Child1")
assert(root.children[1].text == "A")
assert(root.children[2].tag == "Child2")
assert(root.children[2].text == "B")
print("  PASS")

-- ===========================================================================
-- TEST 3: Attributes
-- ===========================================================================
print("TEST 3: attributes")
xml = [[<Clip id="abc" enabled="true">content</Clip>]]
root = assert(qt_xml_parse_string(xml))
assert(root.tag == "Clip")
assert(root.text == "content")
assert(root.attrs.id == "abc", "id attr: " .. tostring(root.attrs.id))
assert(root.attrs.enabled == "true", "enabled attr: " .. tostring(root.attrs.enabled))
print("  PASS")

-- ===========================================================================
-- TEST 4: Self-closing tags
-- ===========================================================================
print("TEST 4: self-closing tags")
xml = [[<Root><Empty/><Also /></Root>]]
root = assert(qt_xml_parse_string(xml))
assert(#root.children == 2)
assert(root.children[1].tag == "Empty")
assert(root.children[1].text == "")
assert(root.children[2].tag == "Also")
print("  PASS")

-- ===========================================================================
-- TEST 5: Whitespace trimming
-- ===========================================================================
print("TEST 5: whitespace trimming")
xml = [[<Name>  hello world  </Name>]]
root = assert(qt_xml_parse_string(xml))
assert(root.text == "hello world", "expected trimmed text, got: '" .. root.text .. "'")
print("  PASS")

-- ===========================================================================
-- TEST 6: Deep nesting (DRP-style structure)
-- ===========================================================================
print("TEST 6: deep nesting (DRP-style)")
xml = [[
<Sm2TiTrack>
  <Items>
    <Element>
      <Sm2TiVideoClip>
        <Name>Test Clip</Name>
        <Duration>100</Duration>
      </Sm2TiVideoClip>
    </Element>
  </Items>
</Sm2TiTrack>
]]
root = assert(qt_xml_parse_string(xml))
assert(root.tag == "Sm2TiTrack")
local items = root.children[1]
assert(items.tag == "Items")
local element = items.children[1]
assert(element.tag == "Element")
local clip = element.children[1]
assert(clip.tag == "Sm2TiVideoClip")
assert(#clip.children == 2)
assert(clip.children[1].tag == "Name")
assert(clip.children[1].text == "Test Clip")
assert(clip.children[2].tag == "Duration")
assert(clip.children[2].text == "100")
print("  PASS")

-- ===========================================================================
-- TEST 7: XML declaration is skipped
-- ===========================================================================
print("TEST 7: XML declaration skipped")
xml = [[<?xml version="1.0" encoding="UTF-8"?><Root>data</Root>]]
root = assert(qt_xml_parse_string(xml))
assert(root.tag == "Root")
assert(root.text == "data")
print("  PASS")

-- ===========================================================================
-- TEST 8: Comments are skipped
-- ===========================================================================
print("TEST 8: comments skipped")
xml = [[<Root><!-- comment --><Child>val</Child></Root>]]
root = assert(qt_xml_parse_string(xml))
assert(root.tag == "Root")
assert(#root.children == 1)
assert(root.children[1].tag == "Child")
assert(root.children[1].text == "val")
print("  PASS")

-- ===========================================================================
-- TEST 9: Error — empty string
-- ===========================================================================
print("TEST 9: error on empty string")
local result, err = qt_xml_parse_string("")
assert(result == nil, "expected nil for empty")
assert(err and err ~= "", "expected error message, got: " .. tostring(err))
print("  PASS")

-- ===========================================================================
-- TEST 10: Error — malformed XML
-- ===========================================================================
print("TEST 10: error on malformed XML")
result, err = qt_xml_parse_string("<Root><Unclosed>")
assert(result == nil, "expected nil for malformed")
assert(err and err ~= "", "expected error message, got: " .. tostring(err))
print("  PASS")

-- ===========================================================================
-- TEST 11: File-based parse (qt_xml_parse)
-- ===========================================================================
print("TEST 11: file-based parse")
local test_file = "/tmp/jve/test_xml_parse_temp.xml"
local f = assert(io.open(test_file, "w"))
f:write([[<Root attr="val"><Item>text</Item></Root>]])
f:close()

root = assert(qt_xml_parse(test_file))
assert(root.tag == "Root")
assert(root.attrs.attr == "val")
assert(#root.children == 1)
assert(root.children[1].tag == "Item")
assert(root.children[1].text == "text")
os.remove(test_file)
print("  PASS")

-- ===========================================================================
-- TEST 12: File not found
-- ===========================================================================
print("TEST 12: error on file not found")
result, err = qt_xml_parse("/tmp/jve/nonexistent_xml_file.xml")
assert(result == nil, "expected nil for missing file")
assert(err and err ~= "", "expected error message")
print("  PASS")

-- ===========================================================================
-- TEST 13: Empty attrs table always present
-- ===========================================================================
print("TEST 13: empty attrs table present")
root = assert(qt_xml_parse_string("<Simple>text</Simple>"))
assert(type(root.attrs) == "table", "attrs should be a table")
print("  PASS")

-- ===========================================================================
-- TEST 14: Attribute with special chars (hyphen, colon)
-- ===========================================================================
print("TEST 14: attribute names with hyphens/colons")
xml = [[<Node data-id="123" xml:lang="en">x</Node>]]
root = assert(qt_xml_parse_string(xml))
assert(root.attrs["data-id"] == "123", "hyphen attr: " .. tostring(root.attrs["data-id"]))
assert(root.attrs["xml:lang"] == "en", "colon attr: " .. tostring(root.attrs["xml:lang"]))
print("  PASS")

print("✅ test_xml_parse.lua passed")
