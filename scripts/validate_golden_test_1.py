#!/usr/bin/env python3
"""
Golden Test 1 Validation Script

Validates that analyze_lua_structure.py produces expected results for project_browser.lua
according to the frozen specification in docs/GOLDEN_TEST_1_SPECIFICATION.md.

CRITICAL ASSERTIONS:
- Nucleus = project_browser.activate_selection (contexts: 2)
- Leverage point = project_browser:update_selection_state (contexts: 4)
- Utility excluded = project_browser.refresh
- Cluster size = 7 functions

Any failure indicates regression in context detection or nucleus scoring.
"""

import subprocess
import sys
import re
from pathlib import Path

# Expected values (CONTRACT)
EXPECTED_NUCLEUS = "project_browser.activate_selection"
EXPECTED_NUCLEUS_CONTEXTS = 2
EXPECTED_LEVERAGE_POINT = "project_browser:update_selection_state"
EXPECTED_LEVERAGE_CONTEXTS = 4
EXPECTED_UTILITY_EXCLUDED = "project_browser.refresh"
EXPECTED_CLUSTER_SIZE = 7

EXPECTED_CLUSTER_FUNCTIONS = {
    "project_browser.activate_selection",
    "project_browser.get_selected_item",
    "project_browser:activate_item",
    "project_browser:apply_single_selection",
    "project_browser:handle_tree_item_changed",
    "project_browser:selection_context",
    "project_browser:update_selection_state",
}


class ValidationError(Exception):
    """Raised when Golden Test 1 fails validation."""
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

    return result.stdout


def parse_analysis_output(output):
    """Extract key values from analysis output."""
    data = {
        'nucleus': None,
        'nucleus_contexts': None,
        'leverage_point': None,
        'leverage_contexts': None,
        'utility_excluded': None,
        'cluster_functions': set(),
    }

    # Extract nucleus from "clear nucleus around <function>"
    nucleus_match = re.search(r'clear nucleus around ([\w.:_]+)', output)
    if nucleus_match:
        data['nucleus'] = nucleus_match.group(1)

    # Extract leverage point from "primary leverage point is <function>"
    leverage_match = re.search(r'primary leverage point is ([\w.:_]+), which touches (\d+) distinct contexts \(nucleus: (\d+)\)', output)
    if leverage_match:
        data['leverage_point'] = leverage_match.group(1)
        data['leverage_contexts'] = int(leverage_match.group(2))
        data['nucleus_contexts'] = int(leverage_match.group(3))

    # Extract utility exclusion
    utility_match = re.search(r'Utilities excluded from clustering.*?\n\s+([\w.:_]+):', output, re.DOTALL)
    if utility_match:
        data['utility_excluded'] = utility_match.group(1)

    # Extract cluster functions (section between "Functions:" and next section)
    functions_section = re.search(r'Functions:\n((?:[\w.:_]+\n)+)', output)
    if functions_section:
        functions_text = functions_section.group(1)
        data['cluster_functions'] = set(line.strip() for line in functions_text.strip().split('\n'))

    return data


