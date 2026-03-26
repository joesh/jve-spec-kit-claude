# Command Contracts: Find, Sift, Find & Replace, Timeline Search

**Feature**: 003-find-sift-find

These are the command specifications (equivalent to API contracts for a desktop app). Each command follows the existing `command_manager` registration pattern.

---

## Query Engine (Library, not a command)

### `query_engine.match(clip_data, query) → boolean`
Pure function. Tests whether a clip matches a single Query criterion.

**Input**: `clip_data` = {name, codec, fps, duration, enabled, ..., properties={scene=..., take=...}}
**Input**: `query` = {column, operator, value}
**Output**: boolean

### `query_engine.match_all(clip_data, queries) → boolean`
AND: all queries must match.

### `query_engine.filter(clips, queries) → {matching, non_matching}`
Applies queries to a list of clips, returns two arrays.

### `query_engine.get_searchable_fields() → array of {name, type, editable, source}`
Returns the registry of all searchable fields for populating UI dropdowns.

---

## Commands

### FindClips (non-undoable)
**Trigger**: Cmd+F (browser or timeline context)
**Purpose**: Execute a search query, select matching clips, set up Find Next/Previous cycling.

```lua
SPEC = {
    undoable = false,
    args = {
        project_id = { required = true },
        column = { required = true },       -- field to search
        operator = { required = true },     -- contains, begins_with, etc.
        value = { required = true },        -- search text
        scope = {},                         -- "all", "visible", "selected"
        context = {},                       -- "browser", "timeline"
        sequence_id = {},                   -- required for timeline context
    },
}
```

**Returns**: `{success=true, match_count=N, match_ids={...}}`
**Side effects**:
- Browser context: selects matching clips in project_browser, scrolls to first match
- Timeline context: selects first matching clip, moves playhead to its position, scrolls timeline

### FindNext (non-undoable)
**Trigger**: Cmd+G
**Purpose**: Advance to next match from active Find session.

```lua
SPEC = {
    undoable = false,
    args = {
        project_id = { required = true },
        direction = {},   -- "forward" (default) or "backward" (Cmd+Shift+G)
    },
}
```

**Side effects**: Updates selection + scroll. Wraps around at end/beginning.

### Sift (non-undoable)
**Trigger**: Cmd+Shift+F (browser context)
**Purpose**: Apply a fresh sift filter, hiding non-matching clips.

```lua
SPEC = {
    undoable = false,
    args = {
        project_id = { required = true },
        column = { required = true },
        operator = { required = true },
        value = { required = true },
        mode = {},   -- "fresh" (default), "expand", "narrow"
    },
}
```

**Side effects**:
- `fresh`: Replace sift criteria, re-evaluate all clips
- `expand`: Add criterion with OR semantics, show additional matches
- `narrow`: Add criterion with AND semantics, hide non-matches within visible set
- Updates `projects.settings.sift_state`
- Updates "(Sifted)" indicator in browser header
- Triggers browser refresh

### ExpandSift (non-undoable)
**Trigger**: Menu/button/shortcut
**Purpose**: Convenience command — calls Sift with `mode="expand"`.

### NarrowSift (non-undoable)
**Trigger**: Menu/button/shortcut
**Purpose**: Convenience command — calls Sift with `mode="narrow"`.

### ClearSift (non-undoable)
**Trigger**: Escape (when sift active in browser), menu/button
**Purpose**: Clear all sift state, show all clips.

```lua
SPEC = {
    undoable = false,
    args = {
        project_id = { required = true },
    },
}
```

**Side effects**:
- Clears sift criteria from `projects.settings`
- Shows all clips
- Removes "(Sifted)" indicator

### ReplaceClipProperty (undoable)
**Trigger**: Replace button in Find & Replace dialog
**Purpose**: Replace search text with replacement text in a single clip's metadata field.

```lua
SPEC = {
    undoable = true,
    args = {
        project_id = { required = true },
        clip_id = { required = true },
        column = { required = true },       -- which field
        find_value = { required = true },
        replace_value = { required = true },
    },
    persisted = {
        previous_value = {},   -- captured by executor for undo
    },
}
```

**Execute**: Read current value, capture in `previous_value`, apply string replacement, write new value.
**Undo**: Restore `previous_value`.

### ReplaceAllClipProperties (undoable)
**Trigger**: Replace All button in Find & Replace dialog
**Purpose**: Batch replace across multiple clips, single undo step.

```lua
SPEC = {
    undoable = true,
    args = {
        project_id = { required = true },
        clip_ids = { required = true },     -- array of clip IDs to modify
        column = { required = true },
        find_value = { required = true },
        replace_value = { required = true },
    },
    persisted = {
        previous_values = {},   -- array of {clip_id, old_value} captured by executor
    },
}
```

**Execute**: For each clip_id, read current value, capture in `previous_values`, apply replacement.
**Undo**: Restore all `previous_values`.

### CreateSmartBin (undoable)
**Trigger**: Menu: "New Smart Bin..."
**Purpose**: Create a new Smart Bin with specified criteria.

```lua
SPEC = {
    undoable = true,
    args = {
        project_id = { required = true },
        name = { required = true },
        criteria_json = { required = true },  -- JSON array of Query objects
        scope_bin_id = {},                     -- NULL = project-wide
    },
    persisted = {
        smart_bin_id = {},   -- UUID generated by executor
    },
}
```

**Execute**: INSERT into smart_bins table, refresh browser tree.
**Undo**: DELETE from smart_bins table.

### UpdateSmartBin (undoable)
**Trigger**: Edit Smart Bin criteria dialog
**Purpose**: Modify an existing Smart Bin's criteria or scope.

```lua
SPEC = {
    undoable = true,
    args = {
        project_id = { required = true },
        smart_bin_id = { required = true },
        name = {},
        criteria_json = {},
        scope_bin_id = {},
    },
    persisted = {
        previous_name = {},
        previous_criteria_json = {},
        previous_scope_bin_id = {},
    },
}
```

### DeleteSmartBin (undoable)
**Trigger**: Delete key on selected Smart Bin, or right-click > Delete
**Purpose**: Remove a Smart Bin.

```lua
SPEC = {
    undoable = true,
    args = {
        project_id = { required = true },
        smart_bin_id = { required = true },
    },
    persisted = {
        name = {},
        criteria_json = {},
        scope_bin_id = {},
    },
}
```

**Execute**: Capture full Smart Bin data in persisted params, DELETE from table.
**Undo**: Re-INSERT with captured data.

---

## Keybinding Additions (default.jvekeys)

```toml
[Edit]
"Cmd+F" = "Find @project_browser"
"Cmd+F" = "Find @timeline"
"Cmd+H" = "FindReplace @project_browser"
"Cmd+H" = "FindReplace @timeline"
"Cmd+G" = "FindNext @project_browser @timeline"
"Cmd+Shift+G" = "FindPrevious @project_browser @timeline"
"Cmd+Shift+F" = "Sift @project_browser"
```

**Resolved**: GoToTimecode moved from Cmd+G to Ctrl+G (Meta on macOS). Cmd+G freed for Find Next.

---

## Menu Additions

```
Edit
├── Find...              Cmd+F
├── Find Next            Cmd+G
├── Find Previous        Cmd+Shift+G
├── Find and Replace...  Cmd+H
├── ─────────────
├── Sift...              Cmd+Shift+F
├── Expand Sift...
├── Narrow Sift...
├── Clear Sift           Escape
├── ─────────────
├── Timeline Index...

View (or Bin submenu)
├── New Smart Bin...
```
