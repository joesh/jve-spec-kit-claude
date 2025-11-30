-- Rational Time Library
-- Provides frame-accurate time representation (Frame Count @ Frame Rate).
-- Replaces floating-point time calculations.

local Rational = {}
local Rational_mt = { __index = Rational }

-- Helper: Check for integer (works in Lua 5.1/JIT)
local function is_integer(n)
    return type(n) == "number" and n % 1 == 0
end

-- Helper: Strict Validation
local function validate_inputs(frames, num, den)
    if not is_integer(frames) then
        error(string.format("Rational.new: frames must be integer, got %s", tostring(frames)), 3)
    end
    if not is_integer(num) then
        error(string.format("Rational.new: fps_numerator must be integer, got %s", tostring(num)), 3)
    end
    if num <= 0 then
        error(string.format("Rational.new: fps_numerator must be positive, got %d", num), 3)
    end
    if den ~= nil then
        if not is_integer(den) then
            error(string.format("Rational.new: fps_denominator must be integer, got %s", tostring(den)), 3)
        end
        if den <= 0 then
            error(string.format("Rational.new: fps_denominator must be positive, got %d", den), 3)
        end
    end
end

--- Create a new Rational time object.
-- @param frames integer Frame count
-- @param fps_numerator integer Frame rate numerator (e.g. 24, 30000)
-- @param fps_denominator integer (Optional) Frame rate denominator (default 1)
-- @return Rational
function Rational.new(frames, fps_numerator, fps_denominator)
    fps_denominator = fps_denominator or 1
    validate_inputs(frames, fps_numerator, fps_denominator)

    local t = {
        frames = frames,
        fps_numerator = fps_numerator,
        fps_denominator = fps_denominator
    }
    setmetatable(t, Rational_mt)
    return t
end

Rational.metatable = Rational_mt

--- Convert a float seconds value to Rational (UI helper only).
-- @param seconds number
-- @param fps_numerator integer
-- @param fps_denominator integer
-- @return Rational
function Rational.from_seconds(seconds, fps_numerator, fps_denominator)
    if type(seconds) ~= "number" then
        error("Rational.from_seconds: seconds must be a number", 2)
    end
    fps_denominator = fps_denominator or 1
    
    -- Math: seconds * (num/den) = frames
    local rate = fps_numerator / fps_denominator
    local frames = math.floor(seconds * rate + 0.5)
    
    return Rational.new(frames, fps_numerator, fps_denominator)
end

--- Rescale time to a new frame rate.
-- @param target_fps_num integer
-- @param target_fps_den integer
-- @return Rational New object
function Rational:rescale(target_fps_num, target_fps_den)
    target_fps_den = target_fps_den or 1
    validate_inputs(0, target_fps_num, target_fps_den) -- Validate rate args only

    if self.fps_numerator == target_fps_num and self.fps_denominator == target_fps_den then
        return Rational.new(self.frames, self.fps_numerator, self.fps_denominator)
    end

    -- Math: new_frames = old_frames * (new_rate / old_rate)
    -- new_frames = old_frames * (new_num / new_den) / (old_num / old_den)
    -- new_frames = (old_frames * new_num * old_den) / (new_den * old_num)
    
    local num = self.frames * target_fps_num * self.fps_denominator
    local den = target_fps_den * self.fps_numerator
    
    -- Integer division with rounding (floor(x + 0.5))
    -- For division a/b, round(a/b) = floor((a + b/2) / b)
    local new_frames = math.floor((num + (den / 2)) / den)
    
    return Rational.new(new_frames, target_fps_num, target_fps_den)
end

function Rational:rescale_floor(target_fps_num, target_fps_den)
    target_fps_den = target_fps_den or 1
    validate_inputs(0, target_fps_num, target_fps_den)

    if self.fps_numerator == target_fps_num and self.fps_denominator == target_fps_den then
        return Rational.new(self.frames, self.fps_numerator, self.fps_denominator)
    end

    local num = self.frames * target_fps_num * self.fps_denominator
    local den = target_fps_den * self.fps_numerator
    
    local new_frames = math.floor(num / den)
    return Rational.new(new_frames, target_fps_num, target_fps_den)
end

