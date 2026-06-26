-- Feature 027 T005: the artifact shipped to the backend contains
-- exactly capture.json + slideshow.mp4 (or capture.json alone for the
-- text-only opt-out) — nothing else. No PNG frames, no .jvp database
-- snapshot, no `database_snapshots` key inside capture.json, no
-- left-behind screenshots/ subdir under the capture root.
--
-- jve_version inside capture.json MUST be the 7-char git SHA, not the
-- legacy hardcoded "0.1.0-dev". Without a real version field every
-- cluster signature would collapse across builds and Joe couldn't
-- filter incoming reports by build.
--
-- Black-box per Constitution III. MUST run via --test mode (absolute
-- script path) because it walks the real export path through capture
-- manager + json exporter + zip writer (T011/T014a/T014c).

print("=== test_bug_reporter_artifact_shape.lua ===")

require("test_env")
local dkjson = require("dkjson")

-- Loader guards: each downstream module is required individually so we
-- get a specific RED message naming the task that owes the work.
local function require_or_red(modname, task)
    local ok, mod = pcall(require, modname)
    if not ok then
        error("RED — " .. modname .. " unloadable (" .. task .. " not landed): " .. tostring(mod))
    end
    return mod
end

require_or_red("bug_reporter", "T010b/T011")
local submission_state  = require_or_red("bug_reporter.ui.submission_state", "T012")
local report_bug        = require_or_red("core.commands.report_bug", "T014c")

if type(report_bug.submit) ~= "function" then
    error("RED — core.commands.report_bug.submit is not a function (T014c not landed)")
end

-- Wire enough of the C++ side for capture_manual to succeed.
local main_window = qt_constants.WIDGET.CREATE_MAIN_WINDOW()
qt_constants.PROPERTIES.SET_SIZE(main_window, 1400, 900)
qt_constants.DISPLAY.SHOW(main_window)
qt_constants.APP.PROCESS_EVENTS()

-- Build the state model the way the dialog does.
local state = submission_state.new()
state:set_title("Artifact shape — automated test report")
state:set_description("synthetic capture for T005")
-- text_only stays false: zip MUST then contain slideshow.mp4.

-- Drive the same Submit-handler the dialog's button invokes.
local result = report_bug.submit(state)
assert(result and result.ok, "report_bug.submit did not return ok=true")
assert(result.zip_path and #result.zip_path > 0,
    "report_bug.submit did not return a zip_path")

local function read_text(path)
    local f = io.open(path, "r")
    assert(f, "expected " .. path .. " to exist")
    local body = f:read("*a")
    f:close()
    return body
end

-- Derive capture dir = dirname(zip_path).
local capture_dir = result.zip_path:match("^(.*)/[^/]+$")
assert(capture_dir, "could not derive capture_dir from zip_path " .. result.zip_path)

-- 1) No screenshots/ subdirectory must remain on disk.
local sentinel = io.open(capture_dir .. "/screenshots", "r")
if sentinel then
    sentinel:close()
    error("screenshots/ subdir survived export — T011 must rm it after slideshow.mp4 is built")
end

-- 2) capture.json must exist, parse, NOT carry a `database_snapshots`
-- key, and carry jve_version that looks like a 7-char git SHA.
local capture_json = read_text(capture_dir .. "/capture.json")
local capture, _, err = dkjson.decode(capture_json)
assert(capture, "capture.json malformed: " .. tostring(err))

assert(capture.capture_metadata, "capture.json missing capture_metadata block")
local version = capture.capture_metadata.jve_version
assert(version and version:match("^[0-9a-f]+$") and #version == 7,
    "jve_version='" .. tostring(version) .. "' — expected 7-char git SHA. " ..
    "T011 must replace '0.1.0-dev' with core.build_info.git_sha.")

assert(capture.database_snapshots == nil,
    "capture.json carries a database_snapshots key — T011 must drop that branch " ..
    "from the exporter; .jvp content MUST NOT ship in any payload (FR-011a).")
assert(capture.video_recording == nil,
    "capture.json carries a video_recording block — T011 must drop that branch")

-- 3) zip must list exactly capture.json + slideshow.mp4, nothing more.
local zip_listing = io.popen("unzip -l " .. ("'" .. result.zip_path:gsub("'", "'\\''") .. "'") .. " 2>/dev/null"):read("*a")
local entries_in_zip = {}
for name in zip_listing:gmatch("%S+%.[%w]+") do
    -- entries appear in the rightmost column; collect basenames with extensions
    if name:match("%.json$") or name:match("%.mp4$") or name:match("%.png$") or name:match("%.db$") then
        entries_in_zip[name] = true
    end
end

assert(entries_in_zip["capture.json"], "zip is missing capture.json")
assert(entries_in_zip["slideshow.mp4"], "zip is missing slideshow.mp4 — text_only was false")
for entry, _ in pairs(entries_in_zip) do
    assert(entry == "capture.json" or entry == "slideshow.mp4",
        "zip carries an unexpected entry: " .. entry)
end

print("✅ test_bug_reporter_artifact_shape.lua passed")
