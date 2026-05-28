# JVE anti-pattern lint rules

Rules enforced by `scripts/lint_anti_patterns.sh`. Each has a stable ID so inline exemptions remain valid across rule reorderings. Exemptions REQUIRE a reason on the same line:

```lua
local s = json.decode(blob) or {}  -- lint-allow: R001 untrusted external feed, recovery is per-message
```

```cpp
QWidget* w = static_cast<QWidget*>(lua_to_widget(L, 1));  // lint-allow: R005 input known QWidget via metatable
```

| ID | Language | Pattern | Why it's a bug | First found |
|---|---|---|---|---|
| **R001** | Lua | `json.decode(x) or <default>` | Silently masks parse failures; corrupt prefs JSON resets user state without warning. | Pass 7, Pass 13 |
| **R002** | Lua | Comment containing `for now`, `hopefully`, `kludge`, `simplification`, `in production we`, `XXX`, `HACK`, `FIXME` | Three+ passes found a real bug adjacent to comments of this shape. Memory rule: "uncertain comments are Claude tells". | Pass 10 |
| **R003** | Lua | `os.getenv("HOME") or ""` | Silent HOME-missing produces invalid paths like `/.jve/foo`. Use `core.dialog_prefs.path_for()` or assert. | Pass 13 |
| **R004** | Lua | `if type(X) ~= "..." then return end` | Silent type-check guard hides contract violations; pass 9 found a case where the guard masked a missing playhead writeback. | Pass 9 |
| **R005** | C++ | `static_cast<T*>(... lua_to_widget(...))` where T ≠ QWidget, not wrapped in qobject_cast | Unchecked downcast; if a wrong widget userdata is passed, the cast succeeds but the object is the wrong runtime type. Use `qobject_cast<T*>(static_cast<QObject*>(...))`. | Pass 11, Pass 15a |
| **R006** | C++ | `delete <name>;` where name is a Qt-flavored widget local (`shortcut`, `action`, `widget`, `menu`, `button`, ...) | Raw `delete` can yank a QObject mid-signal-dispatch. Prefer `->deleteLater()`. | Pass 15a |
| **R007** | C++ | File contains `luaL_ref` but no `luaL_unref` | Lifetime leak unless ref is owned/freed in another translation unit. Annotate per-line if the ref is intentionally process-lifetime, or fix the owner. | Pass 14, Pass 15a |
| **R008** | C++ | Comment containing the R002 markers | Same Claude-tell pattern; C++ variant. | Pass 10, Pass 14 |

## How rules are wired

1. **PostToolUse hook** (`.claude/hooks/lint_anti_patterns_post_edit.sh`): runs on every `Edit` / `Write` / `MultiEdit`, emits violations to Claude as additionalContext. Does NOT block — in-session feedback only.
2. **pre-commit hook** (`.git/hooks/pre-commit`): runs on staged files. Blocks the commit if a violation is on a line being introduced or modified. Pre-existing violations on untouched lines do not block.
3. **Manual sweep**: `scripts/lint_anti_patterns.sh --all` reports everything across `src/`.

## Adding a rule

When a future audit pass surfaces a recurring pattern, add it here:
1. Pick the next free `R0NN`.
2. Add a `grep -nE ... | emit ... R0NN` block in `lint_lua` or `lint_cpp`.
3. Document it in this file with first-found pass.
4. Re-run `scripts/lint_anti_patterns.sh --all` to confirm low false-positive rate before commit.

## Exemption discipline

`lint-allow: <id> <reason>` is reviewable. Bare `lint-allow: <id>` (no reason) is ignored by the matcher — keeps exemptions explicit. If you find yourself adding 3+ exemptions for the same rule, the rule is probably wrong or too coarse — refine it or remove it.
