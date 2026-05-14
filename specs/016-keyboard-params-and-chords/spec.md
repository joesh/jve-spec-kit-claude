# Feature Specification: Keyboard Parameters, Chords, and Argument Prompts

**Branch**: `016-keyboard-params-and-chords` (not yet cut)
**Created**: 2026-05-14
**Status**: Initial sketch — open questions outnumber decisions

---

## Why

Every track-header button is now command-routed and visible in the keyboard customization dialog (`015-source-in-timeline` follow-up, 2026-05-14). Surfaced gap: the existing TOML keymap can attach a literal `param=value` to a binding (`"Shift+Delete" = "DeleteSelection ripple=true"`), but it has no story for

1. **per-binding parameter editing in the UI** — users today must hand-edit TOML to set `property=muted` vs `property=soloed`,
2. **chord / leader-key sequences** — Avid/Premiere/Resolve all expose dozens of single-letter mode commands; flat-bind every variant and the keyspace runs out,
3. **prompted argument entry** — `SetTrackMixValue value=<numeric>` has no UI affordance to enter the number,
4. **numeric prefix arguments** — Vim/Emacs-style `5,` to nudge by 5, `3.` to repeat 3×; cheap once chord state exists.

Track-header parameterised commands (`ToggleTrackPreference property=...`, `SetSyncMode mode=...`, `SetPatch source_track_index=...`, `SetTrackMixValue property=... value=...`) are the immediate forcing function but the same mechanism unlocks future commands across edit, browser, and inspector.

## Out of scope (this spec)

- Replacing TOML as the keymap source of truth. `.jvekeys` stays canonical.
- Touch-bar / MIDI / OSC remote-control surfaces. (Same dispatcher under the hood, different input layer — separate spec.)
- Modal "tools" (Q select / W track-select / R ripple / T roll). They look chord-ish but they're a separate state machine — orthogonal.
- Scriptable macros (record-replay). Could ride on the same arg-prompt machinery but is its own feature.

---

## Mental model

A **binding** is `(input_sequence) → (command_id, frozen_args, context_filter)`.

- `input_sequence` is one of: single key, key+modifiers, **ordered tuple of keys** (chord), or **command + arg-prompt** (the command itself collects further keystrokes until satisfied).
- `frozen_args` are values literally captured in the keymap entry (`property=muted`).
- **runtime args** come from context resolvers (`track_id @from=focused_or_selected`) or arg prompts (`value=<numeric>`).

A command's SPEC declares each arg's **source class**:

| source | meaning | example |
|---|---|---|
| `frozen` | must be set by the binding | `property` on `ToggleTrackPreference` |
| `context` | resolved from app state by a named resolver | `track_id`, `sequence_id`, `clip_id` |
| `prompted` | collected after the command fires, via UI | `value` on `SetTrackMixValue` |
| `count` | the numeric prefix buffer | `magnitude` on `NudgeSelection` |
| `optional` | none of the above; absence is fine | currently the implicit default |

Dispatch is now: resolve all `context` args → if any required `prompted` args remain, open a prompt → execute with combined arg table. Existing keymap entries (no chords, no prompts, frozen-literals only) ride this pipeline unchanged.

---

## Features

### F1 · Per-arg source class in command SPECs

Extend `SPEC.args` to carry source class and (for `context`) a resolver name:

```lua
local SPEC = {
    undoable = false,
    args = {
        property = { required = true, source = "frozen" },
        track_id = { required = true, source = "context",
                     resolver = "focused_or_selected_track" },
        project_id = { required = true, source = "context",
                       resolver = "active_project" },
    },
}
```

Resolvers are pure functions registered in a `core/arg_resolvers.lua` table. They return either a value, a list of values (multi-target), or assert if no candidate exists. `focused_or_selected_track` reads the timeline focus state first, then `selection_hub`'s selected tracks, then asserts.

Backward compatibility: an arg with no `source` defaults to `optional`, matching today's behavior.

