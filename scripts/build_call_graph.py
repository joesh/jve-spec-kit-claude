#!/usr/bin/env python3
"""
Global call graph analyzer for Lua codebase.

Scans entire codebase to build:
- Function definitions (name, file, LOC, line number)
- Call relationships (caller -> callee)
- Fanin/fanout metrics
- Utility classification (high fanin + multi-file usage)

Output: JSON database for use in clustering tools.
"""

import sys
import re
import json
from pathlib import Path
from collections import defaultdict, Counter

# Regex patterns (same as lua_mod_analyze.py)
FUNC_DEF_RE = re.compile(r"\bfunction\s+([a-zA-Z0-9_.:]+)")
CALL_RE = re.compile(r"\b([a-zA-Z0-9_.:]+)\s*\(")
IDENT_RE = re.compile(r"\b([a-zA-Z_][a-zA-Z0-9_]*)\b")

STOPWORDS = {
    "local", "function", "end", "if", "then", "else", "for", "do", "while",
    "return", "nil", "true", "false", "and", "or", "not"
}

def compute_loc(text):
    """Count lines of code (excluding blank lines and comments)."""
    loc = 0
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("--"):
            continue
        loc += 1
    return loc

def parse_lua_file(path):
    """
    Parse a single Lua file.

    Returns:
        functions: {fn_name: line_number}
        calls: {fn_name: set(called_functions)}
        locs: {fn_name: loc_count}
    """
    funcs = {}
    calls = defaultdict(set)
    locs = {}

    try:
        text = path.read_text()
    except Exception as e:
        print(f"Warning: Could not read {path}: {e}", file=sys.stderr)
        return {}, {}, {}

    # Find all function definitions with positions
    func_matches = []
    for m in FUNC_DEF_RE.finditer(text):
        fn_name = m.group(1)
        line_num = text[:m.start()].count('\n') + 1
        funcs[fn_name] = line_num
        func_matches.append((fn_name, m.start(), m.end()))

    # Extract function bodies by parsing function/end pairs
    for name, match_start, match_end in func_matches:
        # Body starts after "function name(...)"
        body_start = match_end

        # Find matching 'end' by counting depth
        depth = 1  # We've seen one 'function'
        pos = body_start
        body_end = len(text)  # Default to EOF if no matching end found

        # Scan forward counting function/end keywords
        while pos < len(text) and depth > 0:
            # Look for next 'function' or 'end' keyword
            next_func = text.find('function', pos)
            next_end = text.find('end', pos)

            # Ensure we only match whole words (not 'pending', 'append', etc.)
            if next_end != -1:
                # Check if 'end' is a whole word
                before_ok = (next_end == 0 or not text[next_end - 1].isalnum() and text[next_end - 1] != '_')
                after_ok = (next_end + 3 >= len(text) or not text[next_end + 3].isalnum() and text[next_end + 3] != '_')
                if not (before_ok and after_ok):
                    # Not a keyword, skip past it
                    pos = next_end + 1
                    continue

            if next_func != -1:
                # Check if 'function' is a whole word
                before_ok = (next_func == 0 or not text[next_func - 1].isalnum() and text[next_func - 1] != '_')
                after_ok = (next_func + 8 >= len(text) or not text[next_func + 8].isalnum() and text[next_func + 8] != '_')
                if not (before_ok and after_ok):
                    # Not a keyword, skip past it
                    pos = next_func + 1
                    continue

            # Determine which comes first
            if next_func == -1 and next_end == -1:
                # No more keywords found - malformed file
                break
            elif next_end == -1 or (next_func != -1 and next_func < next_end):
                # 'function' comes first
                depth += 1
                pos = next_func + 8
            else:
                # 'end' comes first
                depth -= 1
                if depth == 0:
                    body_end = next_end
                pos = next_end + 3

        body = text[body_start:body_end]
        locs[name] = compute_loc(body)

        # Extract function calls
        for m in CALL_RE.finditer(body):
            calls[name].add(m.group(1))

    return funcs, calls, locs

