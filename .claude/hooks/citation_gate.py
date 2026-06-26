#!/usr/bin/env python3
"""
citation_gate.py — Stop hook that blocks turn-end when the last assistant
message contains guess-tells without nearby citations.

Per Joe's instruction (2026-06-25 review thread): three feedback memories
already say "don't guess" and I broke all three. The memory system can't
enforce itself — it's text I read and ignore. This is the hard gate.

Input (stdin JSON):
  {
    "session_id": "...",
    "transcript_path": "/path/to/session.jsonl",
    "hook_event_name": "Stop",
    "stop_hook_active": false
  }

Behavior:
  - Skip if stop_hook_active (prevents infinite loop)
  - Read transcript, find last assistant text
  - Strip code fences (```...```) and blockquotes (> ...) before scanning
  - Skip if message is short (<30 non-blank lines) — conversational turn
  - Skip if message contains opt-out marker [no-citation-gate]
  - Scan for guess-tells; for each, look for a citation within +/-200 chars
  - Exit 2 if any unsourced tells remain; print list to stderr (becomes
    a system-reminder forcing the model to continue with corrections).

Permitted hedges (un-citation-able assertions when explicitly marked):
  [unverified], [not checked], (haven't read), "not verified",
  "haven't traced", "not yet read".

Citation = a token matching one of:
  - file path with extension + ":NNN"     (foo/bar.lua:123)
  - backticked path with extension + ":NNN"
  - "line NNN of <path>"
"""

import json
import os
import re
import sys
from pathlib import Path

# ---------- patterns ----------

CITATION_RE = re.compile(
    r"""
    (?:
        `?[\w./\-]+\.(?:lua|cpp|h|hpp|c|cc|mm|sql|md|sh|py|toml|json|jvekeys)
        :\d+`?
      | `?(?:Makefile|CMakeLists\.txt|Dockerfile):\d+`?
      | line\s+\d+\s+of\s+[\w./\-]+
    )
    """,
    re.VERBOSE | re.IGNORECASE,
)

HEDGE_RE = re.compile(
    r"""
    \[(?:unverified|not\s+checked|not\s+verified|guess|speculative)\]
  | \(haven't\s+read\)
  | haven't\s+(?:traced|read|verified|checked)
  | not\s+verified
  | not\s+yet\s+read
  | I\s+haven't\s+looked
    """,
    re.VERBOSE | re.IGNORECASE,
)

OPT_OUT_MARKER = "[no-citation-gate]"

# Each entry: (label, compiled pattern). Patterns are designed to catch
# claims-about-code, not casual prose.
TELLS = [
    ("probably",         re.compile(r"\bprobabl(?:y|e)\b", re.I)),
    ("should be/work",   re.compile(r"\bshould\s+(?:be|work|have|return|exist|cascade|fire|catch|pass|fail|match)\b", re.I)),
    ("appears to",       re.compile(r"\bappears?\s+(?:to|that)\b", re.I)),
    ("in practice",      re.compile(r"\bin\s+practice\b", re.I)),
    ("dead code",        re.compile(r"\bdead\s+code\b", re.I)),
    ("dead branch",      re.compile(r"\bdead\s+branch\b", re.I)),
    ("confirmed X",      re.compile(r"\bconfirmed\s+(?:safe|innocent|correct|fine|right|unchanged|unaffected)\b", re.I)),
    ("no consumer",      re.compile(r"\bno\s+(?:consumer|caller|callers|consumers|usage|usages|references?)\b", re.I)),
    ("nothing/nowhere",  re.compile(r"\b(?:nothing|nowhere)\s+(?:in|else|references?)\b", re.I)),
    ("looks correct",    re.compile(r"\blooks?\s+(?:correct|right|good|fine|ok|safe)\b", re.I)),
    ("is fine/safe",     re.compile(r"\b(?:is|are|it's|that's)\s+(?:fine|safe|correct|right|unaffected|fine\.)\b", re.I)),
    ("I'm sure",         re.compile(r"\bI'?m\s+sure\b", re.I)),
    ("trust me",         re.compile(r"\btrust\s+me\b", re.I)),
    ("verified",         re.compile(r"\bverified\b", re.I)),
    ("by coincidence",   re.compile(r"\bby\s+coincidence\b", re.I)),
    ("happens to",       re.compile(r"\bhappens?\s+to\b", re.I)),
    ("must be",          re.compile(r"\bmust\s+be\b", re.I)),
    ("X is correct/wrong/broken/safe", re.compile(
        r"\b(?:Phase\s*\w+|the\s+\w+|this\s+\w+)\s+(?:is|are|was|were)\s+"
        r"(?:correct|wrong|broken|safe|right|unsafe|incorrect|fine)\b", re.I)),
    # Negative assertions — "X doesn't Y", "X don't Y" — equally confident,
    # equally citation-worthy. The earlier tells skewed positive ("X is fine").
    ("doesn't/don't VERB", re.compile(
        r"\b(?:doesn'?t|don'?t|do\s+not|does\s+not|didn'?t|did\s+not)\s+"
        r"(?:share|use|depend|matter|affect|fire|exist|run|call|reach|"
        r"cascade|propagate|trigger|invalidate|touch|cache|persist|"
        r"apply|return|emit|handle|cover)\b", re.I)),
    ("no <noun>",        re.compile(
        r"\bno\s+(?:meaningful|shared|cached|persistent|nested|hidden|"
        r"silent|implicit|cross-session|cross-thread|side[-\s]?effect)\s+\w+\b",
        re.I)),
    ("in any meaningful way", re.compile(r"\bin\s+(?:any|no)\s+meaningful\s+way\b", re.I)),
    ("nothing shared",   re.compile(r"\bnothing\s+(?:shared|cached|persistent|carries|crosses)\b", re.I)),
]

