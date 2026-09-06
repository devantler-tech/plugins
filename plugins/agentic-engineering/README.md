# `agentic-engineering`

The primary autonomous-engineering plugin for a repository portfolio. It carries the engineer that
operates and advances the portfolio, the read-only surveyor that gathers current state, and the
meta-engineer that improves the system from measured evidence. The generic role lives here; each
consumer supplies its organization-specific configuration through its canonical `AGENTS.md`.

Version 2 consolidates the former `automated-ai-engineer` plugin into `agentic-engineering`. The
autonomous engineering system is now the center of this plugin. From the earlier
`agentic-engineering` bundle it retains only the tool-neutral `agent-instructions` and `find-skills`
skills; the provider-specific SDK and instruction-blueprint skills were removed. See
[ADR 0004](../../docs/adr/0004-consolidate-agentic-engineering.md).

Version 3 merges spend stewardship into the primary engineer entrypoint and removes the
separate FinOps role and schedule. See
[ADR 0005](../../docs/adr/0005-merge-spend-stewardship-into-the-engineer.md).

Version 4 renames that entrypoint from `automated-ai-engineer` to `agentic-engineer`. See
[ADR 0006](../../docs/adr/0006-rename-agentic-engineer-entrypoint.md).

Version 5 requires explicit, default-off spend enablement. See
[ADR 0007](../../docs/adr/0007-explicit-spend-enablement.md).

## Migrating to version 5

The desired-state schema now requires the boolean
`spec.roles["agentic-engineer"].spendStewardshipEnabled`. Start with `false`; the presence of a
complete Spend contract does not opt a deployment in. Older documents fail validation, and the
engineer treats missing or malformed enablement as disabled while continuing ordinary engineering.

1. Refresh the complete desired-state document from the reviewed plugin revision, including its
   entrypoint digest and scheduler pointers. Keep the shipped flag `false` unless the maintainer
   explicitly enables spend stewardship.
2. Declare the path to one full effective desired-state JSON document in the consumer's
   `AGENTS.md` **Spend contract**. That document supplies the flag for every lane. If the consumer
   keeps a byte-identical upstream mirror, retain it and declare a separate full effective document
   through its native configuration; do not edit the mirror or invent a partial-override merge.
3. Reconcile the native scheduler from the updated pointers and verify preflight reports the
   effective document, boolean value, and any unresolved Spend contract prerequisites. Keep a
   disabled deployment disabled during reconciliation.

Without a declared document, preflight uses the shipped `false` default. A declared document that
cannot be read or validated also disables spend and reports the gap. Resolve the document and flag
once per run; never search unrelated settings for an enabling value or switch sources mid-run.

Only the maintainer may set the flag to literal `true`. This permits spend analysis and decisions
only when the Spend contract also resolves; it does not bypass the private decision channel,
protected-outcomes floor, or authority boundaries. Setting it back to `false` disables the cost
dimension on the next preflight. There is no additional spend schedule.

## Migrating to version 4

Version 4 renames the primary engineer's agent entrypoint from `automated-ai-engineer` to
`agentic-engineer`, so the role's identifier finally matches the name it is called by. There is no
marketplace-level migration for agent names the way there is for plugin names, so a deployment that
persists the old entrypoint keeps pointing at an agent that no longer resolves. Update three places
before the next scheduled run:

1. **Scheduler pointers** — every plugin-backed schedule that names
   `plugin:agentic-engineering/automated-ai-engineer` becomes
   `plugin:agentic-engineering/agentic-engineer`, and any bootstrap prompt that names the entrypoint
   in prose changes with it.
2. **Qualified agent references** — persisted selections such as
   `agentic-engineering:automated-ai-engineer` become `agentic-engineering:agentic-engineer`.
3. **The consumer's desired state** — `spec.source.entrypoint`, the `spec.roles` key, and the
   `spec.runtime.scheduler.schedules` key all move to `agentic-engineer`.

