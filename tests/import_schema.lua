-- Import Schema Helper
-- Loads the full application schema for tests

local function load_schema()
    local paths = {
        "src/lua/schema.sql",
        "../src/lua/schema.sql",
        "../../src/lua/schema.sql"
    }

    for _, path in ipairs(paths) do
        local f = io.open(path, "r")
        if f then
            local content = f:read("*a")
            f:close()
            return content
        end
    end

    error("Could not find src/lua/schema.sql in common search paths")
end

return load_schema()