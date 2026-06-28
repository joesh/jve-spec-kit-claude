-- Pending-report queue (feature 027 T036).
--
-- Pairs of (uuid.payload.zip, uuid.metadata.json) live under
-- ~/.jve/pending-reports/ until a successful transport.post_report
-- drains them. Per amended FR-024 drain semantics:
--   200 or 429 → silently delete the pair (drain success and rate-
--                limit during drain are both log-only).
--   5xx / transport error → leave pair in place; STOP draining.
--   malformed response → assert per FR-021a.
-- Cap: 50 pairs. Inserting the 51st deletes the oldest pair (by mtime)
-- and emits `bug_report_queue_cap_warning` so the UI can surface a
-- modal.

local signals = require("core.signals")
local log     = require("core.logger").for_area("ui")
local utils   = require("bug_reporter.utils")

local M = {}

local DEFAULT_ROOT = (os.getenv("HOME") or "/tmp") .. "/.jve/pending-reports"
local root = DEFAULT_ROOT
local MAX_PAIRS = 50

function M.set_root_for_tests(dir)
    root = dir
end

function M.clear_all_for_tests()
    -- Best-effort recursive remove; missing dir is OK (idempotent setup).
    qt_fs_remove_dir_recursive(root)
    assert(utils.mkdir_p(root))
end

local function ensure_root()
    assert(utils.mkdir_p(root))
end

-- Return {id, mtime} pairs sorted oldest-first.
local function list_pairs()
    local out = {}
    local names = qt_fs_listdir(root)
    if not names then return out end  -- root missing → no entries
    local files_by_id = {}
    for _, name in ipairs(names) do
        local id, kind = name:match("^(.-)%.(payload%.zip)$")
        if not id then
            id, kind = name:match("^(.-)%.(metadata%.json)$")
        end
        if id then
            files_by_id[id] = files_by_id[id] or {}
            files_by_id[id][kind] = true
        end
    end
    for id, kinds in pairs(files_by_id) do
        if kinds["payload.zip"] and kinds["metadata.json"] then
            local mtime = qt_file_mtime(root .. "/" .. id .. ".metadata.json")
            assert(mtime, "pending_queue.list_pairs: qt_file_mtime nil for " .. id)
            out[#out + 1] = { id = id, mtime = mtime }
        end
    end
    table.sort(out, function(a, b) return a.mtime < b.mtime end)
    return out
end

local function delete_pair(id)
    os.remove(root .. "/" .. id .. ".payload.zip")
    os.remove(root .. "/" .. id .. ".metadata.json")
end

-- Both queue files are written mode-0600 via utils.write_secure_file —
-- the zip can carry the user's window screenshots and the metadata
-- carries the install_id, so they're per-user secrets even if the
-- nonce itself lives elsewhere.
local function write_pair(id, payload_zip_bytes, metadata_json)
    local zip_path  = root .. "/" .. id .. ".payload.zip"
    local meta_path = root .. "/" .. id .. ".metadata.json"
    local ok, err = utils.write_secure_file(zip_path, payload_zip_bytes)
    assert(ok, "pending_queue.write_pair: zip write failed: " .. tostring(err))
    ok, err = utils.write_secure_file(meta_path, metadata_json)
    assert(ok, "pending_queue.write_pair: metadata write failed: " .. tostring(err))
end

function M.enqueue(payload_zip_bytes, metadata_json, local_id)
    assert(type(local_id) == "string" and #local_id > 0,
        "pending_queue.enqueue: local_id required (must match the X-Report-Local-Id used on the first attempt to enable Worker idempotency)")
    ensure_root()
    local pairs_list = list_pairs()
    if #pairs_list >= MAX_PAIRS then
        local oldest = pairs_list[1]
        delete_pair(oldest.id)
        signals.emit("bug_report_queue_cap_warning", { dropped_id = oldest.id })
    end
    write_pair(local_id, payload_zip_bytes, metadata_json)
    return local_id
end

local function post_one_then_continue(entries, idx, install_id, nonce, on_done)
    if idx > #entries then on_done(); return end
    local entry = entries[idx]
    local meta_path = root .. "/" .. entry.id .. ".metadata.json"
    local zip_path  = root .. "/" .. entry.id .. ".payload.zip"
    local mf = io.open(meta_path, "r")
    local zf = io.open(zip_path, "rb")
    if not (mf and zf) then
        if mf then mf:close() end
        if zf then zf:close() end
        delete_pair(entry.id)
        return post_one_then_continue(entries, idx + 1, install_id, nonce, on_done)
    end
    local metadata = mf:read("*a"); mf:close()
    local zip_bytes = zf:read("*a"); zf:close()
    local transport = require("bug_reporter.transport")
    transport.post_report(metadata, zip_bytes, entry.id, install_id, nonce, function(result)
        if result.ok then
            delete_pair(entry.id)
            return post_one_then_continue(entries, idx + 1, install_id, nonce, on_done)
        end
        if result.code == "rate_limited" then
            log.event("pending_queue: 429 during drain — dropping %s", entry.id)
            delete_pair(entry.id)
            return post_one_then_continue(entries, idx + 1, install_id, nonce, on_done)
        end
        log.warn("pending_queue: transport/server error during drain (%s) — stopping",
            tostring(result.code))
        on_done()
    end)
end

function M.drain(install_id, nonce, on_done)
    on_done = on_done or function() end
    ensure_root()
    local pairs_list = list_pairs()
    post_one_then_continue(pairs_list, 1, install_id, nonce, on_done)
end

return M