function Rational:rescale_ceil(target_fps_num, target_fps_den)
    target_fps_den = target_fps_den or 1
    validate_inputs(0, target_fps_num, target_fps_den)

    if self.fps_numerator == target_fps_num and self.fps_denominator == target_fps_den then
        return Rational.new(self.frames, self.fps_numerator, self.fps_denominator)
    end

    local num = self.frames * target_fps_num * self.fps_denominator
    local den = target_fps_den * self.fps_numerator
    
    local new_frames = math.ceil(num / den)
    return Rational.new(new_frames, target_fps_num, target_fps_den)
end

--- Add two Rational times.
-- If rates differ, rhs is rescaled to lhs rate.
-- @param other Rational
-- @return Rational
function Rational_mt.__add(lhs, rhs)
    if type(lhs) == "number" then
        if getmetatable(rhs) == Rational_mt then
            lhs = Rational.new(lhs, rhs.fps_numerator, rhs.fps_denominator)
        else
            error("Rational:add: lhs is number but rhs is not Rational", 2)
        end
    elseif type(rhs) == "number" then
        if getmetatable(lhs) == Rational_mt then
            rhs = Rational.new(rhs, lhs.fps_numerator, lhs.fps_denominator)
        else
            error("Rational:add: rhs is number but lhs is not Rational", 2)
        end
    end

    if not (type(lhs) == "table" and lhs.fps_numerator) then
        error("Rational:add: lhs must be Rational (got " .. type(lhs) .. ")", 2)
    end
    if not (type(rhs) == "table" and rhs.fps_numerator) then
        error("Rational:add: rhs must be Rational (got " .. type(rhs) .. ")", 2)
    end

    local rhs_rescaled = rhs
    if lhs.fps_numerator ~= rhs.fps_numerator or lhs.fps_denominator ~= rhs.fps_denominator then
        rhs_rescaled = rhs:rescale(lhs.fps_numerator, lhs.fps_denominator)
    end

    return Rational.new(
        lhs.frames + rhs_rescaled.frames,
        lhs.fps_numerator,
        lhs.fps_denominator
    )
end

--- Subtract two Rational times.
-- If rates differ, rhs is rescaled to lhs rate.
-- @param other Rational
-- @return Rational
function Rational_mt.__sub(lhs, rhs)
    if type(lhs) == "number" then
        if getmetatable(rhs) == Rational_mt then
            lhs = Rational.new(lhs, rhs.fps_numerator, rhs.fps_denominator)
        else
            error("Rational:sub: lhs is number but rhs is not Rational", 2)
        end
    elseif type(rhs) == "number" then
        if getmetatable(lhs) == Rational_mt then
            rhs = Rational.new(rhs, lhs.fps_numerator, lhs.fps_denominator)
        else
            error("Rational:sub: rhs is number but lhs is not Rational", 2)
        end
    end

    if not (type(lhs) == "table" and lhs.fps_numerator) then
        error("Rational:sub: lhs must be Rational (got " .. type(lhs) .. ")", 2)
    end
    if not (type(rhs) == "table" and rhs.fps_numerator) then
        error("Rational:sub: rhs must be Rational (got " .. type(rhs) .. ")", 2)
    end

    local rhs_rescaled = rhs
    if lhs.fps_numerator ~= rhs.fps_numerator or lhs.fps_denominator ~= rhs.fps_denominator then
        rhs_rescaled = rhs:rescale(lhs.fps_numerator, lhs.fps_denominator)
    end

    return Rational.new(
        lhs.frames - rhs_rescaled.frames,
        lhs.fps_numerator,
        lhs.fps_denominator
    )
end

--- Check equality.
function Rational_mt.__eq(lhs, rhs)
    if type(lhs) == "number" and getmetatable(rhs) == Rational_mt then
        lhs = Rational.new(lhs, rhs.fps_numerator, rhs.fps_denominator)
    elseif type(rhs) == "number" and getmetatable(lhs) == Rational_mt then
        rhs = Rational.new(rhs, lhs.fps_numerator, lhs.fps_denominator)
    end

    if getmetatable(lhs) ~= Rational_mt or getmetatable(rhs) ~= Rational_mt then
        return false
    end
    
    -- Optimization: identical rates
    if lhs.fps_numerator == rhs.fps_numerator and lhs.fps_denominator == rhs.fps_denominator then
        return lhs.frames == rhs.frames
    end

    -- Cross multiplication to compare values
    -- frames_a * (num_b / den_b) == frames_b * (num_a / den_a)
    -- frames_a * num_b * den_a == frames_b * num_a * den_b
    
    local lhs_val = lhs.frames * rhs.fps_numerator * lhs.fps_denominator
    local rhs_val = rhs.frames * lhs.fps_numerator * rhs.fps_denominator
    
    return lhs_val == rhs_val