CONTEXT_RADIUS = 200  # chars on each side to look for a citation


# ---------- transcript reader ----------

def last_assistant_text(transcript_path: str) -> str:
    """Walk the JSONL transcript, return concatenated text content of the
    last assistant message. Returns empty string if not found / not readable.
    """
    p = Path(transcript_path)
    if not p.exists():
        return ""
    last = None
    try:
        with p.open("r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if rec.get("type") == "assistant" or rec.get("role") == "assistant":
                    last = rec
                elif isinstance(rec.get("message"), dict) and rec["message"].get("role") == "assistant":
                    last = rec["message"]
    except OSError:
        return ""
    if last is None:
        return ""

    msg = last.get("message", last)
    content = msg.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        chunks = []
        for c in content:
            if isinstance(c, dict) and c.get("type") == "text":
                chunks.append(c.get("text", ""))
        return "\n".join(chunks)
    return ""


# ---------- scanner ----------

def strip_uncheckable(text: str) -> str:
    """Remove regions that shouldn't be scanned:
       - fenced code blocks ```...```
       - inline backticks `...`  (don't penalize code identifiers)
       - blockquotes (lines starting with >)
    """
    # Fenced blocks (multiline)
    text = re.sub(r"```.*?```", " ", text, flags=re.DOTALL)
    # Inline code
    text = re.sub(r"`[^`\n]*`", " ", text)
    # Blockquoted lines
    text = "\n".join(
        line for line in text.splitlines()
        if not line.lstrip().startswith(">")
    )
    return text


def has_nearby_citation_or_hedge(text: str, pos: int) -> bool:
    lo = max(0, pos - CONTEXT_RADIUS)
    hi = min(len(text), pos + CONTEXT_RADIUS)
    window = text[lo:hi]
    if CITATION_RE.search(window):
        return True
    if HEDGE_RE.search(window):
        return True
    return False


def find_unsourced_tells(text: str):
    """Return list of (label, snippet, line_no) for unsourced tells."""
    unsourced = []
    for label, pat in TELLS:
        for m in pat.finditer(text):
            if not has_nearby_citation_or_hedge(text, m.start()):
                # Compute line number from char offset
                line_no = text.count("\n", 0, m.start()) + 1
                # Extract a snippet around the match
                snip_lo = max(0, m.start() - 40)
                snip_hi = min(len(text), m.end() + 40)
                snippet = text[snip_lo:snip_hi].replace("\n", " ").strip()
                unsourced.append((label, snippet, line_no))
    return unsourced


def is_substantial(text: str) -> bool:
    """Gate any reply that makes a confident technical claim, not just long
    reviews. A 6-line "X works this way" answer is exactly as misleading as
    a 50-line audit — the prior 30-line threshold gave short tells a free
    pass (2026-06-26 incident: "threads don't share build state in any
    meaningful way", flat-wrong and short enough to skip scanning).

    Threshold: 8 non-blank lines is enough to be making a claim worth
    citing. Below that it's almost certainly conversational. The opt-out
    marker [no-citation-gate] remains for genuinely conversational turns
    that would otherwise trip the scanner.
    """
    if OPT_OUT_MARKER in text:
        return False
    nonblank = sum(1 for ln in text.splitlines() if ln.strip())
    return nonblank >= 8


# ---------- main ----------

def main():
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        sys.exit(0)  # malformed input — don't block

    if payload.get("stop_hook_active"):
        sys.exit(0)  # already in a stop-hook loop; let it end

    transcript = payload.get("transcript_path", "")
    text = last_assistant_text(transcript)
    if not text.strip():
        sys.exit(0)

    if not is_substantial(text):
        sys.exit(0)

    scanned = strip_uncheckable(text)
    unsourced = find_unsourced_tells(scanned)
    if not unsourced:
        sys.exit(0)

    # Cap to avoid drowning the model in 100 hits; first 10 is plenty.
    capped = unsourced[:10]
    msg = [
        "CITATION GATE: your last message contains unsourced technical "
        "claims. For each, either:",
        "  (a) cite the specific file:line that proves it (e.g. "
        "src/lua/foo.lua:123), or",
        "  (b) restate as not-yet-verified using one of the permitted "
        "hedges: [unverified], [not checked], \"not verified\", "
        "\"haven't read/traced/checked\".",
        "",
        f"Unsourced tells (showing {len(capped)} of {len(unsourced)}):",
    ]
    for label, snippet, line_no in capped:
        msg.append(f"  - [{label}] line {line_no}: \"...{snippet}...\"")
    msg.append("")
    msg.append("Once corrected (or each tell hedged), end the turn.")
    msg.append("Opt out of this gate for non-review turns with the marker "
               "[no-citation-gate] anywhere in the reply.")

    print("\n".join(msg), file=sys.stderr)
    sys.exit(2)  # non-zero stops the stop, forcing continuation


if __name__ == "__main__":
    main()
