# JVE Entity Terminology — Draft v1

**Status:** Draft for Joe to redline. Supersedes the rename proposal in `spec.md` once nailed down.
**Purpose:** Single canonical source of truth for entity names, relationships, and the JVE↔Resolve mapping. NO code changes until this is signed off.

**v0 → v1 deltas:** dropped `placement` for `sequence_ref`; dropped `media`/`media_ref` for `asset`/`asset_ref`; dropped `owner_seq` for `parent_seq`; dropped hard-clamp `limits` for view-hint `focus_range`; added Markers as the favorites/subclip-windowing mechanism; flagged Auditions, full Roles system, and grade composition as deferred.

**v1 mid-draft addition:** the **asset visibility invariant** — assets are JVE-internal; the lowest user-addressable handle for captured material is `mediaseq.id` (a media sequence). Resolve DbId adopts to `mediaseq.id`, never to `asset.id`. Closes prior open Q on asset↔sequence identity overlap.

**v1 redline (Joe, 2026-06-15):** kind names change and **"clip" is UNbanned** as a model word. (Supersedes an earlier same-day redline that retired this proposal on a clip-collision worry — the collision dissolves once "clip" has exactly one model meaning; see below.)

1. **Kind rename.** `contains-assets` sequence → **media sequence** (Joe's preference; "asset sequence" was the alternative). `contains-sequences` sequence → **clip sequence**. The kind names now say what the sequence's tracks hold.

2. **"clip" is a model word again = the on-track windowed reference to a sequence** (today's `sequence_ref` / `clips` row). One precise meaning:
   - a **media sequence** holds **asset_refs** (windows onto files / assets)
   - a **clip sequence** holds **clips** (windows onto sequences) — "a sequence of clips"
   - a **clip** points at a source sequence of either kind (nesting, unchanged)

3. **Why the collision dissolves.** UI "Clip" covers {browser media-sequence, timeline clip}. Model "clip" = the timeline ref only. Those align as two life-stages of the same material: you drag a **Clip** (media sequence) from the browser and it becomes a **clip** (sequence_ref) on the timeline. 021's ban gave "clip" zero model meaning; this gives it one that matches the timeline UI label. Net overload drops.

4. **UI keeps "Clip" AND "Master Clip"** as lingua franca (from the prior redline; not in conflict). "Master Clip" UI label names the **source media sequence** of a master/affiliate edge; banned as a **code** identifier (no `master_clip` table/var), allowed as a UI label.

5. **Reverses 021's biggest rename.** `clips`→`sequence_refs`, `clip.id`→`sequence_ref.id`, `models/clip.lua`→`models/sequence_ref.lua` across the codebase mostly **evaporate** — the `clips` table stays `clips`. The changes table (below) needs revisiting in this light.

**Sub-decisions resolved for this reconcile (Joe to confirm — the whole body below now assumes them):**
- **Kind literal form:** `'media_sequence'` / `'clip_sequence'` (full `*_sequence` form, to disambiguate the sequence *kind* from the `clip` *entity*).
- **Entity name:** "clip" replaces `sequence_ref`. Table `clips`, `models/clip.lua`, `clip.id`, and all `clip_*` tables stay as-is; v1's `clips`→`sequence_refs` rename is withdrawn.
- **`media`→`asset` file rename:** stands. `asset` = the file (precise, deduped, internal); "media" survives only as the wrapper-kind word in "media sequence". A media sequence wraps assets.
- **A media sequence's items:** stay `asset_ref`.

If you redline any of these, the body needs a re-sweep — they're load-bearing throughout.

---

## Architectural premise (the one thing JVE does differently)

Every other NLE has two distinct top-level concepts:
1. a **browser clip** (a file reference with in/out, lives in the browser / media pool / project panel)
2. a **sequence clip** (a clip reference on a track, references a browser clip)

**JVE collapses this at the storage layer to one model entity: the `sequence`.** One table, two `kind`s. The kinds are mutually exclusive — there is never a sequence that contains both asset_refs and clips.

But the user-facing distinction stays. The two kinds are labeled differently in the UI:
- A **media sequence** (kind `media_sequence`, formerly "contains-assets") is labeled **"Clip"** to the user.
- A **clip sequence** (kind `clip_sequence`, formerly "contains-sequences") is labeled **"Sequence"** to the user.

The unification is structural, not perceptual. The user sees Clips and Sequences in the browser as distinct things with distinct affordances; the model sees one entity with a `kind` discriminator. The architectural payoff is that operations defined on a sequence (open, peek inside, nest into another sequence, reuse, version, undo) work uniformly across both kinds — even though the user calls one a Clip and the other a Sequence. Recursion in the model is unrestricted: any sequence may be a clip's source sequence, regardless of kind.

### What the user actually gets

The user never needs to hear the words "kind of sequence." The user-facing pitch is just:

**Clips in JVE aren't atomic. You can open one and fiddle with what's inside.**

That's the whole story at the UI level. Everything else flows from it.

What "fiddle with" covers:
- **Adjust sync between tracks** — slide the audio under the video by a sample-accurate offset.
- **Enable / disable tracks** — for picking a multicam angle, muting scratch audio, soloing a clean take.
- **Add or remove source files** — drop another camera angle in, attach an external WAV, swap a re-conformed render.

What this *eliminates* from the user's day:
- **No "Multicam Source Sequence" step.** Premiere makes you create a separate hidden sequence containing the synced angles, then create a "multicam clip" subclip that points at it, then drop *that* into your edit. JVE: open the Browser Clip, drop more angles into it, done. The Browser Clip is still the Browser Clip.
- **No "Merge Clips" command.** Premiere requires you manufacture a "Merged Clip" artifact from one video clip + N audio clips just to get dual-system sync. JVE: open the Browser Clip, drop the WAV onto an audio track, adjust the offset.
- **No "Subclip" as a separate entity — but YES the things subclips were used for.** Subclips (Premiere/Avid) serve two purposes, and we keep both without manufacturing a new entity:
  1. *Master/affiliate relationship* — a subclip points at a master and inherits/overrides attributes. **JVE pattern:** every clip points at a source sequence; many clips share one master; attributes inherit master → clip with per-clip overrides. F command navigates clip → master. See "Master / Affiliate" below.
  2. *Windowed views that name and surface specific ranges of the source.* In Avid/Premiere a subclip's IN/OUT is set at creation and immutable — your only escape is "Remove Subclip Limits" (one-way). **JVE pattern:** ranged **markers** on the source sequence carry name + range + tag. The browser surfaces them as draggable items via a Favorites-style filter view; dragging a marker into an edit produces a clip whose `source_in`/`source_out` defaults to the marker's range. Markers are first-class — N per sequence, editable both endpoints anytime, deletable. The subclip's "I want to nudge IN by one frame" workflow that required recreating the subclip from scratch goes away. See "Markers" below.
- **"Clip Attributes" dialog is just UI that manipulates the tracks in the Browser Clip.** The Browser Clip's tracks are the source of truth, and the dialog is a lossy projection that drives track edits. The user reaches the tracks by opening the Browser Clip in the Timeline panel; asset_refs there are directly editable. The Inspector exposes the `asset` object's properties (file interpretation, TC override, channel layout) and the `asset_ref` object's properties. The dialog is just a faster path for the common cases.

What the user is prevented from doing on an open Browser Clip:
- Insert / overwrite / ripple edits — those produce clips, which live only in clip sequences. A Browser Clip's tracks hold asset_refs, not clips.
- Nest other Browser Clips or Sequences inside it — same reason.
- (Color grading is NOT in this list — a baseline grade on a Browser Clip is supported and inherited by clips; see Master / Affiliate below.)

This is the architectural payoff in user terms: **the intermediate artifacts other NLEs make you build by hand to get sync done — multicam source sequences, merged clips, subclips — don't exist in JVE.** The Browser Clip itself absorbs all of that. The Timeline panel is the edit surface for both Browser Clips and Sequences; the toolset just narrows on a Browser Clip to the operations that make sense there.

### Master / Affiliate

Mostly the FCP7/Avid pattern, but emerging from JVE's data shape rather than requiring separate machinery:

- **Master** = the source sequence a clip points at (`clip.sequence_id`). When the source is a Browser Clip, the user calls it "the master." (When the source is another clip sequence — i.e. a nested edit — the same edge exists but isn't usually called a master/affiliate relationship; we still navigate it with the F command.)
- **Affiliate** = a clip. Many affiliates can share one master.
- **F command (Match Frame / Find in Browser)** navigates from a selected clip to its master, scrolling the Browser to it.
- **Attribute inheritance:** baseline values live on the master sequence; per-clip overrides live on the clip. For most attributes (label color, comments, default routing) the override is simple replace — clip value wins when set, master value inherits when NULL.
  - **Color grade is the exception:** ∘ is genuinely compositional, not just replace. The `clip_grade` stores a **delta** relative to the master's `sequence_grade` baseline:
    - CDL slope: `master.slope × override.slope` (multiplicative)
    - CDL offset: `master.offset + override.offset` (additive)
    - CDL power: `master.power × override.power` (multiplicative)
    - LUT: master LUT applied first, then override LUT chained after
    - The render pipeline applies the composed result. This is why grade override is stored as a delta, not as an absolute — so it composes cleanly when the master grade changes underneath.
  - Composition operator details (per-channel rules, identity-delta encoding, render order) deferred — see "Not in 021" below.
- **Naming:** "affiliate" is a *relationship* word, not an entity word. The entity is `clip`. The user UI says "Clip." The relationship between a clip and its master is "affiliate-of." Three layers, no conflict.

### Focus range

A sequence may optionally declare a `focus_range = [start, end]`: a per-sequence **view hint and drag default**, not a content clamp.

**Model:**
- `sequences.focus_range_start_frame` INTEGER NULL
- `sequences.focus_range_end_frame` INTEGER NULL
- Both NULL or both set, with `focus_range_start_frame < focus_range_end_frame`. (Rule 2.13 — no soft defaults.)

**Semantics (view hint, not clamp):**
- **Zoom-to-Fit** zooms the viewer/timeline to focus_range when set, otherwise to full content. The user can zoom out past focus_range freely.
- **Drag default**: dragging this sequence from the browser into an edit produces a clip whose `source_in`/`source_out` default to focus_range. The user can then trim past it freely — focus_range never clamps the resulting clip.
- The resolver / `source_window` does NOT consult focus_range. There is no read-time hide.

**Why it's not "limits":** limits implies hard-clamp content scope. Focus range is purely a viewport preference + drag default. Trim operations don't fail against it; the resolver doesn't intersect with it. Calling it "limits" was a category error in v0.

**UI:** distinct ruler affordance (ghosted region outside focus_range when set), draggable endpoints, clearable via a "Clear focus range" action. Not a checkbox toggle — null both columns to clear.

WHEN A MARKER CLIP (term?) is viewed in the source monitor the focus range is set to the marker clip bounds. Alternatively maybe we don’t have a focus_range and instead have a user-invisible flag that says the marker clip’s bounds should be used as a focus range. Still needs thought.

### Markers

Markers are the favorites/subclip-windowing mechanism, generalized.

**Two scopes, two tables:**
- **`sequence_markers`** — markers on a source sequence. The browser-side "favorites" mechanism. N per sequence.
- **`clip_markers`** — markers on a clip (timeline instance). Editor's notes on a specific use. (This is the table 021 v0 called `placement_markers`; v2 keeps the `clip_markers` name.) NOT LOVING THE TERM clip_markers. Discuss these two tables.

**Shape (both tables):**
- `id` (uuid)
- parent fk (`sequence_id` or `clip_id`)
- `start_frame` INTEGER NOT NULL
- `end_frame` INTEGER NULL — NULL = point marker, non-null = ranged marker
- `name` TEXT
- `comments` TEXT
- `keywords` / `tags`
- `color` / `rating` — TBD; at minimum a category field so saved-views can filter

**The favorites story (sequence_markers):**
- Mark a range on a Browser Clip (set IN/OUT, hit `F` or the keyboard shortcut TBD) → adds a marker to the sequence with that range and an optional name.
- The browser supports a Favorites-style filter view that surfaces each ranged marker as a **separately draggable browser entry**, even though they all live on one underlying source sequence. (FCPX precedent: Favorites + Smart Collections.)
- Dragging a marker entry into an edit produces a `clip` whose `source_in`/`source_out` default to the marker's range. The clip is then independent — the user can trim past the original marker range freely. The source-side marker is unchanged.
- N markers per source → N draggable windows without manufacturing subclip artifacts.

**Composition with focus_range:**
- focus_range is the per-sequence default drag window.
- A marker drag overrides that default with the marker's range.
- Both are drag-defaults, neither clamps the resulting clip. NOT SURE I UNDERSTAND WHAT YOURE SAYING 

**Why not collapse focus_range and markers into one table:**
- focus_range is at most one per sequence; markers are N per sequence. I DONT THINK THIS IS TRUE. It’s really about mimicking subclip behavior. Discuss.
- focus_range drives Zoom-to-Fit (viewport behavior); markers drive browser filter views (organizational).
- They compose cleanly (focus_range is the default; a marker drag wins). Separate columns / table tracks the two different roles.

**Subclip parity:** the Avid "subclip with limits" use case is covered by a single ranged marker + the drag-default semantics. The "edit my subclip's IN by one frame" workflow becomes "drag the marker endpoint." No "Remove Subclip Limits" command needed because nothing was clamped to begin with.\
WE NEED TO GO THROUGH AN EXAMPLE WHERE WE DIVIDE A CLIP INTO MULTIPLE “jve subclips” ie ranged markers. What do we see when opening one of these marker clips in the source monitor?

---

## "Clip" — a model word (the on-track reference) AND a UI label

> **[v2 reconcile, Joe 2026-06-15]** This section is inverted from the v1 draft. v1 banned "clip" from the model; v2 **unbans** it and gives it exactly one model meaning. Rationale: a single precise meaning removes the overload the ban was avoiding, and it lines up with how every NLE user already thinks. See the v1-redline block at the top.

Every other NLE uses "clip" for two things — the browser item and the timeline placement — and users call both "the clip." v2 keeps the user's word AND pins a precise model meaning:

- **Model `clip` = the on-track windowed reference to a sequence** — the row in the `clips` table, the thing on a clip sequence's track. This is what older drafts called `sequence_ref`. One meaning, no overload.
- **UI "Clip"** is broader (NLE lingua franca, stays): it labels a **media sequence** when shown in the browser AND a **clip** when shown on the timeline. These are two life-stages of the same material — you drag a Clip (media sequence) from the browser and it becomes a clip (on a track). The model word matches the timeline use exactly; the browser use is just the pre-drop stage.
- **A clip sequence is labeled "Sequence" in the UI**, never "Clip." Browser items split into Clips (media sequences) and Sequences (clip sequences); the user sees this distinction.
- **Top-level model entities at this layer:** `sequence` (kind `media_sequence` | `clip_sequence`) and `clip` (on a clip sequence's track). The `clips` table and `models/clip.lua` keep their current names — v2 does NOT rename them to `sequence_ref`.

This keeps the code layer unambiguous: "clip" means exactly one thing in code (the on-track ref). The user-facing word legitimately covers two model entities (media sequence in the browser | clip on the timeline), but that breadth is a UI-label binding, not a code one.

---

## "Sequence" — model word vs UI label

The rename surfaces a second overload that needs declaring explicitly so future readers don't get caught:

- **`sequence` (model):** any sequence object, either `kind`. The universal container.
- **"Sequence" (UI label):** specifically a `clip_sequence`. A media sequence is labeled **"Clip"** in the UI, never "Sequence."

This is consistent with FCP/Premiere/Avid: users say "this sequence" meaning the edit, not the source material in the browser. So the narrow user meaning is the conventional one, even though the model word is broader.

**Rules:**
- Code, schema, comments, specs: `sequence` always means the universal model entity (either kind). When a code path is restricted to one kind, the code says `kind == 'clip_sequence'` or asserts it, but the noun stays `sequence`.
- UI strings: "Sequence" labels only `clip_sequence`s. "Clip" labels media sequences (in the browser) and clips (on the timeline).
- When discussing the model in design docs (including this one), prefer `media sequence` and `clip sequence` for precision over the bare word `sequence`, unless the kind genuinely doesn't matter.

---

## The asset visibility invariant

**Assets are JVE-internal. The user never holds an asset id.** The lowest user-addressable handle for "this captured material" is a `mediaseq.id` — i.e. the id of the media sequence that wraps the file.

**Why this is load-bearing:** the mediaseq isn't a transparent wrapper around an asset — it carries baseline grade, sync mode, focus_range, markers, multi-track structure, channel layout. That is what makes it a "Clip" in JVE's sense. If F-command or Match Frame or any other path handed the user a bare asset id, the user could plumb it directly into a clip sequence, bypassing every one of those properties. The visibility rule prevents that back-door.

**Rules:**
- F-command, Match Frame, Reveal in Browser, copy/paste, scripting APIs, and every user-facing handle return a **mediaseq id** — never an asset id.
- The UI never says the word "asset" in menus, inspectors, or status. UI vocabulary: "Clip," "File," "Source."
- Assets exist only as a code-internal file binding. The decoder / TMB / renderer layer walks `clip → source_seq (mediaseq) → asset_ref → asset → file_path`. That resolution chain is private; no step in it is callable from a user action.
- "Reveal in Finder" is the single user-facing operation that exposes the asset's source path — and only as a read-only Finder reveal, not as a handle the user can plumb back into JVE.

**Cardinality: 1 asset : N mediaseqs.** An asset is the file-binding identity (one per actual file, deduped by stable file identity — dedup key TBD, see Open Questions). Many mediaseqs can wrap the same asset, each carrying its own marks/grade/focus_range/track configuration. Concrete cases:
- "Duplicate Clip" on a Browser Clip → new mediaseq, same asset.
- Re-importing the same file → asset is deduped; second import yields a second mediaseq sharing the asset (UX details TBD).
- Resolve DRP with two pool clips referencing the same file → two mediaseqs (each adopting its own DbId), one asset.
- Relink mutates the asset's source path; every mediaseq referencing that asset transparently picks up the new path.

**Identity bridge to Resolve:**
- On DRP import: Resolve `Sm2MpVideoClip.DbId` → `mediaseq.id`. `asset.id` is a fresh JVE-internal uuid (or hash-derived; dedup key TBD).
- On DRT export: the pool clip's DbId is written as `mediaseq.id`.
- `asset.id` never crosses the Resolve boundary — symmetric with the visibility rule (invisible to the user, invisible to Resolve).

This closes prior open Q on whether `asset.id == wrapping-sequence.id`. They are distinct ids with distinct lifecycles; the user sees only `mediaseq.id`; Resolve also sees only `mediaseq.id`.

---

## How we talk about this in the source code

The terminology above is the public/design vocabulary. The hardest part is keeping it disciplined inside the code itself. These are the rules.

### 1. Banned words in code

| Word | Where banned | Why |
|---|---|---|
| ~~`clip`~~ **UNBANNED (v2)** | — | `clip` = the on-track reference to a sequence (the `clips` row; older drafts' `sequence_ref`). One precise model meaning. Table `clips`, `models/clip.lua`, `clip.id`, `clip_*` columns all stay. The v1 ban is withdrawn. |
| `master_clip`, `master`, `masterclip` | **Code only** (schema, model, identifiers). NOT banned in UI strings. | Code: no `master_clip` table/var — the entity is gone. UI: "Master Clip" stays (lingua franca); it names the **source media sequence** of a master/affiliate edge. The relationship exists; only the standalone entity was deleted. |
| `timeline` (as an entity) | Schema, model, function names referring to a sequence | Panel name only. Calling a sequence `timeline` re-anchors us to Resolve's outlier vocabulary. |
| `subclip`, `merged_clip`, `multicam_clip` | Everywhere | These artifacts don't exist in JVE — the Clip itself absorbs their function. |
| `placement` | Everywhere | Invented JVE jargon (no NLE precedent — Premiere "placement" means clip position, not an entity). Use `clip`. |
| `media` (as the *file* entity / table / module) | Schema, model, code — as the file entity | Replaced by `asset` (file on disk) and `asset_ref` (windowed file reference). `media` survives as informal English AND (v2) as the **kind word** in "media sequence" (kind `media_sequence`) — the user-facing wrapper, kept distinct from the internal `asset` it wraps. |
| `media_ref`, `mref` | Everywhere | Replaced by `asset_ref` / `aref`. |
| `limits`, `limits_enabled`, `start_limit_frame`, `end_limit_frame` | Everywhere | Replaced by `focus_range_start_frame` / `focus_range_end_frame`. Different semantics (view hint, not clamp). |
| `pool`, `pool_item`, `pool_clip` | JVE-side code (model, commands, UI) | OK on the Resolve parser side, where we're translating Resolve XML. Banned elsewhere. |

Allowed: `timeline_panel`, `timeline_view` (UI), and `pool_clip_elem` etc. inside the DRP parser as Resolve-side locals.

### 2. Bare nouns and what they mean

| Code word | Meaning | Examples |
|---|---|---|
| `sequence`, `seq` | A sequence object, either kind. | `local seq = Sequence.load(id)` |
| `clip` | A clip — the on-track reference to a sequence (older drafts' `sequence_ref`). | `local clip = Clip.load(id)` |
| `asset` | An asset (file on disk). | `local asset = Asset.load(id)` |
| `asset_ref`, `aref` | An asset_ref. | `for _, aref in ipairs(track.asset_refs) do` |
| `track` | A track. | `local track = seq.tracks[i]` |
| `marker` | A marker on a sequence or a clip. Distinguish by parent if ambiguous. | `for _, m in ipairs(seq.markers) do` |

`ref` alone is banned (too generic). Always `asset_ref`/`aref` for a file window, or `clip` for a sequence window.

### 3. Don't encode kind in variable names — encode it in operation names

Tempting: `local asset_seq = ...` for "a media sequence." Don't. It reads as "a sequence of assets," it overloads `asset`, and it forces every other call site to invent a parallel `edit_seq`. There is no good kind-suffixed name for a sequence.

Instead: **the operation tells you the kind, and an assert at the top makes it explicit. Operations are methods on the object, not standalone functions that take the object as a parameter.**

```lua
-- GOOD: method on Sequence; assert makes kind certain.
function Sequence:add_asset_ref(aref)
    assert(self.kind == "media_sequence",
        string.format("add_asset_ref: sequence %s has kind=%s, must be media_sequence",
            self.id, self.kind))
    ...
end

function Sequence:add_clip(clip)
    assert(self.kind == "clip_sequence",
        string.format("add_clip: sequence %s has kind=%s, must be clip_sequence",
            self.id, self.kind))
    ...
end

-- BAD: standalone function takes the object as a parameter, AND uses a kind-bearing
-- variable name. Both wrong: should be a method on Sequence with `self`.
function add_asset_ref(media_seq, aref) ... end
```

The reader of a method body sees `self` and knows from the method's name (and assert) what kind it must be (or that it doesn't matter). The assert is the contract.

### 4. Relational variable names — source vs parent

A `clip` has two sequence relationships:
- `clip.sequence_id` → the **source** sequence (what it points at, any kind).
- `clip.parent_sequence_id` → the **parent** sequence (what physically contains it, always a `clip_sequence`).

Variable names that follow:

| Code | Meaning |
|---|---|
| `source_seq` | The sequence a clip points at (any kind). |
| `parent_seq` | The sequence that contains a clip (always a clip_sequence). |
| `seq` | When only one sequence is in scope, or when role isn't relevant. |

`parent` over `owner` because "owner" reads as master/affiliate relationship. Parent is unambiguously hierarchical containment.

An `asset_ref` has only one sequence relationship (`parent_sequence_id` → a media_sequence), so `parent_seq` is unambiguous in that context.

### 5. Function naming — prefer methods on the object

Operations are methods on the object they act on, called with colon syntax (`obj:method(args)`), not standalone functions that take the object as a parameter. Module-level functions are reserved for constructors (`Sequence.create`, `Sequence.load`) and for peer operations where no single object dominates. The kind constraint lives in the assert, not the function name.

| Good | Bad | Why |
|---|---|---|
| `seq:add_asset_ref(aref)` | `add_asset_ref(seq, aref)` | Method on the dominant object (a media sequence's method). |
| `seq:add_clip(clip)` | `add_clip(seq, clip)` | Method on the dominant object (a clip sequence's method). |
| `Sequence.create(kind, ...)` | `Sequence.create_media_seq(...)` / `Sequence.create_clip_seq(...)` | Constructor — no instance yet, so module-level is correct. Single constructor; kind is a parameter. |
| `Sequence.load(id)` | `Sequence.load_any_kind(id)` | Loading doesn't care about kind. Class method. |
| `clip:source_window()` | `effective_source.for_clip(p)`, `source_window.for_clip(clip)` | Method on the dominant object. Internally composes the source sequence's window with the clip's own window. |
| `clip:apply_grade(grade)` | `clip_grade.apply(clip, grade)` | Method form preferred over standalone. |
| `Asset.load_or_create(file_path)` | `load_or_create_asset(file_path)` | Class method — no instance yet (this IS the creation path). |

### 6. Object property names

`sequence`'s `kind` literals: `'media_sequence'` and `'clip_sequence'` (v2; were `'master'`/`'sequence'` in current code and `'contains-assets'`/`'contains-sequences'` in v1). The full `*_sequence` form disambiguates the sequence *kind* from the `clip` *entity*.

A clip's `sequence_id` property is the source-sequence id. It is **not** named `source_sequence_id` because:
- A clip only ever points at one other sequence, and the relational role from the clip's POV is obvious.
- Compare with `parent_sequence_id` (the back-reference to the containing sequence) — `sequence_id` is the forward reference; the asymmetry of names tracks the asymmetry of direction.

Reference-pair conventions to standardize:

| Forward reference (what this object points at) | Back reference (what physically contains this object) |
|---|---|
| `clips.sequence_id` (source) | `clips.parent_sequence_id` |
| `asset_refs.asset_id` | `asset_refs.parent_sequence_id` |
| `tracks.???` (n/a — tracks are contained, not pointing) | `tracks.parent_sequence_id` |

### 7. Comments and docstrings

- When a comment names a concept that has both a model name and a UI label, use the **model name** (`sequence`, `clip`) unless the comment is specifically about UX.
- A comment about user-facing behavior may say "Clip" or "Sequence" capitalized to signal it's a UI label, e.g. *"opened in the Timeline panel, this sequence is labeled `Clip` in the title bar."*
- `clip` lowercase in a code comment means the on-track reference entity (the `clips` row). Use it freely with that meaning; capitalize "Clip" to signal the UI label.
- The word "media" is allowed only as informal English referring to file content ("the media file is unreadable"); never as a code identifier.
- Don't explain that `sequence` has two kinds in every file; assume the reader has read this doc once. A targeted assert plus one-line precondition comment is enough.

### 8. Tests

Test names describe domain behavior (per CLAUDE.md), in model vocabulary:

```
test_clip_source_window_clamps_to_source_duration.lua          -- good (clip = on-track ref, v2)
test_sequence_ref_source_window_clamps_to_source_duration.lua  -- old name (v1, retired)
test_browser_clip_opens_in_timeline.lua                        -- bad, mixes UI label into code

test_open_media_sequence_in_timeline_panel.lua                 -- good (explicit about kind + panel)
test_timeline_blocks_insert_on_media_sequence.lua              -- good (operation + kind)
test_marker_drag_seeds_clip_source_window.lua                  -- good (favorites-via-markers behavior)
```

UI strings that the test asserts on may include the words "Clip" and "Sequence" (those are the user-visible labels). The test file name and code identifiers stay in model vocabulary.

### 9. The DRP importer (the one place Resolve vocabulary is allowed)

Inside `importers/drp_importer.lua` and its helpers, Resolve vocabulary is allowed on **parsed-XML locals only**:

```lua
local pool_clip_elem = find_direct_child(...)   -- ok: Resolve-side
local timeline_item_elem = ...                  -- ok: Resolve-side
local pool_clip = parse_pool_clip(pool_clip_elem)
-- Boundary: from here on, JVE vocabulary.
local seq = Sequence.create({kind = "media_sequence", ...})
local asset = Asset.create(...)
```

The boundary is the parse-to-model handoff. Anything assigned into a JVE object uses JVE vocabulary; anything still holding a parsed XML element or a Resolve-side intermediate uses Resolve vocabulary. The two never appear in the same identifier (no `pool_seq`, no `clip_sequence_ref`).

### 10. The DRT writer / bridge helper (the other Resolve boundary)

Symmetric to the importer: JVE vocabulary on the input side, Resolve vocabulary on the output side. The `drt_writer` reads `clip`s and `asset_ref`s and emits `<Sm2TiVideoClip>`s and `<Sm2MpVideoClip>`s. Locals named after the emitted Resolve element are allowed (`timeline_item_node`, `pool_clip_node`); locals naming a JVE object stay in JVE vocabulary.

---

## Sequence vs Timeline (model vs panel)

**"Sequence" is the object. "Timeline" is a UI panel that displays a sequence.** Never confuse the two.

Industry alignment:

| NLE | Object name | Panel name |
|---|---|---|
| FCP7 | Sequence | Timeline |
| FCPX | Project | Timeline |
| Premiere | Sequence | Timeline |
| Avid Media Composer | Sequence | Timeline |
| **Resolve** | **Timeline** (UI) / `Sm2Sequence` (code) | Timeline |

Resolve is the sole outlier in using "Timeline" for the object — and even Resolve's own implementation kept `Sm2Sequence` after a partial UI rename. The consensus name for the object is **sequence**, and JVE follows the consensus.

**Rules:**
- **Model / schema / code / spec / docs:** always `sequence`.
- **UI strings, menus, panel names:** `Timeline` refers only to the editing-surface *panel* that displays a clip sequence.
- **Never** call a media sequence a "timeline" in any layer.
- **Never** call a sequence a "timeline" in code.

---

## The structural axis: what does this sequence CONTAIN?

A sequence's `kind` is the answer to a single question: *what do its tracks hold?*

| `kind` value | Tracks hold | User mental model |
|---|---|---|
| `media_sequence` | asset_refs (direct file windows) | "A piece of captured material — one or more files, possibly multi-rate." |
| `clip_sequence` | clips (each pointing at a sequence) | "An edit — its tracks hold references to other sequences." |

Naming axes:
- **structural** (what's inside): `media_sequence` / `clip_sequence`
- **relational** (role from a clip's POV): `source sequence` (what the clip references) / `parent sequence` (what physically contains the clip)

The two axes commute. Both halves read cleanly:
> *"This clip's source sequence is a media sequence."*
> *"This clip's source sequence is a clip sequence."*

Neither sentence uses "master."

**v2 resolved:** kind literals are `'media_sequence'` / `'clip_sequence'` (full form, to disambiguate the sequence *kind* from the `clip` *entity*). Were `'contains-assets'` / `'contains-sequences'` in v1.

---

## The entities

### `asset`
A file on disk. One asset per file (deduped by stable file identity — dedup key TBD). Carries probed metadata (codec, fps, sample rate, duration, TC origin).
**Identity:** JVE-internal uuid (or hash-derived; see Open Questions for dedup key). **Never adopts the Resolve DbId** — the visibility invariant routes that to `mediaseq.id` instead. See "Asset visibility invariant" above.
**Has no concept of in/out.** That belongs to `asset_ref`.
**Has no user handle.** Code-internal only; reached via `asset_ref.asset_id`.

### `asset_ref`
A typed window into an `asset`: `source_in_frame`, `source_out_frame`, plus `audio_sample_rate` (018), plus an in/out position on its parent's track (`sequence_start_frame`, `duration_frames`).
**Lives inside exactly one media sequence.** Never inside a clip sequence.
**Why both source-window AND parent-position?** Because the media sequence is itself editable material — it has a timebase, the asset_refs are arranged on its tracks, and what the user sees when they peek inside is *those asset_refs in that arrangement*.

### `sequence`
The universal container. Has a `kind`, video timebase (fps_num/den), audio sample rate (018), dimensions, marks, focus_range (optional), undo stack, view state.
**Identity:** UUID. When imported from Resolve:
- a media sequence (mediaseq) adopts the pool item's `Sm2Mp*.DbId`. **This is the user-addressable handle for the captured material** — see "Asset visibility invariant."
- a clip sequence adopts `Sm2Sequence.DbId`.

The wrapped asset gets a fresh JVE-internal id; the Resolve DbId never lands on the asset.

### `track`
A lane within a sequence. Has a type (video/audio), an index, sync mode (015), patch state (015), mix state.
A track in a media sequence holds asset_refs.
A track in a clip sequence holds clips.
**Never mixed within one sequence.**

### `clip` (older drafts: `sequence_ref`)
A clip on a track inside a clip sequence. References another sequence via `sequence_id` (the *source sequence*; may be either kind — uniform).
Carries: source window (`source_in_frame`/`source_out_frame` in source sequence's timebase), parent-side position (`sequence_start_frame`/`duration_frames` in parent sequence's timebase), per-instance video/audio track selectors (013), enabled, volume.
**Identity:** UUID. When imported from Resolve, adopted from `Sm2Ti*.DbId` (spec 023 FR-011b).

**Naming rationale:** "clip" describes exactly what it is — the on-track windowed reference to a sequence, placed on a clip sequence's track. One model meaning, matching the timeline UI label. The `clips` table and `models/clip.lua` keep their current names (v2 does not rename them). Matches FCPX's `<ref-clip>` shape in spirit.

### `sequence_markers` and `clip_markers`
Markers come in two scopes:
- Markers on a `sequence`. The favorites/named-windows mechanism.
- Markers on a `clip`. Per-instance editor notes.

Every marker carries `start_frame`, optional `end_frame` (NULL = point marker), `name`, and category/tag properties (TBD). Multiple markers per parent.

### `patch`
Source-routing rule (015). Maps source track → parent track for insert/overwrite operations on a clip sequence.

### `clip_grade` (023)
Per-instance color grade (CDL + LUT). Keyed by `clip.id`. Composed with the source sequence's baseline `sequence_grade` at render time — composition operator deferred (see Not in 021).

### `resolve_bridge_link` (023)
Per-instance bridge identity + fingerprints (edit + grade). Keyed by `clip.id`.

---

## The relationships (ER diagram)

```
                   ┌─────────┐
                   │  asset  │  (file on disk)
                   └────┬────┘
                        │ asset_id
                        ▼
                  ┌───────────┐
       parent ◀───│ asset_ref │   on a media sequence's track
                  └───────────┘
                        ▲
                        │ (a track of kind 'media_sequence' holds asset_refs)
                        │
                  ┌───────────┐
                  │   track   │───┐
                  └───────────┘   │ parent_sequence_id
                        ▲         ▼
                        │   ┌──────────┐
                        │   │ sequence │  kind = media_sequence | clip_sequence
                        │   └────┬─────┘
                        │        │ sequence_id (any kind)
                        │        ▼
                        │   ┌──────┐
                        └───│ clip │   on a clip sequence's track
                  (track of │      │
                  kind      └──┬───┘
                  'clip_        │ clip.id
                  sequence')    ├──────▶ clip_grade (023)
                                └──────▶ resolve_bridge_link (023)
```

**Cardinality rules:**
- `asset : asset_ref` = 1 : N
- `sequence(media_sequence) : asset_ref` = 1 : N (via track)
- `sequence(clip_sequence) : clip` = 1 : N (via track)
- `clip : sequence` = N : 1 (clip's `sequence_id`; the source sequence)
- A given sequence can be the source for many clips (reuse / nesting).

**Invariants:**
- A media sequence's tracks hold ONLY `asset_ref`s.
- A clip sequence's tracks hold ONLY `clip`s.
- An `asset_ref`'s `parent_sequence_id` always points at a media sequence.
- A `clip`'s `parent_sequence_id` always points at a clip sequence.
- A `clip`'s `sequence_id` may point at EITHER kind. This is the nesting mechanism.

---

## The JVE ↔ Resolve mapping

| Resolve concept | JVE entity | Identity bridge |
|---|---|---|
| Media-pool clip (`Sm2MpVideoClip` / `Sm2MpAudioClip`) | the wrapping media sequence (mediaseq) — NOT the asset | `DbId` → `mediaseq.id`. Asset gets a fresh JVE-internal id (asset visibility invariant). |
| Pool folder (`Sm2MpFolder`) | bin (per project_browser bin_map) | `DbId` → bin id |
| Timeline / sequence (`Sm2Sequence`) | a clip sequence | `DbId` → sequence.id |
| Timeline item (`Sm2TiVideoClip` / `Sm2TiAudioClip`) | a `clip` | `DbId` → clip.id (023 FR-011b) |
| Track in a sequence | a `track` | positional (V1, V2…, A1, A2…) |
| `BtAudioInfo` (audio stream within a pool item) | an asset_ref's audio side | `DbId` → asset_ref id (?) |

**On the parser side (DRP importer), use Resolve's vocabulary** (`pool_clip`, `timeline_item`, `Sm2Mp*`, `Sm2Ti*`). **On the model side, use JVE's vocabulary** (`asset`, `sequence`, `clip`). The boundary is the importer — translation happens once, at parse-to-model handoff.

---

## What changes from current vocabulary

Legacy column refers to what is in the codebase today (pre-021). New column is the v1 target.

| Current name (legacy) | New name (021 v2) |
|---|---|
| `media` table | `assets` table |
| `media.id`, `media_id` | `asset.id`, `asset_id` |
| `media_refs` table | `asset_refs` table |
| `media_ref.id`, `media_ref_id` | `asset_ref.id`, `asset_ref_id` |
| Lua var `mref` | `aref` |
| `models/media.lua` | `models/asset.lua` |
| `models/media_ref.lua` | `models/asset_ref.lua` |
| `clips` table | **(unchanged — v2 keeps `clip`)** |
| `kind='master'` | `kind='media_sequence'` |
| `kind='sequence'` | `kind='clip_sequence'` |
| `models/clip.lua` | **(unchanged — v2 keeps `clip`)** |
| `clip.id`, `clip_id` | **(unchanged — v2 keeps `clip`)** |
| `clips.master_layer_track_id` | `clips.video_layer_track_id` (no "master" — the clip already knows its source sequence) |
| `clips.master_audio_track_id` | `clips.audio_layer_track_id` |
| `clip_grade` table | **(unchanged — v2 keeps `clip_grade`)** |
| `clip_links` table | **(unchanged — v2 keeps `clip_links`)** |
| `clip_markers` table | **(unchanged — v2 keeps `clip_markers`)** |
| `clip_channel_override` table | **(unchanged — v2 keeps `clip_channel_override`)** |
| `owner_sequence_id` (on any contained row) | `parent_sequence_id` |
| Lua var `owner_seq` | `parent_seq` |
| `core/effective_source.lua` (module) | `core/source_window.lua` (or fold the computation into `Clip:source_window()`) |
| `effective_source.for_clip(p)` (standalone fn) | `clip:source_window()` (method) |
| "master clip" (concept) | (deleted as code entity — UI label "Master Clip" kept as lingua franca) |
| `database.load_master_clips` | TBD — `load_browser_sequences` is the likely shape |
| `commands/duplicate_master_clip.lua` | `commands/duplicate_sequence.lua` (covers both kinds) |
| `commands/delete_master_clip.lua` | `commands/delete_sequence.lua` |
| `commands/find_master_clip_in_browser.lua` | `commands/find_sequence_in_browser.lua` |
| importer locals `master_clip = {...}` | `pool_clip = {...}` on Resolve side; assigned into `sequence` + `asset` on JVE side |
| importer locals `clip_elem` (timeline-item context) | `timeline_item_elem` |
| importer locals `clip_elem` (pool context) | `pool_clip_elem` |
| Lua variable `clip` (timeline-entry context) | `clip` (unchanged — v2 model word) |
| Comment/string "the clip" in non-UI code | "the clip" (model word for on-track ref; fine in code) |
| UI menu "Duplicate Master Clip" | "Duplicate Clip" (UI label; "Master" kept only in "Master Clip" lingua franca) |
| `sequences.start_limit_frame`, `end_limit_frame`, `limits_enabled` | `sequences.focus_range_start_frame`, `focus_range_end_frame` (both NULL when not set; no separate toggle) |
| "limits" (concept — hard clamp at resolver) | (deleted — focus_range is view hint + drag default only) |
| (none — markers had no duration) | `sequence_markers` table with optional `end_frame` (favorites mechanism) |

**UI plural convention:** code/schema uses `clips`; UI strings also say "clips" to users ("Selected 3 clips"). Model and UI align on v2.

---

## Tests this naming has to pass

1. **The outsider test.** A new engineer reads the schema cold. Can they tell apart "the file on disk," "the thing in the browser," "the thing on a timeline" without context? Yes — `asset` is the file, `sequence` is the container (browser and edit), `clip` is the on-track reference.
2. **The one-noun-one-meaning test.** No word means two things in code. `clip` = the on-track ref (the `clips` row). `sequence` = the universal container. `asset` = the file. `timeline` = the panel only. Each is one meaning.
3. **The Resolve-boundary test.** Translation between Resolve and JVE happens at exactly two places (DRP importer; DRT writer + bridge helper) and the translation table is explicit. Neither side leaks vocabulary.
4. **The "double-click in browser" test.** Whatever the user clicks, the answer is "open the sequence." No type-switching at the UI level.
5. **The recursion test.** A clip's source sequence can itself contain clips whose source sequences contain clips… Reads naturally at any depth.
6. **The user-says-clip test.** When a user says "this clip," code in the relevant handler asks "is the user pointing at a browser item or a timeline entry?" The handler routes to either a sequence id (media sequence in the browser) or a clip id (on-track ref). `clip` in model code always means the on-track ref.
7. **The favorites test.** A user marks five ranges on a Browser Clip; the browser's Favorites view shows them as five separately draggable entries; dragging any one produces a clip seeded to that range. No subclip / favorite entity manufactured.

---

## Not in 021 (deferred)

Features explicitly out of scope for this rename, with the reason for deferral:

- **Audition** (FCPX-style container of alternates with a "pick"). Modelable later as either (a) a clip carrying a list of candidate `source_sequence_id`s + a `pick_index`, or (b) a media sequence with N video tracks at the same position and only the picked track enabled. Deferred — workflow demand should drive the choice.
- **Full Roles system** (FCPX-style typed metadata driving timeline lanes, export stems, mix, per-component subroles). Larger than a rename — affects metadata schema, mix engine, and a future export-stems spec. Patch (015) is the routing primitive today; Roles would unify it with iXML import tagging and export. Future spec.
- **Grade composition operator** (`sequence_grade ∘ clip_grade`). The inheritance shape is established; the CDL+LUT composition arithmetic (slope/offset/power compose, LUT chain order, per-channel rules) is a render-pipeline design separate from terminology. Future spec.
- **Asset dedup key.** Asset visibility invariant locks in 1:N asset:mediaseq with file-binding identity; the actual dedup key (content hash vs BWF UID vs hybrid) is deferred. See Open Questions.
- **Same-file re-import UX.** Silently create a second mediaseq sharing the asset, vs refuse + reveal the existing mediaseq, vs hint-and-create. Deferred.
- **Cross-project asset sharing.** Today projects are `.jvp` files and inter-project copy isn't a workflow. Deferred until it is.

---

## Open questions

1. **Asset dedup key.** Options: content hash (xxhash of first 64KB + size — survives moves, fast, breaks on re-encode), BWF UID (stable for production audio, absent elsewhere), path (fragile), or hybrid (BWF UID → content hash → path-tiebreak). FCPX uses a synthesized UID at `<asset>` that third-party tools can write. Need to pick before assets are first minted.
2. **Same-file re-import UX.** When the user drags in a file already wrapped by an existing mediaseq: (a) silently create a second mediaseq sharing the asset; (b) refuse + reveal existing; (c) hint-and-create. Pick one.
3. **`patch` — fine, or rename to `source_route`?** Question may dissolve into the Roles spec when that lands.
4. **`asset_refs.parent_sequence_id` always points at a media sequence — column-rename to make this explicit, or is the kind check enough?**
5. **Source viewer terminology.** What does the source viewer "load"? A sequence (any kind), full stop. UI label probably says "Source: <sequence-name>."
6. **"Browser" word.** Keep "Project Browser" (current)? "Bin Browser"? "Sequence Browser"? Users say "the browser." FCPX precedent: "Browser" is the panel name, "Event" is the container — JVE could mirror.
7. **Smart Collections / saved-view surface.** Markers carry tag/category/rating fields TBD; what's the affordance to save a marker filter as a reusable browser view? FCPX Smart Collections are the reference design.
8. **Marker schema details.** Beyond `(id, parent_fk, start_frame, end_frame?, name)`, what tag/color/rating columns are first-class vs deferred to a free-form metadata blob?

---

## Unresolved (concise, per Joe's plan-format preference)

- asset dedup key: hash vs BWF UID vs hybrid
- same-file re-import UX
- patch name (may dissolve into Roles)
- parent_sequence_id explicitness for asset_refs
- "browser" word
- marker schema details (tag/color/rating columns)
- Smart Collections affordance shape

---

## Appendix: how other NLEs handle this

Research backing the recommendations above. Read once if you're touching anything master/affiliate / subclip / favorites; skip otherwise.

### Master / subclip / duplicate behavior across NLEs

| NLE | Subclip → master link | Duplicate → master link |
|---|---|---|
| Avid Media Composer | Subclip points at master's media, can be relinked. Explicit **"clone"** of a master propagates changes; explicit **"duplicate"** does not. | Independent (unless cloned). |
| Premiere Pro | **Strong.** Subclip shares the *Master Clip ref*; effects applied via the Master Clip tab propagate to all subclips and all sequence uses. | **None.** Duplicate gets its own Master Clip ref; edits don't propagate either direction. |
| FCP7 | **Strong.** Master / affiliate relationship; metadata propagates master → affiliate. **"Make Independent"** breaks the link (affiliate becomes its own master; one-way). | Same as affiliate (depends on how the duplicate was created). |
| FCPX | **No subclip feature.** Replaced by Favorites (named ranges under one master), Keywords (range-based labels), and Compound Clips (wrap selection as a new sequence). | Duplicate is independent — but the concept rarely comes up since Favorites cover the use case. |
| DaVinci Resolve | Subclips are **independent** clips in the Media Pool referencing a portion. No documented propagation. | Independent. |

**Pattern across 3 of 4 traditional NLEs:** "Subclip" carries propagation from master; "Duplicate" doesn't. The user picks per operation.

**FCPX outlier (and the model JVE follows for the subclip-elimination move):** No subclip entity. Favorites are named ranges *within* the master, surfaced as draggable browser entries in filter views. Apple's stated rationale (per Larry Jordan, PremiumBeat, Frame.io workflow guides): "organize under the master clip, rather than as separate items in bins." Workflow community recommends Favorites *over* subclips when available.

### FCPX Favorites — what it actually is

- Mark a range on a clip (`I`/`O`), hit `F` → named range stored on the source clip. Green line in browser.
- **Multiple favorites per clip**, non-overlapping, renamable.
- Browser "Favorites only" filter view surfaces them as separately-draggable entries — but they remain children of the master clip in the model.
- Library-level Smart Collections can filter favorites/keywords across all clips in an event or the whole library into one virtual browse view.
- Dragging a Favorite into a timeline produces an `<asset-clip>` with the favorite's range as the source window — but the resulting timeline clip is independent and can be trimmed past the favorite range freely. The favorite never clamps downstream uses.

### JVE's position vs each NLE

- **vs Avid / Premiere / FCP7:** JVE eliminates subclip-as-entity. The propagation those NLEs preserve via a *second* affiliation axis (clip-to-clip) is provided in JVE via the *single* clip → source affiliation axis. "Edit the master, see it propagate to all uses" still works — every clip pointing at the source sees the change. The thing JVE can't do is "two browser entries that share a master via affiliation" — but the use cases (named windows, multiple graded versions, multi-cam angles) are covered by ranged markers (favorites mechanism) + duplicate-as-deep-copy + per-instance grade override.
- **vs FCPX:** essentially parity on the organizational side (named ranges under a master via markers; favorites-style filtered browse view). JVE adds:
  1. **Per-sequence focus range** as a view hint + drag default (FCPX has nothing equivalent — favorites are the drag-source, no separate sequence-level default-view concept).
  2. **Master baseline grade with clip override** (`sequence_grade` ∘ `clip_grade`). FCPX has clip-level color and Adjustment Layers but no master/instance composition.
  
  JVE notably does NOT (in 021) match:
  - **Audition** as a first-class container (deferred).
  - **Full Roles system** for lane organization, export stems, iXML auto-tagging (deferred).
- **vs DaVinci Resolve:** Resolve's independent-subclip-on-creation matches JVE's "duplicate is a deep copy." JVE additionally retains a strong master/affiliate edge via clips, which Resolve lacks. Match Frame behavior in JVE is therefore richer.

### Subclip-elimination move: who did what

FCPX (2011) was the first major NLE to eliminate subclips as a separate entity, replacing them with Favorites + Keywords + Compound Clips. JVE follows that precedent for subclip elimination specifically.

**JVE goes further** in one architectural respect FCPX did not: FCPX still splits "things that contain edits" across multiple element types (`<project>`, `<media>` wrapping Compound/Multicam/Sync, plus `<asset-clip>` directly in spines). JVE unifies all of these under one `sequence` entity with a `kind` discriminator. The subclip-elimination move is shared precedent; the container-unification move is JVE-original.

### Single-axis vs two-axis affiliation — the load-bearing JVE claim

Other NLEs have *two* affiliation axes:
1. **Clip-to-clip:** master clip ↔ subclips / cloned clips / affiliated clips. Explicit. Manipulated by File menu commands.
2. **Master-to-timeline-item:** implicit; every timeline placement is also an affiliate of its source. Not first-class in their model.

JVE collapses these into *one* axis at the clip → source edge. Because clips carry their own source window AND are first-class in the model:
- "Subclip with active link" → a ranged marker on the source + a clip seeded to that range.
- "Make Independent" → not needed; clips are already independent of each other.
- "Duplicate clip" → deep-copy a Browser Clip; sovereign thereafter.
- "Master Clip effects" → set on the source sequence; propagated by every clip that points at it (the clip's grade is a delta on top).

Architectural cost: zero (one axis is simpler than two). Cost to Avid power users: re-learn the workflow (use clips + named markers instead of subclips). FCPX shipped the same architectural move in 2011 and the community has accepted it; JVE follows that precedent.

### Sources

- [Master-Affiliate Clip Relationships — FCP6 manual](https://final-cut-pro-6.helpnox.com/en-us/final-cut-pro-user-manual/volume-ii-editing/part-i-organizing-footage-and-preparing-to-edit/creating-subclips/learning-about-subclips/master-affiliate-clip-relationships/)
- [Creating Independent Clips — FCP6 manual](https://final-cut-pro-6.helpnox.com/en-us/final-cut-pro-user-manual/volume-iv-media-management-and-output/part-i-media-and-project-management/working-with-master-and-affiliate-clips/using-master-and-affiliate-clips/creating-independent-clips/)
- [Subclip vs Duplicate — Adobe Community](https://community.adobe.com/t5/premiere-pro-discussions/what-s-the-difference-between-a-subclip-and-a-duplicate/m-p/11512673)
- [Apply Source Clip effects in Premiere Pro — Adobe helpx](https://helpx.adobe.com/in/premiere-pro/using/master-clip-effects.html)
- [Creating Subclips — Avid Media Central](https://help.avid.com/MediaCentral/MediaCentralCloudUX/MCCUX_Help/NUX_UG_Media.06.27.html)
- [DaVinci Resolve Subclips Explained — JayAreTV](https://jayaretv.com/edit/davinci-resolve-subclips-explained/)
- [Subclips Using the Favorite Option — PremiumBeat](https://www.premiumbeat.com/blog/video-tutorial-how-to-create-subclips-using-the-favorite-option-in-final-cut-pro-x/)
- [Selecting the Best Clips in FCPX — Larry Jordan](https://larryjordan.com/articles/fcp-x-selecting-the-best-clips/)
- [Rating and Filtering in FCPX — Mark Spencer / ProVideo Coalition](https://www.provideocoalition.com/rating-and-filtering-in-final-cut-pro-x/)
- [Select ranges in Final Cut Pro — Apple Support](https://support.apple.com/guide/final-cut-pro/select-ranges-ver28cca92/mac)
- [Smart Collections — Apple Support](https://support.apple.com/guide/final-cut-pro/create-smart-collections-ver2833eb5b/mac)
- [Intro to Roles — Apple Support](https://support.apple.com/guide/final-cut-pro/intro-to-roles-verb71cbcbe/mac)
- [Intro to Auditions — Apple Support](https://support.apple.com/guide/final-cut-pro/intro-to-auditions-verbbd3587d/mac)
- [Demystifying FCPXML — FCPCafe](https://fcp.cafe/developer-case-studies/fcpxml/)
