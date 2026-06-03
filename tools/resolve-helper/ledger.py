# Idempotency ledger — replay slot for state-changing verbs (FR-008).
#
# Key derives from (verb, change_token) for state-changing verbs. NOT
# from correlation id. A re-sent request with the same key returns the
# cached response. Process-local: the ledger evaporates on helper
# restart (FR-021 — helper holds no persistent model). Re-importing
# after a restart is correct: JVE's change_token updates on the next
# user action; the helper happily redoes the work.

STATE_CHANGING_VERBS_REQUIRE_TOKEN = {
    "import_timeline":        True,
    "stamp_identity_marker":  True,
    "delete_timeline":        True,
}


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
        # Key mirrors `src/lua/core/resolve_bridge/protocol.lua::
        # idempotency_key`: (verb, change_token) for every state-
        # changing verb.
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
        return "|".join([
            verb,
            ct["project_id"],
            ct["sequence_id"],
            str(ct["mutation_generation"]),
        ])

    def lookup(self, key):
        return self._cache.get(key)

    def store(self, key, response):
        self._cache[key] = response