Sequence this **after** the version 3 migration below: retiring the `finops-engineer` schedule and
renaming the engineer's entrypoint are independent changes, and doing them one at a time keeps a
failed reconcile attributable to one cause. Nothing about the role's behaviour, contract sections, or
guardrails changes in version 4; this is a rename only.

## Migrating to version 3

The plugin name, entrypoint names, and agent set are unchanged. Two consumer-side changes are
required before the next scheduled run:

1. **Retire the `finops-engineer` schedule FIRST — before installing or reconciling v3.** Its work now
   happens inside the engineer's loop, so a surviving schedule would run a role this plugin no longer
   defines. Quiesce or atomically replace it with the runtime's native scheduler control **ahead of**
   the v3 engineer schedule: installing v3 first opens exactly the concurrent-stewardship window this
   migration exists to close, and **a briefly missed cost pass is much cheaper than two writers
   proposing against the same spend.** The cost pass is cadence-gated, not continuous, so the gap
   costs at most one pass.
2. **Rename the consumer contract section to `Spend contract`** and the desired-state key
   `spec.consumer.requiredWhenFinOpsEnabled` to
   `spec.consumer.requiredWhenSpendStewardshipEnabled` (value `["Spend contract"]`). Also delete
   `spec.roles["finops-engineer"]` and `spec.runtime.scheduler.schedules["finops-engineer"]`, and add
   the never-move-money guardrail. The validator rejects the old shape, so a stale copy fails closed
   rather than silently deploying two writers over one concern.

