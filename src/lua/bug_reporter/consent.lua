-- Single source of truth for the bug-reporter consent version.
--
-- consent_dialog renders the prompt; telemetry records the user's
-- decision; install.lua persists `consent_version` alongside the
-- nonce. All three must agree on the integer they're talking about.
--
-- Bump CONSENT_VERSION whenever the consent text materially changes
-- (FR-002a). Worker re-prompt logic compares the stored version to
-- the current one; mismatch triggers re-prompting.

local M = {}

-- v2: consent text updated to point at the new Privacy panel
-- (Cmd+,) for re-enable / revoke instead of "delete install_id.json
-- and relaunch" — the panel landed alongside the bump.
M.CONSENT_VERSION = 2

return M
