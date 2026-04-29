-- Edge-case test (014, T011): handlers tolerate nil incoming/outgoing payloads.
--
-- Spec ref: spec.md edge case #2, FR-001, FR-002.
--
-- Domain: closing the active project ends with the editor in the
-- no-active-project state. The pre-switch signal fires with outgoing
-- = the closing project; the post-switch signal fires with incoming
-- = nil. Handlers MUST tolerate the nil payload without erroring.
--
-- Production scope note: at planning time, JVE has no `close_project`
-- command — every project switch goes through OpenProject which
-- replaces one project with another. The "close, no replacement"
-- transition WIRING is out of scope for feature 014. What IS in
-- scope: the contract that handlers can be invoked with nil payloads
-- (cold start uses outgoing=nil; future close uses incoming=nil).
-- This test pins handler-side nil tolerance using direct signal
-- emission. T010 covers cold-start outgoing=nil end-to-end via the
-- production swap primitive.
--
-- Red today: project_will_change is not registered/documented as
-- a known signal in core/signals.lua. After T016 lands the
-- documentation, this test passes (the dispatcher is already
-- generic over signal names; the contract test fixes the
-- handler-tolerance shape).
--
-- NSF: explicitly verifies handler invocation AND payload nil-ness;
-- explicitly verifies no error propagates from handler invocation.

require("test_env")

local Signals = require("core.signals")

print("=== test_project_switch_close_no_replacement ===")

-- ----------------------------------------------------------------------
-- Register handlers; emit with nil payloads; verify tolerance.
-- ----------------------------------------------------------------------

Signals.clear_all()

local pre = { fired = false }
local post = { fired = false }

local pre_conn = Signals.connect("project_will_change", function(outgoing)
    pre.fired = true
    pre.outgoing = outgoing
    pre.outgoing_type = type(outgoing)
end)
assert(type(pre_conn) == "number",
    "PRECONDITION: Signals.connect must succeed for project_will_change")

local post_conn = Signals.connect("project_changed", function(incoming)
    post.fired = true
    post.incoming = incoming
    post.incoming_type = type(incoming)
end)
assert(type(post_conn) == "number",
    "PRECONDITION: Signals.connect must succeed for project_changed")

-- Pre-switch with outgoing = nil (cold-start-style payload, also valid
-- for close-no-replacement during the post phase).
local pre_emit_ok = pcall(function() Signals.emit("project_will_change", nil) end)
assert(pre_emit_ok, "pre-emit must not propagate handler errors")

-- Post-switch with incoming = nil (close-no-replacement).
local post_emit_ok = pcall(function() Signals.emit("project_changed", nil) end)
assert(post_emit_ok, "post-emit must not propagate handler errors")

-- ----------------------------------------------------------------------
-- Assertions: both handlers ran AND saw nil payloads cleanly.
-- ----------------------------------------------------------------------

assert(pre.fired,
    "NIL TOLERANCE: pre-switch handler must run when emit(..., nil)")
assert(pre.outgoing == nil, string.format(
    "NIL TOLERANCE: pre-handler must observe outgoing=nil exactly\n" ..
    "  (not '' and not omitted). Got: %q (type %s).",
    tostring(pre.outgoing), pre.outgoing_type))
print("  ✓ pre-switch handler tolerates outgoing=nil")

assert(post.fired,
    "NIL TOLERANCE: post-switch handler must run when emit(..., nil)")
assert(post.incoming == nil, string.format(
    "NIL TOLERANCE: post-handler must observe incoming=nil exactly\n" ..
    "  (not '' and not omitted). Got: %q (type %s).",
    tostring(post.incoming), post.incoming_type))
print("  ✓ post-switch handler tolerates incoming=nil")

Signals.clear_all()

print("✅ test_project_switch_close_no_replacement passed")