### F2 · Frozen-arg editing in the customization dialog

Customization dialog rows show `(command_id, frozen_args)` as the binding identity. Each `frozen` arg gets an inline editor next to the binding combo:

```
ToggleTrackPreference   property=[ muted ▾ ]   shortcut=[ M ]
ToggleTrackPreference   property=[ soloed ▾ ] shortcut=[ Shift+M ]
ToggleTrackPreference   property=[ locked ▾ ] shortcut=[ L ]
```

The dropdown's allowed values come from the SPEC's `enum` (new field) for that arg, or a free-text box if no enum. "Add another binding for this command" creates a new row with empty frozen args.

The TOML round-trip keeps current syntax; the dialog is a friendlier face on the same data.

### F3 · Chord / leader-key sequences

A binding's key is the existing combo OR a space-separated tuple of combos:

```
"T M" = "ToggleTrackPreference property=muted"
"T S" = "ToggleTrackPreference property=soloed"
"T L" = "ToggleTrackPreference property=locked"
"T Y" = "SetSyncMode property=cycle"
"Cmd+K Cmd+S" = "ShowKeyboardCustomization"
```

Runtime maintains a prefix tree. On the first matched prefix, the dispatcher enters **chord-pending** state: subsequent keys advance the trie, non-matching keys reset and beep. A bound leaf fires the command. Conflicts (`"M"` AND `"T M"` both bound) resolve by preferring the longest exact match — i.e., the lone `M` only fires once chord-pending times out OR an unambiguous non-prefix key arrives.

Chord state surfaces in a transient HUD: `T …` then `T … (M=mute, S=solo, L=lock, Y=sync)` after a short reveal delay (helpful for discoverability; never required to complete the chord).

### F4 · Prompted arguments

A SPEC arg with `source = "prompted"` triggers an inline input collector on dispatch. Numeric, enum, and free-text variants:

```lua
args = {
    value = { required = true, source = "prompted",
              prompt = { kind = "numeric", min = 0, max = 2, default = 1 } },
}
```

UI is a status-line stripe at the bottom of the active panel (NOT a modal dialog — Avid users would riot). Escape cancels; Return commits; partial input commits if `prompt.commit_on_complete = true` (e.g., enum collector commits once typed-prefix uniquely identifies one option).

### F5 · Numeric prefix argument

A persistent digit buffer between keystrokes:

```
5 ,    → NudgeSelection direction=-1 magnitude=5  (overrides bound magnitude)
3 .    → RepeatLast count=3
12 ↑   → MoveTrackUp count=12
```

Any digit key (when no chord-pending and no prompt-active) appends to the buffer. The buffer feeds the `count` arg of the next-fired command and clears on fire, on Escape, or on any non-digit non-modifier key the next command doesn't consume.

Commands opt in by declaring a `count` arg; commands that don't, ignore the buffer entirely (so digit prefix in front of a "wrong" command is a silent no-op — debatable: should it beep instead?).

### F6 · Status / discoverability HUD

A small overlay above the timeline shows:
- chord-pending state (`T …`),
- numeric prefix buffer (`× 5`),
- active arg prompt (`SetTrackMixValue value: 0.7_`).

Always passive — never steals focus, never blocks input. Sized so it never covers the playhead or selected clip.

### F7 · Context resolvers as named, reusable units

Centralize all "what does the user mean right now" logic in `core/arg_resolvers.lua`:

| resolver | returns |
|---|---|
| `active_project` | project_id (asserts none) |
| `active_sequence` | sequence_id (asserts none) |
| `focused_or_selected_track` | track_id (header focus → selection → assert) |
| `selected_tracks` | list of track_ids (assert empty) |
| `selected_clips` | list of clip_ids |
| `displayed_tab_sequence` | sequence_id of currently-displayed tab |
| `effective_source` | source sequence_id (asserts none) |

