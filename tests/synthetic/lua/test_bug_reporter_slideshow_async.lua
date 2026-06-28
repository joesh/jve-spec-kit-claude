-- Feature 027 FR-009b: slideshow generation MUST be asynchronous so
-- the GUI thread is not blocked during the ~5–10s ffmpeg run.
--
-- Domain contract for generate_async(dir, count, output, on_done):
--   - on_done is called EXACTLY ONCE
--   - success → on_done(output_path, nil)
--   - process exit≠0 → on_done(nil, err) with err naming the failure
--   - invalid args (empty dir, zero/negative count) → on_done(nil, err)
--     fired immediately (no qt_process spawn — fast refusal)
--   - ffmpeg not resolvable → on_done(nil, err) with 'ffmpeg' in the message
--
-- Black-box: drives generate_async through stubbed qt_process_* that
-- record invocations + fire the finished callback synchronously so
-- the call returns once on_done has been invoked.

print("=== test_bug_reporter_slideshow_async.lua ===")
require("test_env")

local slideshow = require("bug_reporter.slideshow_generator")

-- Centralized stub state — every subtest resets it.
local stub
local function reset_stub()
    stub = {
        next_id = 1,
        slots = {},
        invocations = {
            create   = 0,
            start    = 0,
            destroy  = 0,
        },
        plan = {
            -- Default: process succeeds at exit 0 / status "normal".
            start_ok    = true,
            start_err   = nil,
            exit_code   = 0,
            exit_status = "normal",
            -- When set, stdout/stderr chunks are delivered before finished.
            stderr      = nil,
        },
    }
end

_G.qt_process_create = function()
    stub.invocations.create = stub.invocations.create + 1
    local id = stub.next_id
    stub.next_id = stub.next_id + 1
    stub.slots[id] = { finished_cb = nil, stderr_cb = nil, stdout_cb = nil }
    return id
end
_G.qt_process_set_finished_cb = function(id, fn) stub.slots[id].finished_cb = fn end
_G.qt_process_set_stderr_cb   = function(id, fn) stub.slots[id].stderr_cb   = fn end
_G.qt_process_set_stdout_cb   = function(id, fn) stub.slots[id].stdout_cb   = fn end
_G.qt_process_start = function(id, _program, _args)
    stub.invocations.start = stub.invocations.start + 1
    if not stub.plan.start_ok then
        return nil, stub.plan.start_err or "stub-start-failed"
    end
    -- Simulate stderr delivery before the finished callback.
    if stub.plan.stderr and stub.slots[id].stderr_cb then
        stub.slots[id].stderr_cb(stub.plan.stderr)
    end
    if stub.slots[id].finished_cb then
        stub.slots[id].finished_cb(stub.plan.exit_code, stub.plan.exit_status)
    end
    return true
end
_G.qt_process_destroy = function(_id)
    stub.invocations.destroy = stub.invocations.destroy + 1
end

-- Force ffmpeg-found for predictable tests; bypass the
-- /opt/homebrew/... probe so absence on CI hosts doesn't poison.
_G.qt_fs_path_exists = function(path) return path:match("ffmpeg$") ~= nil end
slideshow.check_ffmpeg = function()
    return true, "/usr/local/bin/ffmpeg"
end

local TMP = "/tmp/jve_slideshow_async_test_" .. tostring(math.random(1, 1e9))
os.execute("/bin/mkdir -p " .. TMP)

-- Counts how many times on_done was called and records last args.
local function done_recorder()
    local r = { calls = 0 }
    r.fn = function(p, e)
        r.calls = r.calls + 1
        r.path  = p
        r.err   = e
    end
    return r
end

-- (1) Success: on_done fires exactly once with (output_path, nil).
do
    reset_stub()
    local rec = done_recorder()
    slideshow.generate_async(TMP, 5, TMP .. "/slideshow.mp4", rec.fn)
    assert(rec.calls == 1, "on_done must be called exactly once on success; got " .. rec.calls)
    assert(rec.path == TMP .. "/slideshow.mp4",
        "success on_done must pass the output_path; got " .. tostring(rec.path))
    assert(rec.err == nil,
        "success on_done must pass nil error; got " .. tostring(rec.err))
    assert(stub.invocations.destroy >= 1,
        "qt_process_destroy must be called to free the slot after success")
