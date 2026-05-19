#!/bin/bash
# SessionStart hook — writes <session-id>.pid sidecar next to the session jsonl
# so cozempic guard can find the owning claude process by session ID.
#
# Walks up from $PPID until it finds a process named 'claude' (handles shell
# wrappers between claude and this script). Falls back to $PPID if no claude
# ancestor found.

INPUT_JSON=$(cat)
export INPUT_JSON
export PARENT_PID=$PPID

python3 -c '
import json, os, subprocess, sys

data = json.loads(os.environ["INPUT_JSON"])
transcript = data.get("transcript_path")
if not transcript:
    sys.exit(0)

pidfile = transcript.rsplit(".jsonl", 1)[0] + ".pid"
pid = int(os.environ["PARENT_PID"])
for _ in range(8):
    try:
        out = subprocess.run(
            ["ps", "-o", "ppid=,comm=", "-p", str(pid)],
            capture_output=True, text=True, timeout=2,
        ).stdout.strip().split(None, 1)
        if len(out) < 2:
            break
        ppid, comm = int(out[0]), out[1]
        if "claude" in comm.lower():
            break
        pid = ppid
        if pid <= 1:
            break
    except Exception:
        break

with open(pidfile, "w") as f:
    f.write(str(pid))
'
