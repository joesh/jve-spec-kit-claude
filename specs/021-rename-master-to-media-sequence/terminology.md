# JVE Entity Terminology — Draft v1

**Status:** Draft for Joe to redline. Supersedes the rename proposal in `spec.md` once nailed down.
**Purpose:** Single canonical source of truth for entity names, relationships, and the JVE↔Resolve mapping. NO code changes until this is signed off.

**v0 → v1 deltas:** dropped `placement` for `sequence_ref`; dropped `media`/`media_ref` for `asset`/`asset_ref`; dropped `owner_seq` for `parent_seq`; dropped hard-clamp `limits` for view-hint `focus_range`; added Markers as the favorites/subclip-windowing mechanism; flagged Auditions, full Roles system, and grade composition as deferred.

**v1 mid-draft addition:** the **asset visibility invariant** — assets are JVE-internal; the lowest user-addressable handle for captured material is `mediaseq.id` (a contains-assets `sequence`). Resolve DbId adopts to `mediaseq.id`, never to `asset.id`. Closes prior open Q on asset↔sequence identity overlap.

---

## Architectural premise (the one thing JVE does differently)

Every other NLE has two distinct top-level concepts:
1. a **browser clip** (a file reference with in/out, lives in the browser / media pool / project panel)
2. a **sequence clip** (a clip reference on a track, references a browser clip)

**JVE collapses this at the storage layer to one model entity: the `sequence`.** One table, two `kind`s. The kinds are mutually exclusive — there is never a sequence that contains both asset_refs and sequence_refs.

But the user-facing distinction stays. The two kinds are labeled differently in the UI:
- A **contains-assets** sequence is labeled **"Clip"** to the user.
- A **contains-sequences** sequence is labeled **"Sequence"** to the user.

The unification is structural, not perceptual. The user sees Clips and Sequences in the browser as distinct things with distinct affordances; the model sees one entity with a `kind` discriminator. The architectural payoff is that operations defined on a sequence (open, peek inside, nest into another sequence, reuse, version, undo) work uniformly across both kinds — even though the user calls one a Clip and the other a Sequence. Recursion in the model is unrestricted: any sequence may be a sequence_ref's source sequence, regardless of kind.

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
  1. *Master/affiliate relationship* — a subclip points at a master and inherits/overrides attributes. **JVE pattern:** every sequence_ref points at a source sequence; many sequence_refs share one master; attributes inherit master → sequence_ref with per-sequence_ref overrides. F command navigates sequence_ref → master. See "Master / Affiliate" below.
  2. *Windowed views that name and surface specific ranges of the source.* In Avid/Premiere a subclip's IN/OUT is set at creation and immutable — your only escape is "Remove Subclip Limits" (one-way). **JVE pattern:** ranged **markers** on the source sequence carry name + range + tag. The browser surfaces them as draggable items via a Favorites-style filter view; dragging a marker into an edit produces a sequence_ref whose `source_in`/`source_out` defaults to the marker's range. Markers are first-class — N per sequence, editable both endpoints anytime, deletable. The subclip's "I want to nudge IN by one frame" workflow that required recreating the subclip from scratch goes away. See "Markers" below.
- **"Clip Attributes" dialog is just UI that manipulates the tracks in the Browser Clip.** The Browser Clip's tracks are the source of truth, and the dialog is a lossy projection that drives track edits. The user reaches the tracks by opening the Browser Clip in the Timeline panel; asset_refs there are directly editable. The Inspector exposes the `asset` object's properties (file interpretation, TC override, channel layout) and the `asset_ref` object's properties. The dialog is just a faster path for the common cases.

What the user is prevented from doing on an open Browser Clip:
- Insert / overwrite / ripple edits — those produce sequence_refs, which live only in contains-sequences sequences. A Browser Clip's tracks hold asset_refs, not sequence_refs.
- Nest other Browser Clips or Sequences inside it — same reason.
- (Color grading is NOT in this list — a baseline grade on a Browser Clip is supported and inherited by sequence_refs; see Master / Affiliate below.)

This is the architectural payoff in user terms: **the intermediate artifacts other NLEs make you build by hand to get sync done — multicam source sequences, merged clips, subclips — don't exist in JVE.** The Browser Clip itself absorbs all of that. The Timeline panel is the edit surface for both Browser Clips and Sequences; the toolset just narrows on a Browser Clip to the operations that make sense there.

### Master / Affiliate

Mostly the FCP7/Avid pattern, but emerging from JVE's data shape rather than requiring separate machinery:

