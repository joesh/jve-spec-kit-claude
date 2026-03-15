# Research: RelinkClips

No technical unknowns required research. All building blocks exist in the codebase.

## Decisions

### 1. Command Architecture
- **Decision**: Single `RelinkClips` command with clip-level undo state
- **Rationale**: All clips processed in one pass. Simpler than BatchCommand wrapper.
- **Rejected**: BatchCommand (overhead, no benefit for atomic clip-level undo)

### 2. TC Representation
- **Decision**: `(frames, rate)` — integer frames with associated rate
- **Rationale**: Same type as all other time values in the codebase. Rate-rescaling for cross-rate comparison.
- **Rejected**: Float seconds (ambiguous unit), TC string (requires fps context)

### 3. Matching Rules Persistence
- **Decision**: Per-project via `database.set_project_setting()`, inherited by new projects
- **Rationale**: Existing pattern (browser sort, window geometry). Different projects may need different rules.
- **Rejected**: App-wide `~/.jve/` (no per-project customization)

### 4. Candidate TC Probing
- **Decision**: ffprobe (video TC tags + BWF time_reference for audio)
- **Rationale**: Already implemented and tested. Handles all container formats.
- **Rejected**: EMP.MEDIA_FILE_OPEN (creates VT sessions, exhausts pool on rapid-fire probing)

### 5. Clip-Level vs Media-Level
- **Decision**: Clip-level — each clip independently matched to a candidate
- **Rationale**: Media-managed segments break 1:1 media-file assumption. Different clips from same original may map to different segment files.
- **Rejected**: Media-level (can't handle segments, can't adjust per-clip source_in)

### 6. Resolve/Premiere Dialog Research
- **Decision**: Checkbox-based matching rules with "Accept Trimmed Media" and "Accept Filename Suffixes" options
- **Rationale**: Resolve's Reconform dialog uses similar checkbox approach. Premiere's Link Media dialog also uses configurable matching criteria.
- **Key insight from Resolve**: TC matching is exact (no tolerance setting). Ambiguous matches prompt user choice. "Force Conform" bypasses matching entirely.