def analyze_codebase(root_paths):
    """
    Scan entire codebase to build global call graph.

    Returns:
        global_functions: {
            fn_name: {
                'file': str,
                'line': int,
                'loc': int,
                'calls': [fn_name],
                'callers': [fn_name],
                'fanin': int,
                'fanout': int,
                'files_calling': int,
                'is_utility': bool
            }
        }
    """
    global_functions = {}
    file_to_functions = defaultdict(list)
    duplicates = defaultdict(list)  # Track duplicate definitions

    # Phase 1: Scan all files
    print("Phase 1: Scanning Lua files...", file=sys.stderr)
    for root_path in root_paths:
        root = Path(root_path)
        lua_files = list(root.rglob("*.lua")) if root.is_dir() else [root]

        for lua_file in lua_files:
            funcs, calls, locs = parse_lua_file(lua_file)

            for fn_name, line_num in funcs.items():
                if fn_name in global_functions:
                    print(f"Warning: Duplicate function '{fn_name}' in {lua_file} and {global_functions[fn_name]['file']}", file=sys.stderr)
                    # Track all files that define this function
                    if fn_name not in duplicates:
                        duplicates[fn_name].append(global_functions[fn_name]['file'])
                    duplicates[fn_name].append(str(lua_file))

                global_functions[fn_name] = {
                    'file': str(lua_file),
                    'line': line_num,
                    'loc': locs.get(fn_name, 0),
                    'calls': sorted(calls.get(fn_name, set())),
                    'callers': [],
                    'fanin': 0,
                    'fanout': len(calls.get(fn_name, set())),
                    'files_calling': 0,
                    'is_utility': False,
                    'duplicate_files': []  # Will be populated later
                }

                file_to_functions[str(lua_file)].append(fn_name)

    print(f"  Found {len(global_functions)} functions across {len(file_to_functions)} files", file=sys.stderr)

    # Populate duplicate_files for all functions that have duplicates
    for fn_name, files in duplicates.items():
        if fn_name in global_functions:
            global_functions[fn_name]['duplicate_files'] = files

    # Phase 2: Build reverse index (callers)
    print("Phase 2: Building caller relationships...", file=sys.stderr)
    for fn_name, data in global_functions.items():
        for callee in data['calls']:
            if callee in global_functions:
                global_functions[callee]['callers'].append(fn_name)

    # Phase 3: Calculate metrics
    print("Phase 3: Calculating metrics...", file=sys.stderr)
    for fn_name, data in global_functions.items():
        data['fanin'] = len(data['callers'])

        # Count how many different files call this function
        caller_files = {global_functions[c]['file'] for c in data['callers'] if c in global_functions}
        data['files_calling'] = len(caller_files)

    # Phase 4: Identify utilities
    print("Phase 4: Identifying utilities...", file=sys.stderr)
    utilities = identify_utilities(global_functions)
    for fn_name in utilities:
        global_functions[fn_name]['is_utility'] = True

    print(f"  Identified {len(utilities)} utility functions", file=sys.stderr)

    return global_functions

def identify_utilities(global_functions):
    """
    Identify utility functions based on:
    - High fanin (called by many functions)
    - Multi-file usage (called from multiple files)
    - Low coupling to specific domain

    Research-backed criteria (Wen & Tzerpos):
    - Fanin > threshold (suggesting reusable utility)
    - Called from multiple files (cross-cutting concern)
    - Connected to multiple clusters (in clustering context)
    """
    utilities = set()

    # Calculate thresholds based on distribution
    fanins = [data['fanin'] for data in global_functions.values()]
    if not fanins:
        return utilities

    avg_fanin = sum(fanins) / len(fanins)

    for fn_name, data in global_functions.items():
        fanin = data['fanin']
        files_calling = data['files_calling']

        # Criteria for utility classification:
        # BOTH conditions required (not OR):
        # 1. Called by 5+ functions (high fanin)
        # 2. Called from 3+ different files (cross-file usage)
        #
        # Exception: If fanin is extremely high (3x average), classify as utility
        # even if only used in 2 files (rare but indicates shared infrastructure)

        is_high_fanin = fanin >= 5
        is_multi_file = files_calling >= 3
        is_extreme_outlier = fanin > 3 * avg_fanin and files_calling >= 2

        if (is_high_fanin and is_multi_file) or is_extreme_outlier:
            utilities.add(fn_name)

    return utilities

def main():
    if len(sys.argv) < 2:
        print("usage: build_call_graph.py <path1> [path2 ...] [--output <file.json>]")
        print("\nScans Lua codebase to build global call graph database.")
        print("Output defaults to call_graph.json")
        sys.exit(1)

    # Parse arguments
    paths = []
    output_file = "call_graph.json"

    i = 1
    while i < len(sys.argv):
        if sys.argv[i] == "--output" and i + 1 < len(sys.argv):
            output_file = sys.argv[i + 1]
            i += 2
        else:
            paths.append(sys.argv[i])
            i += 1

    if not paths:
        print("Error: No input paths specified", file=sys.stderr)
        sys.exit(1)

    # Build call graph
    global_functions = analyze_codebase(paths)

    # Generate statistics
    total_funcs = len(global_functions)
    total_loc = sum(data['loc'] for data in global_functions.values())
    utilities = sum(1 for data in global_functions.values() if data['is_utility'])

    # Write output
    output = {
        'metadata': {
            'total_functions': total_funcs,
            'total_files': len({data['file'] for data in global_functions.values()}),
            'total_loc': total_loc,
            'utility_count': utilities
        },
        'functions': global_functions
    }

    with open(output_file, 'w') as f:
        json.dump(output, f, indent=2)

    print(f"\nWrote call graph to {output_file}", file=sys.stderr)
    print(f"  Functions: {total_funcs}", file=sys.stderr)
    print(f"  Total LOC: {total_loc}", file=sys.stderr)
    print(f"  Utilities: {utilities}", file=sys.stderr)

if __name__ == "__main__":
    main()
