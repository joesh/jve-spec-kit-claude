"""Shared helper-side protocol constants.

Mirrors the wire shape documented in
`specs/023-resolve-color-bridge/contracts/helper-protocol.md` and the
JVE side at `src/lua/core/resolve_bridge/protocol.lua`.

This module deliberately holds ONLY the values that both `helper.py`
(server framing) and `verbs.py` (response shape) consume. Verb-
specific request/response derivation stays inside each verb.

Why a third file: until 2026-06-03 `PROTOCOL_VERSION` was hard-coded
in both helper.py and verbs.py. Bumping the wire version meant
remembering to touch both; a divergence would have produced silent
client-server mismatches. Single source removes that footgun (review
item #5).
"""

PROTOCOL_VERSION = 1