This replaces today's pile of ad-hoc `command_manager` injections (`sequence_id` from active monitor, `project_id` from `timeline_state`, etc.). Existing injection sites become 1-line resolver calls.

---

## Edge cases

- **Single key bound AND used as chord prefix** — `M` fires Mute; `T M` is chord. Dispatcher must NOT fire `T` then `M` if `T` is only valid as prefix; conversely lone `M` must not block on chord-timeout when no prefix is open. Rule: `M` fires immediately UNLESS chord-pending state exists.
- **Frozen-arg enum out of sync with command code** — SPEC enum is the contract; mismatched TOML value asserts at keymap-load time with a precise file/line error.
- **Resolver fails (no selected track when M pressed)** — asserts. The HUD surfaces the assertion text; no silent skip.
- **Prompt mid-multi-target** — `M` with two tracks selected and `value=<prompt>`: prompt once, apply value to all.
- **Chord interleaved with prompt** — disallowed at the input layer (prompt swallows all keys until Return/Escape).

## Acceptance criteria

A1. Every track-header command can be bound from the dialog without hand-editing TOML, including selecting its frozen args from enums.
A2. `"T M"` binding fires `ToggleTrackPreference property=muted` on the focused/selected track, no other state needed.
A3. `SetTrackMixValue` bound to `V` prompts for value, accepts numeric input, fires on Return, cancels on Escape.
A4. `5 Right` nudges by 5 frames. `3 .` repeats last command 3 times.
A5. Resolver failures (no selected track, no project) produce a single legible status-line message with the failed resolver's name.
A6. TOML round-trip: any binding you can build in the dialog can be expressed in TOML and survives a save/load cycle byte-identical (modulo ordering).

---

## Open questions

- **chord timeout** — fixed 1.0s default, configurable, or wait-forever? Vim is forever; VSCode is 1s; Avid has no chords. Probably configurable with 1s default.
- **prompt UI surface** — status line stripe (proposed), modal dialog (Avid-like), or inspector panel? Modal kills muscle memory. Inspector wrong cognitive location. Status line wins by default.
- **numeric prefix in v1?** — clean once chord state exists; tiny additional cost. Probably v1.
- **multi-target apply** — `M` on multi-selection: apply to all silently (FCP) or confirm? Default silent, surface via the HUD ("Mute toggled on 3 tracks").
- **arg-prompt commit mode** — auto on uniquely-identified enum prefix? auto on N digits for numeric? Or always Return? Probably always-Return for v1; auto-commit is a "smart" feature with tail risk.
- **chord HUD reveal delay** — 0ms (always) is noisy, 1s+ is too slow. Probably ~300ms after the prefix, like discoverable-but-not-pushy IDE hints.
- **digit prefix scope** — clears on what? Any non-digit non-command key? Only on command fire? Defining "command" key is tricky (modifiers aren't, but `M` is).
- **conflict with text fields** — TC entry, rename, search box. Need a "raw passthrough" mode toggled by focus. Probably out-of-band but worth listing.
- **persisted chord trees from plugins** — if/when scripting/plugins land, can they add bindings at runtime? Yes, but they must also surface a TOML fragment for round-trip. Defer detail.
- **`count` arg semantics for non-count commands** — silent no-op (proposed) or beep? Beep flags accidental prefixes early. Both defensible.
- **resolver vs frozen ordering** — if a binding freezes `track_id=v1` AND the SPEC says `context`, frozen wins. Document and assert.

---

## NOW (next 3 actions if green-lit)

1. Land F1 (arg `source` field in SPECs) for the five track-header commands without changing any UI; tests that the resolver is called and frozen args are respected.
2. Implement `core/arg_resolvers.lua` with `active_project`, `focused_or_selected_track`, `selected_tracks`; migrate existing injection sites one at a time.
3. Build the chord prefix-tree dispatcher and HUD; flat-key bindings must keep working byte-identically. Defer F4/F5/F6 to a second pass.
