local M = {}
function M.now()
    return os.clock() * 1000
end
return M