- **Master** = the source sequence a sequence_ref points at (`sequence_ref.sequence_id`). When the source is a Browser Clip, the user calls it "the master." (When the source is another contains-sequences sequence — i.e. a nested edit — the same edge exists but isn't usually called a master/affiliate relationship; we still navigate it with the F command.)
- **Affiliate** = a sequence_ref. Many affiliates can share one master.
- **F command (Match Frame / Find in Browser)** navigates from a selected sequence_ref to its master, scrolling the Browser to it.
- **Attribute inheritance:** baseline values live on the master sequence; per-sequence_ref overrides live on the sequence_ref. For most attributes (label color, comments, default routing) the override is simple replace — sequence_ref value wins when set, master value inherits when NULL.
  - **Color grade is the exception:** ∘ is genuinely compositional, not just replace. The `sequence_ref_grade` stores a **delta** relative to the master's `sequence_grade` baseline:
    - CDL slope: `master.slope × override.slope` (multiplicative)
    - CDL offset: `master.offset + override.offset` (additive)
    - CDL power: `master.power × override.power` (multiplicative)
    - LUT: master LUT applied first, then override LUT chained after
    - The render pipeline applies the composed result. This is why grade override is stored as a delta, not as an absolute — so it composes cleanly when the master grade changes underneath.
  - Composition operator details (per-channel rules, identity-delta encoding, render order) deferred — see "Not in 021" below.
- **Naming:** "affiliate" is a *relationship* word, not an entity word. The entity is `sequence_ref`. The user UI says "Clip." The relationship between a sequence_ref and its master is "affiliate-of." Three layers, no conflict.

### Focus range

A sequence may optionally declare a `focus_range = [start, end]`: a per-sequence **view hint and drag default**, not a content clamp.

**Model:**
- `sequences.focus_range_start_frame` INTEGER NULL
- `sequences.focus_range_end_frame` INTEGER NULL
- Both NULL or both set, with `focus_range_start_frame < focus_range_end_frame`. (Rule 2.13 — no soft defaults.)

**Semantics (view hint, not clamp):**
- **Zoom-to-Fit** zooms the viewer/timeline to focus_range when set, otherwise to full content. The user can zoom out past focus_range freely.
- **Drag default**: dragging this sequence from the browser into an edit produces a sequence_ref whose `source_in`/`source_out` default to focus_range. The user can then trim past it freely — focus_range never clamps the resulting sequence_ref.
- The resolver / `source_window` does NOT consult focus_range. There is no read-time hide.

**Why it's not "limits":** limits implies hard-clamp content scope. Focus range is purely a viewport preference + drag default. Trim operations don't fail against it; the resolver doesn't intersect with it. Calling it "limits" was a category error in v0.

**UI:** distinct ruler affordance (ghosted region outside focus_range when set), draggable endpoints, clearable via a "Clear focus range" action. Not a checkbox toggle — null both columns to clear.

WHEN A MARKER CLIP (term?) is viewed in the source monitor the focus range is set to the marker clip bounds. Alternatively maybe we don’t have a focus_range and instead have a user-invisible flag that says the marker clip’s bounds should be used as a focus range. Still needs thought.

### Markers

Markers are the favorites/subclip-windowing mechanism, generalized.

**Two scopes, two tables:**
- **`sequence_markers`** — markers on a source sequence. The browser-side "favorites" mechanism. N per sequence.
- **`sequence_ref_markers`** — markers on a sequence_ref (timeline instance). Editor's notes on a specific use. (This is the table 021 v0 called `placement_markers` and the legacy code calls `clip_markers`.) NOT LOVING THE TERM sequence_ref_markers. Discuss these two tables.

**Shape (both tables):**
- `id` (uuid)
- parent fk (`sequence_id` or `sequence_ref_id`)
- `start_frame` INTEGER NOT NULL
- `end_frame` INTEGER NULL — NULL = point marker, non-null = ranged marker
- `name` TEXT
- `comments` TEXT
- `keywords` / `tags`
- `color` / `rating` — TBD; at minimum a category field so saved-views can filter

**The favorites story (sequence_markers):**
- Mark a range on a Browser Clip (set IN/OUT, hit `F` or the keyboard shortcut TBD) → adds a marker to the sequence with that range and an optional name.
- The browser supports a Favorites-style filter view that surfaces each ranged marker as a **separately draggable browser entry**, even though they all live on one underlying source sequence. (FCPX precedent: Favorites + Smart Collections.)
- Dragging a marker entry into an edit produces a `sequence_ref` whose `source_in`/`source_out` default to the marker's range. The sequence_ref is then independent — the user can trim past the original marker range freely. The source-side marker is unchanged.
- N markers per source → N draggable windows without manufacturing subclip artifacts.

**Composition with focus_range:**
- focus_range is the per-sequence default drag window.
- A marker drag overrides that default with the marker's range.
- Both are drag-defaults, neither clamps the resulting sequence_ref. NOT SURE I UNDERSTAND WHAT YOURE SAYING 

**Why not collapse focus_range and markers into one table:**
- focus_range is at most one per sequence; markers are N per sequence. I DONT THINK THIS IS TRUE. It’s really about mimicking subclip behavior. Discuss.
- focus_range drives Zoom-to-Fit (viewport behavior); markers drive browser filter views (organizational).
- They compose cleanly (focus_range is the default; a marker drag wins). Separate columns / table tracks the two different roles.

**Subclip parity:** the Avid "subclip with limits" use case is covered by a single ranged marker + the drag-default semantics. The "edit my subclip's IN by one frame" workflow becomes "drag the marker endpoint." No "Remove Subclip Limits" command needed because nothing was clamped to begin with.\
WE NEED TO GO THROUGH AN EXAMPLE WHERE WE DIVIDE A CLIP INTO MULTIPLE “jve subclips” ie ranged markers. What do we see when opening one of these marker clips in the source monitor?

---

## "Clip" is a user-facing word, NOT a model entity

The hardest naming problem JVE faces: every other NLE uses "clip" for two distinct entities (the browser item AND the timeline placement), and users freely call both "the clip." JVE's storage layer collapses browser-side material into a `contains-assets` sequence, but the user still sees that thing as a Clip — same as on the timeline.

**Resolution:**
- **The word "clip" has NO model meaning.** It does not name an entity, a Lua module, or a schema concept.
- **"Clip" is a UI/menu/user-doc label only**, and it specifically labels:
  - a **contains-assets sequence** (when shown in the browser), and
  - a **sequence_ref** (when shown on the timeline).
  Both are "a piece of editable material" from the user's POV, and the user freely says "this clip" pointing at either. The label is shared because the user's mental model is shared.
- **A contains-sequences sequence is NEVER labeled "Clip"** — it is labeled **"Sequence"** in the UI. Browser items split into Clips and Sequences; the user sees this distinction.
- **The model has exactly two top-level entities at this layer:** `sequence` and `sequence_ref`. Neither is named "clip." The label "Clip" lives only in UI strings and the dispatcher logic that maps user clicks/menu selections back to a sequence id or a sequence_ref id.

This dissolves the overload at the code layer: "clip" stops meaning three things in code (browser item / timeline entry / common-noun). The user-facing word still legitimately covers two model entities (contains-assets sequence | sequence_ref), but that's a UI label binding, not a code one — and it matches how every NLE user already thinks.

---

## "Sequence" — model word vs UI label

The rename surfaces a second overload that needs declaring explicitly so future readers don't get caught:

- **`sequence` (model):** any sequence object, either `kind`. The universal container.
- **"Sequence" (UI label):** specifically a `contains-sequences` sequence. A contains-assets sequence is labeled **"Clip"** in the UI, never "Sequence."

This is consistent with FCP/Premiere/Avid: users say "this sequence" meaning the edit, not the source material in the browser. So the narrow user meaning is the conventional one, even though the model word is broader.

**Rules:**
- Code, schema, comments, specs: `sequence` always means the universal model entity (either kind). When a code path is restricted to one kind, the code says `kind == 'contains-sequences'` or asserts it, but the noun stays `sequence`.
- UI strings: "Sequence" labels only `contains-sequences` sequences. "Clip" labels `contains-assets` sequences and sequence_refs.
- When discussing the model in design docs (including this one), prefer `contains-assets sequence` and `contains-sequences sequence` for precision over the bare word `sequence`, unless the kind genuinely doesn't matter.

---

## The asset visibility invariant

**Assets are JVE-internal. The user never holds an asset id.** The lowest user-addressable handle for "this captured material" is a `mediaseq.id` — i.e. the id of the contains-assets `sequence` that wraps the file.

**Why this is load-bearing:** the mediaseq isn't a transparent wrapper around an asset — it carries baseline grade, sync mode, focus_range, markers, multi-track structure, channel layout. That is what makes it a "Clip" in JVE's sense. If F-command or Match Frame or any other path handed the user a bare asset id, the user could plumb it directly into a contains-sequences sequence, bypassing every one of those properties. The visibility rule prevents that back-door.

**Rules:**
- F-command, Match Frame, Reveal in Browser, copy/paste, scripting APIs, and every user-facing handle return a **mediaseq id** — never an asset id.
- The UI never says the word "asset" in menus, inspectors, or status. UI vocabulary: "Clip," "File," "Source."
- Assets exist only as a code-internal file binding. The decoder / TMB / renderer layer walks `sequence_ref → source_seq (mediaseq) → asset_ref → asset → file_path`. That resolution chain is private; no step in it is callable from a user action.
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
| `clip` | Schema, table names, column names, model files, function names, variable names, type names, parameter names. Comments may reference the UI label only when discussing UX. | UI label only. Has no model meaning. Three distinct things would otherwise hide behind it. |
| `master_clip`, `master`, `masterclip` | Everywhere | Legacy. Refers to a concept that no longer exists. |
| `timeline` (as an entity) | Schema, model, function names referring to a sequence | Panel name only. Calling a sequence `timeline` re-anchors us to Resolve's outlier vocabulary. |
| `subclip`, `merged_clip`, `multicam_clip` | Everywhere | These artifacts don't exist in JVE — the Clip itself absorbs their function. |
| `placement` | Everywhere | Invented JVE jargon (no NLE precedent — Premiere "placement" means clip position, not an entity). Use `sequence_ref`. |
| `media` (as an entity / table / module) | Schema, model, code | Replaced by `asset` (file on disk) and `asset_ref` (windowed file reference). `media` survives only as informal English in comments/UI strings ("the media file"). |
| `media_ref`, `mref` | Everywhere | Replaced by `asset_ref` / `aref`. |
| `limits`, `limits_enabled`, `start_limit_frame`, `end_limit_frame` | Everywhere | Replaced by `focus_range_start_frame` / `focus_range_end_frame`. Different semantics (view hint, not clamp). |
| `pool`, `pool_item`, `pool_clip` | JVE-side code (model, commands, UI) | OK on the Resolve parser side, where we're translating Resolve XML. Banned elsewhere. |

Allowed: `timeline_panel`, `timeline_view` (UI), and `pool_clip_elem` etc. inside the DRP parser as Resolve-side locals.

### 2. Bare nouns and what they mean

| Code word | Meaning | Examples |
|---|---|---|
| `sequence`, `seq` | A sequence object, either kind. | `local seq = Sequence.load(id)` |
| `sequence_ref`, `sref` | A sequence_ref object. | `local sref = SequenceRef.load(id)` |
| `asset` | An asset (file on disk). | `local asset = Asset.load(id)` |
| `asset_ref`, `aref` | An asset_ref. | `for _, aref in ipairs(track.asset_refs) do` |
| `track` | A track. | `local track = seq.tracks[i]` |
| `marker` | A marker on a sequence or sequence_ref. Distinguish by parent if ambiguous. | `for _, m in ipairs(seq.markers) do` |

`ref` alone is banned (too generic). Always `asset_ref`/`aref` or `sequence_ref`/`sref`.

### 3. Don't encode kind in variable names — encode it in operation names

Tempting: `local asset_seq = ...` for "a contains-assets sequence." Don't. It reads as "a sequence of assets," it overloads `asset`, and it forces every other call site to invent a parallel `edit_seq`. There is no good kind-suffixed name for a sequence.

Instead: **the operation tells you the kind, and an assert at the top makes it explicit. Operations are methods on the object, not standalone functions that take the object as a parameter.**

```lua
-- GOOD: method on Sequence; assert makes kind certain.
function Sequence:add_asset_ref(aref)
    assert(self.kind == "contains-assets",
        string.format("add_asset_ref: sequence %s has kind=%s, must be contains-assets",
            self.id, self.kind))
    ...
end

function Sequence:add_sequence_ref(sref)
    assert(self.kind == "contains-sequences",
        string.format("add_sequence_ref: sequence %s has kind=%s, must be contains-sequences",
            self.id, self.kind))
    ...
end

-- BAD: standalone function takes the object as a parameter, AND uses a kind-bearing
-- variable name. Both wrong: should be a method on Sequence with `self`.
function add_asset_ref(asset_seq, aref) ... end
```

The reader of a method body sees `self` and knows from the method's name (and assert) what kind it must be (or that it doesn't matter). The assert is the contract.

