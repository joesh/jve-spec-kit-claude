-- T108a (013): standing guard against FR-018 regressions.
--
-- Scans src/lua for identifiers that the 013 schema refactor retired:
--   * clip_kind
--   * master_clip_id         (renamed to nested_sequence_id)
--   * clip.media_id / c.media_id / clips.media_id  (column dropped)
--   * clip.offline / c.offline / clips.offline     (column dropped)
--   * sequences.kind legacy string literals: 'timeline', 'masterclip',
--     'compound', 'multicam'  (narrowed to 'master'/'nested')
--
-- Expected to fail until T109 completes the scoped legacy purge. Once
-- T109 lands, this test stays green forever and fails loudly on any
-- reintroduction of a banned identifier.
--
-- Rule 2.15 forbids silent schema fallbacks; this test is the forward-
-- facing guard that keeps the model clean.

require("test_env")

local REPO_ROOT = (function()
    local h = io.popen("git rev-parse --show-toplevel")
    assert(h, "git rev-parse failed")
    local root = h:read("*l")
    h:close()
    assert(root and root ~= "", "could not locate repo root")
    return root
end)()

-- Patterns are POSIX extended regex (for `grep -E`). Each entry:
--   pattern  : regex
--   label    : short name
--   allowlist: set of path suffixes (relative to repo root) where the
--              match is intentional / not a bug.
-- Each pattern's allowlist is a list of file path SUFFIXES (relative to
-- repo root) where the match is intentional — surviving V13 callsites
-- that legitimately use the same identifier for a different concept.
local BANNED = {
    {
        label = "clip_kind",
        pattern = [[\bclip_kind\b]],
        -- duplicate_master_clip carries clip_kind in an error-message
        -- string (explains the deprecated V8 INSERT shape). Not a live read.
        allowlist = {
            "src/lua/core/commands/duplicate_master_clip.lua",
        },
    },
    {
        label = "master_clip_id",
        pattern = [[\bmaster_clip_id\b]],
        -- DeleteMasterClip retains master_clip_id as a SPEC.args alias
        -- for the V13 master_sequence_id arg (menu wiring continuity).
        allowlist = {
            "src/lua/core/commands/delete_master_clip.lua",
        },
    },
    {
        label = "clips.media_id",
        -- clip.media_id, c.media_id, clips.media_id — common Lua/SQL forms.
        -- project_browser / browser_state operate on browser-row entries
        -- (master-sequence rows from load_master_clips), where `media_id`
        -- is the master's bound leaf media — a V13-correct field, not a
        -- read off a V13 `clips` row.
        pattern = [[\b(clip|clips|c)\.media_id\b]],
        allowlist = {
            "src/lua/ui/project_browser.lua",
            "src/lua/ui/project_browser/browser_state.lua",
        },
    },
    {
        label = "clips.offline",
        -- `clip.offline` under V13 is a runtime-stamped derived state
        -- (media_status.ensure_clip_status writes it; renderer reads it),
        -- NOT a `clips` table column. Same name, different concept.
        pattern = [[\b(clip|clips|c)\.offline\b]],
        allowlist = {
            "src/lua/core/media/media_status.lua",
            "src/lua/ui/timeline/state/timeline_core_state.lua",
            "src/lua/ui/timeline/view/timeline_view_renderer.lua",
            "src/lua/ui/project_browser.lua",
            "src/lua/ui/project_browser/browser_state.lua",
        },
    },
    {
        label = "legacy sequences.kind literal 'timeline'",
        pattern = [['timeline']],
        allowlist = {},
    },
    {
        label = "legacy sequences.kind literal 'masterclip'",
        pattern = [['masterclip']],
        allowlist = {},
    },
    {
        label = "legacy sequences.kind literal 'compound'",
        pattern = [['compound']],
        allowlist = {},
    },
    {
        label = "legacy sequences.kind literal 'multicam'",
        pattern = [['multicam']],
        allowlist = {},
    },
}

-- Search scope: src/lua only. Tests retain legacy identifiers until
-- they are rewritten in the Phase 3.4+ command/test migration passes;
-- they are out of FR-018's scope per tasks.md T109.
local SEARCH_DIRS = { "src/lua" }

local function run_grep(pattern, dirs)
    local dir_args = table.concat(dirs, " ")
    -- -n: line number, -H: filename, -E: extended regex, -I: skip binary,
    -- -r: recurse. stderr -> /dev/null swallows "no matches" which sets
    -- exit code 1; we read stdout regardless.
    local cmd = string.format(
        "cd %q && grep -EnrIH %q %s 2>/dev/null",
        REPO_ROOT, pattern, dir_args)
    local h = io.popen(cmd)
    assert(h, "grep popen failed")
    local hits = {}
    for line in h:lines() do
        hits[#hits + 1] = line
    end
    h:close()
    return hits
end

local function is_allowlisted(path, allowlist)
    for _, suffix in ipairs(allowlist) do
        if path:sub(-#suffix) == suffix then return true end
    end
    return false
end

-- A match counts as a legitimate hit unless it's purely in a Lua comment
-- line (leading whitespace then `--`) or an inline comment suffix. This
-- is a conservative filter — a comment containing the banned identifier
-- still needs to be cleaned up eventually, but we skip it here so the
-- guard focuses on live code. When T109 strips comments too, they
-- graduate to hard failures.
local function line_is_pure_comment(content)
    -- Lua block comments (--[[ ... ]]) are not tracked here; if they
    -- trip the grep, they need manual cleanup.
    local trimmed = content:match("^%s*(.-)%s*$") or ""
    if trimmed:sub(1, 2) == "--" then return true end
    -- SQL / shell comments
    if trimmed:sub(1, 2) == "/*" then return true end
    return false
end

local total_hits = 0
local by_label = {}

for _, spec in ipairs(BANNED) do
    local raw = run_grep(spec.pattern, SEARCH_DIRS)
    local kept = {}
    for _, hit in ipairs(raw) do
        -- grep -n format: path:lineno:content
        local path, lineno, content = hit:match("^([^:]+):(%d+):(.*)$")
        if path and not is_allowlisted(path, spec.allowlist)
           and not line_is_pure_comment(content) then
            kept[#kept + 1] = {
                path = path, lineno = tonumber(lineno), content = content,
            }
        end
    end
    by_label[spec.label] = kept
    total_hits = total_hits + #kept
end

if total_hits == 0 then
    print("✅ test_no_legacy_identifiers.lua passed")
    return
end

io.stderr:write(string.format(
    "FR-018 regression: %d legacy-identifier hit(s) in src/lua/.\n",
    total_hits))
io.stderr:write("Until T109 completes the scoped purge, this test is "
    .. "expected to be RED. After T109 any re-introduction must fail.\n\n")

for _, spec in ipairs(BANNED) do
    local hits = by_label[spec.label]
    if #hits > 0 then
        io.stderr:write(string.format("== %s (%d) ==\n", spec.label, #hits))
        for _, h in ipairs(hits) do
            io.stderr:write(string.format(
                "  %s:%d: %s\n",
                h.path, h.lineno,
                (h.content:gsub("^%s+", ""):sub(1, 120))))
        end
        io.stderr:write("\n")
    end
end

os.exit(1)
