#!/usr/bin/env python3
import sys, json

if len(sys.argv) != 3:
    print("usage: symbol_index_from_tags.py <tags> <out.json>")
    sys.exit(1)

tags_file, out_file = sys.argv[1], sys.argv[2]
symbols = []

with open(tags_file) as f:
    for line in f:
        if line.startswith("!") or not line.strip():
            continue
        parts = line.rstrip().split("\t")
        if len(parts) < 4:
            continue
        name, file = parts[0], parts[1]
        kind = None
        for p in parts[3:]:
            if p.startswith("kind:"):
                kind = p.split(":",1)[1]
        symbols.append({
            "symbol": name,
            "file": file,
            "kind": kind
        })

with open(out_file, "w") as f:
    json.dump(symbols, f, indent=2)

print(f"Wrote {len(symbols)} symbols to {out_file}")
