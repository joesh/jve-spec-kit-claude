-- Test helper: convert a JVE clip_grade-model CDL (slope_r/.../saturation)
-- into the helper-protocol §read_grades WIRE CDL shape (slope:[r,g,b],
-- offset:[r,g,b], power:[r,g,b], sat). Lets test fixtures stay
-- model-readable while feeding apply() the contract-shape data.
local M = {}

function M.cdl_model_to_wire(m)
    assert(type(m) == "table", "cdl_model_to_wire: model table required")
    return {
        slope  = { m.slope_r,  m.slope_g,  m.slope_b },
        offset = { m.offset_r, m.offset_g, m.offset_b },
        power  = { m.power_r,  m.power_g,  m.power_b },
        sat    = m.saturation,
    }
end

return M
