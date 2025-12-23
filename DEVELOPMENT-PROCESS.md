# DEVELOPMENT-PROCESS.md

## Purpose
This document defines the mandatory operating contract for LLM-assisted development in this repository.
It exists to reduce cost, eliminate permission loops, and preserve developer interruptibility.

This document is authoritative. Prompts must not restate it.

---

## Core Principles (Non-Negotiable)

1. **Intent Is a Control Barrier**
   - Intent checkpoints exist so the user can interrupt or redirect.
   - Intent must precede action.
   - Documentation is secondary to synchronization.

2. **User Prompt Is the First-Class Record**
   - Every action and intent must be traceable to a specific user prompt.
   - The full, verbatim prompt is the causal root of all reasoning.
   - No reasoning may occur before the prompt is echoed.

3. **Act Autonomously, Pause at Intent**
   - The LLM proceeds without permission.
   - The LLM pauses only at explicit intent checkpoints.

4. **Indexes Over Grep**
   - Prefer:
     - docs/symbol-index/commands.json
     - docs/symbol-index/symbols.json
     - tags / ctags
   - Repo-wide grep is allowed only if indexes are insufficient.

5. **Minimal, High-Value Narration**
   - Narration occurs only at intent checkpoints.
   - No step-by-step commentary.
   - No baseline re-reading rituals.

---

## Mandatory Intent Checkpoints (Pre-Action Only)

Intent checkpoints MUST be emitted **before** any irreversible action.

### REQUIRED ORDER (NO EXCEPTIONS)

### 0. Triggering Prompt (Verbatim, Mandatory)
- Echo the **entire user prompt verbatim**, including all lines and formatting.
- This must be the **first output** in the response.
- No reasoning, hypotheses, or narration may appear before it.

### 1. Hypothesis
What is likely wrong and why.

### 2. About To Do
What files/functions will be touched next and why.

---

## Actions (After Intent Only)

After emitting Triggering Prompt, Hypothesis, and About-To-Do checkpoints, the LLM may:
- Read files
- Edit files
- Execute tools

Post-hoc intent is forbidden.

---

## Completion Checkpoints

After actions complete, emit:

### 3. Change Applied
What was changed, where, and intended effect.

### 4. Verification Status
What was verified, what was not, and why.

---

## Logging (Append-Only, Mandatory)

All checkpoints must be appended to:

docs/LLM-CHANGELOG.md

### Required Log Entry Format

```
## YYYY-MM-DD HH:MM — <Short task description>

### Triggering Prompt (Verbatim)
<entire user prompt, unchanged>

### Hypothesis
...

### About To Do
...

### Change Applied
...

### Verification
...
```

Rules:
- Append-only
- Never overwrite
- Never delete entries
- Never summarize, trim, or paraphrase the user prompt
- Never “repair” history

If an error occurs, append a correction entry referencing the original timestamp.

---

## Tooling Rules

- Tool execution must not hide intent.
- Batch scripts must be preceded by conversational intent.
- If tooling collapses intent and action, pause before execution.

---

## Editing Rules

- Prefer full-file edits over snippets.
- If multiple files are involved, produce a ZIP.
- Do not emit patches unless explicitly requested.

---

## Forbidden Behaviors

- Reasoning before echoing the full prompt
- Permission-seeking
- Pre-action checklists
- Baseline-first rituals
- Retroactive intent logging
- Log rewriting
- Process self-repair that hides user interruptibility
- Logging without a triggering prompt

---

## Enforcement

If the LLM violates this process, the user may respond with:

Process violation. Echo full prompt and intent checkpoint, then pause.

The LLM must immediately comply.
