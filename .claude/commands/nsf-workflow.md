---
description: No Silent Failures + skeptical multi-agent review - strict error handling, TDD, coverage, then a loop-until-dry agent review pass
allowed-tools: Bash(cat:*)
---

!`cat .claude/command-fragments/nsf-core.md`

## Skeptical Multi-Agent Review (Final Pass)

Before declaring an NSF task complete, decide whether the change
warrants a multi-agent **Workflow** review. When it does, run one:
fan out specialized reviewers in parallel, fold their findings back
in, and **iterate until no more signal**. Inline solo review shares
the author's blind spots; independent agents don't.

**Claude decides.** A workflow is warranted when the change touches
non-trivial logic, crosses module boundaries, modifies shared state,
adds a new code path, or alters a contract/spec. A workflow is NOT
warranted for pure documentation edits, one-line renames with no
logic change, comment-only changes, or test additions with no
production-code change. Default to running one when in doubt — the
cost of running is small relative to the cost of missing a bug. State
the decision explicitly: "Running workflow review because <reason>"
or "Skipping workflow review because <specific reason>". The burden
is on you to justify skipping.

### Rules

- **When running a workflow, use the Workflow tool**, not solo inline
  review. A solo reviewer shares the author's blind spots; independent
  agents don't.
- **Right-size the pass.** Agent count scales to change size: 2–3
  reviewers for a single-file edit, 4–6 for a multi-file feature,
  up to 10 for an architectural refactor. Picking 6 reviewers for a
  200-line doc edit burns ~200K tokens to find what 2 would find.
- **No more than 10 agents per pass.** Pick from the Review Dimensions
  below — the list is the menu, not the requirement.
- **Cap reviewer prose.** Schema for each finding's `suggested_fix`
  field MUST set `maxLength: 400`. Reviewers tend to write paragraph-
  long fixes; one-sentence fixes carry the same signal.
- **Share reference reading.** Each reviewer independently re-loading
  ENGINEERING.md / CLAUDE.md / the memory dir is the dominant cost.
  When ≥4 reviewers will need the same reference set, run a single
  discovery agent first that extracts the relevant slice and passes
  it inline to the reviewers via prompt.
- **Loop until dry, bounded at 3 passes.** After each pass, fold
  findings into fixes, then run another pass. Stop when a pass returns
  no new actionable signal — defined as: zero findings, OR only nits
  already-known-and-accepted by the user in a prior pass, OR only
  purely-affirmative reports. If 3 full passes haven't converged, stop
  and present the remaining findings to the user — at that point the
  change has a design problem the review loop won't fix.
- **Pass 2+ prunes dimensions.** Only re-run dimensions that produced
  High/Med findings in the prior pass OR that were directly affected
  by the pass-N fixes. Clean dimensions are not re-checked.
- **Skeptical, not affirming.** Each agent must be prompted to look
  FOR problems, not to confirm the change is fine. "Default to finding
  something" beats "approve unless broken."
- **Verify before reporting.** Reviewers must `ls`/Read the artifacts
  they cite. A "this file does not exist" finding without an
  accompanying tool call is a hallucination — drop it in synthesis.

### Review Dimensions (menu — pick up to 10 per pass)

- **DRY** — is anything copy-pasted? Same shape in 3+ places that should
  be lifted? Per [[feedback_lift_dry_when_you_see_third_copy]]:
  third copy means lift now.
- **Architectural correctness** — per [[feedback_architectural_correctness]]:
  is this the right design, or a workaround? Would a reviewer accept it
  as proper, or only as a stopgap? Is the function in the right module?
  Does data flow through the right layer?
- **ENGINEERING.md compliance** — re-read the diff against rules 1.1,
  1.2, 1.12, 1.14, 2.4, 2.5, 2.6, 2.9, 2.13, 2.15, 2.16, 2.17, 2.18,
  2.20, 2.21, 2.29, 2.31, 2.32, 2.34, 3.0, 3.5, 3.9–3.10, 3.14.
  Report rule → finding → fix.
- **Coding style** — CLAUDE.md conventions: no emojis, no decorative
  comments, short functions, no narration of WHAT the code does.
  Comments explain non-obvious WHY only — never narrate WHAT, never
  reference the current task / caller / issue. No aspirational docs.
- **No silent failures** — both halves above; clamp-before-assert
  patterns; ignored return values.
