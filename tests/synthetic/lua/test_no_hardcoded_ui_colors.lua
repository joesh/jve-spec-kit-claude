-- Standing guard: UI color literals live ONLY in core/ui_constants.lua.
--
-- The 3-tier design-token system (docs/ui-theme-tokens.md) is the single
-- source of truth for every color the app paints. Call sites reference
-- semantic/component tokens (ui_constants.COLORS.*); they must never paste
-- a raw hex literal. A pasted hex won't re-tint when TIER-1 values shift
-- (the interface-lightness slider remaps the ramp), so it silently drifts
-- out of the theme — exactly the bug this migration removed.
--
-- This scans src/lua for QUOTED hex color literals (the form an applied
-- color always takes in Lua: "#rrggbb" / "#rgb" / "#aarrggbb"). It is a
-- forward-facing invariant: once green, any reintroduced literal fails it.
--
-- Allowed (not flagged):
--   * core/ui_constants.lua            — the one legal home for hex.
--   * pure-comment lines               — prose may reference a value.
--   * documentation examples ("e.g.")  — e.g. an assert message showing
--                                        the expected argument shape.

require("test_env")

local REPO_ROOT = (function()
    local h = io.popen("git rev-parse --show-toplevel")
    assert(h, "git rev-parse failed")
    local root = h:read("*l")
    h:close()
    assert(root and root ~= "", "could not locate repo root")
    return root
end)()

-- A quoted hex color: an opening quote, '#', then 3, 6, or 8 hex digits.
-- Anchoring on the quote excludes Lua's length operator (`#tbl`) and
-- comment references that lack quotes.
local PATTERN = [[['"]#[0-9A-Fa-f]+]]

-- Path suffixes (relative to repo root) where a quoted hex is legitimate.
local ALLOWLISTED_FILES = {
    "src/lua/core/ui_constants.lua",
}

local function is_allowlisted_file(path)
    for _, suffix in ipairs(ALLOWLISTED_FILES) do
        if path:sub(-#suffix) == suffix then return true end
    end
    return false
end

-- Skip pure-comment lines and documentation-example lines (those carrying
-- "e.g." — an assert/error message demonstrating the argument shape, not
-- an applied color).
local function is_exempt_line(content)
    local trimmed = content:match("^%s*(.-)%s*$") or ""
    if trimmed:sub(1, 2) == "--" then return true end
    if content:find("e%.g%.", 1) then return true end
    return false
end

local function run_grep(pattern)
    local cmd = string.format(
        "cd %q && grep -EnrIH --include=*.lua %q src/lua 2>/dev/null",
        REPO_ROOT, pattern)
    local h = io.popen(cmd)
    assert(h, "grep popen failed")
    local hits = {}
    for line in h:lines() do hits[#hits + 1] = line end
    h:close()
    return hits
end

local violations = {}
for _, hit in ipairs(run_grep(PATTERN)) do
    -- grep -n format: path:lineno:content
    local path, lineno, content = hit:match("^([^:]+):(%d+):(.*)$")
    if path and not is_allowlisted_file(path) and not is_exempt_line(content) then
        violations[#violations + 1] = {
            path = path, lineno = tonumber(lineno), content = content,
        }
    end
end

if #violations == 0 then
    print("✅ test_no_hardcoded_ui_colors.lua passed")
    return
end

io.stderr:write(string.format(
    "Hardcoded UI color literal(s) found outside ui_constants.lua: %d\n",
    #violations))
io.stderr:write("Move each into core/ui_constants.lua as a token and "
    .. "reference it via ui_constants.COLORS.<TOKEN>.\n\n")
for _, v in ipairs(violations) do
    io.stderr:write(string.format("  %s:%d: %s\n",
        v.path, v.lineno, (v.content:gsub("^%s+", ""):sub(1, 120))))
end
os.exit(1)