end

--- Less than.
function Rational_mt.__lt(lhs, rhs)
    if type(lhs) == "number" and getmetatable(rhs) == Rational_mt then
        lhs = Rational.new(lhs, rhs.fps_numerator, rhs.fps_denominator)
    elseif type(rhs) == "number" and getmetatable(lhs) == Rational_mt then
        rhs = Rational.new(rhs, lhs.fps_numerator, lhs.fps_denominator)
    end

    if getmetatable(lhs) ~= Rational_mt or getmetatable(rhs) ~= Rational_mt then
        error("Rational:lt: operands must be Rational or number", 2)
    end
    
    local lhs_val = lhs.frames * lhs.fps_denominator * rhs.fps_numerator
    local rhs_val = rhs.frames * rhs.fps_denominator * lhs.fps_numerator
    
    return lhs_val < rhs_val
end

--- Convert to float seconds (UI Helper).
-- @return number
function Rational:to_seconds()
    local rate = self.fps_numerator / self.fps_denominator
    return self.frames / rate
end

--- String representation.
function Rational_mt.__tostring(self)
    if self.fps_denominator == 1 then
        return string.format("Rational(%d @ %d/1)", self.frames, self.fps_numerator)
    else
        return string.format("Rational(%d @ %d/%d)", self.frames, self.fps_numerator, self.fps_denominator)
    end
end

--- Unary minus.
function Rational_mt.__unm(self)
    return Rational.new(-self.frames, self.fps_numerator, self.fps_denominator)
end

--- Multiply a Rational object by a number.
-- @param lhs Rational|number
-- @param rhs number|Rational
-- @return Rational
function Rational_mt.__mul(lhs, rhs)
    if type(lhs) == "number" and getmetatable(rhs) == Rational_mt then
        -- number * Rational
        local new_frames = math.floor(rhs.frames * lhs + 0.5)
        return Rational.new(new_frames, rhs.fps_numerator, rhs.fps_denominator)
    elseif getmetatable(lhs) == Rational_mt and type(rhs) == "number" then
        -- Rational * number
        local new_frames = math.floor(lhs.frames * rhs + 0.5)
        return Rational.new(new_frames, lhs.fps_numerator, lhs.fps_denominator)
    else
        error("Rational:mul: operands must be Rational and number", 2)
    end
end

--- Divide a Rational object by a number or another Rational.
-- @param lhs Rational
-- @param rhs number|Rational
-- @return Rational (if rhs is number) or number (if rhs is Rational)
function Rational_mt.__div(lhs, rhs)
    if getmetatable(lhs) ~= Rational_mt then
        error("Rational:div: lhs must be a Rational object", 2)
    end

    if type(rhs) == "number" then
        if rhs == 0 then
            error("Rational:div: division by zero", 2)
        end
        local new_frames = math.floor(lhs.frames / rhs + 0.5) -- Round half up
        return Rational.new(new_frames, lhs.fps_numerator, lhs.fps_denominator)
    elseif getmetatable(rhs) == Rational_mt then
        -- Return ratio of durations (scalar number)
        -- Duration A = framesA * denA / numA
        -- Duration B = framesB * denB / numB
        -- Ratio = (framesA * denA * numB) / (framesB * denB * numA)
        
        local num = lhs.frames * lhs.fps_denominator * rhs.fps_numerator
        local den = rhs.frames * rhs.fps_denominator * lhs.fps_numerator
        
        if den == 0 then
             error("Rational:div: division by zero duration", 2)
        end
        
        return num / den
    else
        error("Rational:div: rhs must be a number or Rational object", 2)
    end
end

--- Get the maximum of two Rational objects.
-- Rescales if rates differ.
-- @param r1 Rational
-- @param r2 Rational
-- @return Rational
function Rational.max(r1, r2)
    if getmetatable(r1) ~= Rational_mt or getmetatable(r2) ~= Rational_mt then
        error("Rational.max: operands must be Rational objects", 2)
    end

    if r1.fps_numerator ~= r2.fps_numerator or r1.fps_denominator ~= r2.fps_denominator then
        r2 = r2:rescale(r1.fps_numerator, r1.fps_denominator)
    end

    if r1.frames >= r2.frames then
        return r1
    else
        return r2
    end
end

return Rational
