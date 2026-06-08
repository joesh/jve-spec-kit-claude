# Editor Project Specification v1.2 (Consolidated)

This is the canonical specification for the JVE editor project, integrating design pushbacks, persistence, collaboration, and debugging guidance.

## Problem / Context
- Existing editors (Resolve, Premiere, FCP7/X, Avid) are monolithic. They don’t support modular, hackable workflows. Still more importantly, they're owned by companies that aren't responsive to their userbase. Technical and workflow debt are substantial and users are captive.
- Goal: build a modern, lightweight, script-forward editing platform in the spirit of EMACS where new ideas can be tested without rebuilding an entire NLE. Logic is in lua, with C++ reserved for performance critical components and FFI interfaces.

## Philosophy

- **Script-forward**: Lua for logic/policy; C++ only for performance-critical primitives.
- **Fail early**: validation/error propagation from day 1; dogfood debugging model internally.
- **One-file project**: a `.jve` file is the only artifact users touch. No WAL/SHM/sidecars.

---

## Timeline Scope (v1.2)

- **Core verbs** (FCP7-equivalent):
  - Add Edit (blade)
  - Overwrite
  - Insert
  - Delete (gap insert)
  - Ripple Delete (gap close)
  - Ripple Trim (head/tail)
  - Roll
  - Slip
  - Slide
- **Behaviors**:
  - Track targeting, snapping toggle, enable/disable clip, basic dissolve/crossfade
  - Linked A/V (link/unlink). **Links are advisory**: ripples/targeted edits override link to allow intentional out-of-sync.

Out of scope early: advanced effects, magnetic timeline, multicam, audio mixing.

---

## Architectural Direction

### Language Boundary
- **Lua owns logic**: tools, gestures, inspector schemas, workspace, extensibility.
- **C++ owns performance**: timeline engine, playback/render, heavy transforms, persistence.
- **Interaction model**:
  - Commands: `apply_command(cmd, args) -> delta | error`
  - Lua orchestrates commands/deltas; C++ enforces invariants.
  - Lua may inject policy hooks (snapping, drawing).

### Validation & Error Propagation
- **Envelope**:
  ```json
  {
    "code": "STRING_CONSTANT",
    "message": "human readable",
    "data": { "context": "...", "target": "ref", "range": [start_tc,end_tc] },
    "hint": "expanded from catalog template",
    "audience": "user|developer"
  }
  ```
- **Mandatory hints**:
  - Every `code` has a `hint_template` in the error catalog.
  - `audience=user|developer` controls UI visibility; hints always logged.
  - CI enforces presence of hints.
- **Placement**:
  - C++ validates invariants/args.
  - Lua validates schema/UI types.
- **Sync vs async**:
  - Sync = lightweight invariant checks (O(1)/O(log n)).
  - Async = heavy IO/global scans; surfaced with `trace_id`.

### Persistence & Events
- **SQLite is canonical**: rows = current state; `cmd_log` = audit/events.
- **Schema (MVP)**: projects, media, sequences, tracks, clips, transitions, markers, props, cmd_log, snapshots.
- **Command log**: every command appends `{id,parent_id,term,cmd,args,pre_hash,post_hash}`.
- **Snapshots**: written periodically via `VACUUM INTO` + atomic rename. `.jve` always safe to copy.
- **Archives**: older cmd_log ranges may be compacted into embedded archive blobs inside the file. Missing archives are okay; they just limit time-travel depth.
- **Undo/redo**: commands with inverse deltas, committed like normal commands.

### Scaling & Backups
- `.jve` always one file. Atomic save means safe to copy anytime.
- Snapshots keep open times fast; archives bound file growth.
- Backups = simply copy the file. No WAL/SHM required. Advanced: `jve-backup`, `jve-compact`, `jve-dump` CLIs.

---

## Collaboration Model

### Branching & Merge (Async)
- Divergence handled by rebase of command logs.
- **Merge base**: last common `cmd_id`/`post_hash`.
- **Auto-resolve ladder**: Exact → Snap (±6f) → Offset → Skip.
- **Conflicts**: entity-level (clip/edit/track region). Defaults to “ours wins”; their failing op becomes a pending patch.
- UI exposes only **Apply** and **Skip**; advanced options hidden.

