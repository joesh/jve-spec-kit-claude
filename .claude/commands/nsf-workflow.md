---
description: No Silent Failures - enforce strict error handling, TDD, and comprehensive test coverage
---

# No Silent Failures (NSF) Mode

You are now in strict NSF mode. Apply these rules to ALL code you write or review:

## Core Principles

1. **NO SILENT FAILURES** - Every error must be surfaced immediately
2. **NO FALLBACKS** - Never invent default values when data is missing
3. **NO IGNORED RETURNS** - Check and handle every error return
4. **TDD REQUIRED** - Write failing test FIRST, then implement
5. **ALL PATHS TESTED** - Cover error paths, edge cases, not just happy path

## TWO HALVES OF NSF

NSF has two halves. Both are mandatory. Auditing only half is a failure.

### Half 1: Input Validation (prerequisites)
- Are all required inputs non-nil/non-null?
- Are all parameters in valid range?
- Are all required fields present?
- Is the caller meeting the function's preconditions?

### Half 2: Output Invariants (postconditions)
- Does the function produce a sane result?
- Is the output within expected bounds?
- Did a multi-step pipeline actually produce output (not silently drop data)?
- Can a computed value teleport to an impossible state?

**Example failures from missing Half 2:**
- Audio pump pushes source data to SSE but SSE produces 0 frames → silent (no assert)
- Position advances from frame 0 to frame 124365 in one tick → silent (clamped to boundary, stops playback, no assert)
- Clock returns time_us corresponding to the end of a 90-minute sequence on the first tick → silent

## Error Handling Rules

- Functions that can fail MUST return error info or assert
- Callers MUST check return values - never discard
- Use `assert()` for invariant violations with actionable messages
- Include context in errors: function name, relevant IDs, bad values
- NO try/catch that swallows errors silently
- NO `or default_value` patterns that hide missing data
- Functions that transform data MUST validate output is sane (not just that input was valid)

## TDD Workflow (Mandatory)

1. **Write test first** - Test must fail initially (red)
2. **Show the failure** - Run test, confirm it fails as expected
3. **Implement minimally** - Write just enough code to pass
4. **Run test again** - Confirm green
5. **Refactor if needed** - Keep tests passing

## Test Coverage Requirements

Tests MUST cover:
- Happy path (normal operation)
- Error paths (what happens when things fail?)
- Boundary conditions (empty, zero, max, nil)
- Invalid inputs (wrong types, out of range)
- State transitions (before/after, edge states)

## Code Review Checklist

Before completing any code task, verify:

```
INPUT VALIDATION (Half 1):
[ ] No functions silently return nil/false without caller checking
[ ] No default values substituted for missing required data
[ ] All assert messages include function name + context
[ ] No TODO/FIXME for error handling deferred

OUTPUT INVARIANTS (Half 2):
[ ] Pipeline outputs are checked (did render produce frames? did write succeed?)
[ ] Computed values are bounded (can't teleport, can't exceed physical limits)
[ ] Multi-step chains validate end-to-end (source pushed → frames rendered → output written)
[ ] Clamp-and-continue patterns have asserts BEFORE the clamp (clamp hides the bug)

TESTING:
[ ] Failing test written and shown BEFORE implementation
[ ] Tests exist for error conditions, not just success
[ ] Black-box tests check observable output, not internal calls
```

## Coding Style (ENGINEERING.md)

Also audit for violations of the project's coding standards:

### Structure
- **2.5 Functions Read Like Algorithms** - Main functions tell WHAT happens, helpers handle HOW. Never mix high-level logic with low-level detail in the same function.
- **2.6 Short Functions** - One responsibility per function. If it doesn't fit on one screen, split it.
- **2.18 FFI vs Business Logic** - FFI functions are pure C++ mappings (parameter validation only). Business logic calls FFI, never C++ directly. Never put application logic in FFI functions.

### Safety
- **2.13 No Fallbacks** - Never `or default_value`. Fail explicitly.
- **2.15 No Backward Compatibility** - No shims, migrations, or legacy paths unless Joe explicitly asks.
- **2.17 No Stubs** - No dummy return values. Implement fully or fix the architecture.
- **2.21 Statically-Verifiable** - Prefer compile-time/signature-level enforcement over runtime checks.
- **2.29 sequence_id on Timeline Commands** - All commands modifying a sequence MUST include `sequence_id`.

### Process
- **2.4 Clean Builds** - Zero warnings, zero errors before moving on.
- **2.20 Regression Tests First** - Failing test BEFORE fix. Prove it fails.
- **2.31 Never Change Test Expectations** - Existing assertions are canon. Fix impl, not tests.
- **2.32 New Codepaths Require Tests** - Every new branch/handler needs tests (including error paths).

### Code Review Checklist Addition

```
CODING STYLE:
[ ] Functions are short, single-responsibility (2.5, 2.6)
[ ] No high-level + low-level logic mixed in same function (2.5)
[ ] FFI functions contain no business logic (2.18)
[ ] No stubs or dummy implementations (2.17)
[ ] No backward-compat shims (2.15)
[ ] No fallback values hiding errors (2.13)
[ ] Timeline commands include sequence_id (2.29)
[ ] Build is clean (0 warnings, 0 errors) (2.4)
```

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

When the user invokes `/nsf` and the task involves non-trivial code
changes, plan the review pass(es) AFTER the implementation + initial
audit are complete, and BEFORE reporting the task done. If the change
is genuinely trivial (one-line rename, doc-only edit), say so
explicitly and skip — but the burden is on you to justify skipping.

## Applies To

`$ARGUMENTS` is Claude Code's slash-command argument substitution: it
expands to whatever the user typed after `/nsf` on the invocation line.
Examples: `/nsf src/lua/foo.lua bar.lua` → audit those two files;
`/nsf the bridge code I just touched` → free-form scope hint.

$ARGUMENTS

If no arguments provided, apply to the current task context (the work
the conversation is actively focused on — typically the diff so far on
the current branch).

Execute the task with these constraints strictly enforced.
