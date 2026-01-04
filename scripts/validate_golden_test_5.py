#!/usr/bin/env python3
"""
Golden Test 5 Validation Script

Validates that analyze_lua_structure.py correctly resists seductive but incorrect
refactor signals for event boundary functions (Step 5 - Adversarial Intuition Trap).

CRITICAL ASSERTIONS:
- Cluster must be accepted with nucleus identified
- handle_tree_item_changed must be identified as event boundary
- handle_tree_item_changed must NOT be reported as leverage point
- Must emit explicit discernment reasoning with at least 2 criteria:
  - Function is an event boundary
  - Context breadth reflects responsibility
  - Extraction would create artificial indirection
  - Coupling is convergent, not divergent
  - Responsibilities are aligned, not mixed
- Must NOT emit forbidden reasoning:
  - "Touches many contexts, therefore extract"
  - "High fan-in implies leverage"
  - "Separation of concerns" without explaining which concern

Any failure indicates tool is susceptible to seductive refactoring false positives.
"""

import subprocess
import sys
import re
from pathlib import Path

# Expected values (CONTRACT)
EXPECTED_NUCLEUS = "project_browser.activate_selection"
EXPECTED_EVENT_BOUNDARY = "project_browser:handle_tree_item_changed"  # Colon for internal function
REQUIRED_REASONING_FRAGMENTS = [
    "Event Boundary Analysis:",
    "Candidate examined:",
    "Result: Not a leverage point",
    "Reason:",
    "event boundary",
    "context breadth reflects responsibility",
    "artificial indirection",
    "convergent",
]
PROHIBITED_REASONING_FRAGMENTS = [
    "Extracting",  # Must NOT recommend extraction
    "leverage point is",  # Must NOT identify as leverage point (only "Not a leverage point")
    "separation of concerns",  # Forbidden without explaining which concern
    "Touches many contexts, therefore",  # Forbidden seductive reasoning
]


class ValidationError(Exception):
    """Raised when Golden Test 5 fails validation."""
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


def parse_event_boundary_output(output, stderr):
    """Extract event boundary information from analysis output."""
    data = {
        'accepted': False,
        'nucleus': None,
        'has_event_boundary_analysis': False,
        'event_boundaries_examined': [],
        'target_event_boundary_found': False,
        'event_boundary_is_leverage': False,
        'has_discernment_reasoning': False,
        'required_fragments': [],
        'prohibited_fragments_found': [],
        'reasoning_criteria_count': 0,
    }

    # Check if cluster was accepted (has CLUSTER heading)
    if re.search(r'CLUSTER \d+', output):
        data['accepted'] = True

    # Extract nucleus
    nucleus_match = re.search(r'clear nucleus around ([^\s,]+)', output)
    if nucleus_match:
        data['nucleus'] = nucleus_match.group(1)

    # Extract Event Boundary Analysis section
    event_boundary_section = ""
    if 'Event Boundary Analysis:' in output:
        data['has_event_boundary_analysis'] = True

        # Extract the Event Boundary Analysis section (everything after the heading)
        section_match = re.search(r'Event Boundary Analysis:(.*?)(?=All logic resides|Files:|$)', output, re.DOTALL)
        if section_match:
            event_boundary_section = section_match.group(1)

            # Extract ALL functions examined (may be multiple)
            examined_matches = re.findall(r'Candidate examined: ([^\s]+)', event_boundary_section)
            data['event_boundaries_examined'] = examined_matches

            # Check if target event boundary is among them
            if EXPECTED_EVENT_BOUNDARY in examined_matches:
                data['target_event_boundary_found'] = True

    # Check if event boundary was incorrectly marked as leverage point (in main analysis, not event boundary section)
    main_analysis = output.split('Event Boundary Analysis:')[0] if 'Event Boundary Analysis:' in output else output
    if re.search(r'primary leverage point is.*handle_tree_item_changed', main_analysis, re.IGNORECASE):
        data['event_boundary_is_leverage'] = True
        data['prohibited_fragments_found'].append('leverage point is handle_tree_item_changed')

    # Check for required discernment reasoning fragments (in event boundary section)
    data['required_fragments'] = [frag for frag in REQUIRED_REASONING_FRAGMENTS if frag in output]

    # Count reasoning criteria (should have ≥2) - in event boundary section
    criteria_patterns = [
        'event boundary',
        'context breadth reflects responsibility',
        'artificial indirection',
        'traffic cop',
        'convergent',
        'not divergent',
        'aligned',
    ]
    data['reasoning_criteria_count'] = sum(1 for pattern in criteria_patterns if pattern in event_boundary_section.lower())

    if data['reasoning_criteria_count'] >= 2:
        data['has_discernment_reasoning'] = True

    # CRITICAL: Check for prohibited reasoning fragments ONLY in event boundary section
    # These fragments are CORRECT for leverage points, but INCORRECT for event boundaries
    for prohibited in PROHIBITED_REASONING_FRAGMENTS:
        if prohibited in event_boundary_section:
            data['prohibited_fragments_found'].append(prohibited)

    return data


