#!/usr/bin/env python3
"""
Golden Test 2 Validation Script

Validates that analyze_lua_structure.py correctly REJECTS boilerplate-dominated
clusters with structured explanation (Step 2).

CRITICAL ASSERTIONS:
- Cluster must be rejected (no nucleus, no leverage point, no extraction recommendation)
- Rejection reason must be 'boilerplate_dominated'
- Must emit structured explanation with:
  - No semantic nucleus detected
  - Reason: boilerplate dominance
  - Nature of code (lifecycle/registration/wiring/setup)
  - Why refactoring would be unsafe
  - No leverage points for extraction
  - Recommendation to keep as-is

Any failure indicates regression in boilerplate rejection logic.
"""

import subprocess
import sys
import re
from pathlib import Path

# Expected values (CONTRACT)
EXPECTED_REJECTION_REASON = "boilerplate_dominated"
REQUIRED_OUTPUT_FRAGMENTS = [
    "Cluster rejected:",
    "No semantic nucleus detected",
    "Reason: boilerplate dominance",
    "Nature of code:",
    "Why refactoring would be unsafe:",
    "No leverage points for extraction",
    "Recommendation:",
]


class ValidationError(Exception):
    """Raised when Golden Test 2 fails validation."""
    pass


def run_analysis(lua_file):
    """Run analyze_lua_structure.py on target file."""
    script_dir = Path(__file__).parent
    analyzer = script_dir / "analyze_lua_structure.py"

    if not analyzer.exists():
        raise FileNotFoundError(f"Analyzer not found: {analyzer}")

    if not Path(lua_file).exists():
        raise FileNotFoundError(f"Test file not found: {lua_file}")

    result = subprocess.run(
        ["python3", str(analyzer), lua_file],
        capture_output=True,
        text=True,
        cwd=script_dir.parent  # Run from repo root
    )

    if result.returncode != 0:
        raise RuntimeError(f"Analyzer failed: {result.stderr}")

    return result.stdout, result.stderr


def parse_rejection_output(output, stderr):
    """Extract rejection information from analysis output."""
    data = {
        'rejected': False,
        'rejection_reason': None,
        'has_nucleus': False,
        'has_leverage_point': False,
        'has_extraction_recommendation': False,
        'structured_explanation': False,
        'nature_of_code': [],
    }

    # Check if cluster was rejected (stderr diagnostic)
    if 'rejected: boilerplate_dominated' in stderr:
        data['rejected'] = True
        data['rejection_reason'] = 'boilerplate_dominated'

    # Check for incorrectly emitted outputs (should NOT appear)
    if re.search(r'CLUSTER \d+', output):
        data['has_nucleus'] = True  # Cluster was accepted, not rejected

    if re.search(r'leverage point is', output):
        data['has_leverage_point'] = True

    if 'Extracting' in output and 'into a focused module' in output:
        data['has_extraction_recommendation'] = True

    # Check for required structured explanation fragments
    fragments_found = [frag for frag in REQUIRED_OUTPUT_FRAGMENTS if frag in output]
    data['structured_explanation'] = (len(fragments_found) == len(REQUIRED_OUTPUT_FRAGMENTS))
    data['fragments_found'] = fragments_found

    # Extract nature of code
    nature_match = re.search(r'Nature of code:\s+([^\n]+)', output)
    if nature_match:
        data['nature_of_code'] = [n.strip() for n in nature_match.group(1).split(',')]

    return data


