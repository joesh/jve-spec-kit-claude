# Analysis Tool: Cluster → Module Specification

**Status:** Frozen vocabulary

This document defines how the Lua analysis tool classifies clusters, derives module hypotheses, and emits machine-readable output suitable for AI-assisted refactoring.

The goal is to separate **analysis**, **interpretation**, and **action**, so that downstream tools (including LLMs) execute intent rather than invent architecture.

---

## Core Concepts

### Cluster
A **cluster** is a locality of interaction discovered by structural analysis (calls, shared state, coupling). Clusters describe *how code interacts*, not what it should become.

Clusters are observational.

---

### Module
A **module** is a locality of responsibility with:

- a name
- an ownership boundary
- an interface presented to the rest of the system

At present, **files define modules**. Module names are derived from filenames.

The tool MUST NOT invent module names.

---

### Relationship Between Clusters and Modules

- Every cluster MUST be owned by exactly one module, or explicitly recommended as a new module.
- A cluster may be:
  - an **internal component** of a module
  - **subordinate** to another module
  - a candidate to become a **new module**

Clusters do not float freely.

---

## Cluster Types (Structural Classification)

Cluster type answers:
> *What kind of structure is this?*

### Algorithm

A cluster is an **Algorithm** when:

- cohesion is driven primarily by control flow
- a controlling function (hub) exists
- shared state does not explain cohesion

Algorithms typically benefit from **internal refactoring**, not extraction.

---

### Model

A cluster is a **Model** when:

- cohesion is driven by shared state or data representation
- functions operate symmetrically over that state
- control flow is secondary to data ownership

Models are candidates for explicit module boundaries.

---

### Primitive

A cluster is **Primitive** when:

- it is already at a natural atomic boundary
- responsibilities are minimal and complete
- no meaningful internal decomposition exists

Primitives are valid structure. They are not "nothing".

---

## Ownership Semantics

Ownership answers:
> *Where does this belong?*

Exactly one ownership relationship MUST be emitted.

- **InternalComponent** – part of the module’s internal implementation
- **SubordinateTo** – belongs under another module’s responsibility
- **RecommendNewModule** – cohesive unit not owned by an existing module

The tool MUST NOT emit “no module hypothesis”.

---

## Interface Semantics

A module’s interface consists of:

- explicitly exported functions
- globals currently acting as interface

Globals MAY be treated as interface **temporarily**.

Such globals MUST be labeled:

- `LegacyInterface` – acceptable but should be replaced with accessors
- `Error` – accidental global usage

---

## Refactor Intent

Refactor intent answers:
> *What should be done?*

This is independent of structure.

- **RecommendRefactor** – improve structure without changing module boundaries
- **NoRefactor** – no structural change recommended

Refactor intent MUST NOT imply extraction unless ownership is `RecommendNewModule`.

---

## Explanation Discipline

The tool MUST:

- explain *why* cohesion exists
- suppress invented semantic contexts
- use control-flow language for Algorithm clusters
- use state/data language for Model clusters

The tool MUST NOT:

- derive meaning from identifier frequency alone
- hallucinate domain abstractions

---

## Normative JSON Output Schema

This JSON is the **primary interface** to downstream AI tools.

### Top-Level

```json
{
  "analysis_version": "0.x",
  "scope": {
    "root_paths": ["src/lua/..."],
    "language": "lua"
  },
  "modules": {
    "project_browser.lua": {
      "module_name": "project_browser",
      "naming_basis": "filename"
    }
  },
  "clusters": [],
  "analysis_contract": {}
}
```

---

### Cluster Record

```json
{
  "cluster_id": 1,

  "functions": ["M.create", "handle_tree_drop"],

  "cluster_type": "Algorithm | Model | Primitive",

  "ownership": {
    "module": "project_browser",
    "relationship": "InternalComponent | SubordinateTo | RecommendNewModule"
  },

  "interface": {
    "exported_functions": ["M.create"],
    "globals_used": ["browser_state"],
    "globals_assessment": "LegacyInterface | Error | None"
  },

  "structure": {
    "control_structure": {
      "kind": "SingleHub | MultiHub | Distributed",
      "hub_function": "M.create",
      "hub_dominance": "high | medium | low"
    },
    "interaction_pattern": {
      "symmetry": "symmetric | asymmetric",
      "interpretation": "algorithm | stateful | mixed"
    }
  },

  "refactor_intent": {
    "recommendation": "RecommendRefactor | NoRefactor",
    "rationale": "short explanation",
    "suggested_action": "concrete refactor guidance"
  },

  "file_distribution": {
    "project_browser.lua": 0.77
  },

  "confidence": "high | medium | low"
}
```

---

## Analysis Contract

The JSON MUST include a contract defining enum meanings. This contract is authoritative for AI consumers.

```json
{
  "cluster_type": {
    "Algorithm": "Implements a stepwise procedure coordinating helpers",
    "Model": "Represents shared state and operations over that state",
    "Primitive": "Already atomic; no meaningful decomposition"
  },
  "ownership_relationship": {
    "InternalComponent": "Internal to a module",
    "SubordinateTo": "Belongs under another module",
    "RecommendNewModule": "Candidate for extraction"
  },
  "refactor_intent": {
    "RecommendRefactor": "Internal structural improvement",
    "NoRefactor": "No change recommended"
  }
}
```

---

## Design Intent (Non-Normative)

This specification is designed so that:

- the analysis tool does all interpretation
- AI tools execute intent without guessing
- architectural boundaries are preserved

This document is the source of truth for tool behavior.

