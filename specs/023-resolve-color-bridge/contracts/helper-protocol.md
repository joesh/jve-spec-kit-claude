# Contract: JVE ⇄ Resolve Helper Wire Protocol

The testable boundary between JVE (client) and the helper process (owns the Resolve handle). Transport: Unix domain socket under JVE's app-support dir; one JSON object per line (`\n`-terminated). JVE spawns/supervises the helper via QProcess and connects as a `QLocalSocket` client.

Source: spec.md FR-005..010, FR-013, FR-015, FR-018/019, FR-020; research.md §4.

## Envelope

Request:
```json
{ "v": 1, "id": "<correlation-id>", "verb": "<verb>", "args": { ... } }
```
Response (exactly one per request, same `id`):
```json
{ "v": 1, "id": "<correlation-id>", "ok": true,  "result": { ... } }
{ "v": 1, "id": "<correlation-id>", "ok": false, "error": { "code": "<machine-code>", "message": "<human>" } }
```

- `v` — protocol version, present from the first message; bump on any breaking change.
- `id` — JVE's correlation id. Its **only** job is to match a response to its request; it carries no semantics. Idempotency is keyed on `args.change_token`, not `id` (separation of concerns).
- `args`, `result`, `error` are **always JSON objects** (never arrays, never null), even when empty (`args: {}`). The helper validates `isinstance(args, dict)` and rejects anything else as `bad_request`; JVE's `protocol.lua` tags empty Lua tables with `__jsontype="object"` so `dkjson` encodes `{}` not `[]`.
- Errors are structured (machine `code` + human `message`); never bare strings, never swallowed. A dead Resolve handle is an `error`, not a crash and not a silent reconnect (FR-006, constitution VI/VII).

### Change token (idempotency key, FR-008)
A structured value `{ project_id, sequence_id, mutation_generation }` passed in `args.change_token` of every state-changing verb. The helper's ledger stores, per verb, the last token applied + enough to replay the same `result`. A re-sent request bearing a token already applied returns the prior `result` rather than re-importing/re-rendering — regardless of whether `id` is reused. (Whether a DRT content hash must augment the token for cross-session safety is a Phase-2 decision — spec Deferred.)

