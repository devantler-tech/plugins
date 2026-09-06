# Bundled servers and agents

[Plugin catalogue](plugins.md) · [Installation](installation.md)

## Copy-paste agent onboarding

The [`agentic-engineering` desired-state manifest](../plugins/agentic-engineering/resources/provider-neutral.desired-state.json)
is a provider-neutral, copy-paste onboarding document for a new assistant. Open the assistant in the
consumer repository, paste the complete JSON, and ask it to reconcile the desired state. It points to
the latest reviewed plugin for generic role logic and to the consumer's `AGENTS.md` for organization,
trust, cadence, memory, and maintainer-channel configuration. It also requires the assistant to report
unsupported native capabilities instead of silently weakening the deployment. The manifest carries
separate thin schedule prompts for the Agentic Engineer and the Agent Improver; each resolves its
cadence and deployment facts from the canonical consumer instructions. Spend stewardship has no
schedule of its own — it runs inside the engineer's loop when the consumer declares a `Spend contract`
section.
Existing installations must complete **all three** migrations, in order, before their next scheduled
run — the
[version 2 checklist](../plugins/agentic-engineering/README.md#migrating-from-automated-ai-engineer)
(plugin identity), **then** the
[version 3 checklist](../plugins/agentic-engineering/README.md#migrating-to-version-3) (retire the
`finops-engineer` schedule and adopt the `Spend contract` section), **then** the
[version 4 checklist](../plugins/agentic-engineering/README.md#migrating-to-the-agentic-engineer-entrypoint)
(the `automated-ai-engineer` → `agentic-engineer` entrypoint rename). Stopping early would resume
unattended writes with the retired FinOps schedule still armed, or with a schedule pointing at an
entrypoint that no longer resolves.

## MCP servers

A plugin may bundle [MCP](https://modelcontextprotocol.io) servers as well as skills. The
[`gitops-kubernetes`](../plugins/gitops-kubernetes/) plugin bundles the **Flux MCP server**
([`flux-operator-mcp`](https://github.com/controlplaneio-fluxcd/flux-operator/tree/main/cmd/mcp))
so its `gitops-cluster-debug` skill — which `Requires flux-operator-mcp` — can connect to a live cluster once the server binary and cluster access are configured.

The server is authored once as the plugin's [`.mcp.json`](../plugins/gitops-kubernetes/.mcp.json)
(`mcpServers` map). How each tool consumes it differs (per [ADR 0001](../docs/adr/0001-bundling-mcp-servers-and-custom-agents.md)):

- **Claude Code**, **Copilot CLI**, and **VS Code** — the bundled `.mcp.json` is loaded automatically
  when the plugin is installed. The server binary must be installed separately and have access to
  the intended cluster.

You only need to write MCP config by hand if you are **not** installing this as a plugin — then add the
server to your workspace `.vscode/mcp.json` (note the key there is `servers`, not `mcpServers`):

```json
{
  "servers": {
    "flux-operator-mcp": { "command": "flux-operator-mcp", "args": ["serve"] }
  }
}
```

Every path invokes the same `flux-operator-mcp` binary, so install it first — e.g.
`brew install controlplaneio-fluxcd/tap/flux-operator-mcp` or `go install
github.com/controlplaneio-fluxcd/flux-operator/cmd/mcp@latest` (it reads your kubeconfig from
`KUBECONFIG` / `~/.kube/config`). See the
[Flux MCP docs](https://fluxcd.control-plane.io/operator/mcp/) for read-only mode and remote
transport.

## Custom agents

A plugin may also bundle **custom agents** (subagents). The
[`gitops-kubernetes`](../plugins/gitops-kubernetes/) plugin bundles
[`flux-troubleshooter`](../plugins/gitops-kubernetes/agents/flux-troubleshooter.agent.md) — a **read-only**
Flux CD triage agent that traces the GitOps dependency chain (source → Kustomization/HelmRelease →
workloads), reads status conditions and controller logs via the bundled `flux-operator-mcp` server,
and returns a root-cause diagnosis plus the human-applied fix. It has no apply/reconcile/suspend/
delete tool by design, so it never mutates the cluster.

The agent is authored once as `agents/<name>.agent.md` (Markdown + YAML frontmatter, with the neutral
`name`/`description`/`tools`/`model` core). The `.agent.md` filename is what VS Code and Copilot
discover inside a plugin's `agents/` directory; Claude Code is filename-agnostic (it reads any
Markdown in `agents/` and takes the agent's name from frontmatter), so one file serves all three
tools. The same goes for the `tools:` allowlist: MCP tools are listed in both spellings — Claude
Code's `mcp__<server>__<tool>` and VS Code / Copilot's `<server>/<tool>` — because each tool
ignores entries it does not recognise (per
[ADR 0001](../docs/adr/0001-bundling-mcp-servers-and-custom-agents.md)):

- **Claude Code**, **Copilot CLI**, and **VS Code** — the bundled `agents/` directory is loaded
  automatically when the plugin is installed; in Claude Code the agent is namespaced
  `gitops-kubernetes:flux-troubleshooter`.

As with MCP, hand-placing an agent at `.github/agents/<name>.agent.md` is only for setups that aren't
installing this as a plugin.

The [`vibe-coding`](../plugins/vibe-coding/) plugin bundles
[`vibe-coding-companion`](../plugins/vibe-coding/agents/vibe-coding-companion.agent.md) — a plain-language
build companion for a non-technical audience (design:
[ADR 0003](../docs/adr/0003-vibe-coding-plugin-design.md)). Same delivery rules. Its guardrail requires
the consuming deployment to author a `## Stack map` section in its `AGENTS.md` (see the
[plugin README](../plugins/vibe-coding/README.md)).

The [`agentic-engineering`](../plugins/agentic-engineering/) plugin bundles three agents —
[`agentic-engineer`](../plugins/agentic-engineering/agents/agentic-engineer.agent.md) (the
autonomous portfolio-engineer actor),
[`portfolio-surveyor`](../plugins/agentic-engineering/agents/portfolio-surveyor.agent.md) (its read-only
survey subagent), and
[`agent-improver`](../plugins/agentic-engineering/agents/agent-improver.agent.md) (a meta-engineer that
improves the engineer itself from measured evidence) — alongside its engineering skills (design:
[ADR 0002](../docs/adr/0002-automated-ai-engineer-plugin-boundary.md), consolidation:
[ADR 0004](../docs/adr/0004-consolidate-agentic-engineering.md), spend stewardship:
[ADR 0005](../docs/adr/0005-merge-spend-stewardship-into-the-engineer.md)). Same delivery rules; the
consuming deployment must define the five contract sections (Portfolio map, Trust gate, Cadence,
Memory, Maintainer channels) in its `AGENTS.md` — plus **Agent definition locations** and
**Authority model** if it enables `agent-improver`, and **Spend contract** if it wants the engineer to
steward spend (see the [plugin README](../plugins/agentic-engineering/README.md)).

