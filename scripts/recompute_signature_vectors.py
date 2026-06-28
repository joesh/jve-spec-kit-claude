#!/usr/bin/env python3
"""Recompute expected_sig for every vector in
tests/fixtures/signature_vectors.json from its sig_input_canonical, and
report mismatches. Use after editing fixtures or after any change to
the canonical normalization rules in data-model.md §Signature.

Re-run: ./scripts/recompute_signature_vectors.py
"""
import hashlib
import json
import sys
from pathlib import Path

FIXTURES = Path(__file__).resolve().parent.parent / "tests/fixtures/signature_vectors.json"


def main() -> int:
    data = json.loads(FIXTURES.read_text())
    failures = []
    for v in data["vectors"]:
        actual = hashlib.sha256(v["sig_input_canonical"].encode()).hexdigest()
        marker = "OK" if actual == v["expected_sig"] else "MISMATCH"
        print(f"{marker}\t{v['name']}\t{actual}")
        if actual != v["expected_sig"]:
            failures.append(v["name"])
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
