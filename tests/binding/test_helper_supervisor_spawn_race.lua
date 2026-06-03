-- Regression for spec 023 helper-supervisor spawn race.
--
-- Prior bug (observed 2026-06-03): supervisor.ensure_client() returned
-- (nil, "helper_unavailable", "client.connect: timed out after 5000ms")
-- on every cold-start invocation. qt_process_wait_for_started returns
-- when posix_spawn's fork+exec completes (~1ms), but bash → python →
-- helper.bind_socket takes ~70ms cold. The supervisor called
-- client.connect immediately and QLocalSocket::waitForConnected
-- *returned fast with ServerNotFoundError* rather than retrying for
-- the documented 5000ms — its timeout only covers "connection in
-- progress", not "server file does not exist yet". Supervisor then
-- terminated the helper ~1ms later; bash never got a CPU slice to
-- execute the script. (Misleading "timed out after 5000ms" message is
-- a separate concern — the failure was actually instant.)
--
-- This test exercises the full lifecycle through the production
-- supervisor (no fixture shortcut) and asserts that ensure_client
-- returns a connected client. It must FAIL before the spawn_helper
-- socket-readiness wait is added, and PASS after.
--
-- Run via `jve --test` (needs qt_process_* / qt_local_socket_*).

local supervisor = require("core.resolve_bridge.helper_supervisor")

-- Locate repo root from this test file's path so the test runs regardless
-- of CWD (same pattern as helper_fixture.lua).
local source_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$")
local repo_root = source_dir:match("^(.+)/tests/binding$")
    or assert(nil, "test_helper_supervisor_spawn_race: "
        .. "cannot locate repo root from " .. tostring(source_dir))

supervisor.configure(repo_root .. "/tools/resolve-helper/helper.py")

-- Wipe any state left over from a sibling binding test that touched the
-- supervisor module earlier in the same process (configure persists
-- module-level state; ensure_client may have cached a client).
supervisor.shutdown()

local client, code, msg = supervisor.ensure_client()
assert(client ~= nil, string.format(
    "ensure_client must return a connected client; "
    .. "got nil with code=%q msg=%q (this is the cold-start spawn race "
    .. "— supervisor must wait for the helper to bind the socket before "
    .. "handing off to client.connect)",
    tostring(code), tostring(msg)))

supervisor.shutdown()

print("✅ test_helper_supervisor_spawn_race.lua passed")