def validate_results(data):
    """Validate analysis results against frozen specification."""
    failures = []

    # Assertion 1: Nucleus identity
    if data['nucleus'] != EXPECTED_NUCLEUS:
        failures.append(
            f"NUCLEUS CHANGED: Expected '{EXPECTED_NUCLEUS}', got '{data['nucleus']}'"
        )

    # Assertion 2: Nucleus context count
    if data['nucleus_contexts'] != EXPECTED_NUCLEUS_CONTEXTS:
        failures.append(
            f"NUCLEUS CONTEXTS CHANGED: Expected {EXPECTED_NUCLEUS_CONTEXTS}, got {data['nucleus_contexts']}"
        )

    # Assertion 3: Leverage point identity (CRITICAL)
    if data['leverage_point'] != EXPECTED_LEVERAGE_POINT:
        failures.append(
            f"LEVERAGE POINT CHANGED: Expected '{EXPECTED_LEVERAGE_POINT}', got '{data['leverage_point']}'\n"
            f"  → This indicates regression in context detection (see GOLDEN_TEST_1_SPECIFICATION.md)"
        )

    # Assertion 4: Leverage point context count
    if data['leverage_contexts'] != EXPECTED_LEVERAGE_CONTEXTS:
        failures.append(
            f"LEVERAGE CONTEXTS CHANGED: Expected {EXPECTED_LEVERAGE_CONTEXTS}, got {data['leverage_contexts']}"
        )

    # Assertion 5: Utility exclusion
    if data['utility_excluded'] != EXPECTED_UTILITY_EXCLUDED:
        failures.append(
            f"UTILITY EXCLUSION CHANGED: Expected '{EXPECTED_UTILITY_EXCLUDED}', got '{data['utility_excluded']}'"
        )

    # Assertion 6: Cluster membership
    if data['cluster_functions'] != EXPECTED_CLUSTER_FUNCTIONS:
        missing = EXPECTED_CLUSTER_FUNCTIONS - data['cluster_functions']
        extra = data['cluster_functions'] - EXPECTED_CLUSTER_FUNCTIONS
        if missing:
            failures.append(f"CLUSTER MISSING FUNCTIONS: {missing}")
        if extra:
            failures.append(f"CLUSTER EXTRA FUNCTIONS: {extra}")

    # Assertion 7: Cluster size
    if len(data['cluster_functions']) != EXPECTED_CLUSTER_SIZE:
        failures.append(
            f"CLUSTER SIZE CHANGED: Expected {EXPECTED_CLUSTER_SIZE}, got {len(data['cluster_functions'])}"
        )

    return failures


def main():
    print("=" * 70)
    print("GOLDEN TEST 1: Regression Validation")
    print("=" * 70)
    print()
    print("Testing: project_browser.lua")
    print(f"Contract: docs/GOLDEN_TEST_1_SPECIFICATION.md")
    print()

    try:
        # Run analysis
        print("Running analyzer...")
        output = run_analysis("project_browser.lua")

        # Parse results
        print("Parsing results...")
        data = parse_analysis_output(output)

        # Display findings
        print()
        print("Found Results:")
        print(f"  Nucleus: {data['nucleus']} (contexts: {data['nucleus_contexts']})")
        print(f"  Leverage: {data['leverage_point']} (contexts: {data['leverage_contexts']})")
        print(f"  Utility excluded: {data['utility_excluded']}")
        print(f"  Cluster size: {len(data['cluster_functions'])}")
        print()

        # Validate against specification
        print("Validating against frozen specification...")
        failures = validate_results(data)

        if failures:
            print()
            print("❌ VALIDATION FAILED")
            print("=" * 70)
            for failure in failures:
                print(f"  • {failure}")
            print()
            print("DIAGNOSIS:")
            print("  - Review changes to extract_context_roots() in analyze_lua_structure.py")
            print("  - Verify context taxonomy patterns match GOLDEN_TEST_1_SPECIFICATION.md")
            print("  - Check for threshold changes (NUCLEUS_THRESHOLD, BOILERPLATE_EXCLUSION)")
            print()
            print("If changes are intentional:")
            print("  1. Update GOLDEN_TEST_1_SPECIFICATION.md with rationale")
            print("  2. Update expected values in this script")
            print("  3. Increment specification version")
            print("  4. Commit specification and code changes together")
            print()
            sys.exit(1)
        else:
            print("✅ ALL ASSERTIONS PASSED")
            print()
            print("Golden Test 1 validates:")
            print(f"  ✓ Nucleus detection: {EXPECTED_NUCLEUS}")
            print(f"  ✓ Nucleus contexts: {EXPECTED_NUCLEUS_CONTEXTS}")
            print(f"  ✓ Leverage point: {EXPECTED_LEVERAGE_POINT}")
            print(f"  ✓ Leverage contexts: {EXPECTED_LEVERAGE_CONTEXTS}")
            print(f"  ✓ Utility exclusion: {EXPECTED_UTILITY_EXCLUDED}")
            print(f"  ✓ Cluster size: {EXPECTED_CLUSTER_SIZE} functions")
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
