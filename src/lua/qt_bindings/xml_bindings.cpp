#include "binding_macros.h"
#include <QXmlStreamReader>
#include <QFile>
#include <string>

// ---------------------------------------------------------------------------
// General-purpose XML → Lua table parser using QXmlStreamReader.
//
// Returns {tag, text, attrs, children} table tree — same structure that
// drp_importer and fcp7_xml_importer consume. Replaces the pure-Lua xml2.lua
// parser (char-by-char string.find/string.sub, O(n²) concatenation, millions
// of GC-traced tables). QXmlStreamReader scans in compiled C++ and we build
// Lua tables via the C API, bypassing Lua string interning overhead.
//
// Two entry points:
//   qt_xml_parse(path)    — opens file, parses, returns root table
//   qt_xml_parse_string(s) — parses from Lua string
// ---------------------------------------------------------------------------

// Forward declaration
static bool parse_element(lua_State* L, QXmlStreamReader& reader);

// Parse a single XML element (current token must be StartElement).
// Pushes one Lua table onto the stack.
// Returns false on error (error message already on stack).
static bool parse_element(lua_State* L, QXmlStreamReader& reader)
{
    // Current token is StartElement
    // Use qualifiedName() to preserve namespace prefixes (e.g. "xml:lang")
    QByteArray tagUtf8 = reader.qualifiedName().toUtf8();

    // Create element table: {tag, text, attrs, children}
    lua_newtable(L);  // element table

    // tag
    lua_pushlstring(L, tagUtf8.constData(), tagUtf8.size());
    lua_setfield(L, -2, "tag");

    // attrs
    QXmlStreamAttributes xmlAttrs = reader.attributes();
    if (!xmlAttrs.isEmpty()) {
        lua_newtable(L);  // attrs table
        for (int i = 0; i < xmlAttrs.size(); ++i) {
            QByteArray key = xmlAttrs[i].qualifiedName().toUtf8();
            QByteArray val = xmlAttrs[i].value().toUtf8();
            lua_pushlstring(L, val.constData(), val.size());
            lua_setfield(L, -2, key.constData());
        }
        lua_setfield(L, -2, "attrs");
    } else {
        lua_newtable(L);
        lua_setfield(L, -2, "attrs");
    }

    // children array — will be populated as we encounter child StartElements
    lua_newtable(L);  // children table
    int children_idx = lua_gettop(L);
    int child_count = 0;

    // Accumulate text content (may arrive in multiple Characters tokens)
    std::string text_accum;

    // Parse contents until matching EndElement
    while (!reader.atEnd()) {
        reader.readNext();

        switch (reader.tokenType()) {
        case QXmlStreamReader::StartElement: {
            // Recurse: parse child element
            if (!parse_element(L, reader)) {
                // Error — child pushed error string, propagate
                // Stack: ... element_table children_table error_string
                // Clean up: remove children table and element table
                lua_remove(L, children_idx);       // remove children
                lua_remove(L, children_idx - 1);   // remove element
                return false;
            }
            // Child table is on top of stack, insert into children array
            child_count++;
            lua_rawseti(L, children_idx, child_count);
            break;
        }
        case QXmlStreamReader::Characters:
        case QXmlStreamReader::EntityReference: {
            auto textView = reader.text();
            if (!textView.isEmpty()) {
                QByteArray textUtf8 = textView.toUtf8();
                text_accum.append(textUtf8.constData(), textUtf8.size());
            }
            break;
        }
        case QXmlStreamReader::EndElement: {
            // Set children on element table
            lua_setfield(L, children_idx - 1, "children");

            // Trim and set text
            // Trim leading whitespace
            size_t start = text_accum.find_first_not_of(" \t\n\r");
            if (start == std::string::npos) {
                // All whitespace or empty
                lua_pushliteral(L, "");
            } else {
                size_t end = text_accum.find_last_not_of(" \t\n\r");
                size_t len = end - start + 1;
                lua_pushlstring(L, text_accum.data() + start, len);
            }
            lua_setfield(L, -2, "text");
            return true;
        }
        case QXmlStreamReader::Comment:
        case QXmlStreamReader::DTD:
        case QXmlStreamReader::ProcessingInstruction:
            // Skip
            break;
        default:
            break;
        }
    }

    // If we get here, XML ended without closing tag
    lua_pop(L, 1);  // pop children table
    lua_pop(L, 1);  // pop element table
    lua_pushstring(L, reader.errorString().toUtf8().constData());
    return false;
}

