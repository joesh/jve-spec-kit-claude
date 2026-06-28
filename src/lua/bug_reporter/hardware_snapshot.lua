-- Hardware snapshot for the bug-reporter pipeline (feature 027 T034).
--
-- Composes uname + CPU + memory + GPU bindings into a single record
-- that matches the shape persisted in ~/.jve/install_id.json and the
-- shape POSTed to /register and (on jve_sha bump) /heartbeat.

local M = {}

function M.snapshot()
    local uname = qt_get_uname()
    assert(uname and type(uname.platform) == "string" and uname.platform ~= "",
        "hardware_snapshot: qt_get_uname returned no platform")
    assert(type(uname.arch) == "string" and uname.arch ~= "",
        "hardware_snapshot: qt_get_uname returned no arch")

    local cpu = qt_get_cpu_info()
    local mem = qt_get_system_memory_mb()
    -- GPU binding only exists on macOS; non-Mac falls back to a stub
    -- record with vendor="Unknown" so the data-model shape stays
    -- stable across platforms.
    local gpu
    if qt_get_gpu_info_metal then
        gpu = qt_get_gpu_info_metal()
    else
        gpu = { vendor = "Unknown", model = nil, memory_mb = nil, api = "Unknown", unified_memory = false }
    end

    return {
        platform         = uname.platform,
        os_version       = uname.os_version,
        arch             = uname.arch,
        cpu              = cpu,
        system_memory_mb = mem,
        gpu              = gpu,
    }
end

return M
