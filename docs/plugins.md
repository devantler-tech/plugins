# Plugin catalogue

A **skill** teaches an assistant a task. An **agent** gives it a specialized role; an **MCP server** connects it to external tools through the Model Context Protocol.

[Install a plugin](installation.md) · [Back to the overview](../README.md)

| Plugin | Resources | Description |
|--------|-----------|-------------|
| [`gitops-kubernetes`](../plugins/gitops-kubernetes/) | `gitops-cluster-debug`, `gitops-knowledge`, `gitops-tenant-onboarding` (skills) · `flux-operator-mcp` (MCP server) · `flux-troubleshooter` (agent) | Flux CD debugging, knowledge, and tenant onboarding — bundles the Flux MCP server and a read-only Flux troubleshooter agent for live-cluster debugging |
| [`github`](../plugins/github/) | `gh-cli`, `gh-stack`, `github-actions-docs`, `github-issues` | GitHub CLI, stacked PRs, Actions docs, and issue management |
| [`agentic-engineering`](../plugins/agentic-engineering/) | `agent-improvement`, `agent-instructions`, `find-skills`, `portfolio-maintenance`, `product-engineering`, `self-improvement` (skills) · `agent-improver`, `agentic-engineer`, `portfolio-surveyor` (agents) | The autonomous engineering system for a whole repository portfolio — engineer, read-only surveyor, and meta-engineer agents plus their operating, spend, and improvement workflows; configured by the consumer's `AGENTS.md` |
| [`go`](../plugins/go/) | `golang-pro` | Go best practices, concurrency, generics, interfaces, and testing |
| [`engineering-practices`](../plugins/engineering-practices/) | `conventional-release`, `git-commit`, `refactor`, `test-driven-development`, `ways-of-working` | Git commits, conventional releases, refactoring, TDD, and engineering ways of working |
| [`frontend-design`](../plugins/frontend-design/) | `astro`, `frontend-design`, `web-design-guidelines` | Astro, frontend design, and web design guidelines |
| [`vibe-coding`](../plugins/vibe-coding/) | `needs-stack-mapping`, `allowed-stack-guardrail`, `jargon-free-voice` (skills) · `vibe-coding-companion` (agent) | Build a product by conversation alone — plain-language companion agent + guardrailed needs-to-stack skills for people with no technical background |