// Sanitize XML content for QXmlStreamReader.
// DRP files use C++ namespace-style tag names (e.g. "ListMgt::LmPowerNodeList")
// which contain "::" — invalid in XML names. Replace "::" with "__" in tag
// positions only (between '<' and '>').
static void sanitize_xml_tag_names(QByteArray& data)
{
    // Quick check — skip if no "::" present
    if (!data.contains("::")) return;

    // Replace all "::" with "__" inside tags
    // Scan for '<', then replace "::" until '>' or end
    int i = 0;
    while (i < data.size()) {
        if (data[i] == '<') {
            ++i;
            // Skip comments, PI, CDATA
            if (i < data.size() && (data[i] == '!' || data[i] == '?')) {
                while (i < data.size() && data[i] != '>') ++i;
            } else {
                // Inside a tag — replace "::" with "__"
                while (i < data.size() - 1 && data[i] != '>') {
                    if (data[i] == ':' && data[i + 1] == ':') {
                        data[i] = '_';
                        data[i + 1] = '_';
                    }
                    ++i;
                }
            }
        }
        ++i;
    }
}

// Core parse function — takes QXmlStreamReader, returns root element table or nil+error
static int do_xml_parse(lua_State* L, QXmlStreamReader& reader)
{
    // Disable namespace processing — treat colons as literal characters in names
    reader.setNamespaceProcessing(false);

    // Skip to first StartElement (skip XML declaration, DTD, comments, etc.)
    while (!reader.atEnd()) {
        reader.readNext();
        if (reader.tokenType() == QXmlStreamReader::StartElement) {
            if (!parse_element(L, reader)) {
                // Error string is on stack
                lua_pushnil(L);
                lua_insert(L, -2);  // nil, error_string
                return 2;
            }
            return 1;  // root element table
        }
        if (reader.hasError()) {
            lua_pushnil(L);
            lua_pushstring(L, reader.errorString().toUtf8().constData());
            return 2;
        }
    }

    if (reader.hasError()) {
        lua_pushnil(L);
        lua_pushstring(L, reader.errorString().toUtf8().constData());
        return 2;
    }

    lua_pushnil(L);
    lua_pushliteral(L, "XML contains no elements");
    return 2;
}

// qt_xml_parse(path) → table, err
static int lua_qt_xml_parse(lua_State* L)
{
    const char* path = luaL_checkstring(L, 1);

    QFile file(QString::fromUtf8(path));
    if (!file.open(QIODevice::ReadOnly)) {
        lua_pushnil(L);
        lua_pushfstring(L, "Failed to open XML file: %s", path);
        return 2;
    }

    QByteArray data = file.readAll();
    sanitize_xml_tag_names(data);
    QXmlStreamReader reader(data);
    return do_xml_parse(L, reader);
}

// qt_xml_parse_string(xml_string) → table, err
static int lua_qt_xml_parse_string(lua_State* L)
{
    size_t len;
    const char* xml = luaL_checklstring(L, 1, &len);

    if (len == 0) {
        lua_pushnil(L);
        lua_pushliteral(L, "XML content is empty");
        return 2;
    }

    QByteArray data(xml, static_cast<int>(len));
    sanitize_xml_tag_names(data);
    QXmlStreamReader reader(data);
    return do_xml_parse(L, reader);
}

// Registration
static void register_xml_bindings(lua_State* L)
{
    lua_pushcfunction(L, lua_qt_xml_parse);
    lua_setglobal(L, "qt_xml_parse");

    lua_pushcfunction(L, lua_qt_xml_parse_string);
    lua_setglobal(L, "qt_xml_parse_string");
}
