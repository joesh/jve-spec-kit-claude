#!/usr/bin/env python3
"""
AST-based call graph analyzer for Lua codebase.

Uses luaparser to properly parse Lua AST and extract:
- Function definitions (handles nested functions, control flow)
- Function calls (direct calls with parentheses)
- Function references (callbacks, handlers, table values)
"""

import sys
import json
from pathlib import Path
from collections import defaultdict, Counter
from luaparser import ast

def extract_name(node):
    """Extract identifier/name from various node types."""
    if not node:
        return None
    if hasattr(node, 'id'):
        # Simple name: foo
        return node.id
    elif hasattr(node, 'value') and hasattr(node, 'idx'):
        # Index: M.create, obj.method
        base = extract_name(node.value)
        idx = extract_name(node.idx)
        if base and idx:
            return f"{base}.{idx}"
    return None

def count_loc_from_source(code, start_line, end_line):
    """Count non-blank, non-comment lines in a range."""
    lines = code.split('\n')[start_line:end_line]
    loc = 0
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith('--'):
            loc += 1
    return loc

def analyze_lua_ast(tree, filepath, code):
    """Walk AST and extract function definitions, calls, and references."""
    functions = {}  # {name: (line_number, is_local, loc, nested_count)}
    calls = defaultdict(set)  # {caller: {callee1, callee2, ...}}

    # First pass: find all function definitions with LOC and nested function count
    function_nodes = {}  # {name: node} for second pass

    for node in ast.walk(tree):
        node_type = type(node).__name__

        if node_type == 'LocalFunction':
            # local function name()
            if hasattr(node, 'name'):
                func_name = extract_name(node.name)
                if func_name:
                    line = node.line if hasattr(node, 'line') else 1
                    last_line = node.last_line if hasattr(node, 'last_line') else line + 10
                    loc = count_loc_from_source(code, line - 1, last_line)

                    # Count nested function definitions
                    nested_count = sum(1 for n in ast.walk(node)
                                      if type(n).__name__ in ['LocalFunction', 'Function'] and n != node)

                    functions[func_name] = (line, True, loc, nested_count)
                    function_nodes[func_name] = node

        elif node_type == 'Function':
            # function M.name() or function name()
            if hasattr(node, 'name') and node.name:
                func_name = extract_name(node.name)
                if func_name:
                    line = node.line if hasattr(node, 'line') else 1
                    last_line = node.last_line if hasattr(node, 'last_line') else line + 10
                    loc = count_loc_from_source(code, line - 1, last_line)

                    # Count nested function definitions
                    nested_count = sum(1 for n in ast.walk(node)
                                      if type(n).__name__ in ['LocalFunction', 'Function'] and n != node)

                    functions[func_name] = (line, False, loc, nested_count)
                    function_nodes[func_name] = node

        elif node_type == 'Assign':
            # name = function() or M.name = function()
            if hasattr(node, 'targets') and hasattr(node, 'values'):
                for target, value in zip(node.targets, node.values):
                    if type(value).__name__ in ['Function', 'AnonymousFunction']:
                        func_name = extract_name(target)
                        if func_name:
                            line = node.line if hasattr(node, 'line') else 1
                            last_line = node.last_line if hasattr(node, 'last_line') else line + 10
                            loc = count_loc_from_source(code, line - 1, last_line)

                            # Count nested function definitions
                            nested_count = sum(1 for n in ast.walk(value)
                                              if type(n).__name__ in ['LocalFunction', 'Function'])

                            functions[func_name] = (line, False, loc, nested_count)
                            function_nodes[func_name] = value

        elif node_type == 'LocalAssign':
            # local name = function()
            if hasattr(node, 'targets') and hasattr(node, 'values'):
                for target, value in zip(node.targets, node.values):
                    if type(value).__name__ in ['Function', 'AnonymousFunction']:
                        func_name = extract_name(target)
                        if func_name:
                            line = node.line if hasattr(node, 'line') else 1
                            last_line = node.last_line if hasattr(node, 'last_line') else line + 10
                            loc = count_loc_from_source(code, line - 1, last_line)

                            # Count nested function definitions
                            nested_count = sum(1 for n in ast.walk(value)
                                              if type(n).__name__ in ['LocalFunction', 'Function'])

                            functions[func_name] = (line, True, loc, nested_count)
                            function_nodes[func_name] = value

    # Second pass: find calls within each function
    # We'll use a simple heuristic: any Call node belongs to the nearest enclosing function
    # This is approximate but good enough
    def find_calls_in_function(func_node):
        """Find all calls within a function body."""
        func_calls = set()

        for node in ast.walk(func_node):
            node_type = type(node).__name__

            if node_type == 'Call':
                # Function call
                callee = extract_name(node.func) if hasattr(node, 'func') else None
                if callee:
                    func_calls.add(callee)

            elif node_type == 'Table':
                # Table constructor - look for handler/callback patterns
                if hasattr(node, 'fields'):
                    for field in node.fields:
                        if hasattr(field, 'key') and hasattr(field, 'value'):
                            key_name = extract_name(field.key)
                            if key_name in ['handler', 'callback', 'listener', 'action', 'on_click', 'on_change']:
                                func_ref = extract_name(field.value)
                                if func_ref:
                                    func_calls.add(func_ref)

        return func_calls

    # Second pass: associate calls with functions using stored nodes
    for func_name, node in function_nodes.items():
        calls[func_name] = find_calls_in_function(node)

    return functions, calls  # functions = {name: (line, is_local, loc, nested_count)}

