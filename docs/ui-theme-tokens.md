# UI Theme Tokens

The single source of truth for every colour, and most fonts/spacing, in the UI
is `src/lua/core/ui_constants.lua`. This doc explains the model so you reach for
an existing token instead of inventing a new constant or pasting a hex literal.

> **Hard rule for humans and Claudes alike:** never write a hex literal in UI
> code, and never add a new colour constant without first checking this doc for
> a token that already means what you want. If none fits, add it to the correct
> tier in `ui_constants.lua` (not at the call site) and document it here.

---

## The three tiers

Mirrors the standard design-token model (primitive → semantic → component). Each
tier has one job; call sites only ever touch tiers 2 and 3.

| Tier | Name pattern | Names describe | Holds | Who reads it |
|------|--------------|----------------|-------|--------------|
| 1 PALETTE   | `GREY_720`, `BLUE`, `INK_050` | **appearance** (a lightness rank or hue) | the raw hex values | only tier 2/3, never call sites |
| 2 SEMANTIC  | `SURFACE_PANEL`, `TEXT_LABEL`, `STATE_FOCUS` | **intent / role** | an alias to a tier-1 value | almost every call site |
| 3 COMPONENT | `TRACK_HEADER_BG`, `FIELD_WELL_BG` | **a specific widget** | an alias to a tier-1 value or a tier-2 role | the one widget it names |

**Why the split:** the value lives in exactly one place. A re-theme edits ~19
tier-1 literals; every name and every call site stays put. A call site that says
`SURFACE_CANVAS` keeps meaning "the editing surface" no matter what colour that
becomes.

### Tier 1 names are lightness ranks, not pixel values

`GREY_720` is the 720-rung on a 50→950 lightness ladder (950 = darkest), **not**
`#2b2b2b`. The rank survives a re-tint because re-tint changes the *value*
attached to the rung, not the rung's identity. So `GREY_720` may be `#2b2b2b`
today and `#2a2b30` after we cool the palette — same name, same call sites.

Hues that aren't grey are named by hue: `BLUE`, `BLUE_DEEP`, `CYAN`, `RED`,
`ORANGE`. Near-white text neutrals are `INK_000`…`INK_460`.

---

## Tier 2 — the tokens you should be using

### `SURFACE_*` — backgrounds, ordered by elevation

Deeper rung = more recessed. Pick by where the surface sits, not by its colour.

| Token | Use for |
|-------|---------|
| `SURFACE_WELL`    | deepest insets — input wells, scrollbar tracks |
| `SURFACE_CANVAS`  | editing surfaces — timeline canvas, ruler, monitor letterbox |
| `SURFACE_CHROME_RECESSED` | recessed chrome bars — panel header/tab strips, monitor title + marks bars |
| `SURFACE_CHROME`  | the app / panel chrome (the signature grey behind everything) |
| `SURFACE_PANEL`   | a content panel raised on the chrome — e.g. the inspector body |
| `SURFACE_OVERLAY` | things that float over panels — dropdowns, menus, popovers, section headers |
| `SURFACE_HOVER`   | hover wash over an interactive row/item |
| `SURFACE_DISABLED`| a disabled control's fill |

Elevation invariant: an overlay must be lighter than the panel it floats over,
which must be lighter than the chrome. If you find yourself wanting an overlay
darker than its panel, you've picked the wrong token.

### `TEXT_*`

| Token | Use for |
|-------|---------|
| `TEXT_PRIMARY` | default body / value text, pure white |
| `TEXT_HEADING` | section + panel titles |
| `TEXT_LABEL`   | field labels, secondary captions |
| `TEXT_VALUE`   | text inside an editable field |
| `TEXT_MUTED`   | read-only / disabled text |

### `BORDER_*`

| Token | Use for |
|-------|---------|
| `BORDER_HAIRLINE` | thin field outlines (near-black) |
| `BORDER_DIVIDER`  | visible structural dividers between regions |
| `BORDER_CONTROL`  | input / dropdown outlines |

### `STATE_*` — interactive feedback

| Token | Use for |
|-------|---------|
| `STATE_FOCUS`      | border of the focused panel or field |
| `STATE_FOCUS_RING` | keyboard-navigation focus ring (cyan) |
| `STATE_SELECTED`   | selection border (also the field-error border — same red today) |
| `STATE_PRESSED`    | pressed/active action control |

### `ACCENT_*` — brand / action

| Token | Use for |
|-------|---------|
| `ACCENT_ACTION`  | the primary action button in a dialog/panel (the "call to action") |
| `ACCENT_SECTION` | collapsible-section marker (orange) |

---

## Tier 3 — component tokens

Only exist where a widget needs a surface that isn't a plain tier-2 role. Use
them only in the widget they name; don't borrow `TRACK_HEADER_BG` for a button.

`INSPECTOR_HEADER_BG`, `INSPECTOR_CONTENT_BG`, `FIELD_WELL_BG`, `FIELD_FOCUS_BG`,
`FIELD_READONLY_BG`, `SCROLL_AREA_BG`, `SCROLLBAR_THUMB`, `TRACK_HEADER_BG`,
`TRACK_HEADER_BORDER`, `TRACK_BUTTON_BORDER`, `TRACK_ROW_EVEN`, `TRACK_ROW_ODD`,
`TIMELINE_CANVAS_BG`, `UNFOCUSED_PANEL_BORDER`.

---

## How to…

**…colour a new widget:** find the tier-2 role that matches its job. Reach for a
tier-3 token only if the widget is one of the named special cases above. Never
paste a hex.

**…add a colour that genuinely doesn't exist yet:** add the value as a tier-1
primitive (named by lightness rank or hue), then add a tier-2 semantic alias
that names its role, and export the semantic name. Add a row to this doc. Don't
export tier-1 names.

**…re-tint / re-theme the whole UI:** edit only the tier-1 value literals in
`ui_constants.lua`. Do not touch tier-2/3 or any call site. The lightness ranks
tell you the intended order — keep darker ranks darker.

**…find every place a colour is used:** call sites use the semantic/component
name, so `rg "SURFACE_PANEL"` finds them all. That's the payoff of never pasting
hex.

---

## Planned: interface-lightness slider

A future feature will let the user drag overall interface lightness from very
dark to light. This is *why* tier-1 names are lightness ranks, not pixel values:
the slider sets a base lightness and a generator recomputes each `GREY_<rank>`
from its rank offset, while tier 2/3 and every call site stay frozen. When you
build new chrome, stay on the ramp — anything that hardcodes a hex will not move
with the slider. See the `todo-ui-lightness-slider` memory for the sketch.

## Provenance

The grey ramp is sampled from DaVinci Resolve's UI — a blue-tinted neutral
(B ≈ R+6, R = G), not a pure grey. JVE deliberately matches Resolve's chrome so
the two apps sit side by side without a colour clash. When in doubt about a
chrome value, sample Resolve, don't guess.
