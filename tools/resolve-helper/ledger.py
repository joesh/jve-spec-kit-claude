# Idempotency ledger — replay slot for state-changing verbs (FR-008).
#
# Key derives from (verb, change_token, per-verb arg digest) for state-
# changing verbs. NOT from correlation id. A re-sent request with the
# same key returns the cached response. Process-local: the ledger
# evaporates on helper restart (FR-021 — helper holds no persistent
# model). Re-importing after a restart is correct: JVE's change_token
# updates on the next user action; the helper happily redoes the work.

# The "state-changing verbs require a token" gate IS enforced — but in
# two real places: each verb's body calls `_validate_change_token` which
# returns bad_request if the token is missing/malformed (verbs.py), and
# the JVE-side `protocol.lua::idempotency_key` asserts on the way out
# (caller side). There used to be a `STATE_CHANGING_VERBS_REQUIRE_TOKEN`
# dict here that wasn't consulted anywhere — deleted 2026-06-03 to
# remove dead code (review #34). Documentation-only mirroring of the
# JVE list adds no value; the two enforcement sites already cover both
# directions.

import hashlib
import json

# Per-verb args that participate in the cache key beyond change_token.
# Two stamp_identity_marker calls at the same change_token but for
# different (resolve_item_id, custom_data) would otherwise COLLIDE —
# the second would silently return the first's cached response, a
# replay lie (review items #18 + #19). Same class for import_timeline:
# two imports with the same token but different drt_path / media_paths
# / clip_positions would conflate.
_VERB_EXTRA_KEY_FIELDS = {
    "stamp_identity_marker": ["resolve_item_id", "custom_data"],
    "import_timeline":       ["drt_path", "media_paths", "clip_positions"],
    # delete_timeline carries its own resolve_timeline_id discriminator
    # — two delete_timeline calls with the same change_token but
    # different uids would otherwise collide.
    "delete_timeline":       ["resolve_timeline_id"],
    # apply_test_grade: same token applied to two items (or with two
    # different grades) must not conflate.
    "apply_test_grade":      ["resolve_item_id", "cdl", "lut_path"],
}


def _digest_extra(verb, args):
    fields = _VERB_EXTRA_KEY_FIELDS.get(verb)
    if not fields:
        return None
    payload = {k: args.get(k) for k in fields}
    encoded = json.dumps(payload, sort_keys=True,
        separators=(",", ":"), default=str)
    return hashlib.sha256(encoded.encode()).hexdigest()[:16]


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
        # Key shape:
        #   "<verb>|<project>|<seq>|<mut_gen>"
        #   "<verb>|<project>|<seq>|<mut_gen>|<sha256-of-extra-args>"
        # The second form applies to verbs registered in
        # `_VERB_EXTRA_KEY_FIELDS`.
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
        extra = _digest_extra(verb, args)
        if extra is not None:
            parts.append(extra)
        return "|".join(parts)

    def lookup(self, key):
        return self._cache.get(key)

    def store(self, key, response):
        self._cache[key] = response
