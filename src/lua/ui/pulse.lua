--- Reusable opacity pulse for "in progress" labels.
--
-- The pulser owns the WHOLE visibility lifecycle of an in-progress message:
-- start() puts the message up and animates it; stop() takes it down. Each
-- side of the lifecycle is a caller-supplied callback so the pulser stays
-- agnostic of the widget shape and the surrounding QSS:
--
--   opts.show(rgba_color)   — called every frame while active; the caller
--                             paints the message (set text + styled bar)
--                             using the supplied "rgba(r,g,b,a)" text colour.
--   opts.hide()             — called once on stop(); the caller takes the
--                             message down (clear text + transparent bar).
--
-- The pulse curve is a cosine ease between A_MIN and A_MAX, PERIOD_S per
-- cycle. A generation counter invalidates any in-flight chained timer so
-- a late tick after stop() can neither re-paint nor re-arm.
--
-- Future: a colour tween between two RGB endpoints would slot in next to
-- the alpha tween here (same clock, same show/hide contract, different
-- formatter). Kept out of scope here — current callers only need opacity.
local pulse = {}
pulse.__index = pulse

-- Tunables. Exposed on the module so tests can read them without
-- duplicating magic numbers (Joe: "we'll probably make use of a color
-- tween later" — these constants will be reused by that path).
pulse.PERIOD_S = 3.0
pulse.A_MIN    = 0.20
pulse.A_MAX    = 1.00
pulse.STEP_MS  = 33   -- ~30Hz; smooth enough for a slow pulse, cheap

local function hex_to_rgb(hex)
    local h = hex:gsub("^#", "")
    assert(#h == 6, "pulse.attach: base_hex must be #rrggbb, got " .. tostring(hex))
    local r = tonumber(h:sub(1, 2), 16)
    local g = tonumber(h:sub(3, 4), 16)
    local b = tonumber(h:sub(5, 6), 16)
    assert(r and g and b, "pulse.attach: base_hex not hex: " .. tostring(hex))
    return r, g, b
end

local function format_rgba(r, g, b, a)
    return string.format("rgba(%d,%d,%d,%.3f)", r, g, b, a)
end

local function alpha_at(t)
    -- Cosine ease: at phase 0 → s=0 → A_MIN; at phase 0.5 → s=1 → A_MAX.
    local phase = (t % pulse.PERIOD_S) / pulse.PERIOD_S
    local s = (1 - math.cos(phase * 2 * math.pi)) * 0.5
    return pulse.A_MIN + (pulse.A_MAX - pulse.A_MIN) * s
end

--- Attach a pulser.
-- opts.show     (required) function(rgba_color) — paint the message with
--               this text colour. Called once on start() and every STEP_MS
--               thereafter until stop().
-- opts.hide     (required) function() — take the message down. Called
--               exactly once per active→inactive transition.
-- opts.base_rgb {r,g,b} integers 0..255, OR
-- opts.base_hex "#rrggbb"
function pulse.attach(opts)
    assert(type(opts) == "table", "pulse.attach: opts table required")
    assert(type(opts.show) == "function", "pulse.attach: opts.show function required")
    assert(type(opts.hide) == "function", "pulse.attach: opts.hide function required")
    local r, g, b
    if opts.base_rgb then
        r, g, b = opts.base_rgb[1], opts.base_rgb[2], opts.base_rgb[3]
        assert(r and g and b, "pulse.attach: base_rgb needs 3 components")
    else
        assert(opts.base_hex, "pulse.attach: base_rgb or base_hex required")
        r, g, b = hex_to_rgb(opts.base_hex)
    end
    return setmetatable({
        show = opts.show,
        hide = opts.hide,
        r = r, g = g, b = b,
        active = false,
        t0 = 0,
        gen = 0,
    }, pulse)
end

function pulse:_tick(gen)
    -- Stale-timer guard: stop() bumps gen; a late callback whose gen
    -- doesn't match must do nothing (no show, no re-arm).
    if not self.active or gen ~= self.gen then return end
    local t = qt_monotonic_s() - self.t0
    self.show(format_rgba(self.r, self.g, self.b, alpha_at(t)))
    local g = self.gen
    qt_create_single_shot_timer(pulse.STEP_MS, function() self:_tick(g) end)
end

function pulse:start()
    if self.active then return end
    self.gen = self.gen + 1
    self.active = true
    self.t0 = qt_monotonic_s()
    self:_tick(self.gen)
end

function pulse:stop()
    -- Idempotent: stop() before any start() (or after a previous stop) is
    -- a no-op so the caller can drive lifecycle from a single boolean
    -- without tracking "did I already stop?".
    if not self.active then return end
    self.gen = self.gen + 1
    self.active = false
    self.hide()
end

return pulse