def validate_results(data):
    """Validate analysis results against Step 2 requirements."""
    failures = []

    # Assertion 1: Cluster must be rejected
    if not data['rejected']:
        failures.append(
            "CLUSTER NOT REJECTED: Boilerplate-dominated cluster was accepted instead of rejected"
        )

    # Assertion 2: Rejection reason must be 'boilerplate_dominated'
    if data['rejection_reason'] != EXPECTED_REJECTION_REASON:
        failures.append(
            f"WRONG REJECTION REASON: Expected '{EXPECTED_REJECTION_REASON}', got '{data['rejection_reason']}'"
        )

    # Assertion 3: Must NOT emit nucleus
    if data['has_nucleus']:
        failures.append(
            "NUCLEUS EMITTED: Rejected cluster should not have nucleus output (found 'CLUSTER N' heading)"
        )

    # Assertion 4: Must NOT emit leverage point
    if data['has_leverage_point']:
        failures.append(
            "LEVERAGE POINT EMITTED: Rejected cluster should not identify leverage points"
        )

    # Assertion 5: Must NOT recommend extraction
    if data['has_extraction_recommendation']:
        failures.append(
            "EXTRACTION RECOMMENDED: Rejected cluster should explicitly state 'No leverage points for extraction'"
        )

    # Assertion 6: Must emit structured explanation
    if not data['structured_explanation']:
        missing_fragments = set(REQUIRED_OUTPUT_FRAGMENTS) - set(data['fragments_found'])
        failures.append(
            f"INCOMPLETE STRUCTURED EXPLANATION: Missing fragments: {missing_fragments}"
        )

    # Assertion 7: Must identify nature of code
    if not data['nature_of_code']:
        failures.append(
            "MISSING CODE NATURE: Must identify lifecycle/registration/wiring/setup patterns"
        )

    return failures


def main():
    print("=" * 70)
    print("GOLDEN TEST 2: Boilerplate Blob Rejection")
    print("=" * 70)
    print()
    print("Testing: lifecycle_coordinator.lua")
    print(f"Requirement: Reject with structured explanation (Step 2)")
    print()

    try:
        # Run analysis
        print("Running analyzer...")
        output, stderr = run_analysis("lifecycle_coordinator.lua")

        # Parse results
        print("Parsing results...")
        data = parse_rejection_output(output, stderr)

        # Display findings
        print()
        print("Found Results:")
        print(f"  Rejected: {data['rejected']}")
        print(f"  Rejection reason: {data['rejection_reason']}")
        print(f"  Structured explanation: {data['structured_explanation']}")
        print(f"  Nature of code: {', '.join(data['nature_of_code']) if data['nature_of_code'] else 'NONE'}")
        print(f"  Has nucleus: {data['has_nucleus']} (should be False)")
        print(f"  Has leverage point: {data['has_leverage_point']} (should be False)")
        print(f"  Has extraction rec: {data['has_extraction_recommendation']} (should be False)")
        print()

        # Validate against specification
        print("Validating against Step 2 requirements...")
        failures = validate_results(data)

        if failures:
            print()
            print("❌ VALIDATION FAILED")
            print("=" * 70)
            for failure in failures:
                print(f"  • {failure}")
            print()
            print("DIAGNOSIS:")
            print("  - Review boilerplate domination logic in validate_and_split_clusters()")
            print("  - Check that lifecycle pattern detection is working (is_*, set_*, init, setup, etc.)")
            print("  - Verify boilerplate check happens BEFORE competing nuclei check")
            print("  - Ensure structured explanation output in print_text()")
            print()
            sys.exit(1)
        else:
            print("✅ ALL ASSERTIONS PASSED")
            print()
            print("Golden Test 2 validates:")
            print(f"  ✓ Cluster rejected: {data['rejection_reason']}")
            print(f"  ✓ Structured explanation emitted")
            print(f"  ✓ Nature identified: {', '.join(data['nature_of_code'])}")
            print(f"  ✓ No nucleus emitted")
            print(f"  ✓ No leverage point emitted")
            print(f"  ✓ No extraction recommended")
            print()
            print("Step 2 requirement satisfied: Boilerplate blobs correctly rejected")
            print("with structured explanation about why refactoring is unsafe.")
            print()
            sys.exit(0)

    except FileNotFoundError as e:
        print(f"❌ ERROR: {e}")
        sys.exit(2)
    except Exception as e:
        print(f"❌ UNEXPECTED ERROR: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(2)


if __name__ == "__main__":
    main()
