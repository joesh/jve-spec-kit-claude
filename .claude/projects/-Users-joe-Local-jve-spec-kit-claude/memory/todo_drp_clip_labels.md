---
name: drp-clip-labels-and-metadata
description: DRP importer should extract clip name keywords (scene/shot/take), store as properties, and render expanded label — not just store filename as master clip name
type: project
---

DRP importer stores filename as master clip name and expanded label (e.g. "20-086-001") as timeline clip name. Missing: the keyword source that generates the label.

**Why:** Find in browser returns 0 matches for scene/shot searches because master clips only have filenames. Timeline clips have the expanded label but it's not on the master clip. Scene/Shot/Take metadata schemas exist but nothing populates them from DRP.

**How to apply:**
1. Find where Resolve stores the clip name source (keyword template) vs rendered name in the DRP XML
2. Extract scene/shot/take keywords from the DRP and store as clip properties
3. Cache our own rendered version of the expanded label
4. Store all metadata_schemas attributes that DRP provides
5. Master clip should have both filename AND display label

Related: spec 003-find-sift-find — Find in browser vs timeline returns different results because master clips lack DRP metadata.