- **Test quality** — per [[feedback_tests_from_domain]] and
  [[feedback_tdd_before_fix]]: black-box vs implementation-mirroring;
  expected values derived from domain not from code; failing test came
  first; edge paths covered.
- **No mocks** — per [[feedback_no_mocks_use_test_mode]]: zero mocks
  in tests (no `package.loaded[X] = stub`, no stub modules). Pure-Lua
  tests stay pure model; anything touching Qt/panels/source-monitor
  goes through `--test` mode against the real bindings.
- **Tests drive via user-visible primitives** — per
  [[feedback_tests_drive_via_user_primitives]]: no `database.init()`,
  no raw schema bootstrap, no direct SQL. Tests exercise the same
  commands and lifecycles a user would (OpenProject, NewProject,
  command_manager.execute). Bypassing the lifecycle hides bugs in the
  real user path AND leaks state.
- **Verify wrapper contracts** — per [[feedback_verify_wrapper_contracts]]:
  when calling existing helpers/wrappers, read the implementation
  end-to-end to verify what it RETURNS and whether intermediate layers
  are transparent. Don't trust signatures alone — wrappers swallow
  return values, public tables omit internal methods.
- **Spec sync** — did this change invalidate any FR / data-model claim
  / contract in `specs/NNN-*/`? Same commit fixes the spec.
- **Memory hygiene** — any TODO/FIXME/HACK/`for now`/`legacy` markers
  left in code? Each must be folded into a `todo_*.md` memory file or
  removed.
- **Dead code / bloat** — unused params, unused locals, dead branches,
  premature abstractions, error handling for impossible cases.
- **Naming** — does the function name match what the function actually
  does post-change? (When fixing "X was asking the wrong object," the
  name often becomes a lie.)

### Workflow Shape

Concrete schema for each reviewer's structured output:

```jsonschema
{
  "type": "object",
  "required": ["findings"],
  "additionalProperties": false,
  "properties": {
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["dimension", "file", "location", "severity",
                     "description", "suggested_fix"],
        "additionalProperties": false,
        "properties": {
          "dimension":     { "type": "string", "description": "the dimension slug this finding came from" },
          "file":          { "type": "string", "description": "absolute path" },
          "location":      { "type": "string", "description": "line number, range 'N-M', or section heading" },
          "severity":      { "enum": ["high", "medium", "low"] },
          "description":   { "type": "string", "maxLength": 400 },
          "suggested_fix": { "type": "string", "maxLength": 400 }
        }
      }
    }
  }
}
```

Phases:

```
phase 1: parallel skeptical reviewers (up to 10), one per dimension,
         each returning {findings: [...]} per schema above.
phase 2: synthesize — dedup by (file, location, description); when
         duplicates appear keep the highest severity; drop purely-
         affirmative reports.
phase 3: present High and Medium findings to the user for triage
         before applying. Apply Low findings inline only when the user
         hasn't asked for review of them. NEVER silently apply High/Med.
phase 4: re-run targeted tests on touched files (`cd tests && luajit
         test_harness.lua <touched-tests>` for Lua-only, full
         `make -j4` only if the change crossed into C++).
phase 5: if pass N applied any fixes, run pass N+1. Stop per the
         "Loop until dry" rule above (no new signal, OR pass cap of 3).
```

Use `parallel()` for the reviewer fan-out — synthesis needs all
results together to dedup across dimensions. Use the `Explore`
agentType so reviewers can read files but can't edit.

### Invocation

When the user invokes `/nsf-workflow` and the task involves non-trivial
code changes, plan the review pass(es) AFTER the implementation +
initial audit are complete, and BEFORE reporting the task done. If the
change is genuinely trivial (one-line rename, doc-only edit), say so
explicitly and skip — but the burden is on you to justify skipping.

## Applies To

`$ARGUMENTS` is Claude Code's slash-command argument substitution: it
expands to whatever the user typed after `/nsf-workflow` on the
invocation line. Examples: `/nsf-workflow src/lua/foo.lua bar.lua` →
audit those two files; `/nsf-workflow the bridge code I just touched` →
free-form scope hint.

$ARGUMENTS

If no arguments provided, apply to the current task context (the work
the conversation is actively focused on — typically the diff so far on
the current branch).

Execute the task with these constraints strictly enforced.
