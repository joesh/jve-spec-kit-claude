# Quickstart: Find, Sift, Find & Replace, and Timeline Search

**Feature**: 003-find-sift-find

## Validation Scenarios

These scenarios validate the feature end-to-end. Each maps to acceptance scenarios from the spec.

### 1. Query Engine (unit tests)

```
Setup: Create 10 clip_data objects with varied names, codecs, fps values, and custom properties.

Test 1.1 — Contains operator:
  query = {column="name", operator="contains", value="INT"}
  Assert: clips named "INT_SCENE1", "INTERVIEW", "PAINTING" match; "EXT_SCENE1" does not
  Assert: matching is case-insensitive ("int" matches "INT_SCENE1")

Test 1.2 — Begins With operator:
  query = {column="name", operator="begins_with", value="A001"}
  Assert: "A001_01" matches; "XA001" does not

Test 1.3 — Ends With operator:
  query = {column="name", operator="ends_with", value="_wide"}
  Assert: "scene5_wide" matches; "wide_angle" does not

Test 1.4 — Matches Exactly:
  query = {column="name", operator="matches_exactly", value="Interview"}
  Assert: "Interview" matches; "Interview 2" does not
  Assert: case-insensitive: "interview" matches "Interview"

Test 1.5 — Numeric equals:
  query = {column="fps", operator="equals", value="24"}
  Assert: 24fps clips match; 25fps clips do not

Test 1.6 — Numeric greater than:
  query = {column="duration", operator="greater_than", value="100"}
  Assert: clips with duration > 100 match

Test 1.7 — Custom property search:
  query = {column="scene", operator="contains", value="42"}
  Assert: clips with Scene property containing "42" match

Test 1.8 — match_all (AND):
  queries = [{column="codec", operator="contains", value="ProRes"}, {column="fps", operator="equals", value="24"}]
  Assert: only ProRes 24fps clips match

Test 1.9 — filter function:
  Assert: filter returns two arrays (matching, non_matching) that together contain all input clips

Test 1.10 — get_searchable_fields:
  Assert: returns fields with correct type, editability, source metadata
  Assert: "name" is editable, "duration" is not, "scene" is editable
```

### 2. Bin Find (integration tests via --test mode)

```
Setup: Open project with 20+ master clips with varied names.

Test 2.1 — Find selects matches:
  Execute FindClips with column="name", operator="contains", value="INT"
  Assert: browser selection contains exactly the matching clips
  Assert: first match is scrolled into view

Test 2.2 — Find Next cycles:
  Execute FindNext direction="forward"
  Assert: selection moves to next match
  Execute FindNext enough times to wrap
  Assert: wraps back to first match

Test 2.3 — Find Previous:
  Execute FindNext direction="backward"
  Assert: selection moves to previous match

Test 2.4 — Escape restores selection:
  Note initial selection
  Execute FindClips (changes selection)
  Dismiss Find (ClearFind)
  Assert: selection restored to initial state

Test 2.5 — Scope switch with sift active:
  Apply Sift (hide some clips)
  Execute FindClips with scope="visible"
  Assert: only visible clips are searched
  Execute FindClips with scope="all"
  Assert: hidden clips are also searched
```

### 3. Bin Sift (integration tests)

```
Setup: Open project with clips of mixed codecs and fps.

Test 3.1 — Sift hides non-matches:
  Execute Sift column="codec", operator="contains", value="ProRes"
  Assert: browser shows only ProRes clips
  Assert: browser header shows "(Sifted)"

Test 3.2 — Expand Sift (OR):
  Execute Sift mode="expand", column="codec", operator="contains", value="DNxHD"
  Assert: browser shows ProRes AND DNxHD clips

Test 3.3 — Narrow Sift (AND):
  Execute Sift mode="narrow", column="fps", operator="equals", value="24"
  Assert: browser shows only 24fps clips from the ProRes+DNxHD set

Test 3.4 — Clear Sift:
  Execute ClearSift
  Assert: all clips visible
  Assert: "(Sifted)" indicator removed

Test 3.5 — Sift persists across sessions:
  Apply Sift
  Save project, close, reopen
  Assert: same sift criteria active, same clips hidden

Test 3.6 — New import respects sift:
  Apply Sift for ProRes
  Import a DNxHD clip
  Assert: new clip is hidden (doesn't match sift)
  Import a ProRes clip
  Assert: new clip is visible (matches sift)
```

