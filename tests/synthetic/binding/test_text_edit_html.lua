-- SET_TEXT_EDIT_HTML binding (run via `jve --test`).
--
-- Black-box: a rich-text report set through SET_TEXT_EDIT_HTML must be
-- interpreted as HTML — reading the widget's text back yields the
-- rendered words with no markup. Contrast pass: the same string set
-- through PROPERTIES.SET_TEXT goes in as plain text, so the literal
-- tags survive. This is the distinction the relink results pane relies
-- on (media_relink_dialog renders its summary as HTML).

local qt = require("core.qt_constants")

assert(type(qt.CONTROL.SET_TEXT_EDIT_HTML) == "function",
    "SET_TEXT_EDIT_HTML binding not registered")

local html = "<b>3 relinked</b> &nbsp;\194\183&nbsp; <i>1 not found</i>"

-- HTML path: tags consumed, entities decoded.
do
    local te = qt.WIDGET.CREATE_TEXT_EDIT("")
    qt.CONTROL.SET_TEXT_EDIT_HTML(te, html)
    local text = qt.PROPERTIES.GET_TEXT(te)
    assert(type(text) == "string", "GET_TEXT must read a QTextEdit back")
    assert(text:find("3 relinked", 1, true) and text:find("1 not found", 1, true),
        string.format("rendered text must keep the words: %q", text))
    assert(not text:find("<b>", 1, true) and not text:find("&nbsp;", 1, true),
        string.format("markup must be interpreted, not shown literally: %q", text))
end

-- Plain-text path: SET_TEXT on a QTextEdit stays literal (the reason
-- the dedicated HTML setter exists).
do
    local te = qt.WIDGET.CREATE_TEXT_EDIT("")
    qt.PROPERTIES.SET_TEXT(te, html)
    local text = qt.PROPERTIES.GET_TEXT(te)
    assert(text:find("<b>", 1, true),
        string.format("SET_TEXT must remain plain-text on QTextEdit: %q", text))
end

print("✅ test_text_edit_html.lua passed")
