# Smoke Test Authoring — the rule + the pattern

Every JVE test that involves the running app drives it through the real
UI. No exceptions inside the test body. This document is what to follow;
the rule lives at `~/.claude/projects/.../memory/feedback_drive_jve_via_ui_only.md`.

## The rule (2026-05-30)

Tests drive JVE through real OS-level input (osascript keystroke,
osascript click). The test body:

- Operates on the anamnesis-derived template project that
  `JVESmokeCase` opens at class setup — rich real-world media, clips,
  sequences. NO hand-crafted fixtures, NO `database.init`, NO
  `command_manager.execute(...)`.
- Selects, clicks, types via real input.
- Edits the timeline via real keystrokes (`F9`/`F10`/`B`/`D`/etc.).
- Undoes via `Cmd+Z`. Redoes via `Cmd+Shift+Z`. Saves via `Cmd+S`.
- Inspects state via the debug-terminal REPL (`self.eval_*` calls,
  preferably routed through `core.debug_helpers` to keep eval strings
  short and survivable).

The test body does NOT contain `command_manager.execute(...)`,
`database.init(...)`, `Project.create(...)`, `Sequence.create(...)`,
`package.loaded["..."] = stub`, or `require("ui.layout")`. There are no
mocks at all — we test the actual app.

## Shared state per class (intentional contamination surface)

`JVESmokeCase` opens ONE fresh copy of the anamnesis template at
`setUpClass` — test methods within the class share that project and
accumulate state. This is deliberate:

> "group tests that can operate on the same data and not keep clearing
> the project. We WANT to find cross command contamination. We WANT to
> string together commands that may interact in unexpected ways.
> That's much higher stress than doing a command in a clean state."
> — Joe, 2026-05-30

A `TestCase` class is a **session of related operations on one project**.
Methods run in declared order (alphabetical in unittest); each method
inherits whatever state the prior method left.

To opt into a fresh start before a specific method, override `setUp`:

```python
def setUp(self) -> None:
    super().setUp()
    self._reset_to_template()  # opens a brand-new copy mid-class
```

Use sparingly — the design point is shared state. Reach for
`_reset_to_template()` only when a method genuinely needs a pristine
baseline (testing project-open behavior itself, or recovering from a
deliberately destructive method that left things unusable for the
next).

## Exceptions to the "drive via real UI" rule

Only pure parser/decoder unit tests (no UI surface) may stay in
`--test` mode. Each `--test` use must be approved by Joe per case.
See the live exception list in
`~/.claude/projects/.../memory/feedback_drive_jve_via_ui_only.md`.

## The pattern

A new smoke is a `tests/smoke/cases/test_*.py` file subclassing
`tests/smoke/runner/case.JVESmokeCase`. The runner is a
suite-singleton long-lived JVE; `setUpClass` opens a fresh anamnesis
copy for the class.

```python
"""
<one-liner — what user-visible behavior this pins>

Operates on the anamnesis-derived template. Methods chain in order;
state accumulates intentionally.
"""

import sys, unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[3]))
from tests.smoke.runner.case import JVESmokeCase


class TestSomeUserBehavior(JVESmokeCase):
    """Group of related operations. Methods share state."""

    def test_01_first_action(self) -> None:
        # ---- 1. set state via real input only ----
        self.focus_panel("timeline")
        self.key("F9")
        # ---- 2. inspect via debug_helpers (observer, never mutator) ----
        n = self.eval_int(
            'return require("core.debug_helpers").sequence_count()')
        self.assertEqual(n, 1, "F9 against a selected source...")

    def test_02_chained_action(self) -> None:
        # Inherits the F9 state from test_01.
        self.key("Cmd+Z")
        ...
```

Name methods `test_NN_<verb>` (zero-padded) when method order matters —
makes the intended sequence explicit, and reordering is a deliberate
edit, not an alphabetical accident.

## What to query — `core.debug_helpers`