def parse_lua_file(filepath):
    """Parse a single Lua file and extract call graph info."""
    try:
        code = filepath.read_text(encoding='utf-8', errors='ignore')
        tree = ast.parse(code)

        functions, calls = analyze_lua_ast(tree, filepath, code)

        return functions, dict(calls)
    except Exception as e:
        print(f"Warning: Failed to parse {filepath}: {e}", file=sys.stderr)
        return {}, {}

def build_call_graph(root_paths):
    """Build call graph from Lua files."""
    global_functions = {}
    duplicates = defaultdict(list)

    print("Phase 1: Parsing Lua files...", file=sys.stderr)
    for root_path in root_paths:
        root = Path(root_path)
        lua_files = list(root.rglob("*.lua")) if root.is_dir() else [root]

        for lua_file in lua_files:
            funcs, calls = parse_lua_file(lua_file)

            for fn_name, (line_num, is_local, loc, nested_count) in funcs.items():
                # Only track duplicates for non-local functions
                # Local functions are file-scoped and don't conflict
                is_module_func = fn_name.startswith('M.')

                if fn_name in global_functions:
                    # Skip duplicate tracking for local functions (different scopes)
                    # Skip duplicate tracking for module functions (different modules)
                    if not is_local and not is_module_func:
                        print(f"Warning: Duplicate function '{fn_name}' in {lua_file} and {global_functions[fn_name]['file']}", file=sys.stderr)
                        if fn_name not in duplicates:
                            duplicates[fn_name].append(global_functions[fn_name]['file'])
                        duplicates[fn_name].append(str(lua_file))

                global_functions[fn_name] = {
                    'file': str(lua_file),
                    'line': line_num,
                    'loc': loc,
                    'nested_functions': nested_count,
                    'calls': sorted(calls.get(fn_name, set())),
                    'callers': [],
                    'fanin': 0,
                    'fanout': len(calls.get(fn_name, set())),
                    'files_calling': 0,
                    'is_utility': False,
                    'is_local': is_local,
                    'duplicate_files': []
                }

    # Populate duplicate_files
    for fn_name, files in duplicates.items():
        if fn_name in global_functions:
            global_functions[fn_name]['duplicate_files'] = files

    print(f"  Found {len(global_functions)} functions across {len(set(f['file'] for f in global_functions.values()))} files", file=sys.stderr)

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
    """Identify utility functions (high fanin + multi-file usage)."""
    utilities = set()
    fanins = [data['fanin'] for data in global_functions.values()]
    if not fanins:
        return utilities

    avg_fanin = sum(fanins) / len(fanins)

    for fn_name, data in global_functions.items():
        fanin = data['fanin']
        files_calling = data['files_calling']

        is_high_fanin = fanin >= 5
        is_multi_file = files_calling >= 3
        is_extreme_outlier = fanin > 3 * avg_fanin and files_calling >= 2

        if (is_high_fanin and is_multi_file) or is_extreme_outlier:
            utilities.add(fn_name)

    return utilities

def main():
    if len(sys.argv) < 2:
        print("usage: build_call_graph_ast.py <path1> [path2 ...] [--output <file.json>]")
        sys.exit(1)

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

    global_functions = build_call_graph(paths)

    total_funcs = len(global_functions)
    total_loc = sum(data['loc'] for data in global_functions.values())
    utilities = sum(1 for data in global_functions.values() if data['is_utility'])

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
    print(f"  Utilities: {utilities}", file=sys.stderr)

if __name__ == "__main__":
    main()
