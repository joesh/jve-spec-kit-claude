#!/usr/bin/env python3
"""
Golden Test 3 Validation Script

Validates that analyze_lua_structure.py correctly ACCEPTS small, well-factored
micro-clusters without inventing leverage points (Step 3).

CRITICAL ASSERTIONS:
- Cluster must be accepted (not rejected for size)
- Nucleus must be identified: clip_audio_inspector.clip_has_audio
- NO leverage point must be reported
- NO extraction recommendation (explicit restraint)
- Must state cluster is well-factored
- Must state no refactoring recommended

Any failure indicates over-rejection of small algorithms.
"""

import subprocess
import sys
import re
from pathlib import Path

# Expected values (CONTRACT)
EXPECTED_NUCLEUS = "clip_audio_inspector.clip_has_audio"
EXPECTED_CLUSTER_SIZE = 2
REQUIRED_OUTPUT_FRAGMENTS = [
    "clear nucleus around",
    "small",
    "well-factored",
    "No leverage points identified",
    "No refactoring recommended",
]
PROHIBITED_OUTPUT_FRAGMENTS = [
    "Extracting",  # Must NOT recommend extraction
    "into a focused module",  # Must NOT suggest splitting
    "leverage point is",  # Must NOT identify leverage point (only "No leverage points")
]


class ValidationError(Exception):
    """Raised when Golden Test 3 fails validation."""
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


def parse_acceptance_output(output, stderr):
    """Extract acceptance information from analysis output."""
    data = {
        'accepted': False,
        'nucleus': None,
        'cluster_size': None,
        'has_leverage_point': False,
        'has_extraction_rec': False,
        'states_well_factored': False,
        'states_no_refactor': False,
        'required_fragments': [],
        'prohibited_fragments_found': [],
    }

    # Check if cluster was accepted (has CLUSTER heading)
    if re.search(r'CLUSTER \d+', output):
        data['accepted'] = True

    # Extract nucleus
    nucleus_match = re.search(r'clear nucleus around ([\w.:_]+)', output)
    if nucleus_match:
        data['nucleus'] = nucleus_match.group(1)

    # Extract cluster size from output
    size_match = re.search(r'small \((\d+) functions?\)', output)
    if size_match:
        data['cluster_size'] = int(size_match.group(1))

    # Check for prohibited outputs (must NOT appear)
    if re.search(r'primary leverage point is', output):
        data['has_leverage_point'] = True
        data['prohibited_fragments_found'].append('leverage point is')

    if 'Extracting' in output and 'into a focused module' in output:
        data['has_extraction_rec'] = True
        data['prohibited_fragments_found'].append('Extracting ... into a focused module')

    # Check for required fragments
    data['required_fragments'] = [frag for frag in REQUIRED_OUTPUT_FRAGMENTS if frag in output]
    data['states_well_factored'] = 'well-factored' in output
    data['states_no_refactor'] = 'No refactoring recommended' in output

    return data


def validate_results(data):
    """Validate analysis results against Step 3 requirements."""
    failures = []

    # Assertion 1: Cluster must be accepted
    if not data['accepted']:
        failures.append(
            "CLUSTER REJECTED: Micro-cluster was rejected instead of accepted (check for size-based rejection)"
        )

    # Assertion 2: Nucleus must be identified
    if data['nucleus'] != EXPECTED_NUCLEUS:
        failures.append(
            f"WRONG NUCLEUS: Expected '{EXPECTED_NUCLEUS}', got '{data['nucleus']}'"
        )

    # Assertion 3: Cluster size must match
    if data['cluster_size'] != EXPECTED_CLUSTER_SIZE:
        failures.append(
            f"WRONG CLUSTER SIZE: Expected {EXPECTED_CLUSTER_SIZE}, got {data['cluster_size']}"
        )

    # Assertion 4: Must NOT identify leverage point
    if data['has_leverage_point']:
        failures.append(
            "LEVERAGE POINT INVENTED: Micro-cluster should not have leverage point (explicit restraint required)"
        )

    # Assertion 5: Must NOT recommend extraction
    if data['has_extraction_rec']:
        failures.append(
            "EXTRACTION RECOMMENDED: Micro-cluster should explicitly state 'No refactoring recommended'"
        )

    # Assertion 6: Must state well-factored
    if not data['states_well_factored']:
        failures.append(
            "MISSING WELL-FACTORED STATEMENT: Must explicitly state cluster is well-factored"
        )

    # Assertion 7: Must state no refactoring
    if not data['states_no_refactor']:
        failures.append(
            "MISSING NO-REFACTOR STATEMENT: Must explicitly state 'No refactoring recommended'"
        )

    # Assertion 8: All required fragments present
    missing_fragments = set(REQUIRED_OUTPUT_FRAGMENTS) - set(data['required_fragments'])
    if missing_fragments:
        failures.append(
            f"MISSING REQUIRED FRAGMENTS: {missing_fragments}"
        )

    # Assertion 9: No prohibited fragments
    if data['prohibited_fragments_found']:
        failures.append(
            f"PROHIBITED FRAGMENTS FOUND: {data['prohibited_fragments_found']} (violates explicit restraint)"
        )

    return failures


def main():
    print("=" * 70)
    print("GOLDEN TEST 3: Micro-Cluster Acceptance")
    print("=" * 70)
    print()
    print("Testing: clip_audio_inspector.lua")
    print(f"Requirement: Accept with explicit restraint (Step 3)")
    print()

    try:
        # Run analysis
        print("Running analyzer...")
        output, stderr = run_analysis("clip_audio_inspector.lua")

        # Parse results
        print("Parsing results...")
        data = parse_acceptance_output(output, stderr)

        # Display findings
        print()
        print("Found Results:")
        print(f"  Accepted: {data['accepted']}")
        print(f"  Nucleus: {data['nucleus']}")
        print(f"  Cluster size: {data['cluster_size']}")
        print(f"  Has leverage point: {data['has_leverage_point']} (should be False)")
        print(f"  Has extraction rec: {data['has_extraction_rec']} (should be False)")
        print(f"  States well-factored: {data['states_well_factored']} (should be True)")
        print(f"  States no refactor: {data['states_no_refactor']} (should be True)")
        print()

        # Validate against specification
        print("Validating against Step 3 requirements...")
        failures = validate_results(data)

        if failures:
            print()
            print("❌ VALIDATION FAILED")
            print("=" * 70)
            for failure in failures:
                print(f"  • {failure}")
            print()
            print("DIAGNOSIS:")
            print("  - Review leverage point detection logic in _analysis_for_cluster()")
            print("  - Check is_micro_cluster and skip_leverage_for_micro flags")
            print("  - Verify output generation includes 'No refactoring recommended' branch")
            print("  - Ensure ≤4 function check is working correctly")
            print()
            sys.exit(1)
        else:
            print("✅ ALL ASSERTIONS PASSED")
            print()
            print("Golden Test 3 validates:")
            print(f"  ✓ Cluster accepted: {EXPECTED_NUCLEUS}")
            print(f"  ✓ Cluster size: {EXPECTED_CLUSTER_SIZE} functions")
            print(f"  ✓ No leverage point identified (explicit restraint)")
            print(f"  ✓ No extraction recommended")
            print(f"  ✓ States well-factored")
            print(f"  ✓ States no refactoring needed")
            print()
            print("Step 3 requirement satisfied: Small, well-factored algorithms")
            print("correctly accepted without over-aggressive refactoring suggestions.")
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
