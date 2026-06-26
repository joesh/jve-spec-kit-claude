-- Feature 027 T014a: tiny zip-archive primitive used by the
-- bug-reporter export to pack capture.json (+ slideshow.mp4 when
-- text_only is off) into a single payload zip.
--
-- Implementation: shells out to /usr/bin/zip with -j (junk paths so
-- the archive entries are flat basenames, never directory trees). We
-- use the absolute binary path because Finder-launched .app processes
-- run with a stripped PATH (CLAUDE.md feedback_finder_launched_app_path).
-- The %q quoting around every argument keeps user-supplied paths safe
-- under /bin/sh's interpretation.
--
-- Returns `(true, nil)` on success, `(false, "<reason>")` on failure.
-- No fallback to a different zipper — fail-loud per Constitution VI.

local M = {}

local ZIP_BIN = "/usr/bin/zip"

local function shellquote(s) return string.format("%q", s) end

function M.zip_files(output_path, file_paths)
    assert(type(output_path) == "string" and output_path ~= "",
        "zip_writer: output_path required")
    assert(type(file_paths) == "table" and #file_paths > 0,
        "zip_writer: file_paths must be a non-empty array")

    local parts = { ZIP_BIN, "-j", shellquote(output_path) }
    for _, f in ipairs(file_paths) do
        assert(type(f) == "string" and f ~= "",
            "zip_writer: every file path must be a non-empty string")
        parts[#parts + 1] = shellquote(f)
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
