-- TogglePreferenceBugReporting command (feature 027 T039).
--
-- Single CLI/menu entry point that flips the bug_reporter_enabled
-- preference. The full Preferences UI shell is a future feature; this
-- command is the v1 surface so users can re-enable bug reporting after
-- declining at first launch (FR-002 / AS #15).

local M = {}
local dialog_prefs = require("core.dialog_prefs")
local log = require("core.logger").for_area("commands")

local SPEC = {
    undoable = false,
    args = {
        project_id  = {},
        sequence_id = {},
    },
}

local PREFS_FILENAME = "bug_reporter_prefs.json"
local PREF_KEY = "bug_reporter_enabled"

local function load_prefs()
    return dialog_prefs.load(dialog_prefs.path_for(PREFS_FILENAME)) or {}
end

local function save_prefs(prefs)
    dialog_prefs.save(dialog_prefs.path_for(PREFS_FILENAME), prefs)
end

function M.register(executors, undoers, db)  -- luacheck: no unused args
    local function executor(command)  -- luacheck: no unused args
        local prefs = load_prefs()
        local current = prefs[PREF_KEY]
        -- Three-state semantics: nil (never set) = enabled-by-default;
        -- true = explicitly on; false = explicitly off. Toggle moves
        -- nil→false, true→false, false→true.
        local new_value
        if current == false then new_value = true
        else new_value = false end
        prefs[PREF_KEY] = new_value
        save_prefs(prefs)
        log.event("TogglePreferenceBugReporting: bug_reporter_enabled = %s",
            tostring(new_value))

        -- If turning ON and no install record exists yet, the next
        -- backend interaction needs to fire /register first (FR-002 /
        -- AS #15). Delegate to telemetry which handles the consent +
        -- register dance.
        if new_value then
            local ok, telemetry = pcall(require, "bug_reporter.telemetry")
            if ok then telemetry.apply_pref_toggle(true) end
        end
        return true
    end
    return { executor = executor, spec = SPEC }
end

return M