### 4. Relational variable names — source vs parent

A `sequence_ref` has two sequence relationships:
- `sequence_ref.sequence_id` → the **source** sequence (what it points at, any kind).
- `sequence_ref.parent_sequence_id` → the **parent** sequence (what physically contains it, always `contains-sequences`).

Variable names that follow:

| Code | Meaning |
|---|---|
| `source_seq` | The sequence a sequence_ref points at (any kind). |
| `parent_seq` | The sequence that contains a sequence_ref (always contains-sequences). |
| `seq` | When only one sequence is in scope, or when role isn't relevant. |

`parent` over `owner` because "owner" reads as master/affiliate relationship. Parent is unambiguously hierarchical containment.

An `asset_ref` has only one sequence relationship (`parent_sequence_id` → contains-assets), so `parent_seq` is unambiguous in that context.

### 5. Function naming — prefer methods on the object

Operations are methods on the object they act on, called with colon syntax (`obj:method(args)`), not standalone functions that take the object as a parameter. Module-level functions are reserved for constructors (`Sequence.create`, `Sequence.load`) and for peer operations where no single object dominates. The kind constraint lives in the assert, not the function name.

| Good | Bad | Why |
|---|---|---|
| `seq:add_asset_ref(aref)` | `add_asset_ref(seq, aref)` or `add_asset_ref_to_clip(seq, aref)` | Method on the dominant object; "clip" banned. |
| `seq:add_sequence_ref(sref)` | `add_sequence_ref(seq, sref)` | Method on the dominant object. |
| `Sequence.create(kind, ...)` | `Sequence.create_clip(...)` / `Sequence.create_edit(...)` | Constructor — no instance yet, so module-level is correct. Single constructor; kind is a parameter. |
| `Sequence.load(id)` | `Sequence.load_any_kind(id)` | Loading doesn't care about kind. Class method. |
| `sref:source_window()` | `effective_source.for_clip(p)`, `source_window.for_sequence_ref(sref)` | Method on the dominant object. Internally composes the source sequence's window with the sequence_ref's own window. |
| `sref:apply_grade(grade)` | `clip_grade.apply(clip, grade)` | Method form; both renames. |
| `Asset.load_or_create(file_path)` | `load_or_create_asset(file_path)` | Class method — no instance yet (this IS the creation path). |