A consumer that keeps its FinOps definition as a separate agent is not broken by this release — but it
is no longer the shape this plugin describes. Current spend enablement follows the explicit flag and
resolving `Spend contract` described in [*Migrating to version 5*](#migrating-to-version-5).

## Migrating from `automated-ai-engineer`

Version 2 deliberately replaces the old marketplace identity instead of keeping a second alias
bundle. The marketplace's append-only rename history maps `automated-ai-engineer` to
`agentic-engineering`. Claude Code 2.1.193 and later automatically migrates the persisted installed
plugin key when the marketplace refreshes; restart Claude Code or run `/reload-plugins`, then continue
with step 2 below.

For older Claude Code versions and runtimes that do not implement marketplace rename migration,
complete the plugin-name change manually before the next scheduled run:

1. Remove the installed `automated-ai-engineer` plugin with the runtime's native plugin control, then
   install `agentic-engineering@devantler-plugins` from `devantler-tech/agent-plugins`.
2. Change persisted qualified agent references from the `automated-ai-engineer` plugin namespace to
   `agentic-engineering`. The entrypoint is renamed separately in
   [*Migrating to version 4*](#migrating-to-version-4).
3. Copy the [provider-neutral desired state](resources/provider-neutral.desired-state.json) into the
   consumer workspace and reconcile its native agents and schedules. Preserve the consumer's
   canonical `AGENTS.md`; do not copy its organization-specific facts into this plugin.
4. Before re-enabling unattended writes, verify that the installed plugin reports version `5.0.0` or
   later, so **[*Migrating to version 3*](#migrating-to-version-3),
   [*Migrating to version 4*](#migrating-to-version-4), and
   [*Migrating to version 5*](#migrating-to-version-5) must all be complete too**; a stop at `2.0.0`
   would resume writes with the retired FinOps schedule still armed, and a stop at `3.0.0` with a
   schedule pointing at an entrypoint that no longer resolves — and that it
   exposes `agentic-engineer`, `portfolio-surveyor`, and `agent-improver`, and that every
   plugin-backed schedule points to `plugin:agentic-engineering/<entrypoint>`. Run the required
   read-only preflight and record the installed source revision and any unsupported capability.

The migration is complete only after the old plugin identity no longer resolves in the runtime and
the read-only preflight loads the new namespace successfully.

## What it includes

Three agents:

- **`agentic-engineer`** — the actor that runs the survey → select → act → report loop, operates
  the portfolio, advances the oldest actionable issue, and — after explicit maintainer opt-in and a
  resolving **Spend contract** — stewards the portfolio's running cost in the same loop.
- **`portfolio-surveyor`** — a delegated, read-only agent that returns a compact current-state digest.
- **`agent-improver`** — a meta-engineer that evaluates deployed instances and improves their shared
  definition from evidence.

Six skills:

- **`portfolio-maintenance`** — the autonomous run loop and portfolio operating discipline.
- **`product-engineering`** — strategy, issue delivery, quality, performance, and secure product
  advancement.
- **`self-improvement`** — evidence-led improvement by an engineer reflecting on its own runs.
- **`agent-improvement`** — outside-in evaluation across the session corpus and deployed instances.
- **`agent-instructions`** — one canonical cross-tool instruction architecture with thin shims.
- **`find-skills`** — discovery of additional reusable skills when the current bundle is insufficient.

`self-improvement` and `agent-improvement` are complementary. The former lets one run bank and verify
its own learnings. The latter is an external observer that can identify recurrence, cross-instance
drift, and dispatch failures that no single run can see.

## Copy-paste onboarding

[`resources/provider-neutral.desired-state.json`](resources/provider-neutral.desired-state.json) is
the provider-neutral desired state for a new assistant. Copy the complete JSON document into the new
assistant while it is opened in the consumer repository. The embedded onboarding instruction tells it
to install or load this plugin, validate the consumer contract, map the roles and permissions onto its
native capabilities, reconcile two thin scheduled dispatches from `AGENTS.md`, and report any
capability it cannot safely implement.

The manifest exposes one provider-neutral bootstrap prompt for each scheduled role under
`spec.runtime.scheduler.schedules`:

- **`agentic-engineer`** loads this plugin's primary engineer entrypoint.
- **`agent-improver`** loads this plugin's meta-engineer entrypoint after verifying the additional
  definition-location and authority contract.

**Spend stewardship has no schedule of its own.** It is a dimension of the primary engineer rather
than a separate role, so the cost pass runs inside the engineer's loop on the consumer's declared
cadence. The generic mandate and its money boundaries — value per unit cost, the protected-outcomes
veto, never move money, no personalised investment advice, and no private financial data in a public
artifact — live in the entrypoint definition. The deployment's own money facts stay consumer-owned in
`AGENTS.md#Spend contract`, which is why the plugin stays portable without duplicating sensitive or
fast-changing details. See [ADR 0005](../../docs/adr/0005-merge-spend-stewardship-into-the-engineer.md).

The manifest deliberately contains no organization inventory, account identifiers, secrets, fixed
schedule, or provider-specific setup. Those facts remain in the consumer's version-controlled
`AGENTS.md`; the manifest points to them so improvements land in one canonical place and future runs
refresh the latest reviewed plugin definition before starting.

## Consumer contract

The consuming repository's canonical `AGENTS.md` must define five named sections. The agents and core
skills fail closed when any are absent:

- **Portfolio map** — repositories in scope and each product's `## Maintenance` card, including
  validate commands, labels, protected/generated files, roadmap home, and the standard
  **feature-flag mechanism** required for non-trivial feature work.
- **Trust gate** — trusted identities, reviewer-only identities, and repository merge mechanics.
- **Cadence** — run frequency, run budget, and rotation intervals.
- **Memory** — durable-store location, schema, and cross-run cursors.
- **Maintainer channels** — active decision channels, the canonical AI-disclosure line, and the
  maintainer's interactive-session marker (the literal a PR body carries when it came from the
  maintainer's own hand-driven session, so the surveyor can tell that PR from the engineer's own).

The surveyor also reads **Writer namespaces** for cross-instance claim discovery. Deployments with
expiring claims must declare their lease duration and authoritative start/renewal timestamp source
there, or link a **Claim protocol** that supplies both. Missing policy makes a claimed candidate's
actionability unknown; claim-free candidates do not require an expiration policy.

Enabling `agent-improver` adds two required sections:

- **Agent definition locations** — every definition surface it may change and whether that surface is
  version-controlled or runtime-local.
- **Authority model** — the separate boundaries for tightening and loosening prose and enforcement
  guardrails.

Enabling the engineer's spend stewardship requires literal `true` in
`spec.roles["agentic-engineer"].spendStewardshipEnabled` and **Spend contract**, which names the
single effective desired-state document,
cost evidence sources and which are actually wired, the protected-outcomes floor and who may change
it, the run procedure for a cost pass, the private channel a financial decision goes to, and the
cadence a cost pass runs on. Disabled or unresolved, the engineer runs normally with the **cost dimension failed
closed** — it does no spend analysis rather than guessing a floor, a price, or a channel.

The `Memory` section must also name the scorecard and open verification-hypothesis store used by the
improvement loop. The role/configuration boundary remains the one established by
[ADR 0002](../../docs/adr/0002-automated-ai-engineer-plugin-boundary.md): portable decision logic lives
in this plugin; consumer-owned facts live in `AGENTS.md`.

## Delivery ownership

Every write-capable role owns selected engineering work from claim through exact-head review and
merge. Discovery remains read-only, but once the primary engineer or the Agent Improver chooses an
implementable change, it does not stop at an issue, recommendation, or draft pull request. It follows
the consumer's **Trust gate**, branch-claim protocol, review gates, and merge mechanics until the work
lands. Issue-only handoff is reserved for a named external blocker or authority the consumer contract
genuinely withholds. A cost finding is no exception: the engineer drives the measurement, manifest, or
configuration pull request to merge itself, and routes only the purchase, cancellation, commitment, or
other money-moving step to the maintainer — that single step is missing authority, never a reason to
leave the surrounding engineering work undone.

## Runtime guard note

The surveyor's read-only discipline is declared in its definition, but deployments should enforce the
same boundary in their permission layer. Scheduled instances should use fresh per-run worktrees, unique
branch namespaces, least privilege, and a non-interactive execution policy. The desired-state resource
records those requirements without assuming a particular runtime.

### Enforcing the boundary: `scripts/forge-readonly-guard.sh`

[`scripts/forge-readonly-guard.sh`](scripts/forge-readonly-guard.sh) is the decision procedure that
layer calls. It answers one question about one candidate command — is this provably a read against the
source forge — and it is tool-neutral: a Claude Code `PreToolUse` hook, a Codex approval guard, and a
plain wrapper all ask it the same way.

```sh
forge-readonly-guard.sh --command '<command>'   # exit 0 allow · 1 deny (prints `deny: <reason>`) · 2 usage
<command> | forge-readonly-guard.sh --stdin
```

`forge-readonly-guard.sh --command` is the whole portable contract. A runtime whose pre-execution
interface hands you the candidate command calls the guard directly and needs nothing else.

The wrapper [`scripts/surveyor-forge-readonly.sh`](scripts/surveyor-forge-readonly.sh) exists only for
runtimes that present the candidate command as structured JSON on stdin rather than as an argument. It
is not a second classifier and not a second policy: it reads `tool_input.command` and asks
`forge-readonly-guard.sh --command`. Use it where that shape matches; call the guard directly where it
does not. A deployment that has installed neither, or has not wired one of them onto the surveyor
agent, fails closed: forge reads are `QUERY-UNKNOWN`.

#### The wiring is the consumer's, and it cannot be shipped from here

**A plugin cannot wire this onto the surveyor for you, and this plugin does not pretend to.** Two
mechanisms exist and neither reaches an agent-scoped hook from inside a plugin:

- **Plugin-wide hooks** (`hooks/hooks.json`, or inline in `plugin.json`) are auto-discovered for
  *every* agent in the plugin and cannot be scoped to one. A plugin-wide `Bash` matcher would deny the
  engineer's own write path, so this plugin deliberately ships no such file.
- **Agent-scoped hooks in agent frontmatter** are supported for project and user agents, but *not* for
  plugin-shipped ones: `hooks`, `mcpServers`, and `permissionMode` are unsupported in a plugin agent's
  frontmatter and are ignored when the agent is loaded from a plugin. Adding a `hooks:` block to
  `agents/portfolio-surveyor.agent.md` would therefore be silently inert — the appearance of
  enforcement with none of it.

So the enforcement is **consumer-side by construction**. A consumer that wants it registers the guard
at its own surveyor-only pre-execution point — for a runtime with agent frontmatter hooks, by taking
its own copy of the surveyor agent under the consumer's agent directory and adding the `PreToolUse`
`Bash` hook there. Keep the hook path out of desired-state JSON, which stays provider-neutral.

**Until a consumer does that, the deployment is incomplete for forge reads.** It must treat forge
reads as `QUERY-UNKNOWN` and must not permit them until it installs and registers a supported
surveyor-scoped read-only path. The wiring being consumer-side is a statement about *which layer
owns the mechanism* — it is not permission to run the surveyor unguarded, and the guard is not
optional defence in depth.

A consumer runtime that wires `gh` through the guard must also `export GH_TELEMETRY=0` (or `false`) in the process environment before any `gh` read. GitHub CLI 2.96.0 otherwise writes `gh/device-id` on a certified `gh api` GET. The guard denies every `gh` segment unless that export is already in the environment; putting `GH_TELEMETRY=0` on the command line is itself denied as an env-prefixed `gh`. The bundled `classify-default-branch-ci-runs.sh` helper exports `GH_TELEMETRY=0` before its remote `gh api` GET so that one compound read stays allowed.

Because the guard denies by default, run your own deployment's survey vocabulary through it before
turning it on: a read it does not yet recognise fails closed, which is the intended direction but is
better discovered deliberately than mid-run.

The sole bundled compound read is `scripts/classify-default-branch-ci-runs.sh` in remote mode. Its
provider-neutral desired-state entry pins the plugin-relative path, reviewed SHA-256, and executable
requirement. The
guard accepts only the exact classifier beside itself and only `--repo`, `--branch`, and a full
`--head-sha`; it refuses the helper's offline `--input` mode. Resolve both scripts from the same
installed, reviewed plugin directory. Preflight may supply the literal absolute classifier path.
Otherwise, one bare `classify-default-branch-ci-runs.sh` probe through the active guard is a denied
discovery request: it executes nothing and returns `classifier-path-json:` with a JSON string naming
the guard's own executable sibling. The adapter preserves this record in its denial reason and
stderr. Decode it as data, quote the decoded path as one literal shell argument, and submit the
remote-mode command through the same guard. Never evaluate the record or use JSON double quotes as
shell quoting. Missing JSON tooling, a missing executable, or an absent, malformed, ambiguous, or
unusable hint leaves classification `QUERY-UNKNOWN`; directory searches and fallback roots are not
part of discovery. The classifier captures its fixed paginated API GET in memory,
so this exception neither writes an intermediate file nor permits an arbitrary local executable.

**Three residues the guard cannot close from argv alone — the calling runtime must.** They are stated
here rather than left implicit, because a guard whose limits are undocumented gets trusted for things
it never claimed:

- **`core.pager`.** A surveyed repository can name a pager program, and git runs it only when
  standard output is a terminal. The guard refuses `--paginate` and allows `--no-pager`, but it
  cannot see whether a TTY is attached. **Run the guarded command non-interactively** (no TTY on
  stdout), which is already how a scheduled agent executes.
- **Parameter expansion.** A named expansion such as `$REPO` is allowed, so the word the shell builds
  depends on the environment the runtime provides. Positional and special parameters are refused
  precisely because they are removable, but named ones are a deliberate convenience. **Do not
  interpolate untrusted text into the environment** of the shell that runs a guarded command.
- **`GH_TELEMETRY`.** GitHub CLI's default telemetry writes `gh/device-id` before the API result
  exists. The guard denies any `gh` segment unless a disabling value (`0` or `false`) is already in
  the process environment; argv cannot carry it. **`export GH_TELEMETRY=0` before any `gh` read.**
  The bundled classifier does that before its own `gh` call. Git-only commands do not need it.

Tools that implement this marketplace's plugin layout auto-discover the `agents/` and `skills/`
directories. On surfaces without full plugin support, load the same canonical agent and skill files
from this repository; do not fork or paste copies into the consumer repository.
