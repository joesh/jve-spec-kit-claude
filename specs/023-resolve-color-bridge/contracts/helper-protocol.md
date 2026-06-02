# Contract: JVE ⇄ Resolve Helper Wire Protocol

The testable boundary between JVE (client) and the helper process (owns the Resolve handle). Transport: Unix domain socket under JVE's app-support dir; one JSON object per line (`\n`-terminated). JVE spawns/supervises the helper via QProcess and connects as a `QLocalSocket` client.

Source: spec.md FR-005..010, FR-013, FR-015, FR-020; research.md §4.

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
- **args**: `{ drt_path, media_roots: [string], clip_positions: [{clip_id, track_type, track_index, record_start}], change_token }`
- **result**: `{ mapping: [{ jve_guid, resolve_item_id }], unrelinked: [{ jve_guid, reason }], unkeyed_resolve_items: [{ resolve_item_id, track_type, track_index, record_start }] }`
- Imports the JVE-authored `.drt`, relinks media against `media_roots`, returns the identity join (FR-002). JVE clips that don't appear on the imported timeline are reported in `unrelinked` (FR-001/007) — never silently dropped. `unrelinked[].reason` is a closed-set string: `"absent_from_live_timeline"` (helper observed no item at the JVE-supplied position — most commonly Resolve dropping a clip whose media couldn't be relinked). Re-send with the same token returns the prior mapping.
- **Identity derivation (post-T047)**: the helper resolves `jve_guid → resolve_item_id` by matching JVE-supplied `clip_positions` against the imported timeline's items by `(track_type, track_index, record_start)`. Resolve preserves DRT track order through import (see §read_timeline), so the position tuple is stable. JVE supplies `clip_positions` because the helper holds no JVE state (FR-021); the JVE side already knows where it wrote each clip in the DRT. Matched items are stamped with a marker (`customData == clip.id`) so subsequent §read_identities / §read_timeline calls are id-anchored — no more position dependency once stamped. Resolve items that don't match any JVE position (user added/modified content in Resolve between JVE writing the DRT and the helper importing) flow into `unkeyed_resolve_items` for JVE-side review.

### `read_identities`
- **args**: none
- **result**: `{ items: [{ resolve_item_id, jve_guid }], unkeyed_count }`
- Current Resolve timeline items with recovered join keys; reconciles after manual changes in Resolve (FR-013). Items lacking a join key are omitted from `items` and counted in `unkeyed_count` (so the caller knows the timeline has unmatched items rather than seeing them silently vanish).
- Bidirectional note (FR-011b/c, **corrected by 2026-05-29 T047 spike**): the live `resolve_item_id` here is `TimelineItem:GetUniqueId()`, a runtime instance handle that does **NOT** equal the DRP `Sm2Ti DbId` JVE adopted as `clip.id` (proven 0/1003). So `jve_guid` in this result is recovered via either (a) a clip marker carrying `clip.id` (id-anchored) or (b) content/position match (`name + record-TC + source-TC + media identity`, first-connect) — NOT via raw id equality with `clip.id`. Items lacking both channels are omitted from `items` and counted in `unkeyed_count`.
- **Marker channel convention**: JVE stamps timeline-item markers with `customData == clip.id` (the JVE clip UUID, verbatim). Stamping happens via `TimelineItem:AddMarker(frame, color, name, note, duration, customData)` on the helper side (T048) or at outbound DRT authoring (T049 follow-on). The reader (T029) iterates `TimelineItem:GetMarkers()` and surfaces any non-empty `customData` as `jve_guid`. Marker `color`/`name`/`note` are reserved for user use and NOT inspected — only `customData` carries identity.

### `read_timeline`
- **args**: `{ item_ids?: [string] }` (omit ⇒ all)
- **result**: `{ items: [{ resolve_item_id, track_type, track_index, record_start, record_duration, source_in, source_out, enabled }] }` — `track_type ∈ {"video","audio"}` and `track_index` is Resolve's 1-based track index. Track identity is positional, not carried: Resolve preserves DRT track order through import (JVE V1 stays first video track, V2 stays second), so `(track_type, track_index)` is stable across re-sends without needing a carrier. JVE-side callers translate to a JVE `track_id` via `Track.find_by_sequence(seq_id, track_type)[track_index]`; if that returns nil the item belongs to a Resolve track JVE doesn't have (user added it in Resolve), which the classifier surfaces as `missing_target_track_in_jve`. The helper deliberately does not invent JVE-namespace ids — it has no JVE state.
- The live per-item **edit** state, for pulling Resolve-side edit tweaks back into JVE (FR-024). Read-only; manual-pull only. Times are absolute TC consistent with JVE's timecode-is-truth invariant; the locale-rate guard (FR-020) applies. **Video items**: integer frames only (no subframe). **Audio items**: each TC field is `{frame, subframe}` where subframe is sample-level precision below the frame (matches JVE clip schema's `source_in_subframe`/`source_out_subframe`). JVE diffs these against its matched clips + the stored `edit_fingerprint` to separate Resolve-side changes from JVE-side local edits (FR-025).

### `stamp_identity_marker` *(state-changing; idempotent on change token + (resolve_item_id, custom_data))*
- **args**: `{ resolve_item_id, custom_data, change_token }` — `resolve_item_id` is a live Resolve `TimelineItem` id (`GetUniqueId`); `custom_data` is the JVE `clip.id` to stamp on the item's marker `customData` (the §read_identities marker convention).
- **result**: `{ stamped: bool }` — `true` when the helper called `AddMarker`; `false` when the item already carried a marker with the same `customData` (idempotent no-op).
- Stamps the user-consented identity marker per FR-011c: on first connect, after `ConnectToResolveProject` has matched a JVE clip to a Resolve item by position/content, this verb converts that position match into a marker-anchored link for subsequent syncs. The marker uses `customData == clip.id`; `name`/`color`/`note` are reserved for user use and not consulted by §read_identities — same convention as the reader (§read_identities marker channel).
- Refuses (resolve_api_error) when the item already carries a marker with a DIFFERENT non-empty `customData` — the helper does not silently overwrite a prior identity. Reconciling that ambiguity is a JVE-side decision.

### `read_grades`
- **args**: `{ item_ids?: [string] }` (omit ⇒ all)
- **result**: `{ grades: [{ jve_guid, cdl?: { slope:[r,g,b], offset:[r,g,b], power:[r,g,b], sat }, lut?: { ref }, fidelity }] }`
- `fidelity` ∈ `primary|partial|unrepresentable`, mandatory and honest (FR-015): a node graph exceeding CDL/LUT is downgraded, never approximated. `cdl` present only when representable; `lut.ref` is a local path. Manual-pull only (no server-push).

> **Carved out 2026-06-02**: `queue_render` and `render_status` were part of the v1 contract until the render+relink path was scoped out (see spec.md §Locked decisions "Roundtrip depth"). Their wire contract is preserved at git tag `spec023-render-relink-deferred`.

## Test obligations (constitution III, spec §9)
- **Contract tests** assert request/response *shape* per verb (envelope, required result fields, error-code set). May run against a recorded, regenerable real-Resolve fixture.
- **Live tests** assert **observable Resolve state** against a real Studio: post-`import_timeline`, the Resolve timeline has N items and item K carries join key == the JVE GUID written (gates everything).
- **Idempotency live test**: same state-changing `id` twice → Resolve state changed exactly once, both responses identical.
- Forbidden: any test whose assertion is satisfied solely by its own setup (no mock-asserts-mock).
