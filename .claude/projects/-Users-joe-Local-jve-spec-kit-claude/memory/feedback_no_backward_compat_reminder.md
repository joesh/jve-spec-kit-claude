---
name: no-backward-compat-reminder
description: When modifying schema or data structures, never add backward compatibility - fail early with asserts per CLAUDE.md rules
type: feedback
---

When modifying schema, data structures, or APIs: no backward compatibility, no fallbacks, no migration shims. Fail early with asserts.

**Why:** ENGINEERING.md rule 2.15 — "we DO NOT maintain backward compatibility for schemas, APIs, data stores, or workflows; delete legacy paths as soon as replacements exist." Rule 2.13 — "NEVER use fallback values." Rule 1.14 — fail-fast assert policy.

**How to apply:** When adding new DB tables or columns, just add them to schema.sql. No version gates, no `CREATE TABLE IF NOT EXISTS` workarounds, no graceful degradation for missing tables. If the schema doesn't match, assert. Old projects get deleted/reset, not migrated (unless Joe explicitly asks for migration).