### Live Collaboration (Coordinator)
- **Single-writer lease** in SQLite (`coord` row: leader_id, term, lease_expires_at`).
- Clients auto-renew lease; if expired, others race to acquire. Silent failover.
- Leadership changes invisible to users. Only prolonged absence = banner “Working locally”.

### Local vs Authoritative
- Each client maintains local working copy.
- When connected, commands go through leader → authoritative log → echoed back as deltas.
- If offline, client diverges; on reconnect, auto-merge runs.

### Transport
- **LAN**: direct TCP (Bonjour/mDNS).
- **WAN**: WebRTC/QUIC with STUN; HTTPS relay fallback.
- Invite tokens (`project_id`, term, caps, expiry) control join.
- Disinvite = term/key rotation. Revoked clients drop.

---

## Zero-Admin Mode (User Experience)

- User only sees one `.jve` file.
- Discovery, leader election, snapshots, merges happen automatically.
- Presence shown as “editing live” or “working locally”; no leader/follower detail.
- Invites: simple links or QR codes. Revocation via “Remove Access”.

---

## Debugging & Tooling

### CLI Tools
- `jve-validate`: check db or command args/invariants.
- `jve-dump`: tail/dump command log.
- `jve-replay`: replay logs, bisect nondeterminism, verify hashes.
- `jve-migrate`: forward schema migrations.
- `jve-backup`: snapshot copy.
- `jve-merge`: async branch merges.
- `jve-net`: collab status.
- `jve-prof`: quick profile.

### Debugger Manual
See **Debugger Manual v1.1** (`docs/jve-debugger-manual.md`):
- Step-by-step sections by symptom (commands, determinism, persistence, merge, collab, performance, access).
- Laminated card (quick triage).
- Sample practice cases.

---

## Build Order (Milestones)

1. **Local engine**: C++ core, Lua tools, SQLite persistence, snapshots.
2. **Command log & replay tools**.
3. **Merge model** (async collab).
4. **Coordinator (LAN live collab)**.
5. **Transport (WAN + relay, invites/disinvites)**.

Each milestone shippable with clear test harness (golden replays, invariant checks, CLI).

---

## Appendix A: Error Codes (starter)

- `TRACK_LOCKED`
- `BOUNDS_CLAMPED`
- `OVERLAP_FORBIDDEN`
- `NO_MEDIA`
- `BAD_TIMEBASE`
- `SNAP_TARGET_MISSING`
- `UNSUPPORTED_OP`
- `PERMISSION_DENIED`
- `SCHEMA_VIOLATION`

Each has mandatory `message_template` + `hint_template` + `audience`.

---

## Appendix B: Determinism Checks

- `jve-replay --verify-hash` suite must pass.
- Any divergence is bisected and logged with first offending command.


---

# Appendix C: Debugger Manual (v1.1)

# JVE Debugger Manual v1.0 (for Spec v1.2)

A step‑by‑step, appliance‑style guide to isolate and fix issues across the JVE stack.
Scope matches Spec v1.2 (Lua policy, C++ engine, SQLite rows + cmd_log, snapshots, optional coordinator).

---

## 0) Quick Triage (90‑second checklist)

1. **Symptom class?** Choose one and jump to its section:
   - ❒ Command fails or behaves wrong → [A. Command & Validation](#a-command--validation)
   - ❒ Timeline state is wrong after a sequence of edits → [B. Determinism & Replay](#b-determinism--replay)
   - ❒ Project won’t open / crashes on open → [C. Persistence & Snapshots](#c-persistence--snapshots)
   - ❒ Merge produced conflicts or bad results → [D. Merge & Branching](#d-merge--branching)
   - ❒ Live collaboration issues (stalls/offline) → [E. Coordinator & Transport](#e-coordinator--transport)
   - ❒ Performance (jank, slow trims, UI stalls) → [F. Performance](#f-performance)
   - ❒ Invite/disinvite or auth issues → [G. Access & Security](#g-access--security)

2. **Capture basics** (copy/paste into bug report later):
   - Project: file name + `project_id`
   - Build: commit or version
   - OS + hardware
   - Last 20 **command IDs** (from statusline or `jve-dump --tail 20`)
   - If error surfaced: **`code`, `message`, `data`, `hint`, `audience`**

3. **Don’t guess**. Reproduce once. Then follow the section flow.

---

## A. Command & Validation

**Goal:** When a command fails, find *why* and whether it’s a policy bug (Lua), an invariant (C++), or bad args.

### A1. Read the envelope
- Every failure returns:
  ```json
  {"code": "...", "message": "...", "data": {...}, "hint": "...", "audience": "user|developer"}
  ```
- Action:
  - Note `code`, `data`, `hint`.
  - If `audience=developer`, open Dev Console for details.

### A2. Fast isolation
1) **Run** `jve-validate --cmd {id}`  
   - Confirms argument shape and invariants again.  
   - If it passes here, suspect **Lua policy** (gesture → args).  
2) **Run** `jve-dump --cmd {id}`  
   - Shows fully‑resolved args (after snapping/targeting).  
   - If args look wrong → **Lua tool** bug.
3) **Run** `jve-replay --single {id}` (on a snapshot copy)  
   - If engine returns the same error → invariant or engine check is correct.  
   - If replay passes → look for **race** (concurrent edit altered pre‑state).

### A3. Fix path
- **Lua policy issue**: tool constructs wrong args → adjust mapping or snapping policy.
- **Engine invariant**: update error/hint or relax rule; add test.
- **Schema/UI error**: inspector types/ranges wrong → fix schema + add validation test.

**Artifacts to attach**: error envelope JSON, `jve-dump --cmd {id}`, minimal steps.

---

## B. Determinism & Replay

**Goal:** Same inputs → same deltas. If not, find the first divergent command.

### B1. One‑liner
```
jve-replay --from {cmd_base} --to {cmd_tip} --verify-hash
```
- Expected: identical `post_hash` as recorded in `cmd_log`.

### B2. Bisect on divergence
```
jve-replay --bisect {cmd_base}..{cmd_tip}
```
- Finds first bad command. Save the failing pair `(pre_state_hash, cmd_id)`.

### B3. Classify
- **Non‑deterministic Lua policy** (time‑based snapping, random IDs): fix to be deterministic.
- **Engine nondeterminism** (unordered iteration, float math): replace with stable ordering / integer ticks.
- **Persistence skew** (rows not matching delta): fix transaction application order.

**Artifacts**: `bisect.log`, failing `cmd_id`, minimal repro snapshot.

---

## C. Persistence & Snapshots

**Goal:** Project opens; rows + snapshots are sane; one‑file contract holds.

### C1. If open fails
1) Copy file → keep original safe.
2) `jve-validate --db project.jve`
   - Checks schema versions, FKs, row overlaps, snapshot presence.
3) If validator fails:
   - `jve-migrate --to latest` (forward-only). Retry open.
4) If still failing:
   - `jve-restore --from-snapshot latest` → opens at last good checkpoint.
   - Optionally `jve-replay --from {snapshot_cmd}` to rebuild tail.

### C2. If file seems stale or truncated
- Ensure snapshotter is running: check app logs: “VACUUM INTO … → rename ok”.
- Force snapshot: **File → Save Snapshot**. Try copy/open again.

**Artifacts**: validator report, snapshot id, last `cmd_id` applied.

---

## D. Merge & Branching

**Goal:** Safe, predictable merges via command‑log rebase.

### D1. One‑shot
```
jve-merge ours.jve theirs.jve --out merged.jve
```
- Default auto‑resolve ladder: Exact → Snap(±6f) → Offset → Skip.

### D2. If conflicts remain
- Open Merge Lane UI: review **pending patches**.
- For each patch: **Apply** (auto) or **Skip**.
- Only use **Advanced** to force specific step.

### D3. Common conflict hints
- `TRACK_LOCKED`: unlock track or retarget.
- `OVERLAP_FORBIDDEN`: adjust insert point or allow auto‑slip.
- `BAD_TIMEBASE`: conform FPS/timebase first (`jve-conform`).

**Artifacts**: base `cmd_id`, conflict list, chosen resolutions.

---

## E. Coordinator & Transport

**Goal:** Live collab either works silently or falls back to local branch; no admin.

### E1. Symptoms
- ❒ Edits stop applying for all → likely no leader.
- ❒ Only my edits stall → connectivity/auth to leader.

### E2. Steps
1) **Health**: `jve-net status`  
   - Shows connected, leader present (internal), or offline mode.
2) **Reconnect**: app auto‑retries; if >N seconds offline, banner “Working locally”. Keep editing.
3) **On return**: auto‑merge runs. Check Merge Lane if prompted.

### E3. WAN specifics
- If remote, ensure invite token not expired; reissue if needed.
- Relay fallback should engage automatically.

**Artifacts**: `jve-net status` output, approximate outage window.

---

## F. Performance

**Goal:** Is the jank in Lua policy, engine, or I/O?

### F1. Quick profile
```
jve-prof --once 3s
```
- Reports top hotspots: **Lua**, **Engine**, **DB**, **Render**.

### F2. Actions
- **Lua hotspot**: move it to C++ or batch calls; avoid per‑frame Lua.
- **Engine hotspot**: add indices or reduce allocations; integer math only.
- **DB hotspot**: ensure bulk changes are wrapped in one txn.
- **Render hotspot**: cache thumbnails/waveforms; defer heavy redraws.

**Artifacts**: profiler snapshot, offending command IDs or UI actions.

---

## G. Access & Security (Invites/Disinvites)

**Goal:** Join failures or unwanted access.

### G1. Join fails
- Check token expiry/term → regenerate invite (`jve-share --invite edit 7d`).
- If fingerprints mismatch after term bump → force rejoin.

### G2. Disinvite
- Rotate `term`/keys (`jve-share --rotate`). Revoked clients drop on next auth.

**Artifacts**: token metadata (no secrets), app logs around join.

---

## H. Standard Bug Report Template

```
Title: [Area] short summary

Build/OS: vX.Y.Z / macOS 15.1 (M1 Max)
Project: MyProject.jve (project_id=...)
Symptom: (one line)

Last 20 commands: jve-dump --tail 20 → attached
Error (if any): code=..., message=..., hint=..., data=...
Repro: steps 1..N (short)
Artifacts: project snapshot, cmd_log tail, profiler report (if perf)
Expected vs Actual:
Notes:
```

---

## Appendix A: CLI Cheat Sheet

- Validate project: `jve-validate --db project.jve`
- Validate command: `jve-validate --cmd {id}`
- Dump tail of log: `jve-dump --tail 50`
- Replay & verify: `jve-replay --from A --to B --verify-hash`
- Bisect divergence: `jve-replay --bisect A..B`
- Migrate schema: `jve-migrate --to latest`
- Backup (snapshot copy): `jve-backup project.jve --out backup.jve`
- Merge projects: `jve-merge ours.jve theirs.jve --out merged.jve`
- Network status (collab): `jve-net status`
- Profiler snapshot: `jve-prof --once 3s`

---

## Appendix B: Error Codes (starter list)

`TRACK_LOCKED` • `BOUNDS_CLAMPED` • `OVERLAP_FORBIDDEN` • `NO_MEDIA` • `BAD_TIMEBASE` • `SNAP_TARGET_MISSING` • `UNSUPPORTED_OP` • `PERMISSION_DENIED` • `SCHEMA_VIOLATION`

Each code has a catalog entry with `message_template`, **mandatory** `hint_template` and `audience`.

---

## Appendix C: Golden Tests (what “good” looks like)

- **Command determinism**: 100% pass in `jve-replay --verify-hash` on suite.
- **Engine invariants**: no row overlaps on same track (except transitions).
- **Persistence**: open succeeds after kill‑mid‑save (last snapshot restored).
- **Merge**: auto‑resolve covers 90% test branches; pending patches minimal.
- **Network**: leader failover < 500ms; clients continue or go local seamlessly.

---

## Appendix D: On‑Disk Expectations

- `.jve` is self‑contained: rows + recent `cmd_log` tail + snapshots + (optional) embedded archives.
- Atomic saves via `VACUUM INTO` + rename; safe to copy at any time.
- No WAL/SHM files for users to manage.

---

# Appendix E: Laminated Card (Quick Triage)

**Pin this next to your keyboard.**

## 1. What failed?
- ❒ Command failed → `jve-validate --cmd {id}`  
- ❒ State diverged → `jve-replay --verify-hash`  
- ❒ Project won’t open → `jve-validate --db project.jve`  
- ❒ Merge odd → `jve-merge ours theirs`  
- ❒ Collab odd → `jve-net status`  

## 2. Always capture
- `project_id`  
- Build/version  
- Last 20 cmd IDs (`jve-dump --tail 20`)  
- Error envelope (code, message, data, hint, audience)  

## 3. Next step by area
- Validation → fix tool args vs invariants.  
- Replay → `--bisect` to find first nondet.  
- Persistence → migrate/restore snapshot.  
- Merge → review pending patches.  
- Net → auto-retry, check token expiry.  

**Golden Rule:** never guess. Always repro once, then use CLI.

---

# Appendix F: Sample Cases (for Practice)

1. **Bad arg**  
```
jve-validate --cmd 123
# Expect TRACK_LOCKED
```

2. **Determinism fail**  
```
jve-replay --from 200 --to 250 --verify-hash
# Expect mismatch → bisect
```

3. **Broken file**  
```
jve-validate --db broken.jve
# Expect schema violation
```

4. **Merge conflict**  
```
jve-merge ours.jve theirs.jve --out merged.jve
# Expect pending patches
```
