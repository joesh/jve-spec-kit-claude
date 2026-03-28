# Data Model: Find, Sift, Find & Replace, and Timeline Search

**Feature**: 003-find-sift-find
**Date**: 2026-03-26

## Entities

### Query (value object, not persisted independently)
The atomic unit of search. Used by Find, Sift, Smart Bins, and Timeline Index.

| Field | Type | Description |
|-------|------|-------------|
| column | string | Metadata field name (e.g. "name", "codec", "fps", "scene") |
| operator | enum | Text: `contains`, `begins_with`, `ends_with`, `matches_exactly`. Numeric: `equals`, `greater_than`, `less_than` |
| value | string | User-entered search value (stored as text, parsed for numeric comparisons) |

**Validation rules**:
- `column` must be a recognized searchable field (from clip, media, or properties tables)
- `operator` must be valid for the field's type (text operators for text fields, numeric for numeric)
- `value` must not be empty

**Column resolution** — where each searchable field comes from:
- `name`, `enabled`, `offline`, `volume` → `clips` table
- `codec`, `width`, `height`, `fps_numerator`, `fps_denominator`, `audio_sample_rate`, `audio_channels` → `media` table (joined via `clips.media_id`)
- `duration_frames` → `clips` table (or `media` for master clips)
- Custom properties (Scene, Take, Shot, Comments, etc.) → `properties` table (joined via `clip_id`)

### Sift State (transient + persisted)
Active filter state for a project browser view. Composed through sequential Sift/Expand/Narrow operations.

| Field | Type | Description |
|-------|------|-------------|
| active | boolean | Whether any sift filter is currently applied |
| criteria | array of Query | The accumulated criteria (each with its composition mode) |
| composition_modes | array of string | Per-criterion: `"fresh"`, `"expand"` (OR), `"narrow"` (AND) |
| hidden_ids | set of string | Clip IDs currently hidden by the sift (computed, not persisted) |

**Persistence**: The `criteria` and `composition_modes` arrays are persisted in `projects.settings` JSON under key `"sift_state"`. On project open, criteria are re-evaluated to compute `hidden_ids`.

**State transitions**:
```
No sift → Sift → active=true, criteria=[Q1], modes=["fresh"]
Active  → Expand Sift → criteria=[Q1, Q2], modes=["fresh", "expand"]
Active  → Narrow Sift → criteria=[Q1, Q2, Q3], modes=["fresh", "expand", "narrow"]
Active  → Clear Sift → active=false, criteria=[], modes=[], hidden_ids={}
```

**Re-evaluation**: When clips are added, removed, or modified, the sift must be re-evaluated against all clips to update `hidden_ids`. This happens on:
- Media import
- Clip rename / property change
- Clip delete
- Project open (full re-evaluation from persisted criteria)

### Smart Bin (new DB table)
A named, persistent collection of Query criteria that dynamically resolves to matching clips.

| Field | Type | Description |
|-------|------|-------------|
| id | TEXT (UUID) | Primary key |
| project_id | TEXT (FK) | References projects(id) |
| name | TEXT | Display name in browser tree |
| scope_bin_id | TEXT (FK, nullable) | If set, search is scoped to this bin. If NULL, project-wide. |
| criteria_json | TEXT | JSON array of Query objects (AND logic between rows) |
| created_at | INTEGER | Unix timestamp |
| modified_at | INTEGER | Unix timestamp |

**SQL**:
```sql
CREATE TABLE smart_bins (
    id TEXT PRIMARY KEY,
    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    name TEXT NOT NULL CHECK(length(name) > 0),
    scope_bin_id TEXT REFERENCES tags(id) ON DELETE SET NULL,
    criteria_json TEXT NOT NULL DEFAULT '[]',
    created_at INTEGER NOT NULL,
    modified_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_smart_bins_project ON smart_bins(project_id);
```

**Relationships**:
- Belongs to a project (CASCADE delete)
- Optionally scoped to a bin via `scope_bin_id` → `tags(id)`. SET NULL on bin delete (falls back to project-wide).
- Does NOT own clips — membership is computed dynamically from criteria

**State transitions**:
```
Created → criteria_json set, appears in browser tree
Edited → criteria_json updated, browser refreshes membership
Deleted → removed from browser tree, no clip impact
Bin scope deleted → scope_bin_id becomes NULL (project-wide)
```

### Find State (transient, not persisted)
Active state during a Find session (browser or timeline).

| Field | Type | Description |
|-------|------|-------------|
| active | boolean | Whether Find is currently open |
| query | Query | Current search criteria |
| scope | enum | `"all"`, `"visible"` (browser), `"selected"` (replace) |
| matches | array of string | Ordered list of matching clip IDs |
| current_index | integer | Index into matches for Find Next/Previous cycling |
| previous_selection | array of string | Selection state before Find was invoked (for Escape restore) |
| context | enum | `"browser"`, `"timeline"` — which panel originated the Find |

### Replace Operation (persisted via command system)
Captured in command params for undo/redo.

| Field | Type | Description |
|-------|------|-------------|
| column | string | Which metadata field was replaced |
| find_value | string | The search text |
| replace_value | string | The replacement text |
| affected_clips | array of {clip_id, previous_value} | Each clip's ID and its value before replacement |

## Existing Tables Modified

### projects.settings (JSON column)
New keys added:
- `"sift_state"`: `{criteria: [...], composition_modes: [...]}` — persisted sift criteria
- `"find_dialog_settings"`: `{last_column, last_operator, last_scope}` — dialog persistence (FR-025b)
- `"replace_dialog_settings"`: `{last_column, last_scope}` — dialog persistence

### No schema version bump required for sift persistence
Sift state lives in the existing `projects.settings` JSON column — no ALTER TABLE needed.

### Schema version bump required for Smart Bins
The `smart_bins` table is new and requires a schema migration (V6 → V7). This depends on the schema migration system (currently TODO/stub). Options:
1. Add table in schema.sql and bump version — breaks existing projects (no migration path)
2. Defer Smart Bins until migration system exists
3. Create table dynamically on first access (avoid version gate)

**Decision**: Add table directly to schema.sql. No backward compat, no `IF NOT EXISTS` workaround. Old projects get reset/deleted per project rules (ENGINEERING.md 2.15).

## Searchable Fields Registry

The query engine needs a registry mapping field names to their source table and column, type (text/numeric/boolean), and editability.

| Field Name | Source | Column | Type | Editable |
|-----------|--------|--------|------|----------|
| name | clips | name | text | yes |
| enabled | clips | enabled | boolean | yes |
| offline | clips | offline | boolean | no |
| volume | clips | volume | numeric | yes |
| codec | media | codec | text | no |
| resolution | media | width, height | computed | no |
| fps | media | fps_numerator/denominator | numeric | no |
| duration | clips | duration_frames | numeric | no |
| audio_channels | media | audio_channels | numeric | no |
| audio_sample_rate | media | audio_sample_rate | numeric | no |
| date_modified | clips | modified_at | numeric | no |
| (custom) | properties | property_value | varies | yes |

Custom properties from `metadata_schemas.lua` (Scene, Take, Shot, Comments, etc.) are resolved dynamically from the properties table.
