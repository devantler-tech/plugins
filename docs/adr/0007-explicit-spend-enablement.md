# ADR 0007: Explicit spend enablement

## Context

The engineer's Spend contract describes deployment facts and authority boundaries. Treating the
presence of those facts as activation makes a complete onboarding document enable cost work without
a distinct maintainer choice. The shipped desired state needs an explicit disabled state that can
be validated independently of contract completeness.

## Decision

The desired-state schema requires the boolean
`spec.roles["agentic-engineer"].spendStewardshipEnabled`, shipped as `false`. Only the maintainer may
opt in by setting literal `true`; a resolving Spend contract remains a separate prerequisite.
Missing, malformed, or unreadable enablement disables spend analysis and decisions while ordinary
operate and advance engineering continues.

The consumer declares one full effective desired-state document in its Spend contract. If no
effective document is declared, use the shipped disabled default. The engineer resolves that source and value once
during preflight and keeps them fixed for the run. Consumers that retain an exact upstream mirror
declare a separate full effective document through native configuration. The plugin defines no
partial-override merge or search through arbitrary settings.

Onboarding preserves the configured value and reports its source and unresolved prerequisites. Thin
scheduler pointers refer to the same field and the engineer's canonical policy. A flag does not
relax the private-channel, protected-outcomes, or money-moving boundaries.

## Consequences

Version 5 is a breaking desired-state change: version 4 documents must add the field and refresh
their entrypoint digest and scheduler pointers. Existing spend deployments need explicit opt-in;
contract presence and historical activity do not supply it. Consumer adoption follows the merged
plugin revision, while runtime-managed caches remain the responsibility of native runtime controls.

The manifest validator accepts both boolean states and rejects missing or malformed values. Tests
also pin the actual shipped default and require both onboarding and dispatch to consume the field.