### 4. Timeline Quick Find (integration tests via --test mode)

```
Setup: Open project with active timeline containing 20+ clips across 3 tracks.

Test 4.1 — Find moves playhead:
  Execute FindClips context="timeline", column="name", operator="contains", value="Interview"
  Assert: playhead is at first matching clip's timeline_start
  Assert: that clip is selected

Test 4.2 — Find Next in timeline order:
  Note first match position
  Execute FindNext
  Assert: playhead moved to next match (by timeline_start, any track)
  Assert: new match's timeline_start >= previous match's timeline_start

Test 4.3 — Select All matches:
  Execute FindClips, then SelectAllMatches
  Assert: all matching clips selected
  Assert: playhead unchanged

Test 4.4 — No active sequence:
  Clear active sequence
  Execute FindClips context="timeline"
  Assert: command returns error / is disabled
```

### 5. Timeline Index Panel (integration tests via --test mode)

```
Setup: Open project with active timeline.

Test 5.1 — Panel lists all clips:
  Open Timeline Index
  Assert: row count equals total clips in active sequence
  Assert: each row has: #, Clip Name, Track, Source In, Source Out, Record In, Record Out, Duration

Test 5.2 — Filter bar:
  Type "Interview" in filter bar
  Assert: only rows with "Interview" in text columns are visible

Test 5.3 — Click navigates:
  Click a row
  Assert: playhead moves to that clip's timeline_start
  Assert: clip is selected on timeline

Test 5.4 — Column sort:
  Click "Clip Name" header
  Assert: rows sorted alphabetically by name
  Click again
  Assert: sort reversed

Test 5.5 — Keyboard navigation:
  Select a row, press Down
  Assert: next row selected, corresponding clip selected on timeline
  Shift+Down
  Assert: both rows selected, both clips selected
```

### 6. Find & Replace (integration tests)

```
Setup: Open project with clips named "Scene01_v1", "Scene02_v1", "Scene03_v2".

Test 6.1 — Replace All:
  Execute ReplaceAllClipProperties column="name", find_value="v1", replace_value="v2"
  Assert: "Scene01_v1" → "Scene01_v2", "Scene02_v1" → "Scene02_v2"
  Assert: "Scene03_v2" unchanged (no "v1" to replace)

Test 6.2 — Undo Replace All:
  Cmd+Z
  Assert: all names restored to originals

Test 6.3 — Single Replace + Skip:
  Open Find & Replace, type find="v1"
  Click Replace → first match replaced, advances to next
  Click Skip → second match skipped, advances to next
  Assert: first clip changed, second unchanged

Test 6.4 — Scope: selected only:
  Select 1 of 2 matching clips
  Execute ReplaceAll with scope="selected"
  Assert: only the selected clip was modified

Test 6.5 — Read-only column excluded:
  Assert: "Duration", "FPS", "Resolution" do not appear in column selector
```

### 7. Smart Bins (integration tests)

```
Setup: Open project with mixed media.

Test 7.1 — Create Smart Bin:
  Execute CreateSmartBin name="24fps ProRes", criteria=[{column="codec", operator="contains", value="ProRes"}, {column="fps", operator="equals", value="24"}]
  Assert: Smart Bin appears in browser tree with distinct icon
  Assert: Smart Bin contents match criteria

Test 7.2 — Dynamic update:
  Import new 24fps ProRes clip
  Assert: clip appears in Smart Bin automatically
  Change a matching clip's codec
  Assert: clip disappears from Smart Bin

Test 7.3 — Undo create:
  Cmd+Z
  Assert: Smart Bin removed from browser tree

Test 7.4 — Scope to bin:
  Create Smart Bin with scope_bin_id set to a specific bin
  Assert: only clips in that bin are matched

Test 7.5 — Edit criteria:
  Execute UpdateSmartBin with new criteria
  Assert: contents refresh to match new criteria
  Undo
  Assert: old criteria restored
```
