# Idempotency ledger — replay slot for state-changing verbs (FR-008).
#
# Key derives from (verb, change_token) for `import_timeline`, and from
# (verb, change_token, spec_hash) for `queue_render` per
# helper-protocol.md (`queue_render` is "idempotent on change token +
# spec hash" — two queue_renders with the same change_token but
# different specs are distinct jobs, not dedup'd). NOT from correlation
# id. A re-sent request with the same key returns the cached response.
# Process-local: the ledger evaporates on helper restart (FR-021 —
# helper holds no persistent model). Re-importing after a restart is
# correct: JVE's change_token updates on the next user action; the
# helper happily redoes the work.

import hashlib
import json

STATE_CHANGING_VERBS_REQUIRE_TOKEN = {
    "import_timeline": True,
    "queue_render": True,
}


def _hash_spec(spec):
    # Deterministic JSON-canonical hash; sort_keys + separators ensure
    # the same spec dict always hashes to the same digest. 16 hex chars
    # of sha256 is more than enough collision resistance for a
    # process-local cache.
    canonical = json.dumps(spec, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:16]


class IdempotencyLedger:
    def __init__(self):
        self._cache = {}

    def compute_key(self, verb, args):
        # Cache-layer key derivation. NEVER raises on malformed args —
        # returns None instead, leaving the verb's own bad_request
        # validation to surface the problem. Per helper.py only ok=true
        # responses get cached, so a None key for a malformed request
        # just means "no caching" and the verb's bad_request flows
        # through normally.
        #
        # Base key mirrors `src/lua/core/resolve_bridge/protocol.lua::
        # idempotency_key` for the (verb, change_token) shape;
        # `queue_render` extends with the spec hash per
        # helper-protocol.md (two queue_renders with the same
        # change_token but different specs are distinct jobs).
        if not isinstance(args, dict):
            return None
        ct = args.get("change_token")
        if ct is None:
            # Non-state-changing verbs legitimately have no token.
            # State-changing verbs ARE required to carry one
            # (helper-protocol.md FR-008) — but enforcement belongs in
            # the verb so a missing-token request surfaces as
            # bad_request, not as a cache-layer crash.
            return None
        if not (
            isinstance(ct, dict)
            and isinstance(ct.get("project_id"), str)
            and isinstance(ct.get("sequence_id"), str)
            and isinstance(ct.get("mutation_generation"), int)
        ):
            return None
        parts = [
            verb,
            ct["project_id"],
            ct["sequence_id"],
            str(ct["mutation_generation"]),
        ]
        if verb == "queue_render":
            spec = args.get("spec")
            if not isinstance(spec, dict):
                return None
            parts.append(_hash_spec(spec))
        return "|".join(parts)

    def lookup(self, key):
        return self._cache.get(key)

    def store(self, key, response):
        self._cache[key] = response
