# Design: wiring content_match into live discovery (FR-011c)

**Status:** IMPLEMENTED + VERIFIED 2026-06-17 (Option I) — gate CLOSED.
Joe chose **Option I** AND that **content beats position on disagreement** (so the
content channel runs BEFORE position, not after — this reverses §6's earlier lean).
Landed: `discovery.match_by_content` channel (direct-id → marker → **content** →
position), `load_clips_on_track` exposes `master.import_uuid`, content matches are
ledger-persisted (`source="content_match"`) and marker-stamped like position matches,
the dead `identity_ledger.reconcile` + `blade_inherit` + `test_identity_reconcile.lua`
deleted, helper `read_timeline` emits `import_uuid`. Pure-data matcher fully covered
by `test_bridge_discovery_match.lua` (scenarios 13–18). **Gate CLOSED (2026-06-17):**
the probe (`probe_mp_item_identity.py` vs `anamnesis-gold-timeline.drp`) confirmed
`MediaPoolItem.GetUniqueId()` == `Sm2MpVideoClip@DbId` == `import_uuid`
(GetUniqueId ∩ DbId = 15, ∩ UniqueMediaPoolItemId = 0; GetMediaId is the other
family — see phase0-findings §K1a). The helper line is correct as written; the
content channel is LIVE-correct, not dormant.

**Context:** source-clip identity now lives on `sequences.import_uuid` (the master);
`media.file_uuid` dropped. The outbound payload already carries this identity. The
*inbound* match path (pull grades/edits back from Resolve) does NOT yet use it.

## 1. What's live today

The live pull-back matcher is `discovery.match` → `discover_and_link`, called from
`sync_grades_from_resolve` and `sync_edits_from_resolve`. Precedence:

```
match_by_direct_id   (clip.id == resolve_item_id)        — rate-independent
match_by_marker      (item.jve_guid == clip.id)          — stamped marker channel
match_by_position    (track_type:track_index:record_start, then content check
                      on name + source_in + media_file_path)   — skipped on TC-rate mismatch
unmatched
```

`discovery.match`'s clip shape (`load_clips_on_track`) carries **no** source-clip
identity — no `file_uuid`, no `import_uuid`. The position channel's "content check"
is path/name/source_in, not identity.

## 2. What's dead

`identity_ledger.reconcile` is a fully-implemented pure-data matcher with a
**content_match** pass (`rs.file_uuid == jve_clip.file_uuid` AND `jve_guid` empty AND
source-TC overlap) plus a **blade_inherit** pass (child range ⊂ a directly-matched
sibling's range on the same identity). It is called **only by its own test**. Its
`file_uuid` input is `master.import_uuid`. Nothing in production populates that input.

`blade_inherit` has **no analog** in `discovery.match`.

## 3. Two blockers to make content_match live (both required)

- **A (JVE side):** `load_clips_on_track` must follow clip → master and expose
  `master.import_uuid` as an identity field on the matcher shape. Mechanical.
- **B (helper/Resolve side):** the `read_timeline` helper response carries no
  source-clip identity field. `discovery` can only match on what the helper returns;
  today that's marker guid + position + name + media_file_path. To match by identity,
  the helper must read each Resolve timeline-item's pool MediaRef DbId and return it.
  This is the same field we emit outbound — round-trips as the item's `@DbId` / `<MediaRef>`.
  (Per `todo_t049b_content_match_media_identity`: T049b delivered name+path content
  check, NOT identity.)

## 4. THE FORK (Joe decides)

**Option I — incremental channel (recommended).** Add a 4th channel to
`discovery.match`, after position, before unmatched:

```
direct_id → marker → position → content_match(import_uuid + source-TC overlap) → unmatched
```

- Keeps `discovery.match`'s structure, auto-stamping, ambiguity reporting.
- content_match only fires on clips position couldn't settle AND Resolve items with
  no jve_guid (else direct/marker already won) — low blast radius.
- `blade_inherit` stays unimplemented (defer until a real blade/split case needs it).
- Delete `identity_ledger.reconcile` + its test (dead, and Option I doesn't use it),
  OR keep as reference. Lean: delete — dead code misleads.

**Option II — adopt reconcile wholesale.** Replace `discovery.match`'s body with
`reconcile`'s 3-pass (direct/content/blade_inherit).

- Gains blade_inherit now.
- Loses position-channel matching (reconcile has none) — regresses the rate-mismatch
  and no-identity-on-wire cases that position currently covers. Would have to fold
  position INTO reconcile. Larger, riskier.

Recommendation: **Option I**. It's additive, preserves the position channel as the
fallback when identity is absent (offline items, pre-identity DRPs), and lifts the
content_match logic from `reconcile` (the overlap+empty-guid gate) into a new
`match_by_content` without throwing away the live matcher.

## 5. Option I plumbing (if chosen)

1. `discovery.load_clips_on_track` — add `import_uuid = master.import_uuid` to the
   clip shape (resolve clip → `clip.sequence_id`/master → `import_uuid`).
2. Helper `read_timeline` — return `import_uuid` (pool item MediaRef DbId) per item.
   This is the only out-of-Lua change; mirrors the outbound emit. **Contract bump.**
3. `discovery.match` — new `match_by_content(unsettled, items_by_identity, already_claimed)`
   between position and unmatched: for each unsettled clip, find an unclaimed Resolve
   item with equal `import_uuid`, empty `jve_guid`, and overlapping source TC. On a
   single hit → match + stamp; on >1 → `ambiguous "duplicate_identity_content"`.
4. Persist via existing `persist_matches` with `source = "content_match"`.
5. Delete `identity_ledger.reconcile` + `test_identity_reconcile.lua` (or keep, Joe's call).

## 6. Unresolved questions

- Helper contract bump for `read_timeline` to carry identity — OK to widen the
  contract + its `tests/binding/test_helper_read_timeline` (client-side gate only,
  no live Resolve poke)?
- Keep or delete `reconcile`/`blade_inherit`? Delete = simpler; keep = blade_inherit
  reference for the eventual split-clip case.
- ~~content_match precedence vs position~~ **RESOLVED (Joe, 2026-06-17): content
  BEATS position.** The content channel runs BEFORE position — identity (a source clip
  that round-trips through Resolve's DbId) is higher-confidence than geometry, so a
  clip the colorist moved follows its source clip, not its old slot. Same-source
  duplicates (one identity, several overlapping items) are reported
  `duplicate_identity_content` and fall through to position, which disambiguates by
  record_start. Position remains the fallback for clips with no source identity
  (native/compound) and for rate-mismatch runs where the content channel still works
  (it is source-TC based, not record_start based).
- ~~**VERIFICATION GATE (open):** which live `MediaPoolItem` accessor returns the
  `Sm2MpVideoClip@DbId` JVE adopts as `import_uuid`.~~ **CLOSED (2026-06-17):**
  `probe_mp_item_identity.py` vs `anamnesis-gold-timeline.drp` confirmed
  `GetUniqueId()` is the accessor (∩ `Sm2MpVideoClip@DbId` = 15, ∩
  `UniqueMediaPoolItemId` = 0; `GetMediaId()` is the `UniqueMediaPoolItemId`
  family). Helper emits `GetUniqueId()` correctly — no code change. Verdict in
  phase0-findings §K1a.