### 6. Object property names

`sequence`'s `kind` literals: `'contains-assets'` and `'contains-sequences'`. Verbose in code (`seq.kind == 'contains-assets'`) but unambiguous; this is the right trade.

A sequence_ref's `sequence_id` property is the source-sequence id. It is **not** named `source_sequence_id` because:
- A sequence_ref only ever points at one other sequence, and the relational role from the sequence_ref's POV is obvious.
- Compare with `parent_sequence_id` (the back-reference to the containing sequence) — `sequence_id` is the forward reference; the asymmetry of names tracks the asymmetry of direction.

Reference-pair conventions to standardize:

| Forward reference (what this object points at) | Back reference (what physically contains this object) |
|---|---|
| `sequence_refs.sequence_id` (source) | `sequence_refs.parent_sequence_id` |
| `asset_refs.asset_id` | `asset_refs.parent_sequence_id` |
| `tracks.???` (n/a — tracks are contained, not pointing) | `tracks.parent_sequence_id` |

### 7. Comments and docstrings

- When a comment names a concept that has both a model name and a UI label, use the **model name** (`sequence`, `sequence_ref`) unless the comment is specifically about UX.
- A comment about user-facing behavior may say "Clip" or "Sequence" capitalized to signal it's a UI label, e.g. *"opened in the Timeline panel, this sequence is labeled `Clip` in the title bar."*
- Avoid "clip" lowercase in any code comment — it's too easily mistaken for a model term.
- The word "media" is allowed only as informal English referring to file content ("the media file is unreadable"); never as a code identifier.
- Don't explain that `sequence` has two kinds in every file; assume the reader has read this doc once. A targeted assert plus one-line precondition comment is enough.