def validate_results(data):
    """Validate analysis results against Step 5 requirements."""
    failures = []

    # Assertion 1: Cluster must be accepted
    if not data['accepted']:
        failures.append(
            "CLUSTER REJECTED: Cluster containing event boundary was rejected instead of accepted"
        )

    # Assertion 2: Nucleus must be identified correctly
    if data['nucleus'] != EXPECTED_NUCLEUS:
        failures.append(
            f"WRONG NUCLEUS: Expected '{EXPECTED_NUCLEUS}', got '{data['nucleus']}'"
        )

    # Assertion 3: Event boundary analysis section must exist
    if not data['has_event_boundary_analysis']:
        failures.append(
            "MISSING EVENT BOUNDARY ANALYSIS: No 'Event Boundary Analysis:' section found"
        )

    # Assertion 4: Target function examined as event boundary
    if not data['target_event_boundary_found']:
        failures.append(
            f"TARGET EVENT BOUNDARY NOT FOUND: Expected '{EXPECTED_EVENT_BOUNDARY}' among event boundaries, got {data['event_boundaries_examined']}"
        )

    # Assertion 5: Event boundary must NOT be leverage point
    if data['event_boundary_is_leverage']:
        failures.append(
            "EVENT BOUNDARY MARKED AS LEVERAGE: Tool fell for adversarial intuition trap"
        )

    # Assertion 6: Must have discernment reasoning (≥2 criteria)
    if not data['has_discernment_reasoning']:
        failures.append(
            f"INSUFFICIENT DISCERNMENT REASONING: Found {data['reasoning_criteria_count']} criteria, need ≥2"
        )

    # Assertion 7: All required fragments present
    missing_fragments = set(REQUIRED_REASONING_FRAGMENTS) - set(data['required_fragments'])
    if missing_fragments:
        failures.append(
            f"MISSING REQUIRED FRAGMENTS: {missing_fragments}"
        )

    # Assertion 8: No prohibited reasoning
    if data['prohibited_fragments_found']:
        failures.append(
            f"PROHIBITED REASONING FOUND: {data['prohibited_fragments_found']} (seductive false positive signals)"
        )

    return failures


def main():
    print("=" * 70)
    print("GOLDEN TEST 5: Adversarial Intuition Trap")
    print("=" * 70)
    print()
    print("Testing: project_browser.lua")
    print(f"Requirement: Resist seductive refactor signals (Step 5)")
    print()

    try:
        # Run analysis
        print("Running analyzer...")
        output, stderr = run_analysis("project_browser.lua")

        # Parse results
        print("Parsing results...")
        data = parse_event_boundary_output(output, stderr)

        # Display findings
        print()
        print("Found Results:")
        print(f"  Accepted: {data['accepted']}")
        print(f"  Nucleus: {data['nucleus']}")
        print(f"  Has event boundary analysis: {data['has_event_boundary_analysis']}")
        print(f"  Event boundaries examined: {data['event_boundaries_examined']}")
        print(f"  Target event boundary found: {data['target_event_boundary_found']} (should be True)")
        print(f"  Event boundary is leverage: {data['event_boundary_is_leverage']} (should be False)")
        print(f"  Has discernment reasoning: {data['has_discernment_reasoning']} (should be True)")
        print(f"  Reasoning criteria count: {data['reasoning_criteria_count']} (need ≥2)")
        print(f"  Required fragments found: {len(data['required_fragments'])}/{len(REQUIRED_REASONING_FRAGMENTS)}")
        print()

        # Validate against specification
        print("Validating against Step 5 requirements...")
        failures = validate_results(data)

        if failures:
            print()
            print("❌ VALIDATION FAILED")
            print("=" * 70)
            for failure in failures:
                print(f"  • {failure}")
            print()
            print("DIAGNOSIS:")
            print("  - Review event boundary detection logic in _analysis_for_cluster()")
            print("  - Check event_boundary_patterns list for completeness")
            print("  - Verify discernment reasoning output includes ≥2 criteria")
            print("  - Ensure event boundaries excluded from leverage candidate list")
            print()
            sys.exit(1)
        else:
            print("✅ ALL ASSERTIONS PASSED")
            print()
            print("Golden Test 5 validates:")
            print(f"  ✓ Cluster accepted: {EXPECTED_NUCLEUS}")
            print(f"  ✓ Event boundary identified: {EXPECTED_EVENT_BOUNDARY}")
            print(f"  ✓ Event boundary NOT marked as leverage point")
            print(f"  ✓ Discernment reasoning emitted ({data['reasoning_criteria_count']} criteria)")
            print(f"  ✓ No seductive false positive signals")
            print()
            print("Step 5 requirement satisfied: Tool demonstrates architectural judgment")
            print("and resists seductive but incorrect refactoring recommendations.")
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
