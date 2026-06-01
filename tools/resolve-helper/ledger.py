# Idempotency ledger — replay slot for state-changing verbs (FR-008).
#
# Key derives from (verb, change_token), NOT from correlation id. A re-sent
# request with the same key returns the cached response. Process-local: the
# ledger evaporates on helper restart (FR-021 — helper holds no persistent
# model). Re-importing after a restart is correct: JVE's change_token
# updates on the next user action; the helper happily redoes the work.

STATE_CHANGING_VERBS_REQUIRE_TOKEN = {
    "import_timeline": True,
    "queue_render": True,
}


class IdempotencyLedger:
    def __init__(self):
        self._cache = {}

    def compute_key(self, verb, args):
        # Mirror src/lua/core/resolve_bridge/protocol.lua:idempotency_key.
        ct = args.get("change_token")
        if ct is None:
            assert verb not in STATE_CHANGING_VERBS_REQUIRE_TOKEN, (
                f"state-changing verb '{verb}' missing change_token (FR-008)"
            )
            return None
        assert (
            isinstance(ct, dict)
            and isinstance(ct.get("project_id"), str)
            and isinstance(ct.get("sequence_id"), str)
            and isinstance(ct.get("mutation_generation"), int)
        ), (
            "change_token must be "
            "{project_id, sequence_id, mutation_generation}"
        )
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
