-- demo_smoke.lua — driven by driver.sh via `jve --test`.
--
-- Proves the full JVEEditor process boots with all C++ bindings AND the Lua
-- model/command/DB stack working, WITHOUT opening a window or touching the
-- user's real project. Two independent checks:
--   1. EMP (editor_media_platform) C++ media bindings — open + probe a fixture.
--   2. Blank-project bootstrap through the real OpenProject command path —
--      proves SQLite persistence, the command manager, and the model layer.
--
-- This is the canonical shape of a `--test` script: require the integration
-- env, exercise real subsystems, print results, end with a PASS line. Exit
-- code is 0 on success (any error/assert returns 1 from main.cpp).

-- Self-locate the repo's tests/ tree. main.cpp only auto-adds package.path
-- for scripts that live UNDER a tests/ dir; this one lives in the skill dir,
-- so derive the repo root from our own absolute path and prepend tests/.
local src = debug.getinfo(1, "S").source:sub(2) -- strip leading '@'
local repo = src:gsub("/%.claude/skills/run%-jve%-editor/demo_smoke%.lua$", "")
assert(repo ~= src, "demo_smoke.lua: could not derive repo root from " .. src)
package.path = repo .. "/tests/?.lua;" .. repo .. "/tests/?/init.lua;" .. package.path

local env = require("synthetic.integration.integration_test_env")

print("--- demo_smoke.lua ---")

-- 1) C++ media bindings: open a fixture and read its real container info.
local EMP = env.require_emp()
local MEDIA = "test_tone_48k_stereo.wav"
local path = env.test_media_path(MEDIA)
local mf = assert(EMP.MEDIA_FILE_OPEN(path), "EMP failed to open " .. MEDIA)
local info = EMP.MEDIA_FILE_INFO(mf)
assert(info.has_audio, "fixture must have audio")
print(string.format("  [bindings] %s: sr=%d ch=%d dur=%.2fs has_audio=%s has_video=%s",
    MEDIA, info.audio_sample_rate, info.audio_channels,
    info.duration_us / 1e6, tostring(info.has_audio), tostring(info.has_video)))
EMP.MEDIA_FILE_CLOSE(mf)

-- 2) Model + DB + command path: open a fresh project off a template.
local blank_project = require("synthetic.helpers.blank_project")
local db_path = "/tmp/jve/run_skill_demo.jvp"
os.execute(string.format("rm -f %q %q-shm %q-wal", db_path, db_path, db_path))
os.execute('mkdir -p /tmp/jve')
local opened = blank_project.open_fresh(db_path, {
    template_name = "Film 24fps",
    project_name  = "run-skill-demo",
})
assert(opened.project_id and opened.sequence_id, "open_fresh must return ids")

local debug_helpers = require("core.debug_helpers")
print(string.format("  [model] project=%s seq=%s sequence_count=%d media_count=%d",
    opened.project_id:sub(1, 8), opened.sequence_id:sub(1, 8),
    debug_helpers.sequence_count(), debug_helpers.media_count()))

print("PASS demo_smoke.lua")