### Error codes (closed set; extend by bumping `v`)
| code | meaning |
|------|---------|
| `not_studio` | connected Resolve is not Studio / external bridge unavailable (FR-010) |
| `handle_stale` | Resolve handle invalid and could not be reacquired (FR-009) |
| `relink_failed` | the import could not proceed at all (e.g. no media resolvable). Partial relink is NOT this — it succeeds with a populated `unrelinked` list |
| `locale_rate_corruption` | a fractional rate read back as integer (FR-020) — refuse, do not proceed |
| `identity_field_missing` | imported item lacks the join key (FR-002) |
| `bad_request` | malformed envelope/args |
| `resolve_api_error` | underlying scripting call failed (carries Resolve's message + `resolve_version`) |
| `helper_unavailable` | JVE-side: helper process not running / socket unreachable / connect timeout. Never wire-observed (the helper can't emit it about itself); surfaced by `client.lua`/`helper_supervisor.lua` to the same on_complete channel so command callers see a single closed-set error space |
| `not_implemented` | verb not yet wired in this helper build (returned BEFORE touching the Resolve API so state stays consistent). Distinct from `resolve_api_error` so log readers can tell a Resolve API failure from a coverage gap |

## Verbs

State-changing verbs revalidate the handle before touching the Resolve API and return `handle_stale` if it cannot reacquire (FR-009). Liveness (`ping`) calls `handle.acquire()` directly so it can downgrade to `alive=True/resolve_connected=False` on handle errors without raising. Verbs not yet wired in this helper build return `not_implemented` without touching the handle.

### `ping`
- **args**: none
- **result**: `{ alive, resolve_connected, resolve_version, helper_version }`
- Liveness + version surface JVE gates on. `resolve_version` is logged (API-drift landmine).

### `import_timeline` *(state-changing; idempotent on change token)*
- **args**: `{ drt_path, media_roots: [string], change_token }`
- **result**: `{ mapping: [{ jve_guid, resolve_item_id }], unrelinked: [{ jve_guid, reason }] }`
- Imports the JVE-authored `.drt`, relinks media against `media_roots`, returns the identity join (FR-002). Media it cannot relink is reported in `unrelinked` (FR-001/007) — never silently dropped. Re-send with the same token returns the prior mapping.

### `read_identities`
- **args**: none
- **result**: `{ items: [{ resolve_item_id, jve_guid }], unkeyed_count }`
- Current Resolve timeline items with recovered join keys; reconciles after manual changes in Resolve (FR-013). Items lacking a join key are omitted from `items` and counted in `unkeyed_count` (so the caller knows the timeline has unmatched items rather than seeing them silently vanish).
- Bidirectional note (FR-011b/c, **corrected by 2026-05-29 T047 spike**): the live `resolve_item_id` here is `TimelineItem:GetUniqueId()`, a runtime instance handle that does **NOT** equal the DRP `Sm2Ti DbId` JVE adopted as `clip.id` (proven 0/1003). So `jve_guid` in this result is recovered via either (a) a clip marker carrying `clip.id` (id-anchored) or (b) content/position match (`name + record-TC + source-TC + media identity`, first-connect) — NOT via raw id equality with `clip.id`. Items lacking both channels are omitted from `items` and counted in `unkeyed_count`.

### `read_timeline`
- **args**: `{ item_ids?: [string] }` (omit ⇒ all)
- **result**: `{ items: [{ resolve_item_id, track_id, record_start, record_duration, source_in, source_out, enabled }] }` — `track_id` is the JVE track id (string). For Resolve-originated timelines the helper maps Resolve track index → JVE `track_id` via the identity reconciliation (FR-012); for imported timelines the JVE track id is carried directly.
- The live per-item **edit** state, for pulling Resolve-side edit tweaks back into JVE (FR-024). Read-only; manual-pull only. Times are absolute TC consistent with JVE's timecode-is-truth invariant; the locale-rate guard (FR-020) applies. **Video items**: integer frames only (no subframe). **Audio items**: each TC field is `{frame, subframe}` where subframe is sample-level precision below the frame (matches JVE clip schema's `source_in_subframe`/`source_out_subframe`). JVE diffs these against its matched clips + the stored `edit_fingerprint` to separate Resolve-side changes from JVE-side local edits (FR-025).

### `read_grades`
- **args**: `{ item_ids?: [string] }` (omit ⇒ all)
- **result**: `{ grades: [{ jve_guid, cdl?: { slope:[r,g,b], offset:[r,g,b], power:[r,g,b], sat }, lut?: { ref }, fidelity }] }`
- `fidelity` ∈ `primary|partial|unrepresentable`, mandatory and honest (FR-015): a node graph exceeding CDL/LUT is downgraded, never approximated. `cdl` present only when representable; `lut.ref` is a local path. Manual-pull only (no server-push).

### `queue_render` *(state-changing; idempotent on change token + spec hash)*
- **args**: `{ spec, change_token }`
- **result**: `{ job_id }`

### `render_status`
- **args**: `{ job_id }`
- **result**: `{ state, progress, output_paths? }` — pollable to completion; JVE then relinks to `output_paths` (FR-019).

## Test obligations (constitution III, spec §9)
- **Contract tests** assert request/response *shape* per verb (envelope, required result fields, error-code set). May run against a recorded, regenerable real-Resolve fixture.
- **Live tests** assert **observable Resolve state** against a real Studio: post-`import_timeline`, the Resolve timeline has N items and item K carries join key == the JVE GUID written (gates everything).
- **Idempotency live test**: same state-changing `id` twice → Resolve state changed exactly once, both responses identical.
- Forbidden: any test whose assertion is satisfied solely by its own setup (no mock-asserts-mock).
