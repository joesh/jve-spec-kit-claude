<!--
Sync Impact Report:
Version change: template → 1.0.0
Modified principles: All principles defined from template
Added sections: Core Principles, Quality Standards, Development Workflow, Governance
Removed sections: None (all template sections populated)
Templates requiring updates: ✅ All template references verified
Follow-up TODOs: None
-->

# JVE Spec Kit for Claude Constitution

## Core Principles

### I. Library-First Architecture
Every feature starts as a standalone library with clear boundaries and purpose. Libraries MUST be self-contained, independently testable, and thoroughly documented. No organizational-only libraries are permitted - each library must solve a specific, well-defined problem.

Rationale: Modularity ensures maintainability, testability, and reusability across different contexts and projects.

### II. CLI Interface Standard
Every library MUST expose its functionality via a standardized CLI interface. Text in/out protocol: stdin/arguments → stdout, with errors directed to stderr. All interfaces MUST support both JSON and human-readable formats for maximum versatility.

Rationale: Consistent interfaces enable automation, integration, and human interaction without forcing specific API choices.

### III. Test-First Development (NON-NEGOTIABLE)
Test-Driven Development is mandatory for all code. Tests MUST be written first, approved by stakeholders, allowed to fail, and only then implemented. The Red-Green-Refactor cycle is strictly enforced without exception.

Rationale: TDD ensures code quality, prevents regression, validates requirements understanding, and drives better design decisions.

### IV. Documentation-Driven Specifications
All features begin with comprehensive specifications before any implementation. Specifications MUST include user scenarios, functional requirements, acceptance criteria, and clear success metrics. Implementation follows specification, not the reverse.

Rationale: Clear specifications prevent scope creep, ensure stakeholder alignment, and provide measurable success criteria.

### V. Template-Based Consistency
All project artifacts MUST follow established templates for specifications, plans, tasks, and documentation. Templates ensure consistency, completeness, and enable automated validation of project deliverables.

Rationale: Standardized formats improve quality, reduce errors, and enable tooling automation across all projects.

## Quality Standards

All code MUST pass linting, type checking, and security validation before integration. Performance requirements are domain-specific but MUST be defined upfront and continuously validated. Code coverage MUST exceed 85% with meaningful tests, not just coverage metrics.

Error handling MUST be comprehensive with structured logging for all failure modes. Security practices MUST follow industry standards with no hardcoded secrets or credentials in any repository.

## Development Workflow

All changes MUST follow the specification → plan → tasks → implementation → validation workflow. No implementation may begin without an approved specification and implementation plan.

Code reviews are mandatory for all changes with focus on constitutional compliance, test coverage, and documentation completeness. All constitutional principles MUST be verified during review process.

Branch protection and automated testing gates MUST prevent non-compliant code from reaching main branch. Manual overrides of constitutional requirements require explicit justification and approval.

## Governance

This constitution supersedes all other development practices and standards. Any conflicts between this constitution and other guidance MUST be resolved in favor of constitutional principles.

Amendments require documentation of the change rationale, stakeholder approval, and a migration plan for existing code. All constitutional changes MUST maintain backward compatibility where possible.

All pull requests and code reviews MUST verify compliance with constitutional principles. Complexity that violates constitutional principles MUST be justified or simplified. Teams MUST reference this constitution for runtime development guidance and decision-making.

Constitutional violations discovered in existing code MUST be tracked and remediated according to established technical debt management processes.

**Version**: 1.0.0 | **Ratified**: 2025-09-26 | **Last Amended**: 2025-09-26