### 8. Tests

Test names describe domain behavior (per CLAUDE.md), in model vocabulary:

```
test_sequence_ref_source_window_clamps_to_source_duration.lua  -- good
test_clip_source_window_clamps_to_source_duration.lua          -- bad, "clip" banned
test_browser_clip_opens_in_timeline.lua                        -- bad, mixes UI label into code

test_open_contains_media_sequence_in_timeline_panel.lua        -- good (explicit about kind + panel)
test_timeline_blocks_insert_on_contains_media_sequence.lua    -- good (operation + kind)
test_marker_drag_seeds_sequence_ref_source_window.lua          -- good (favorites-via-markers behavior)
```

UI strings that the test asserts on may include the words "Clip" and "Sequence" (those are the user-visible labels). The test file name and code identifiers stay in model vocabulary.

### 9. The DRP importer (the one place Resolve vocabulary is allowed)

Inside `importers/drp_importer.lua` and its helpers, Resolve vocabulary is allowed on **parsed-XML locals only**:

```lua
local pool_clip_elem = find_direct_child(...)   -- ok: Resolve-side
local timeline_item_elem = ...                  -- ok: Resolve-side
local pool_clip = parse_pool_clip(pool_clip_elem)
-- Boundary: from here on, JVE vocabulary.
local seq = Sequence.create({kind = "contains-assets", ...})
local asset = Asset.create(...)
```

The boundary is the parse-to-model handoff. Anything assigned into a JVE object uses JVE vocabulary; anything still holding a parsed XML element or a Resolve-side intermediate uses Resolve vocabulary. The two never appear in the same identifier (no `pool_seq`, no `clip_sequence_ref`).

### 10. The DRT writer / bridge helper (the other Resolve boundary)

Symmetric to the importer: JVE vocabulary on the input side, Resolve vocabulary on the output side. The `drt_writer` reads `sequence_ref`s and `asset_ref`s and emits `<Sm2TiVideoClip>`s and `<Sm2MpVideoClip>`s. Locals named after the emitted Resolve element are allowed (`timeline_item_node`, `pool_clip_node`); locals naming a JVE object stay in JVE vocabulary.

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
- **UI strings, menus, panel names:** `Timeline` refers only to the editing-surface *panel* that displays a contains-sequences sequence.
- **Never** call a contains-assets sequence a "timeline" in any layer.
- **Never** call a sequence a "timeline" in code.

---

## The structural axis: what does this sequence CONTAIN?

A sequence's `kind` is the answer to a single question: *what do its tracks hold?*

| `kind` value (proposed) | Tracks hold | User mental model |
|---|---|---|
| `contains-assets` | asset_refs (direct file windows) | "A piece of captured material — one or more files, possibly multi-rate." |
| `contains-sequences` | sequence_refs (each pointing at a sequence) | "An edit — its tracks hold references to other sequences." |

