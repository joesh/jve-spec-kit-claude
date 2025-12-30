# Cluster → Module Inference Specification

## Purpose

Define how the analysis tool interprets **clusters of interacting functions** and derives **module hypotheses**, **ownership**, and **refactoring guidance** without inventing semantics or unstable labels.

This specification explicitly separates:

- interaction patterns (clusters)
- semantic ownership (modules)
- structural organization (files, internal components)

---

## Core Definitions

### Cluster
A **cluster** is a set of functions with high internal interaction density.

Properties:
- Derived mechanically from call graph and coupling metrics
- Describes *interaction locality*, not responsibility
- Not an architectural unit

A cluster **does not imply** a module.

---

### Module
A **module** is a semantic unit defined by:
- a coherent responsibility or model
- a stable external interface
- ownership over its internal state and algorithms

A module:
- may span one or more files
- may contain multiple clusters
- is the primary architectural unit

---

### Ownership Classification (Mandatory)

Every cluster must be classified by **ownership** before any other interpretation.

Exactly one of:

1. **Root of module X**
2. **Subordinate to module X**

There is no third category.

---

### Subordinate (Semantic Fact)

A cluster is **subordinate to module X** if:

- it has no independent responsibility
- it exposes no public interface
- its lifecycle is entirely governed by X
- it exists only to support X’s behavior

Subordination is **not optional** and **not structural**.

---

### Internal Component (Structural Choice)

An **internal component** is an *organizational decision* applied **only after** subordination is established.

Properties:
- purely internal to a module
- improves readability, isolation, or testability
- may be a file, namespace, or grouped functions
- does not change module boundaries

> A cluster cannot be “either subordinate or an internal component”.
> It may only be subordinate, and optionally *organized as* an internal component.

---

## Cluster Types

Cluster types describe *why* cohesion exists. They do **not** imply module boundaries.

### Algorithm Cluster
Cohesion driven by:
- dominant hub function
- asymmetric call graph
- control flow rather than shared state

Interpretation:
- Implements an algorithm
- Typically subordinate to a module
- Refactoring action: factor helpers, not extract modules

Language:
> “This cluster implements an algorithm for X.”

---

### Model (State) Cluster
Cohesion driven by:
- shared state or model objects
- symmetric or near-symmetric interactions
- stable data abstractions

Interpretation:
- Candidate for a module or a core internal component
- May define or strongly imply a module boundary

Language:
> “This cluster centers on the X model.”

---

### Symmetric Utility Cluster
Cohesion driven by:
- small size
- mirrored responsibilities
- pure helpers

Interpretation:
- No refactor pressure
- No module hypothesis

---

## Orchestration Terminology (Deprecated)

The term **“orchestration”** is replaced.

Use:
- **Algorithm**
- **Algorithm implementation**

Avoid:
- orchestration
- algorithmic control
- coordination (unless meaningfully distinct)

---

## Context Attribution Guardrail

The tool must **not invent semantic context labels**.

Rule:

If cohesion is explained primarily by:
- hub dominance
- call density
- control flow

Then:
- **do not emit “shared X context” language**
- classify as **Algorithm cluster**
- suppress token-based context attribution

---

## Module Hypothesis Rules

The tool may emit a **module hypothesis** only when:

- cohesion is explained by shared state or model
- interactions are not dominated by a single algorithmic hub
- the cluster plausibly defines a stable interface

Otherwise:

- classify as subordinate to an existing module
- explicitly name the owning module

Never say:
> “No module hypothesis can be formed.”

Instead say:
> “This cluster is subordinate to module X.”

---

## Files and Folders

- Files are **containers**, not modules
- Folders may suggest module boundaries but do not define them
- A module may:
  - span multiple files
  - contain multiple clusters
- A file may contain:
  - multiple internal components
  - multiple clusters
  - parts of different modules (temporarily, during refactors)

---

## Refactoring Guidance Emission

When a cluster is subordinate and algorithmic:

- recommend factoring helpers
- recommend naming internal responsibilities
- do **not** recommend extraction into a new module

When a cluster is model-driven:

- recommend interface definition
- recommend boundary clarification
- optionally recommend file or folder extraction

---

## Summary Invariants

- Clusters ≠ Modules
- Ownership precedes structure
- Subordinate is semantic, internal component is structural
- Algorithm clusters do not create modules
- Model clusters may
- Context labels are optional, absence is meanin