end

-- (2) Process failure (non-zero exit): on_done(nil, err).
do
    reset_stub()
    stub.plan.exit_code = 1
    stub.plan.exit_status = "normal"
    stub.plan.stderr = "ffmpeg: nonsense argument\n"
    local rec = done_recorder()
    slideshow.generate_async(TMP, 5, TMP .. "/slideshow.mp4", rec.fn)
    assert(rec.calls == 1, "on_done must be called exactly once on failure; got " .. rec.calls)
    assert(rec.path == nil, "failure on_done must pass nil path; got " .. tostring(rec.path))
    assert(rec.err and tostring(rec.err):find("ffmpeg", 1, true),
        "failure err must name ffmpeg so the caller can surface it; got " .. tostring(rec.err))
end

-- (3) Crashed process (exit_status ≠ 'normal'): also fails.
do
    reset_stub()
    stub.plan.exit_code = -1
    stub.plan.exit_status = "crashed"
    local rec = done_recorder()
    slideshow.generate_async(TMP, 5, TMP .. "/slideshow.mp4", rec.fn)
    assert(rec.calls == 1, "on_done must fire once when process crashed; got " .. rec.calls)
    assert(rec.path == nil, "crashed process must NOT deliver a video path")
    assert(rec.err, "crashed process must deliver an err message")
end

-- (4) qt_process_start fails (binding refused to spawn): on_done(nil, err).
do
    reset_stub()
    stub.plan.start_ok = false
    stub.plan.start_err = "permission denied"
    local rec = done_recorder()
    slideshow.generate_async(TMP, 5, TMP .. "/slideshow.mp4", rec.fn)
    assert(rec.calls == 1, "start-failure on_done must fire once; got " .. rec.calls)
    assert(rec.path == nil, "start-failure must NOT deliver a path")
    assert(rec.err and tostring(rec.err):find("permission denied", 1, true),
        "start-failure err must propagate the underlying message; got " .. tostring(rec.err))
end

-- (5) Invalid args fire on_done immediately, do NOT spawn a process.
do
    reset_stub()
    local rec = done_recorder()
    slideshow.generate_async("", 5, TMP .. "/slideshow.mp4", rec.fn)
    assert(rec.calls == 1, "empty screenshot_dir must fail-fast via on_done")
    assert(rec.path == nil and rec.err, "empty-dir on_done must carry an err")
    assert(stub.invocations.create == 0,
        "empty-dir refusal must NOT spawn a process; saw " .. stub.invocations.create)
end
do
    reset_stub()
    local rec = done_recorder()
    slideshow.generate_async(TMP, 0, TMP .. "/slideshow.mp4", rec.fn)
    assert(rec.calls == 1, "zero screenshot_count must fail-fast via on_done")
    assert(rec.path == nil and rec.err)
    assert(stub.invocations.create == 0,
        "zero-count refusal must NOT spawn a process; saw " .. stub.invocations.create)
end

-- (6) ffmpeg missing → on_done(nil, err with 'ffmpeg' in message).
do
    reset_stub()
    slideshow.check_ffmpeg = function() return false, "ffmpeg not found" end
    local rec = done_recorder()
    slideshow.generate_async(TMP, 5, TMP .. "/slideshow.mp4", rec.fn)
    assert(rec.calls == 1, "missing-ffmpeg on_done must fire once")
    assert(rec.path == nil, "missing-ffmpeg must NOT deliver a path")
    assert(rec.err and tostring(rec.err):lower():find("ffmpeg", 1, true),
        "missing-ffmpeg err must mention ffmpeg; got " .. tostring(rec.err))
    assert(stub.invocations.create == 0,
        "missing-ffmpeg refusal must NOT spawn a process; saw " .. stub.invocations.create)
end

os.execute("/bin/rm -rf " .. TMP)
print("✅ test_bug_reporter_slideshow_async.lua passed")
