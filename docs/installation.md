# Installation

### VS Code

Add the marketplace to your settings:

```jsonc
// settings.json
"chat.plugins.marketplaces": [
    "devantler-tech/agent-plugins"
]
```

Then open **Extensions**, search `@agentPlugins`, and install a plugin from this marketplace. Review the source when VS Code asks you to trust it. See the [VS Code plugin guide](https://code.visualstudio.com/docs/agent-customization/agent-plugins).

### Copilot CLI

Run these in your terminal; `devantler-plugins` is the marketplace name registered by the first command. See the [Copilot plugin reference](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-plugin-reference).

```sh
# Register the marketplace
copilot plugin marketplace add devantler-tech/agent-plugins

# Browse available plugins
copilot plugin marketplace browse devantler-plugins

# Install a plugin
copilot plugin install gitops-kubernetes@devantler-plugins
```

### Claude Code

Add the marketplace, then install a plugin — run these inside Claude Code ([official guide](https://code.claude.com/docs/en/discover-plugins)):

```text
/plugin marketplace add devantler-tech/agent-plugins
/plugin install gitops-kubernetes@devantler-plugins
```

Browse everything on offer with `/plugin` (**Discover** tab) or list it with `/plugin list`. The bundled [`.claude-plugin/marketplace.json`](../.claude-plugin/marketplace.json) is also discovered automatically when this repo is added as a plugin source.

Claude Desktop can add the same GitHub repository from **Plugins → Personal**. That path validates the marketplace remotely in strict mode; every plugin therefore includes the canonical `.claude-plugin/plugin.json` manifest it requires.

### Any other agent — skills only, via `npx skills`

[`npx skills`](https://github.com/vercel-labs/skills) reads this repo's [`.claude-plugin/marketplace.json`](../.claude-plugin/marketplace.json) and installs the bundled **skills** into any of its 70+ supported agents — useful when your agent isn't one of the three above:

```sh
# Browse the bundled skills without installing
npx skills add devantler-tech/agent-plugins --list

# Install specific skills for a specific agent
npx skills add devantler-tech/agent-plugins --skill gitops-knowledge --agent cursor
```

> [!IMPORTANT]
> This is a **partial** install path. The example installs only `gitops-knowledge` for Cursor. Use
> `--all` to install every bundled skill across detected agents, or combine a pattern such as
> `--skill gitops-*` with `--agent cursor` to target that agent. None of these skills-only forms
> install the [MCP servers](resources.md#mcp-servers) or [custom agents](resources.md#custom-agents). To get everything a
> plugin bundles, install it as a plugin in **VS Code**, **Copilot CLI**, or **Claude Code** above —
> all three load a plugin's bundled `.mcp.json` and `agents/` automatically.


[Plugin catalogue](plugins.md) · [Bundled servers and agents](resources.md)
