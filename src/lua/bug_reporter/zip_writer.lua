-- Feature 027 T014a: tiny zip-archive primitive used by the
-- bug-reporter export to pack capture.json (+ slideshow.mp4 when
-- text_only is off) into a single payload zip.
--
-- Implementation: shells out to /usr/bin/zip with -j (junk paths so
-- the archive entries are flat basenames, never directory trees). We
-- use the absolute binary path because Finder-launched .app processes
-- run with a stripped PATH (CLAUDE.md feedback_finder_launched_app_path).
-- Every argument is wrapped in '...' via utils.shell_quoted_arg —
-- inside single quotes /bin/sh expands NOTHING, so user-controlled
-- paths can't trigger $/backtick/glob injection.
--
-- Returns `(true, nil)` on success, `(false, "<reason>")` on failure.
-- No fallback to a different zipper — fail-loud per Constitution VI.

local utils = require("bug_reporter.utils")

local M = {}

local ZIP_BIN = "/usr/bin/zip"

function M.zip_files(output_path, file_paths)
    assert(type(output_path) == "string" and output_path ~= "",
        "zip_writer: output_path required")
    assert(type(file_paths) == "table" and #file_paths > 0,
        "zip_writer: file_paths must be a non-empty array")

    local parts = { ZIP_BIN, "-j", utils.shell_quoted_arg(output_path) }
    for _, f in ipairs(file_paths) do
        assert(type(f) == "string" and f ~= "",
            "zip_writer: every file path must be a non-empty string")
        parts[#parts + 1] = utils.shell_quoted_arg(f)
    end
    -- Suppress zip's "adding: ..." chatter from the TSO; errors still
    -- come back via the exit code.
    parts[#parts + 1] = "1>/dev/null"
    parts[#parts + 1] = "2>/dev/null"

    local cmd = table.concat(parts, " ")
    local ok, exit_type, exit_code = os.execute(cmd)
    if ok == 0 or ok == true then return true end
    return false, string.format(
        "zip_writer: %s exited %s (type=%s) for output %s",
        ZIP_BIN, tostring(exit_code or ok), tostring(exit_type), output_path)
end

return M