Naming axes:
- **structural** (what's inside): `contains-assets` / `contains-sequences`
- **relational** (role from a sequence_ref's POV): `source sequence` (what the sequence_ref references) / `parent sequence` (what physically contains the sequence_ref)

The two axes commute. Both halves read cleanly:
> *"This sequence_ref's source sequence is a contains-assets sequence."*
> *"This sequence_ref's source sequence is a contains-sequences sequence."*

Neither sentence uses "master" or "clip."

**OPEN: Joe to confirm `contains-assets` / `contains-sequences` as the literal `kind` values, vs shorter aliases like `leaf` / `branch`. The long form is unambiguous but verbose in code.**

---

## The entities

### `asset`
A file on disk. One asset per file (deduped by stable file identity — dedup key TBD). Carries probed metadata (codec, fps, sample rate, duration, TC origin).
**Identity:** JVE-internal uuid (or hash-derived; see Open Questions for dedup key). **Never adopts the Resolve DbId** — the visibility invariant routes that to `mediaseq.id` instead. See "Asset visibility invariant" above.
**Has no concept of in/out.** That belongs to `asset_ref`.
**Has no user handle.** Code-internal only; reached via `asset_ref.asset_id`.

### `asset_ref`
A typed window into an `asset`: `source_in_frame`, `source_out_frame`, plus `audio_sample_rate` (018), plus an in/out position on its parent's track (`sequence_start_frame`, `duration_frames`).
**Lives inside exactly one `contains-assets` sequence.** Never inside a `contains-sequences` sequence.
**Why both source-window AND parent-position?** Because the contains-assets sequence is itself editable material — it has a timebase, the asset_refs are arranged on its tracks, and what the user sees when they peek inside is *those asset_refs in that arrangement*.

### `sequence`
The universal container. Has a `kind`, video timebase (fps_num/den), audio sample rate (018), dimensions, marks, focus_range (optional), undo stack, view state.
**Identity:** UUID. When imported from Resolve:
- a contains-assets sequence (mediaseq) adopts the pool item's `Sm2Mp*.DbId`. **This is the user-addressable handle for the captured material** — see "Asset visibility invariant."
- a contains-sequences sequence adopts `Sm2Sequence.DbId`.

The wrapped asset gets a fresh JVE-internal id; the Resolve DbId never lands on the asset.

### `track`
A lane within a sequence. Has a type (video/audio), an index, sync mode (015), patch state (015), mix state.
A track in a `contains-assets` sequence holds asset_refs.
A track in a `contains-sequences` sequence holds sequence_refs.
**Never mixed within one sequence.**

### `sequence_ref`
A sequence_ref on a track inside a `contains-sequences` sequence. References another sequence via `sequence_id` (the *source sequence*; may be either kind — uniform).
Carries: source window (`source_in_frame`/`source_out_frame` in source sequence's timebase), parent-side position (`sequence_start_frame`/`duration_frames` in parent sequence's timebase), per-instance video/audio track selectors (013), enabled, volume.
**Identity:** UUID. When imported from Resolve, adopted from `Sm2Ti*.DbId` (spec 023 FR-011b).

**Naming rationale:** "sequence_ref" describes exactly what it is — a reference to a sequence, placed on a parent sequence's track. It is *not* "a clip" — the model has no clip entity. "Clip" is a UI word users say when pointing at a sequence_ref (or at a browser sequence); it doesn't appear in the schema or code. Matches FCPX's `<ref-clip>` shape in spirit without using the banned word "clip."

### `sequence_markers` and `sequence_ref_markers`
Markers come in two scopes:
- Markers on a `sequence`. The favorites/named-windows mechanism.
- Markers on a `sequence_ref`. Per-instance editor notes.

Every marker carries `start_frame`, optional `end_frame` (NULL = point marker), `name`, and category/tag properties (TBD). Multiple markers per parent.

### `patch`
Source-routing rule (015). Maps source track → parent track for insert/overwrite operations on a contains-sequences sequence.

### `sequence_ref_grade` (023, renamed from `clip_grade`)
Per-instance color grade (CDL + LUT). Keyed by `sequence_ref.id`. Composed with the source sequence's baseline `sequence_grade` at render time — composition operator deferred (see Not in 021).

### `resolve_bridge_link` (023)
Per-instance bridge identity + fingerprints (edit + grade). Keyed by `sequence_ref.id`.

---

## The relationships (ER diagram)

```
                   ┌─────────┐
                   │  asset  │  (file on disk)
                   └────┬────┘
                        │ asset_id
                        ▼
                  ┌───────────┐
       parent ◀───│ asset_ref │   on a contains-assets sequence's track
                  └───────────┘
                        ▲
                        │ (a track of kind 'contains-assets' holds asset_refs)
                        │
                  ┌───────────┐
                  │   track   │───┐
                  └───────────┘   │ parent_sequence_id
                        ▲         ▼
                        │   ┌──────────┐
                        │   │ sequence │  kind = contains-assets | contains-sequences
                        │   └────┬─────┘
                        │        │ sequence_id (any kind)
                        │        ▼
                        │   ┌──────────────┐
                        └───│ sequence_ref │   on a contains-sequences sequence's track
                  (track of │              │
                  kind      └────┬─────────┘
                  'contains-      │ sequence_ref.id
                  sequences')     ├──────▶ sequence_ref_grade (023)
                                  └──────▶ resolve_bridge_link (023)
```

**Cardinality rules:**
- `asset : asset_ref` = 1 : N
- `sequence(contains-assets) : asset_ref` = 1 : N (via track)
- `sequence(contains-sequences) : sequence_ref` = 1 : N (via track)
- `sequence_ref : sequence` = N : 1 (sequence_ref's `sequence_id`; the source sequence)
- A given sequence can be the source for many sequence_refs (reuse / nesting).

**Invariants:**
- A `contains-assets` sequence's tracks hold ONLY `asset_ref`s.
- A `contains-sequences` sequence's tracks hold ONLY `sequence_ref`s.
- An `asset_ref`'s `parent_sequence_id` always points at a `contains-assets` sequence.
- A `sequence_ref`'s `parent_sequence_id` always points at a `contains-sequences` sequence.
- A `sequence_ref`'s `sequence_id` may point at EITHER kind. This is the nesting mechanism.

---

## The JVE ↔ Resolve mapping

| Resolve concept | JVE entity | Identity bridge |
|---|---|---|
| Media-pool clip (`Sm2MpVideoClip` / `Sm2MpAudioClip`) | the wrapping `contains-assets` sequence (mediaseq) — NOT the asset | `DbId` → `mediaseq.id`. Asset gets a fresh JVE-internal id (asset visibility invariant). |
| Pool folder (`Sm2MpFolder`) | bin (per project_browser bin_map) | `DbId` → bin id |
| Timeline / sequence (`Sm2Sequence`) | a `contains-sequences` sequence | `DbId` → sequence.id |
| Timeline item (`Sm2TiVideoClip` / `Sm2TiAudioClip`) | a `sequence_ref` | `DbId` → sequence_ref.id (023 FR-011b) |
| Track in a sequence | a `track` | positional (V1, V2…, A1, A2…) |
| `BtAudioInfo` (audio stream within a pool item) | an asset_ref's audio side | `DbId` → asset_ref id (?) |

**On the parser side (DRP importer), use Resolve's vocabulary** (`pool_clip`, `timeline_item`, `Sm2Mp*`, `Sm2Ti*`). **On the model side, use JVE's vocabulary** (`asset`, `sequence`, `sequence_ref`). The boundary is the importer — translation happens once, at parse-to-model handoff.

---

## What changes from current vocabulary

Legacy column refers to what is in the codebase today (pre-021). New column is the v1 target.

| Current name (legacy) | New name (021 v1) |
|---|---|
| `media` table | `assets` table |
| `media.id`, `media_id` | `asset.id`, `asset_id` |
| `media_refs` table | `asset_refs` table |
| `media_ref.id`, `media_ref_id` | `asset_ref.id`, `asset_ref_id` |
| Lua var `mref` | `aref` |
| `models/media.lua` | `models/asset.lua` |
| `models/media_ref.lua` | `models/asset_ref.lua` |
| `clips` table | `sequence_refs` table |
| `kind='master'` | `kind='contains-assets'` |
| `kind='sequence'` | `kind='contains-sequences'` |
| `models/clip.lua` | `models/sequence_ref.lua` |
| `clip.id`, `clip_id` | `sequence_ref.id`, `sequence_ref_id` |
| `clips.master_layer_track_id` | `sequence_refs.video_layer_track_id` (no "master" — the sequence_ref already knows its source sequence) |
| `clips.master_audio_track_id` | `sequence_refs.audio_layer_track_id` |
| `clip_grade` table | `sequence_ref_grade` table |
| `clip_links` table | `sequence_ref_links` table |
| `clip_markers` table | `sequence_ref_markers` table |
| `clip_channel_override` table | `sequence_ref_channel_override` table |
| `owner_sequence_id` (on any contained row) | `parent_sequence_id` |
| Lua var `owner_seq` | `parent_seq` |
| `core/effective_source.lua` (module) | `core/source_window.lua` (or fold the computation into `SequenceRef:source_window()`) |
| `effective_source.for_clip(p)` (standalone fn) | `sref:source_window()` (method) |
| "master clip" (concept) | (deleted — no such entity) |
| `database.load_master_clips` | TBD — `load_browser_sequences` is the likely shape |
| `commands/duplicate_master_clip.lua` | `commands/duplicate_sequence.lua` (covers both kinds) |
| `commands/delete_master_clip.lua` | `commands/delete_sequence.lua` |
| `commands/find_master_clip_in_browser.lua` | `commands/find_sequence_in_browser.lua` |
| importer locals `master_clip = {...}` | `pool_clip = {...}` on Resolve side; assigned into `sequence` + `asset` on JVE side |
| importer locals `clip_elem` (timeline-item context) | `timeline_item_elem` |
| importer locals `clip_elem` (pool context) | `pool_clip_elem` |
| Lua variable `clip` (timeline-entry context) | `sequence_ref` (or `sref`) |
| Comment/string "the clip" in non-UI code | "the sequence_ref" |
| UI menu "Duplicate Master Clip" | "Duplicate Clip" (UI word "clip" is fine here) |
| `sequences.start_limit_frame`, `end_limit_frame`, `limits_enabled` | `sequences.focus_range_start_frame`, `focus_range_end_frame` (both NULL when not set; no separate toggle) |
| "limits" (concept — hard clamp at resolver) | (deleted — focus_range is view hint + drag default only) |
| (none — markers had no duration) | `sequence_markers` table with optional `end_frame` (favorites mechanism) |

**UI plural convention:** code/schema uses `sequence_refs`; UI strings continue to say "clips" to users ("Selected 3 clips"). The split mirrors FCPX precedent (every NLE user says "clip" naturally).

---

## Tests this naming has to pass

1. **The outsider test.** A new engineer reads the schema cold. Can they tell apart "the file on disk," "the thing in the browser," "the thing on a timeline" without context? Yes — `asset` is the file, `sequence` is the browser thing, `sequence_ref` is the timeline entry.
2. **The one-noun-one-meaning test.** No word means two things in code. "Clip" appears only in UI strings, never in model code. "Sequence" means the entity; "timeline" means the panel; "sequence_ref" means the timeline entry.
3. **The Resolve-boundary test.** Translation between Resolve and JVE happens at exactly two places (DRP importer; DRT writer + bridge helper) and the translation table is explicit. Neither side leaks vocabulary.
4. **The "double-click in browser" test.** Whatever the user clicks, the answer is "open the sequence." No type-switching at the UI level.
5. **The recursion test.** A sequence_ref's source sequence can itself contain sequence_refs whose source sequences contain sequence_refs… Reads naturally at any depth.
6. **The user-says-clip test.** When a user says "this clip," code in the relevant handler asks "is the user pointing at a browser item or a timeline entry?" The handler resolves to either a sequence id or a sequence_ref id. "Clip" never appears as a model variable.
7. **The favorites test.** A user marks five ranges on a Browser Clip; the browser's Favorites view shows them as five separately draggable entries; dragging any one produces a sequence_ref seeded to that range. No subclip / favorite entity manufactured.

---

## Not in 021 (deferred)

Features explicitly out of scope for this rename, with the reason for deferral:

- **Audition** (FCPX-style container of alternates with a "pick"). Modelable later as either (a) a sequence_ref carrying a list of candidate `source_sequence_id`s + a `pick_index`, or (b) a contains-assets sequence with N video tracks at the same position and only the picked track enabled. Deferred — workflow demand should drive the choice.
- **Full Roles system** (FCPX-style typed metadata driving timeline lanes, export stems, mix, per-component subroles). Larger than a rename — affects metadata schema, mix engine, and a future export-stems spec. Patch (015) is the routing primitive today; Roles would unify it with iXML import tagging and export. Future spec.
- **Grade composition operator** (`sequence_grade ∘ sequence_ref_grade`). The inheritance shape is established; the CDL+LUT composition arithmetic (slope/offset/power compose, LUT chain order, per-channel rules) is a render-pipeline design separate from terminology. Future spec.
- **Asset dedup key.** Asset visibility invariant locks in 1:N asset:mediaseq with file-binding identity; the actual dedup key (content hash vs BWF UID vs hybrid) is deferred. See Open Questions.
- **Same-file re-import UX.** Silently create a second mediaseq sharing the asset, vs refuse + reveal the existing mediaseq, vs hint-and-create. Deferred.
- **Cross-project asset sharing.** Today projects are `.jvp` files and inter-project copy isn't a workflow. Deferred until it is.

---

## Open questions

1. **Literal `kind` values:** `contains-assets` / `contains-sequences` (verbose, unambiguous) vs shorter aliases?
2. **Asset dedup key.** Options: content hash (xxhash of first 64KB + size — survives moves, fast, breaks on re-encode), BWF UID (stable for production audio, absent elsewhere), path (fragile), or hybrid (BWF UID → content hash → path-tiebreak). FCPX uses a synthesized UID at `<asset>` that third-party tools can write. Need to pick before assets are first minted.
3. **Same-file re-import UX.** When the user drags in a file already wrapped by an existing mediaseq: (a) silently create a second mediaseq sharing the asset; (b) refuse + reveal existing; (c) hint-and-create. Pick one.
4. **`patch` — fine, or rename to `source_route`?** Question may dissolve into the Roles spec when that lands.
5. **`asset_refs.parent_sequence_id` always points at a contains-assets sequence — column-rename to make this explicit, or is the kind check enough?**
6. **Source viewer terminology.** What does the source viewer "load"? A sequence (any kind), full stop. UI label probably says "Source: <sequence-name>."
7. **"Browser" word.** Keep "Project Browser" (current)? "Bin Browser"? "Sequence Browser"? Users say "the browser." FCPX precedent: "Browser" is the panel name, "Event" is the container — JVE could mirror.
8. **Smart Collections / saved-view surface.** Markers carry tag/category/rating fields TBD; what's the affordance to save a marker filter as a reusable browser view? FCPX Smart Collections are the reference design.
9. **Marker schema details.** Beyond `(id, parent_fk, start_frame, end_frame?, name)`, what tag/color/rating columns are first-class vs deferred to a free-form metadata blob?

---

## Unresolved (concise, per Joe's plan-format preference)

- kind literal: long vs short
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

- **vs Avid / Premiere / FCP7:** JVE eliminates subclip-as-entity. The propagation those NLEs preserve via a *second* affiliation axis (clip-to-clip) is provided in JVE via the *single* sequence_ref → source affiliation axis. "Edit the master, see it propagate to all uses" still works — every sequence_ref of the source sees the change. The thing JVE can't do is "two browser entries that share a master via affiliation" — but the use cases (named windows, multiple graded versions, multi-cam angles) are covered by ranged markers (favorites mechanism) + duplicate-as-deep-copy + per-instance grade override.
- **vs FCPX:** essentially parity on the organizational side (named ranges under a master via markers; favorites-style filtered browse view). JVE adds:
  1. **Per-sequence focus range** as a view hint + drag default (FCPX has nothing equivalent — favorites are the drag-source, no separate sequence-level default-view concept).
  2. **Master baseline grade with sequence_ref override** (`sequence_grade` ∘ `sequence_ref_grade`). FCPX has clip-level color and Adjustment Layers but no master/instance composition.
  
  JVE notably does NOT (in 021) match:
  - **Audition** as a first-class container (deferred).
  - **Full Roles system** for lane organization, export stems, iXML auto-tagging (deferred).
- **vs DaVinci Resolve:** Resolve's independent-subclip-on-creation matches JVE's "duplicate is a deep copy." JVE additionally retains a strong master/affiliate edge via sequence_refs, which Resolve lacks. Match Frame behavior in JVE is therefore richer.

### Subclip-elimination move: who did what

FCPX (2011) was the first major NLE to eliminate subclips as a separate entity, replacing them with Favorites + Keywords + Compound Clips. JVE follows that precedent for subclip elimination specifically.

**JVE goes further** in one architectural respect FCPX did not: FCPX still splits "things that contain edits" across multiple element types (`<project>`, `<media>` wrapping Compound/Multicam/Sync, plus `<asset-clip>` directly in spines). JVE unifies all of these under one `sequence` entity with a `kind` discriminator. The subclip-elimination move is shared precedent; the container-unification move is JVE-original.

### Single-axis vs two-axis affiliation — the load-bearing JVE claim

Other NLEs have *two* affiliation axes:
1. **Clip-to-clip:** master clip ↔ subclips / cloned clips / affiliated clips. Explicit. Manipulated by File menu commands.
2. **Master-to-timeline-item:** implicit; every timeline placement is also an affiliate of its source. Not first-class in their model.

JVE collapses these into *one* axis at the sequence_ref → source edge. Because sequence_refs carry their own source window AND are first-class in the model:
- "Subclip with active link" → a ranged marker on the source + a sequence_ref seeded to that range.
- "Make Independent" → not needed; sequence_refs are already independent of each other.
- "Duplicate clip" → deep-copy a Browser Clip; sovereign thereafter.
- "Master Clip effects" → set on the source sequence; propagated by every sequence_ref that points at it (the sequence_ref's grade is a delta on top).

Architectural cost: zero (one axis is simpler than two). Cost to Avid power users: re-learn the workflow (use sequence_refs + named markers instead of subclips). FCPX shipped the same architectural move in 2011 and the community has accepted it; JVE follows that precedent.

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
