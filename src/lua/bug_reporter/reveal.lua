-- Feature 027 T014b: reveal a file in Finder (macOS).
--
-- macOS implementation: `/usr/bin/open -R <path>` selects the file in
-- Finder. Absolute binary path defeats the Finder-launched stripped-PATH
-- trap (CLAUDE.md feedback_finder_launched_app_path.md).
--
-- Linux / Windows: stub returning `false` immediately. Documented
-- limitation (out-of-scope per spec — JVE doesn't ship there yet).
--
-- Test hook: if env var `JVE_BUG_REPORT_REVEAL_HOOK` is set to a file
-- path, write the supplied path into that file instead of calling
-- `open`. Production code branches on the env var only (off by default
-- in production launches), no sentinel-in-production pollution.
--
-- Spec sync: revised from "C++ binding via NSWorkspace selectFile:" to
-- `open -R` — the binding would have needed AppKit framework linkage
-- + objc_msgSend plumbing for a one-shot user-visible action.

local M = {}

local function platform_is_mac()
    -- LuaJIT exposes `jit.os`; older Lua falls back to package.config.
    if jit and jit.os then return jit.os == "OSX" end
    return package.config:sub(1, 1) == "/"
end

function M.reveal(path)
    assert(type(path) == "string" and path ~= "",
        "reveal_in_finder: path required")

    local hook = os.getenv("JVE_BUG_REPORT_REVEAL_HOOK")
    if hook and hook ~= "" then
        local f, err = io.open(hook, "w")
        assert(f, "reveal_in_finder: hook write failed at " .. hook ..
            ": " .. tostring(err))
        f:write(path)
        f:close()
        return true
    end

    if not platform_is_mac() then
        return false  -- Linux/Windows stub per spec out-of-scope.
    end

    local ok = os.execute(string.format("/usr/bin/open -R %q", path))
    return ok == 0 or ok == true
end

return M