Smokes inspect state via `require("core.debug_helpers").X()`.
Available queries (`src/lua/core/debug_helpers.lua`):

| Query | Returns |
|---|---|
| `active_project_id()` | currently-active project id (or nil) |
| `active_sequence_id()` | active edit-target sequence id (or nil) |
| `displayed_sequence_id()` | which sequence is rendered (≠ active when source tab displayed) |
| `displayed_tab_kind()` | `"record"` / `"source"` / nil |
| `sequence_count()` | rows in `sequences` (routes through `Sequence.count()`) |
| `clip_count_on_sequence(id)` | clips owned by the given sequence (via `Clip.list_in_sequence`) |
| `mark_in()` / `mark_out()` | display-mark frames (or nil) |
| `selection_count()` | currently-selected clip count on displayed sequence |
| `focused_panel()` | id of the focused panel |
| `clip_enabled(id)` | true / false |

Adding a query: append to `debug_helpers.lua`; route through the
appropriate model (per JVE's SQL-isolation policy — only `models/` may
execute SQL); document in the table above.

## Boundary-of-sequence-start tests (per Joe's 2026-05-30 directive)

Some scenarios should always be exercised regardless of test-grouping
strategy:

- Try to **roll** an edit at the sequence start — must clamp.
- Try to **ripple** a clip before the sequence start — must clamp.
- Try to **move** a clip earlier than sequence start — must clamp.
- **Playhead** below start — must clamp.
- **Arrow-left at boundary** — must clamp.
- **Extend-edit at boundary** — must clamp.
- **Nudge-clip at boundary** — must clamp.

These are ALREADY smokes today under
`tests/smoke/cases/test_*_clamps.py` and
`test_extend_edit_at_start_boundary.py`. Keep them; they protect a
class of bug regression that's easy to introduce.

## What NOT to do (anti-patterns)

| Bad | Why | Right thing |
|---|---|---|
| `self.eval("require('core.command_manager').execute('Insert', {...})")` | Calls an executor from the test body — bypasses keyboard dispatch, focus rules, panel routing. | `self.key("F9")` after selecting source + clicking timeline. |
| `self.eval("require('models.clip').load(id):save{enabled=false}")` | Direct model mutation — no command, no undo, no signals. | `self.key("D")` (ToggleClipEnabled bound to `D`). |
| `package.loaded["ui.panel_manager"] = { ... }` from inside `--test` script | Mocks production code. We test the actual app. | Drive via smoke. If you find yourself wanting a mock, the test belongs in `tests/smoke/`. |
| Bespoke `db:exec("INSERT INTO ...")` setup | Bypasses lifecycle, hides bugs in the real path, leaks state. | The anamnesis project is the substrate; act on it via real input. |
| Resetting state at every method via `_reset_to_template()` | Defeats the cross-command contamination surface Joe wants exercised. | Let methods chain. Only reset when truly needed (see "Shared state" above). |
| `os.exit()` anywhere in test code | Kills the long-lived JVE. | `error(msg)` (or just `assertTrue` — unittest reports failure cleanly). |

## File / menu dialog driving

NOT YET IMPLEMENTED: a robust `runner.pick_file(path)` helper that
drives `QFileDialog` via `Cmd+Shift+G` + typed path + Return.
Required for any smoke that goes through File→Import→…→file picker.
See `~/.claude/projects/.../memory/todo_smoke_file_dialog_driver.md`.

## Running smokes

```bash
make smoke                     # runs ALL smokes via unittest discover
python3 -m unittest tests.smoke.cases.test_X -v
JVE_SMOKE_IN_VM=1 python3 ...   # for UTM guest (higher timeouts)
```

The runner needs Accessibility permission on the calling process
(Terminal / iTerm / your IDE → System Settings → Privacy & Security →
Accessibility). Without it `osascript` returns error 1002 and the
runner surfaces this loudly.
