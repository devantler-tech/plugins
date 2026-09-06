#!/usr/bin/env bash
# Validate the plugin marketplace manifests, every plugins/<name>/plugin.json, and the
# README plugin table.
#
# Single source of truth for the checks the 🧪 CI "Validate manifests" job runs:
#   1. Both marketplace manifests (Copilot + Claude) are well-formed (.name + .plugins).
#   2. The two manifests are byte-for-byte equivalent (key-sorted) — no drift.
#   3. Append-only plugin rename history resolves to a current plugin or an explicit removal.
#   4. Every plugins/<name>/plugin.json is complete and well-shaped, and has an
#      equivalent .claude-plugin/plugin.json for strict Claude ingestion.
#   5. Manifest entries and on-disk plugins are in lockstep (no missing/orphan plugin,
#      no name/description/version/source divergence).
#   6. The README plugin table and on-disk plugin resources are in lockstep (every plugin
#      has a row and vice versa; each row's Resources column matches the plugin's bundled
#      skills + MCP servers).
#   7. Ancillary *.desired-state.json onboarding resources are structurally complete,
#      provider-neutral, placeholder-free, and linked from their plugin README.
#
# Operates on the current working directory (run from the repo root, exactly as CI
# does). Documented in AGENTS.md for local runs and self-tested by
# validate-manifests.test.sh, so the gate stays a single source of truth with no
# inline/doc drift. Stops at the first failing check, mirroring the job's
# stop-on-first-failing-step behaviour.
set -euo pipefail

COPILOT_MANIFEST=".github/plugin/marketplace.json"
CLAUDE_MANIFEST=".claude-plugin/marketplace.json"
RENAME_HISTORY="scripts/marketplace-rename-history.json"
README="README.md"

# Digest helpers are shared with the desired-state digest generator, so the value this
# gate demands and the value that generator writes cannot drift apart. See
# scripts/sha256.lib.sh.
# shellcheck source=scripts/sha256.lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sha256.lib.sh"

# 1. A marketplace manifest must parse and carry both required top-level keys.
validate_marketplace_json() {
  local manifest="$1"
  if ! jq -e '.name and .plugins' "$manifest" > /dev/null 2>&1; then
    echo "::error::Invalid $manifest"
    return 1
  fi
  echo "✓ $manifest is valid"
}

# 2. The Copilot and Claude manifests must be identical once key-sorted.
validate_marketplace_parity() {
  if ! diff <(jq -S . "$COPILOT_MANIFEST") <(jq -S . "$CLAUDE_MANIFEST") > /dev/null 2>&1; then
    echo "::error::Marketplace manifests are out of sync"
    diff <(jq -S . "$COPILOT_MANIFEST") <(jq -S . "$CLAUDE_MANIFEST") || true
    return 1
  fi
  echo "✓ Marketplace manifests are in sync"
}

# 3. Claude Code persists qualified plugin names in enabledPlugins and pluginConfigs.
# Once this marketplace renames or retires a plugin, its top-level `renames` history is
# therefore a permanent compatibility contract: sources must be retired kebab-case names,
# and every chain must terminate at a current plugin or an explicit null removal. The
# append-only baseline pins every published transition so retaining some newer entry cannot
# hide the accidental deletion of an older persisted rename.
validate_marketplace_renames() {
  local manifest="$CLAUDE_MANIFEST"
  if ! jq -e '.renames | type == "object" and length > 0' "$manifest" > /dev/null; then
    echo "::error::$manifest: must declare non-empty top-level 'renames' migration history"
    return 1
  fi

  if ! jq -e 'type == "object" and length > 0' "$RENAME_HISTORY" > /dev/null 2>&1; then
    echo "::error::$RENAME_HISTORY: persisted plugin rename history must be a non-empty object"
    return 1
  fi

  if ! jq -e --slurpfile history "$RENAME_HISTORY" '
    . as $manifest
    | all($history[0] | to_entries[];
        . as $required
        | ($manifest.renames | has($required.key))
          and ($manifest.renames[$required.key] == $required.value))
  ' "$manifest" > /dev/null; then
    echo "::error::$manifest: must preserve every persisted plugin rename from $RENAME_HISTORY"
    return 1
  fi

  if ! jq -e '
    . as $root
    | ($root.plugins | map(.name)) as $active
    | all($root.renames | to_entries[];
        .key as $old
        | .value as $new
        | ($old | test("^[a-z0-9-]+$"))
          and (($active | index($old)) == null)
          and ($new == null or
            (($new | type) == "string" and ($new | test("^[a-z0-9-]+$")))))
  ' "$manifest" > /dev/null; then
    echo "::error::$manifest: rename sources must be retired kebab-case plugin names and targets must be kebab-case names or null"
    return 1
  fi

  if ! jq -e '
    . as $root
    | ($root.plugins | map(.name)) as $active
    | def resolves($name; $seen):
        if (($seen | index($name)) != null) then false
        elif ($root.renames | has($name)) then
          $root.renames[$name] as $next
          | if $next == null then true
            elif ($next | type) != "string" then false
            else resolves($next; $seen + [$name])
            end
        else (($active | index($name)) != null)
        end;
      all($root.renames | keys[]; . as $old | resolves($old; []))
  ' "$manifest" > /dev/null; then
    echo "::error::$manifest: rename chains must terminate at a current plugin or null without cycles"
    return 1
  fi

  echo "✓ Marketplace plugin rename history is valid"
}

# A bundled MCP server (ADR 0001 §D3): an .mcp.json must be valid JSON with a
# non-empty '.mcpServers' object, each server carrying a 'command' (stdio transport)
# or a 'url' (remote transport).
validate_mcp_json() {
  local mcp="$1" bad
  if ! jq -e . "$mcp" > /dev/null 2>&1; then
    echo "::error::$mcp: not valid JSON"
    return 1
  fi
  if [ "$(jq -r '(.mcpServers // {}) | length' "$mcp")" -eq 0 ]; then
    echo "::error::$mcp: '.mcpServers' must be a non-empty object"
    return 1
  fi
  bad=$(jq -r '.mcpServers | to_entries[]
    | select((.value.command // "") == "" and (.value.url // "") == "") | .key' "$mcp")
  if [ -n "$bad" ]; then
    echo "::error::$mcp: server(s) missing a 'command' (stdio) or 'url' (remote): ${bad//$'\n'/ }"
    return 1
  fi
  return 0
}

# Does a top-level key in a Markdown file's YAML frontmatter carry a non-empty value?
# Frontmatter is the block between the first two '---' lines. The value counts as present
# when it is a non-empty inline scalar (`key: value`) OR a block scalar (`key: >-` / `key: |`)
# whose following indented lines are non-blank — so a folded multi-line description satisfies
# it. An empty, quoted-empty (`""`/`''`), comment-only (`# …`), or bare-block-indicator value
# with no body is rejected, and a file with no frontmatter yields no match. Staying awk-only
# (no yq dependency), mirroring validate_skill_provenance.
frontmatter_has_value() {
  local file="$1" key="$2"
  awk -v key="$key" '
    NR==1 && $0 !~ /^---[[:space:]]*$/ { exit 1 }         # no frontmatter ⇒ absent
    /^---[[:space:]]*$/ { fm++; if (fm==2) exit(found?0:1); next }
    fm!=1 { next }
    $0 ~ "^" key ":" {                                     # our top-level key
      inkey=1
      v=$0; sub("^" key ":[[:space:]]*","",v)             # drop the key
      sub(/[[:space:]]+#.*$/,"",v)                         # drop trailing " # comment"
      if (v ~ /^#/) v=""                                   # whole value is a comment ⇒ null
      gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/,"",v) # trim spaces + surrounding quotes
      if (v ~ /^[|>][0-9+-]*$/) v=""                       # bare block-scalar indicator ⇒ body decides
      if (v != "") { found=1; inkey=0 }
      next
    }
    /^[^[:space:]]/ { inkey=0; next }                      # another top-level key closes scope
    inkey && /[^[:space:]]/ { found=1; inkey=0 }           # indented non-blank body of a block scalar
    END { exit(found?0:1) }
  ' "$file"
}

# A bundled custom-agents resource (ADR 0001 §D1/§D3): an agents/ directory must hold at least
# one agents/*.agent.md, and every agent file must carry YAML frontmatter with a non-empty 'name'
# and 'description' (the neutral cross-tool core). The .agent.md suffix is REQUIRED — it is the
# discovery pattern VS Code and Copilot CLI use, while Claude Code is filename-agnostic, so a bare
# .md agent would pass CI yet be invisible on two of the three supported tools. A body-only or
# placeholder file is rejected.
validate_agent_dir() {
  local dir="$1" md count=0 failed=0
  for md in "$dir"/*.md; do
    [ -e "$md" ] || continue
    count=$((count + 1))
    case "$md" in
      *.agent.md) ;;
      *)
        echo "::error::$md: agent files must use the <name>.agent.md suffix (VS Code/Copilot discovery; bare .md is invisible there)"
        failed=1
        continue
        ;;
    esac
    if ! frontmatter_has_value "$md" name; then
      echo "::error::$md: agent must declare a non-empty 'name' in its YAML frontmatter"
      failed=1
    fi
    if ! frontmatter_has_value "$md" description; then
      echo "::error::$md: agent must declare a non-empty 'description' in its YAML frontmatter"
      failed=1
    fi
  done
  if [ "$count" -eq 0 ]; then
    echo "::error::$dir: must contain at least one agents/*.agent.md"
    return 1
  fi
  return "$failed"
}

# 4. Every plugins/<name>/plugin.json is complete and well-shaped, has an equivalent
#    .claude-plugin/plugin.json for strict Claude marketplace ingestion, and declares
#    at least one recognized resource (skills/, a bundled .mcp.json, or agents/) —
#    ADR 0001 §D3.
validate_plugin_json() {
  local failed=0
  local pj plugin_dir claude_pj ok plugin_name resource_count
  for pj in plugins/*/plugin.json; do
    plugin_dir=$(dirname "$pj")
    claude_pj="$plugin_dir/.claude-plugin/plugin.json"
    ok=1
    resource_count=0
    if ! jq -e 'type == "object"' "$pj" > /dev/null 2>&1; then
      echo "::error::Invalid $pj"
      failed=1
      continue
    fi
    plugin_name=$(jq -r '.name // ""' "$pj")
    if ! echo "$plugin_name" | grep -qE '^[a-z0-9-]+$'; then
      echo "::error::$pj: name '$plugin_name' must be kebab-case (a-z, 0-9, hyphens)"
      ok=0
    fi
    if [ "$(jq -r '.description // "" | length' "$pj")" -eq 0 ]; then
      echo "::error::$pj: missing or empty 'description' field"
      ok=0
    fi
    if [ "$(jq -r '.version // "" | length' "$pj")" -eq 0 ]; then
      echo "::error::$pj: missing or empty 'version' field"
      ok=0
    fi
    # Claude Desktop's remote marketplace service validates sourced plugins in strict
    # mode and requires the canonical .claude-plugin/plugin.json path. Copilot/VS Code
    # consume the portable top-level plugin.json, so keep both normalized JSON documents
    # equivalent rather than letting either provider receive a divergent contract.
    if [ ! -f "$claude_pj" ]; then
      echo "::error::$plugin_dir requires .claude-plugin/plugin.json for strict Claude marketplace ingestion"
      ok=0
    elif ! jq -e 'type == "object"' "$claude_pj" > /dev/null 2>&1; then
      echo "::error::Invalid $claude_pj"
      ok=0
    elif ! diff -u <(jq -S . "$pj") <(jq -S . "$claude_pj") > /dev/null; then
      echo "::error::$claude_pj differs from $pj"
      ok=0
    fi
    # Component-path fields (skills/agents), when present, MUST be arrays. Claude Code rejects
    # the bare-string form ('"skills": "skills/"' → 'skills: Invalid input'), which breaks
    # 'claude plugin install' even though Copilot CLI tolerates it. Both tools auto-discover
    # the default skills/ and agents/ dirs when the field is omitted, so omitting it is the
    # portable form and what these plugins do — this guard just stops the broken string form
    # from returning.
    for field in skills agents; do
      if [ "$(jq -e --arg f "$field" 'has($f)' "$pj")" = "true" ] \
        && [ "$(jq -r --arg f "$field" '.[$f] | type' "$pj")" != "array" ]; then
        echo "::error::$pj: '$field' must be an array of paths, or omitted to auto-discover $field/ (Claude Code rejects the bare-string form)"
        ok=0
      fi
    done
    # Skills resource (ADR 0001 §D3): auto-discovered from the on-disk skills/ directory —
    # both tools default to skills/ when the manifest omits the field — so detection is
    # directory-based, not field-based. A skills/ dir must hold >=1 <skill>/SKILL.md to count.
    if find "$plugin_dir/skills" -mindepth 2 -maxdepth 2 -name SKILL.md -print -quit 2>/dev/null | grep -q .; then
      resource_count=$((resource_count + 1))
    elif [ -d "$plugin_dir/skills" ]; then
      echo "::error::$plugin_dir: 'skills/' present but contains no <skill>/SKILL.md"
      ok=0
    fi
    # MCP resource: a bundled .mcp.json at the plugin root must validate.
    if [ -f "$plugin_dir/.mcp.json" ]; then
      if validate_mcp_json "$plugin_dir/.mcp.json"; then
        resource_count=$((resource_count + 1))
      else
        ok=0
      fi
    fi
    # Custom-agents resource: an agents/ directory with at least one valid agents/*.md
    # (each carrying name + description frontmatter — ADR 0001 §D3).
    if find "$plugin_dir/agents" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
      if validate_agent_dir "$plugin_dir/agents"; then
        resource_count=$((resource_count + 1))
      else
        ok=0
      fi
    fi
    if [ "$resource_count" -eq 0 ]; then
      echo "::error::$plugin_dir: must declare at least one resource (skills/, .mcp.json, or agents/)"
      ok=0
    fi
    if [ "$ok" -eq 1 ]; then
      echo "✓ $pj ($plugin_name)"
    else
      failed=1
    fi
  done
  return "$failed"
}

# 5. Manifest entries and on-disk plugins are in lockstep.
validate_marketplace_plugins_parity() {
  local failed=0
  local manifest="$CLAUDE_MANIFEST"
  local name description version source ok pj
  # Every plugin entry in the manifest resolves to a matching plugins/<name>/ on disk.
  while IFS=$'\t' read -r name description version source; do
    ok=1
    if [ "$source" != "./plugins/$name" ]; then
      echo "::error::$manifest: plugin '$name' source '$source' must be './plugins/$name'"
      ok=0
    fi
    pj="plugins/$name/plugin.json"
    if [ ! -f "$pj" ]; then
      echo "::error::$manifest: plugin '$name' has no $pj on disk"
      failed=1
      continue
    fi
    if [ "$(jq -r '.name' "$pj")" != "$name" ]; then
      echo "::error::$pj: name does not match manifest entry '$name'"
      ok=0
    fi
    if [ "$(jq -r '.description' "$pj")" != "$description" ]; then
      echo "::error::$pj: description differs from manifest entry '$name'"
      ok=0
    fi
    if [ "$(jq -r '.version' "$pj")" != "$version" ]; then
      echo "::error::$pj: version differs from manifest entry '$name'"
      ok=0
    fi
    if [ "$ok" -eq 1 ]; then
      echo "✓ $name ↔ $pj"
    else
      failed=1
    fi
  done < <(jq -r '.plugins[] | [.name, .description, .version, .source] | @tsv' "$manifest")
  # Every plugins/<name>/ on disk appears in the manifest (no orphan plugin).
  for pj in plugins/*/plugin.json; do
    name=$(jq -r '.name' "$pj")
    if ! jq -e --arg n "$name" '.plugins[] | select(.name == $n)' "$manifest" > /dev/null; then
      echo "::error::plugins/$name is not listed in $manifest"
      failed=1
    fi
  done
  return "$failed"
}

# Resource token names (sorted, space-separated) a plugin bundles, across ALL three
# resource kinds validate_plugin_json accepts (ADR 0001 §D3): every skill directory under
# plugins/<name>/skills/, every MCP server key in an optional plugins/<name>/.mcp.json, AND
# every custom-agent entry under an optional plugins/<name>/agents/ (its basename, with a
# trailing .agent.md — VS Code's discovery suffix, ADR 0001's 2026-07-18 correction — or bare
# .md stripped). These are the tokens the README "Resources" column must list.
# Count EVERY skill directory / agent entry, not only those already fleshed out, so a
# stray/half-added folder (the exact drift this parity check guards against) is surfaced
# rather than silently hidden. Kept in lockstep with validate_plugin_json's resource model
# so a plugin can never satisfy that check with a resource kind this enumerator ignores.
plugin_disk_resources() {
  local name="$1" d b mcp="plugins/$1/.mcp.json"
  {
    for d in "plugins/$name/skills"/*/; do
      [ -d "$d" ] || continue
      basename "$d"
    done
    if [ -f "$mcp" ]; then
      jq -r '.mcpServers // {} | keys[]' "$mcp"
    fi
    for d in "plugins/$name/agents"/*; do
      [ -e "$d" ] || continue
      b="$(basename "$d" .md)"
      printf '%s\n' "${b%.agent}"
    done
  } | sort | tr '\n' ' '
}

# 6. The README plugin table and on-disk plugin resources are in lockstep.
#    Table rows look like:
#      | [`<name>`](plugins/<name>/) | `skill-a`, `mcp-server-b` | <editorial description> |
#    The Resources column lists every bundled skill AND MCP server; the Description
#    column stays free prose (plugin.json↔manifest already guards it).
# The backticks below are literal table-cell markers in regex/sed patterns, not command
# substitution — SC2016 (won't-expand) is a false positive here.
# shellcheck disable=SC2016
validate_readme_parity() {
  local failed=0
  local line name readme_resources disk_resources
  local readme_names=()
  # Each README plugin row: parse the plugin name (col 1) and its Resources column (col 3).
  while IFS= read -r line; do
    name=$(printf '%s' "$line" | sed -nE 's/^\| \[`([a-z0-9-]+)`\].*/\1/p')
    [ -z "$name" ] && continue
    readme_names+=("$name")
    readme_resources=$(printf '%s' "$line" | awk -F'|' '{print $3}' \
      | grep -oE '`[a-z0-9-]+`' | tr -d '`' | sort | tr '\n' ' ')
    # Require the manifest, not just the directory: a stray plugins/<name>/ without a
    # plugin.json would otherwise pass here yet stay invisible to the orphan scan below
    # (which only iterates plugins/*/plugin.json).
    if [ ! -f "plugins/$name/plugin.json" ]; then
      echo "::error::$README lists plugin '$name' with no plugins/$name/plugin.json on disk"
      failed=1
      continue
    fi
    disk_resources=$(plugin_disk_resources "$name")
    if [ "$readme_resources" != "$disk_resources" ]; then
      echo "::error::$README Resources for '$name' (${readme_resources% }) differ from on-disk resources (${disk_resources% })"
      failed=1
    else
      echo "✓ $README ↔ plugins/$name (resources: ${disk_resources% })"
    fi
  done < <(grep -E '^\| \[`[a-z0-9-]+`\]' "$README")
  # Every plugins/<name>/ on disk appears as a README row (no plugin missing from the table).
  local pj listed rn
  for pj in plugins/*/plugin.json; do
    name=$(jq -r '.name' "$pj")
    listed=0
    for rn in "${readme_names[@]}"; do
      [ "$rn" = "$name" ] && listed=1 && break
    done
    if [ "$listed" -eq 0 ]; then
      echo "::error::plugins/$name is not listed in the $README plugin table"
      failed=1
    fi
  done
  return "$failed"
}

# 7. A copy-paste desired-state resource is ancillary deployment wiring: plugin runtimes do
#    not auto-discover it like skills, MCP servers, or agents, but it ships in the plugin
#    directory for a human to paste into any assistant. Keep the contract deliberately small
#    and provider-neutral. The generic role remains in the plugin; this document only tells a
#    new runtime how to load that role and resolve deployment facts from the consumer AGENTS.md.
validate_desired_state_resources() {
  local failed=0 resource_failed resource kind plugin_dir plugin_name readme basename entrypoint
  local schedule_source schedule_plugin schedule_agent runtime_asset runtime_asset_sha
  local runtime_asset_executable actual_asset_sha
  local plugin_root runtime_asset_dir resolved_asset asset_parent asset_component asset_component_path
  local parent_linked
  local -a asset_components
  local entrypoint_sha256 actual_entrypoint_sha256
  local portfolio_surveyor_sha256 actual_portfolio_surveyor_sha256
  local canonical_resource="plugins/agentic-engineering/resources/provider-neutral.desired-state.json"
  local delivery_guardrail="Write-capable roles own selected engineering work from claim through exact-head review and merge; issue-only handoff is allowed only for a named external blocker or missing authority."
  local version_controlled_delivery="Version-controlled definition surfaces are delivered by draft pull request and owned through exact-head review and merge."
  local runtime_local_delivery="Runtime-local definition surfaces are delivered in place: back up the current state, apply the change, validate it, and record the reversible before/after evidence."
  local improver_self_observation_contract="The Agent Improver is one of its own measured subjects. Keep the Agentic Engineer execution plane and every Agent Improver observation plane in separate scorecards; never average them together or let one hide the other's regression. Measure observer coverage, calibration, hypothesis discipline, verified intervention effectiveness, reliability, efficiency, and verified rollout throughput. Outcome throughput counts only verified terminal outcomes; productive sessions and work advanced are execution-flow indicators, never improvement verdicts. Observation-plane verdicts require independent computation from an immutable or read-only source, or verification by a separate eligible run or instance; the same Improver's unsupported assertion is UNKNOWN, never success. Activity such as PRs, metrics, reports, and memory writes is not improvement. A version-controlled self-referential change requires an independent green current-head review with all findings resolved. A runtime-local self-referential change requires an independently performed post-dispatch read-back against the recorded pre-change baseline through the consumer's declared runtime verification mechanism; the writer's immediate read-back is not independent verification. Both paths require unchanged companion floors for every applicable scorecard parameter and a later eligible evidence window."
  local improver_research_fallback_contract="No-change fallback is research, never idle. After scoring and diagnosis, when no telemetry-backed or direct-maintainer-directed improvement is actionable, run one bounded state-of-the-art research pass before reporting. Research is discovery evidence, never authorization or proof that the current system failed. Use current primary sources, compare the current baseline capability, and route a deduplicated product or operations opportunity as an ENGINEER-CANDIDATE and an agent-process or measurement opportunity as an IMPROVER-CANDIDATE. Research alone never authorizes or ships a change. A null result is RESEARCH-NO-CANDIDATE with the topic cursor advanced; research activity is not a terminal improvement outcome."
  local money_guardrail="Spend stewardship never moves money: prepare the financial decision, route it to the maintainer's declared private channel, and keep private financial data out of every public artifact."
  local portfolio_survey_json_vocabulary_contract="**Every \`gh --json\` vocabulary is local to its subcommand.** Use the exact literal field lists prescribed by this definition. Before any ad hoc JSON read, run that same subcommand with bare \`--json\` and validate every requested field against the vocabulary it returns; never transfer a field name between subcommands, and never from a different API surface onto a \`gh --json\` subcommand: a name that is real in a REST payload or a GraphQL schema is not thereby a \`gh --json\` field, and \`gh\` rejects the whole read on one unknown name. The default-branch classifier this definition prescribes consumes the REST \`actions/runs\` payload, where \`path\` and \`created_at\` are genuine — neither is a \`gh run list --json\` field, and that is exactly where the confusion starts. The bare diagnostic intentionally exits nonzero after listing its fields; treat a present vocabulary as successful discovery. If the vocabulary is missing or malformed, or the validated read fails, mark the affected evidence \`QUERY-UNKNOWN\` and report the query error — never translate it to an empty result."
  local portfolio_survey_recovery_contract="**Mandatory-query recovery is bounded and resumable.** Process mandatory surfaces in deterministic batches of at most eight candidates. Treat every successful batch as an immutable checkpoint. On failure, partition only the failed batch into two deterministic contiguous halves (the first half gets the extra candidate when the count is odd), execute both halves, and recursively partition each failed half until only failed singleton candidates remain. Never re-run a successful half. Continue unaffected batches and mark only failed singleton candidates \`QUERY-UNKNOWN\`; never discard completed evidence or collapse it into portfolio-wide \`QUERY-UNKNOWN\`."
  local portfolio_survey_global_failure_contract="Known candidate-independent failures—exhausted query budget, invalid authentication, or a forge-wide transport failure—must fail the affected mandatory surface closed immediately without splitting. Partition only candidate-specific, shape-specific, or partial failures."
  local portfolio_survey_head_revalidation_contract="Before emitting any PR disposition, re-read every checkpointed candidate's current head OID. If it changed, discard only that candidate's stale checkpoint and refresh its mandatory evidence; if refresh fails, emit \`NEEDS-FIX\` with \`QUERY-UNKNOWN\`. Never emit \`CLEAR\`, \`REVIEW-READY\`, or \`MERGE-READY\` from evidence bound to a superseded head."
  local portfolio_survey_maintainer_control_contract="Authenticated maintainer controls are mandatory evidence, not optional enrichment. Collect exact-login, non-AI-disclosed maintainer comments for every ownership-gated PR or Advance candidate before classifying or ranking it; a failed control-channel query makes only that candidate \`QUERY-UNKNOWN\`."
  local portfolio_survey_fail_closed_contract="An incomplete candidate can never be classified clean: no \`CLEAR\`, \`MERGE-READY\`, \`REVIEW-READY\`, or \"no signal\"."
  local portfolio_survey_disclosure_contract="**\`disclosure\` is three-valued and matched by WHICH literal appears, never by where it sits.** Emit exactly one of \`routine\`, \`interactive\`, or \`none\`: \`routine\` when the body carries the deployment's AI-disclosure prefix (match the **structural** prefix the consumer contract defines, never a specific actor word — roles get renamed, and a matcher keyed to one spelling silently reclassifies everything written under the others); \`interactive\` when it carries the deployment's declared interactive-session marker (declared beside the AI-disclosure prefix in **Maintainer channels**; a contract that declares no such marker cannot yield \`interactive\`, so report that gap and emit \`none\` — never guess a literal); and \`none\` when it carries neither, which is genuinely unknown — never a synonym for the maintainer's and never a synonym for the orchestrator's own. Match both literals as a **structural line anywhere in the body**: a line whose content, after leading whitespace and any blockquote \`>\` or list \`-\`/\`*\` markers, begins with the marker (an optional 🤖 may precede it). Never a bare substring, and never anchored to the body start — an interactive marker can be the last line and a routine disclosure can sit under a template heading, so a leads-with test reports \`none\` for both and cannot tell them apart. A marker line counts wherever it appears, **including inside a fenced code block — there is deliberately no fence suppression.** A fence detector is unbounded to specify (an unclosed fence, a nested fence, a blockquoted close token, an indented code block, a backtick inside an info string, a raw HTML block), and every container spelling it must skip is another way for it to swallow a real marker; measured across 1029 PR bodies in a consuming deployment (2026-08-11), a delimiter-aware fence state machine changed zero verdicts. The accepted cost is the cheap direction — a body that fences an example of the interactive literal classifies \`interactive\`, which costs a steer the maintainer can repeat — while a real marker swallowed by a mis-parsed fence would read the maintainer's own commentary as an instruction. When both literals appear, **\`interactive\` wins**. The two values carry asymmetric weight: \`interactive\` is decisive on its own, while \`routine\` only corroborates the orchestrator's creation record, because the routine prefix also appears on maintainer-interactive PRs. The field tells the orchestrator whose control channel a maintainer-login comment on that PR is; it never decides whether the PR may be driven."
  local portfolio_survey_disclosure_row="disclosure=<routine|interactive|none>"
  # Pinned separately from the ownership row above: a bare-token search passes while the
  # merged-PR channel silently loses the field, since the two rows carry the same token.
  local portfolio_survey_comment_disclosure_row="CANDIDATE-MAINTAINER-COMMENT <repo> #<n> (draft?, merged?) — disclosure=<routine|interactive|none>"
  local portfolio_survey_call_shape_contract="**Every forge read is one command in one call.** The read-only guard refuses on shape before it ever inspects intent: output redirection, \`;\`, \`&\`, \`&&\`, a newline, command substitution, and any leading program that is neither a forge command nor a reviewed helper this definition names are all denied, so an ordinary shell idiom silently costs the read. Emit exactly one forge command per call and reduce it in-band with \`--paginate\` and \`--jq\`, or a pipe into the allowlisted read-only filters; never redirect to a scratch file. Sweep repositories with one call per repository or one org-wide search, never a \`for\` loop. Take every timestamp from a payload you already read, never from \`date\`. Select with \`--jq\` rather than \`grep -oE\` or \`xargs\`. A shape denial is a lost read that reads exactly like no evidence: mark the affected evidence \`QUERY-UNKNOWN\` and reissue in the admitted shape — never work around the guard."
  local portfolio_survey_classifier_argv_contract="**Invoke the classifier only in its flag form, by its resolved installed path:** \`<installed plugin>/scripts/classify-default-branch-ci-runs.sh --repo OWNER/REPO --branch BRANCH --head-sha FULL_SHA\`. The helper and the read-only guard accept nothing else: the guard admits only that exact installed sibling path — never a bare basename, a \`PATH\` lookup, or a relative \`../scripts/\` form — and a positional \`OWNER/REPO BRANCH SHA\` is denied as \`not the guarded remote-mode shape\` while the helper itself exits 2 on it, so the first invocation must already carry the resolved path and all three flags."

  if [ -d plugins/agentic-engineering ]; then
    if [ ! -f "$canonical_resource" ]; then
      echo "::error::$canonical_resource: missing canonical agentic desired-state resource"
      failed=1
    elif jq -e . "$canonical_resource" > /dev/null 2>&1 \
      && ! jq -e '.kind == "AgenticEngineeringDesiredState"' "$canonical_resource" > /dev/null; then
      echo "::error::$canonical_resource: canonical agentic desired-state resource must use kind AgenticEngineeringDesiredState"
      failed=1
    fi
  fi

  while IFS= read -r resource; do
    resource_failed=0
    if ! jq -e . "$resource" > /dev/null 2>&1; then
      echo "::error::$resource: not valid JSON"
      failed=1
      resource_failed=1
      continue
    fi

    plugin_dir=$(dirname "$(dirname "$resource")")
    plugin_name=$(basename "$plugin_dir")
    readme="$plugin_dir/README.md"
    basename=$(basename "$resource")

    if [ ! -f "$plugin_dir/plugin.json" ]; then
      echo "::error::$resource: $plugin_dir has no plugin.json; desired-state resources must belong to a manifested plugin"
      failed=1
      continue
    fi

    if ! jq -e '.kind | type == "string" and length > 0' "$resource" > /dev/null; then
      echo "::error::$resource: desired-state kind must be a non-empty string"
      failed=1
      resource_failed=1
      continue
    fi
    kind=$(jq -r '.kind' "$resource")

    if [ "$kind" != "AgenticEngineeringDesiredState" ]; then
      echo "::error::$resource: unsupported desired-state kind $kind"
      failed=1
      continue
    fi

    if ! jq -e '
      .spec.source.providerPolicy == "neutral"
      and ([
        .. | objects | keys[] | ascii_downcase
        | select((contains("provider") or contains("vendor")) and . != "providerpolicy")
      ] | length == 0)
    ' "$resource" > /dev/null; then
      echo "::error::$resource: must declare neutral provider policy without provider or vendor fields"
      failed=1
      resource_failed=1
    fi

    if ! jq -e '
      [
        .. | strings | ascii_downcase
        | select(test("(^|[^a-z0-9])(anthropic|claude|openai|chatgpt|codex|copilot|gemini)([^a-z0-9]|$)"))
      ] | length == 0
    ' "$resource" > /dev/null; then
      echo "::error::$resource: desired-state values must not name a specific provider"
      failed=1
      resource_failed=1
    fi

    if grep -Eiq '<[^>]+>|TODO|CHANGEME|REPLACE_ME|YOUR_ORG|\{\{[^}]+\}\}|__[A-Z][A-Z0-9_]*__|\[INSERT [^]]+\]|\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Z_][A-Z0-9_]*' "$resource"; then
      echo "::error::$resource: must be copy-paste ready with no unresolved placeholders"
      failed=1
      resource_failed=1
    fi

    if [ ! -f "$readme" ] || ! grep -qF "](resources/$basename)" "$readme"; then
      echo "::error::$resource: must be linked from $readme"
      failed=1
      resource_failed=1
    fi

    entrypoint=$(jq -r '.spec.source.entrypoint // ""' "$resource")

    if [ "$entrypoint" != "agentic-engineer" ] \
      || [ ! -f "$plugin_dir/agents/$entrypoint.agent.md" ]; then
      echo "::error::$resource: entrypoint must resolve to the bundled agentic-engineer agent"
      failed=1
      resource_failed=1
    fi

    while IFS=$'\t' read -r runtime_asset runtime_asset_sha runtime_asset_executable; do
      [ -n "$runtime_asset" ] || continue
      case "$runtime_asset" in
        /* | .. | ../* | */../* | */..)
          echo "::error::$resource: required runtime asset must be a plugin-relative path: $runtime_asset"
          failed=1
          resource_failed=1
          continue
          ;;
      esac
      if [ "$runtime_asset_executable" != "true" ]; then
        echo "::error::$resource: required runtime asset executable must be true: $runtime_asset"
        failed=1
        resource_failed=1
        continue
      fi
      if [ ! -f "$plugin_dir/$runtime_asset" ] \
        || [ -L "$plugin_dir/$runtime_asset" ] \
        || [ ! -x "$plugin_dir/$runtime_asset" ]; then
        echo "::error::$resource: required runtime asset is missing, linked, or not executable: $runtime_asset"
        failed=1
        resource_failed=1
        continue
      fi
      plugin_root=$(cd -P "$plugin_dir" && pwd -P)
      if ! runtime_asset_dir=$(cd -P "$(dirname "$plugin_dir/$runtime_asset")" 2>/dev/null && pwd -P); then
        echo "::error::$resource: required runtime asset parent cannot be resolved: $runtime_asset"
        failed=1
        resource_failed=1
        continue
      fi
      resolved_asset="$runtime_asset_dir/$(basename "$runtime_asset")"
      case "$resolved_asset" in
        "$plugin_root"/*) ;;
        *)
          echo "::error::$resource: required runtime asset resolves outside its plugin: $runtime_asset"
          failed=1
          resource_failed=1
          continue
          ;;
      esac
      asset_parent=${runtime_asset%/*}
      if [ "$asset_parent" != "$runtime_asset" ]; then
        IFS='/' read -r -a asset_components <<< "$asset_parent"
        asset_component_path="$plugin_dir"
        parent_linked=0
        for asset_component in "${asset_components[@]}"; do
          if [ -z "$asset_component" ] || [ "$asset_component" = "." ]; then
            continue
          fi
          asset_component_path="$asset_component_path/$asset_component"
          if [ -L "$asset_component_path" ]; then
            echo "::error::$resource: required runtime asset parent path is linked: $runtime_asset"
            failed=1
            resource_failed=1
            parent_linked=1
            break
          fi
        done
        [ "$parent_linked" -eq 0 ] || continue
      fi
      if ! printf '%s\n' "$runtime_asset_sha" | grep -Eq '^[a-f0-9]{64}$'; then
        echo "::error::$resource: required runtime asset sha256 must be a lowercase SHA-256 digest: $runtime_asset"
        failed=1
        resource_failed=1
        continue
      fi
      actual_asset_sha=$(sha256_bytes "$plugin_dir/$runtime_asset")
      if [ "$runtime_asset_sha" != "$actual_asset_sha" ]; then
        echo "::error::$resource: required runtime asset digest does not match: $runtime_asset"
        failed=1
        resource_failed=1
      fi
    done < <(jq -r '
      .spec.source.requiredRuntimeAssets[]?
      | [(.path // ""), (.sha256 // ""), (.executable // "")]
      | @tsv
    ' "$resource")

    # This is a content-integrity and review gate, not a natural-language semantic parser:
    # the canonical block pins the required rule, while the digest makes every other
    # entrypoint edit visible as a coordinated desired-state change. Ignore checkout-only
    # CRLF conversion so the committed LF digest remains portable without hiding
    # a content-changing lone carriage return.
    entrypoint_sha256=$(jq -r '.spec.source.entrypointSha256 // ""' "$resource")
    if ! printf '%s\n' "$entrypoint_sha256" | grep -Eq '^[a-f0-9]{64}$'; then
      echo "::error::$resource: entrypointSha256 must be a lowercase SHA-256 digest"
      failed=1
      resource_failed=1
    elif [ -f "$plugin_dir/agents/$entrypoint.agent.md" ]; then
      actual_entrypoint_sha256=$(sha256_file "$plugin_dir/agents/$entrypoint.agent.md")
      if [ "$entrypoint_sha256" != "$actual_entrypoint_sha256" ]; then
        echo "::error::$resource: entrypoint digest must match the bundled agent"
        failed=1
        resource_failed=1
      fi
    fi

    portfolio_surveyor_sha256=$(
      jq -r '.spec.roles["portfolio-surveyor"].definitionSha256 // ""' "$resource"
    )
    if ! printf '%s\n' "$portfolio_surveyor_sha256" | grep -Eq '^[a-f0-9]{64}$'; then
      echo "::error::$resource: portfolioSurveyor definitionSha256 must be a lowercase SHA-256 digest"
      failed=1
      resource_failed=1
    elif [ -f "$plugin_dir/agents/portfolio-surveyor.agent.md" ]; then
      actual_portfolio_surveyor_sha256=$(
        sha256_file "$plugin_dir/agents/portfolio-surveyor.agent.md"
      )
      if [ "$portfolio_surveyor_sha256" != "$actual_portfolio_surveyor_sha256" ]; then
        echo "::error::$resource: portfolio-surveyor digest must match the bundled agent"
        failed=1
        resource_failed=1
      fi
    fi

    agent_improver_sha256=$(
      jq -r '.spec.roles["agent-improver"].definitionSha256 // ""' "$resource"
    )
    if ! printf '%s\n' "$agent_improver_sha256" | grep -Eq '^[a-f0-9]{64}$'; then
      echo "::error::$resource: agentImprover definitionSha256 must be a lowercase SHA-256 digest"
      failed=1
      resource_failed=1
    elif [ -f "$plugin_dir/agents/agent-improver.agent.md" ]; then
      actual_agent_improver_sha256=$(
        sha256_file "$plugin_dir/agents/agent-improver.agent.md"
      )
      if [ "$agent_improver_sha256" != "$actual_agent_improver_sha256" ]; then
        echo "::error::$resource: agent-improver digest must match the bundled agent"
        failed=1
        resource_failed=1
      fi
    fi

    agent_improvement_skill="$plugin_dir/skills/agent-improvement/SKILL.md"
    agent_improvement_skill_sha256=$(
      jq -r '.spec.roles["agent-improver"].skillSha256 // ""' "$resource"
    )
    if ! printf '%s\n' "$agent_improvement_skill_sha256" | grep -Eq '^[a-f0-9]{64}$'; then
      echo "::error::$resource: agentImprover skillSha256 must be a lowercase SHA-256 digest"
      failed=1
      resource_failed=1
    elif [ ! -f "$agent_improvement_skill" ]; then
      echo "::error::$resource: agent-improvement skill digest must resolve to the bundled skill"
      failed=1
      resource_failed=1
    else
      actual_agent_improvement_skill_sha256=$(sha256_file "$agent_improvement_skill")
      if [ "$agent_improvement_skill_sha256" != "$actual_agent_improvement_skill_sha256" ]; then
        echo "::error::$resource: agent-improvement skill digest must match the bundled skill"
        failed=1
        resource_failed=1
      fi
    fi

    if ! jq -e '
      .spec.source.marketplace == "devantler-tech/agent-plugins"
      and .spec.source.updatePolicy == "latest-reviewed-default-branch"
    ' "$resource" > /dev/null; then
      echo "::error::$resource: marketplace and update policy must use the reviewed canonical source"
      failed=1
      resource_failed=1
    fi

    if ! jq -e '
      def nonempty_string: type == "string" and length > 0;
      (.metadata.description | nonempty_string)
      and (.spec.source.marketplace | nonempty_string)
      and (.spec.source.entrypoint | nonempty_string)
      and (.spec.source.updatePolicy | nonempty_string)
      and (.spec.runtime.execution.branchNamespace | nonempty_string)
      and (.spec.onboarding.copyPasteInstruction | nonempty_string)
      and (.spec.onboarding.steps | type == "array" and length > 0
        and all(.[]; nonempty_string))
    ' "$resource" > /dev/null; then
      echo "::error::$resource: text fields must be non-empty strings"
      failed=1
      resource_failed=1
    fi

    if ! jq -e '
      def nonempty_string: type == "string" and length > 0;
      ([
        .metadata.description,
        .spec.source.marketplace,
        .spec.source.plugin,
        .spec.source.entrypoint,
        .spec.source.updatePolicy,
        .spec.source.providerPolicy,
        .spec.source.refreshTiming,
        .spec.consumer.canonicalInstructions,
        .spec.consumer.repositoryResolution,
        .spec.consumer.organizationScopeFrom,
        .spec.roles["agentic-engineer"].mode,
        .spec.roles["portfolio-surveyor"].mode,
        .spec.roles["agent-improver"].enabledWhen,
        .spec.roles["agent-improver"].mode,
        .spec.runtime.scheduler.definitionStrategy,
        .spec.runtime.scheduler.cadenceFrom,
        .spec.runtime.scheduler.timezoneFrom,
        .spec.runtime.scheduler.reconcilePolicy,
        .spec.runtime.scheduler.notificationPolicy,
        .spec.runtime.execution.sourceRevision,
        .spec.runtime.execution.isolation,
        .spec.runtime.execution.branchNamespace,
        .spec.runtime.execution.branchNamespacePolicy,
        .spec.runtime.execution.permissions,
        .spec.runtime.execution.approvalMode,
        .spec.runtime.model.selectionPolicy,
        .spec.runtime.model.upgradePolicy,
        .spec.runtime.model.reasoningPolicy,
        .spec.runtime.memory.backendPolicy,
        .spec.runtime.memory.contractFrom,
        .spec.onboarding.copyPasteInstruction
      ] | all(.[]; nonempty_string))
      and .spec.source.hotSwapDuringRun == false
      and .spec.roles["agentic-engineer"].enabled == true
      and .spec.roles["portfolio-surveyor"].enabled == true
      and .spec.runtime.memory.loadBeforeContract == true
      and .spec.runtime.memory.writeBackAfterRun == true
      and all(.spec.consumer.requiredContractSections[]; nonempty_string)
      and all(.spec.consumer.requiredWhenAgentImproverEnabled[]; nonempty_string)
      and all(.spec.consumer.requiredWhenSpendStewardshipEnabled[]; nonempty_string)
      and all(.spec.runtime.scheduler.schedules[];
        (.definitionFrom | nonempty_string) and (.bootstrapPrompt | nonempty_string))
      and all(.spec.onboarding.steps[]; nonempty_string)
      and all(.spec.onboarding.completionReport[]; nonempty_string)
      and all(.spec.guardrails[]; nonempty_string)
    ' "$resource" > /dev/null; then
      echo "::error::$resource: desired-state fields must use their declared semantic value types"
      failed=1
      resource_failed=1
    fi

    if ! jq -e --arg name "$plugin_name" '
      def nonempty_string: type == "string" and length > 0;
      .apiVersion == "agent-plugins.devantler.tech/v1alpha1"
      and .kind == "AgenticEngineeringDesiredState"
      and .metadata.name == $name
      and (.metadata.description | nonempty_string)
      and .spec.source.plugin == $name
      and (.spec.source.marketplace | nonempty_string)
      and (.spec.source.entrypoint | nonempty_string)
      and (.spec.source.updatePolicy | nonempty_string)
      and .spec.consumer.canonicalInstructions == "AGENTS.md"
      and .spec.runtime.scheduler.definitionStrategy == "thin-pointer"
      and .spec.runtime.scheduler.cadenceFrom == "AGENTS.md#Cadence"
      and .spec.runtime.execution.isolation == "fresh-per-run-worktree"
      and (.spec.runtime.execution.branchNamespace | nonempty_string)
      and (.spec.onboarding.copyPasteInstruction | nonempty_string)
      and (.spec.onboarding.steps | type == "array" and length > 0
        and all(.[]; nonempty_string))
    ' "$resource" > /dev/null; then
      echo "::error::$resource: incomplete AgenticEngineeringDesiredState schema"
      failed=1
      resource_failed=1
    fi

    if ! jq -e '
      def only_keys($allowed): (keys - $allowed | length) == 0;
      def has_keys($required):
        . as $object | all($required[]; . as $key | $object | has($key));
      (only_keys(["apiVersion", "kind", "metadata", "spec"])
        and has_keys(["apiVersion", "kind", "metadata", "spec"]))
      and (.metadata
        | only_keys(["name", "description"]) and has_keys(["name", "description"]))
      and (.spec
        | only_keys(["source", "consumer", "roles", "runtime", "onboarding", "guardrails", "notes"])
          and has_keys(["source", "consumer", "roles", "runtime", "onboarding", "guardrails"]))
      and (.spec.source
        | only_keys([
          "marketplace", "plugin", "entrypoint", "entrypointSha256", "updatePolicy", "providerPolicy",
            "refreshTiming", "hotSwapDuringRun", "requiredRuntimeAssets"
          ])
          and has_keys([
            "marketplace", "plugin", "entrypoint", "entrypointSha256", "updatePolicy", "providerPolicy",
            "refreshTiming", "hotSwapDuringRun"
          ])
          and ((.requiredRuntimeAssets // [])
            | type == "array" and all(.[];
                type == "object"
                and (keys - ["path", "sha256", "executable"] | length == 0)
                and has("path") and has("sha256") and has("executable")
                and (.path | type == "string" and length > 0)
                and (.sha256 | type == "string" and test("^[a-f0-9]{64}$"))
                and .executable == true)))
      and (.spec.consumer
        | only_keys([
            "canonicalInstructions", "repositoryResolution", "organizationScopeFrom",
            "requiredContractSections", "requiredWhenAgentImproverEnabled",
            "requiredWhenSpendStewardshipEnabled"
          ])
          and has_keys([
            "canonicalInstructions", "repositoryResolution", "organizationScopeFrom",
            "requiredContractSections", "requiredWhenAgentImproverEnabled",
            "requiredWhenSpendStewardshipEnabled"
          ]))
      and (.spec.roles
        | only_keys(["agentic-engineer", "portfolio-surveyor", "agent-improver"])
          and has_keys(["agentic-engineer", "portfolio-surveyor", "agent-improver"]))
      and (.spec.roles["agentic-engineer"]
        | only_keys(["enabled", "mode"]) and has_keys(["enabled", "mode"]))
      and (.spec.roles["portfolio-surveyor"]
        | only_keys(["enabled", "mode", "definitionSha256"])
          and has_keys(["enabled", "mode", "definitionSha256"]))
      and (.spec.roles["agent-improver"]
        | only_keys(["enabledWhen", "mode", "definitionSha256", "skillSha256"])
          and has_keys(["enabledWhen", "mode", "definitionSha256", "skillSha256"]))
      and (.spec.runtime
        | only_keys(["scheduler", "execution", "model", "memory"])
          and has_keys(["scheduler", "execution", "model", "memory"]))
      and (.spec.runtime.scheduler
        | only_keys([
            "definitionStrategy", "cadenceFrom", "timezoneFrom", "reconcilePolicy",
            "notificationPolicy", "schedules"
          ])
          and has_keys([
            "definitionStrategy", "cadenceFrom", "timezoneFrom", "reconcilePolicy",
            "notificationPolicy", "schedules"
          ]))
      and all(.spec.runtime.scheduler.schedules[];
        only_keys(["definitionFrom", "bootstrapPrompt"])
        and has_keys(["definitionFrom", "bootstrapPrompt"]))
      and (.spec.runtime.execution
        | only_keys([
            "sourceRevision", "isolation", "branchNamespace", "branchNamespacePolicy",
            "permissions", "approvalMode"
          ])
          and has_keys([
            "sourceRevision", "isolation", "branchNamespace", "branchNamespacePolicy",
            "permissions", "approvalMode"
          ]))
      and (.spec.runtime.model
        | only_keys(["selectionPolicy", "upgradePolicy", "reasoningPolicy"])
          and has_keys(["selectionPolicy", "upgradePolicy", "reasoningPolicy"]))
      and (.spec.runtime.memory
        | only_keys(["backendPolicy", "contractFrom", "loadBeforeContract", "writeBackAfterRun"])
          and has_keys(["backendPolicy", "contractFrom", "loadBeforeContract", "writeBackAfterRun"]))
      and (.spec.onboarding
        | only_keys(["copyPasteInstruction", "steps", "completionReport"])
          and has_keys(["copyPasteInstruction", "steps", "completionReport"]))
      and (.spec.onboarding.completionReport
        | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
      and (.spec.guardrails
        | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
      and ((.spec.notes // "") | type == "string")
    ' "$resource" > /dev/null; then
      echo "::error::$resource: desired-state schema is missing required fields or contains unsupported fields"
      failed=1
      resource_failed=1
    fi

    if ! jq -e '
      (.spec.consumer.requiredContractSections | sort) ==
        (["Portfolio map", "Trust gate", "Cadence", "Memory", "Maintainer channels"] | sort)
      and
      (.spec.consumer.requiredWhenAgentImproverEnabled | sort) ==
        (["Agent definition locations", "Authority model"] | sort)
      and
      (.spec.consumer.requiredWhenSpendStewardshipEnabled | sort) ==
        (["Spend contract"] | sort)
    ' "$resource" > /dev/null; then
      echo "::error::$resource: required consumer contract sections must match the automated AI engineer contract"
      failed=1
      resource_failed=1
    fi

    if ! jq -e --arg delivery_guardrail "$delivery_guardrail" '
      .spec.guardrails | index($delivery_guardrail) != null
    ' "$resource" > /dev/null; then
      echo "::error::$resource: write-capable roles must own selected engineering work through merge"
      failed=1
      resource_failed=1
    fi

    if ! jq -e --arg money_guardrail "$money_guardrail" '
      .spec.guardrails | index($money_guardrail) != null
    ' "$resource" > /dev/null; then
      echo "::error::$resource: spend stewardship must declare the never-move-money boundary"
      failed=1
      resource_failed=1
    fi

    # Spend stewardship is merged into the entrypoint rather than a separate role, so the
    # entrypoint itself must carry the mandate, its conditional contract section, and the
    # money boundary that used to live in a standalone FinOps definition.
    for spend_marker in \
      '## Spend stewardship' \
      '**Spend contract**' \
      '**You never move money.**' \
      'Private financial data never reaches a public artifact'; do
      if [ ! -f "$plugin_dir/agents/$entrypoint.agent.md" ] \
        || ! grep -qF "$spend_marker" "$plugin_dir/agents/$entrypoint.agent.md"; then
        echo "::error::$resource: $entrypoint must absorb spend stewardship, missing: $spend_marker"
        failed=1
        resource_failed=1
      fi
    done

    for deadline_marker in \
      '**Give expected-to-run-long local commands an explicit execution deadline.**' \
      '**bounded tool timeout**' \
      '**measured repository or CI duration**' \
      'runtime exposes no per-call setting'; do
      if [ ! -f "$plugin_dir/agents/$entrypoint.agent.md" ] \
        || ! grep -qF "$deadline_marker" \
          "$plugin_dir/agents/$entrypoint.agent.md"; then
        echo "::error::$resource: agentic-engineer must bound expected-to-run-long local commands, missing: $deadline_marker"
        failed=1
        resource_failed=1
      fi
    done

    remote_wait_contract="**Bounded one-shot remote reads or mutations are allowed. Never foreground-poll remote state, and never wait on it through a foreground retry or sleep loop.** For CI, review, merge, or deploy state that needs later collection, prefer a supported completion callback. Otherwise, arm at most one detached watcher when the runtime supports it. Before ending the run, persist the watcher's handle, target, owner, start time, deadline, and teardown or collection state in durable memory; a later invocation must reuse or clean up that record before it may arm another watcher or query the same target. If neither a callback nor a safe watcher is available, persist the pending target, end the run, and let the next invocation—scheduled or on demand—collect it with a bounded one-shot query."
    if [ -f "$plugin_dir/agents/$entrypoint.agent.md" ]; then
      normalized_agent="$(
        tr '\n' ' ' < "$plugin_dir/agents/$entrypoint.agent.md" \
          | sed 's/[[:space:]][[:space:]]*/ /g'
      )"
      case "$normalized_agent" in
        *"$remote_wait_contract"*)
          ;;
        *)
          echo "::error::$resource: agentic-engineer must forbid foreground remote waits with the canonical contiguous contract"
          failed=1
          resource_failed=1
          ;;
      esac
    fi

    secret_inspection_contract="**Never let a credential become tool output.** Every other confidentiality rule you follow acts when something is *published* — a comment, a commit, a report. A secret that reaches your tool output has already passed that boundary: the transcript is durable, later runs mine it, and nothing downstream can un-write it. So inspect a secret-bearing resource — a cluster secret, a CI or provider credential, a secret store, a machine or provider config — through the **narrowest read that answers the question**: metadata, key names, counts, or explicitly selected non-secret fields, never a whole-object dump. Where a value must be handled, **redact it in the same command that produces it**, so the raw secret is never emitted. If a credential surfaces unexpectedly, **stop rather than continue**: never echo it, never pass it into a later command, and treat it as a leak under your deployment's rotation and private-notes rules."
    if [ -f "$plugin_dir/agents/$entrypoint.agent.md" ]; then
      normalized_agent_secret="$(
        tr '\n' ' ' < "$plugin_dir/agents/$entrypoint.agent.md" \
          | sed 's/[[:space:]][[:space:]]*/ /g'
      )"
      case "$normalized_agent_secret" in
        *"$secret_inspection_contract"*)
          ;;
        *)
          echo "::error::$resource: agentic-engineer must forbid a credential reaching tool output with the canonical contiguous contract"
          failed=1
          resource_failed=1
          ;;
      esac
    fi

    if [ -f "$plugin_dir/agents/portfolio-surveyor.agent.md" ]; then
      normalized_surveyor="$(
        tr '\n' ' ' < "$plugin_dir/agents/portfolio-surveyor.agent.md" \
          | sed 's/[[:space:]][[:space:]]*/ /g'
      )"
      case "$normalized_surveyor" in
        *"$portfolio_survey_json_vocabulary_contract"*)
          ;;
        *)
          echo "::error::$resource: portfolio-surveyor must validate ad hoc gh JSON fields against the same subcommand"
          failed=1
          resource_failed=1
          ;;
      esac
      # The ownership hint is three-valued and matched anywhere in the body. A two-valued
      # leads-with test reported "no disclosure" for a maintainer-interactive PR and for the
      # orchestrator's own template-bodied PR alike, and the orchestrator then moved the
      # maintainer's heads (#117, #118). Pin the rule and the digest grammar separately so a
      # prose edit that keeps the row, or a row edit that keeps the prose, still fails.
      case "$normalized_surveyor" in
        *"$portfolio_survey_disclosure_contract"*)
          ;;
        *)
          echo "::error::$resource: portfolio-surveyor must report a three-valued disclosure matched as a structural line anywhere in the body"
          failed=1
          resource_failed=1
          ;;
      esac
      case "$normalized_surveyor" in
        *"$portfolio_survey_disclosure_row"*)
          ;;
        *)
          echo "::error::$resource: portfolio-surveyor must emit $portfolio_survey_disclosure_row in its digest row"
          failed=1
          resource_failed=1
          ;;
      esac
      case "$normalized_surveyor" in
        *"$portfolio_survey_comment_disclosure_row"*)
          ;;
        *)
          echo "::error::$resource: portfolio-surveyor must carry the disclosure hint on the maintainer-comment row, which covers merged PRs the ownership row never reaches"
          failed=1
          resource_failed=1
          ;;
      esac
      case "$normalized_surveyor" in
        *"$portfolio_survey_recovery_contract"*)
          ;;
        *)
          echo "::error::$resource: portfolio-surveyor must preserve bounded resumable mandatory-query recovery"
          failed=1
          resource_failed=1
          ;;
      esac
      case "$normalized_surveyor" in
        *"$portfolio_survey_global_failure_contract"*)
          ;;
        *)
          echo "::error::$resource: portfolio-surveyor must preserve immediate fail-closed handling for global failures"
          failed=1
          resource_failed=1
          ;;
      esac
      case "$normalized_surveyor" in
        *"$portfolio_survey_head_revalidation_contract"*)
          ;;
        *)
          echo "::error::$resource: portfolio-surveyor must revalidate checkpoint heads before readiness"
          failed=1
          resource_failed=1
          ;;
      esac
      case "$normalized_surveyor" in
        *"$portfolio_survey_maintainer_control_contract"*)
          ;;
        *)
          echo "::error::$resource: portfolio-surveyor must preserve mandatory authenticated maintainer-control evidence"
          failed=1
          resource_failed=1
          ;;
      esac
      case "$normalized_surveyor" in
        *"$portfolio_survey_fail_closed_contract"*)
          ;;
        *)
          echo "::error::$resource: portfolio-surveyor must preserve candidate-scoped fail-closed dispositions"
          failed=1
          resource_failed=1
          ;;
      esac
      case "$normalized_surveyor" in
        *"$portfolio_survey_call_shape_contract"*)
          ;;
        *)
          echo "::error::$resource: portfolio-surveyor must state the guard's admitted call shape"
          failed=1
          resource_failed=1
          ;;
      esac
      case "$normalized_surveyor" in
        *"$portfolio_survey_classifier_argv_contract"*)
          ;;
        *)
          echo "::error::$resource: portfolio-surveyor must state the classifier's flag-form argument shape"
          failed=1
          resource_failed=1
          ;;
      esac
    else
      echo "::error::$resource: portfolio-surveyor must preserve bounded resumable mandatory-query recovery"
      echo "::error::$resource: portfolio-surveyor must preserve immediate fail-closed handling for global failures"
      echo "::error::$resource: portfolio-surveyor must revalidate checkpoint heads before readiness"
      echo "::error::$resource: portfolio-surveyor must preserve mandatory authenticated maintainer-control evidence"
      echo "::error::$resource: portfolio-surveyor must preserve candidate-scoped fail-closed dispositions"
      echo "::error::$resource: portfolio-surveyor must state the guard's admitted call shape"
      echo "::error::$resource: portfolio-surveyor must state the classifier's flag-form argument shape"
      failed=1
      resource_failed=1
    fi

    if [ ! -f "$plugin_dir/agents/agent-improver.agent.md" ] \
      || ! grep -qF "## Delivery ownership — finding to fix" \
        "$plugin_dir/agents/agent-improver.agent.md"; then
      echo "::error::$resource: agent-improver must define Delivery ownership — finding to fix"
      failed=1
      resource_failed=1
    fi

    if [ ! -f "$plugin_dir/agents/agent-improver.agent.md" ] \
      || ! grep -qF "$version_controlled_delivery" \
        "$plugin_dir/agents/agent-improver.agent.md"; then
      echo "::error::$resource: agent-improver must own version-controlled definitions through exact-head review and merge"
      failed=1
      resource_failed=1
    fi

    if [ ! -f "$plugin_dir/agents/agent-improver.agent.md" ] \
      || ! grep -qF "$runtime_local_delivery" \
        "$plugin_dir/agents/agent-improver.agent.md"; then
      echo "::error::$resource: agent-improver must preserve backed-up runtime-local in-place delivery"
      failed=1
      resource_failed=1
    fi

    if [ ! -f "$plugin_dir/agents/agent-improver.agent.md" ] \
      || ! tr '\n' ' ' < "$plugin_dir/agents/agent-improver.agent.md" \
        | tr -s '[:space:]' ' ' \
        | grep -qF "$improver_self_observation_contract"; then
      echo "::error::$resource: agent-improver must measure its own observation plane without self-scoring"
      failed=1
      resource_failed=1
    fi

    if [ ! -f "$plugin_dir/agents/agent-improver.agent.md" ] \
      || ! tr '\n' ' ' < "$plugin_dir/agents/agent-improver.agent.md" \
        | tr -s '[:space:]' ' ' \
        | grep -qF "$improver_research_fallback_contract"; then
      echo "::error::$resource: agent-improver must research and route candidates instead of idling"
      failed=1
      resource_failed=1
    fi

    if ! jq -e --arg name "$plugin_name" '
      (.spec.runtime.scheduler.schedules | keys | sort) ==
        (["agentic-engineer", "agent-improver"] | sort)
      and all(.spec.runtime.scheduler.schedules[];
        (.definitionFrom | type == "string" and length > 0)
        and (.bootstrapPrompt | type == "string" and length > 0))
      and .spec.runtime.scheduler.schedules["agentic-engineer"].definitionFrom ==
        ("plugin:" + $name + "/agentic-engineer")
      and .spec.runtime.scheduler.schedules["agent-improver"].definitionFrom ==
        ("plugin:" + $name + "/agent-improver")
    ' "$resource" > /dev/null; then
      echo "::error::$resource: must define all provider-neutral schedule prompts for plugin $plugin_name"
      failed=1
      resource_failed=1
    fi

    while IFS= read -r schedule_source; do
      schedule_plugin=${schedule_source#plugin:}
      schedule_plugin=${schedule_plugin%%/*}
      schedule_agent=${schedule_source##*/}
      if [ "$schedule_plugin" != "$plugin_name" ]; then
        echo "::error::$resource: plugin-backed schedule namespace must match plugin $plugin_name: $schedule_source"
        failed=1
        resource_failed=1
      elif [ ! -f "$plugin_dir/agents/$schedule_agent.agent.md" ]; then
        echo "::error::$resource: plugin-backed schedule target must resolve to a bundled agent: $schedule_agent"
        failed=1
        resource_failed=1
      fi
    done < <(jq -r '
      .spec.runtime.scheduler.schedules[]?.definitionFrom
      | select(type == "string" and startswith("plugin:"))
    ' "$resource")

    if ! jq -e '
      all(.spec.runtime.scheduler.schedules[];
        .bootstrapPrompt
        | type == "string"
          and length > 0
          and length <= 600
          and (ascii_downcase
            | contains("load") and contains("agents.md") and contains("invoke")))
    ' "$resource" > /dev/null; then
      echo "::error::$resource: schedule prompts must be thin source-loading pointers"
      failed=1
      resource_failed=1
    fi

    if ! jq -e '
      any(.spec.onboarding.steps[];
        ascii_downcase
        | contains("schedule")
          and contains("only")
          and contains("enabled")
          and contains("runtime.scheduler.schedules"))
    ' "$resource" > /dev/null; then
      echo "::error::$resource: onboarding must create schedules only for enabled scheduler entries"
      failed=1
      resource_failed=1
    fi

    if [ ! -f "$readme" ] || ! grep -qF "feature-flag mechanism" "$readme"; then
      echo "::error::$resource: $readme must document the required feature-flag mechanism"
      failed=1
      resource_failed=1
    fi

    if [ ! -f "$readme" ] || ! grep -qF "## Runtime guard note" "$readme"; then
      echo "::error::$resource: $readme must define the Runtime guard note section"
      failed=1
      resource_failed=1
    fi

    if [ "$resource_failed" -eq 0 ]; then
      echo "✓ desired state $resource"
    fi
  done < <(find plugins -type f -path '*/resources/*.desired-state.json' | sort)
  return "$failed"
}

# 8. Every bundled SKILL.md carries its upstream provenance frontmatter.
#    `gh skill install` records the true upstream in each skill's `metadata.github-*`
#    frontmatter, and AGENTS.md forbids hand-authored/divergent skills — so a bundled
#    skill MUST carry a real `github-repo` value *inside the `metadata:` block* of the
#    YAML frontmatter (the lines between the first two `---`). Staying jq/grep-only (no
#    yq dependency), one awk pass both slices the frontmatter and scopes the lookup to
#    `metadata:` so a TOP-LEVEL `github-repo:` cannot satisfy it, and rejects an empty,
#    quoted-empty (`""`/`''`) or comment-only (`# …`) value — each of which can only
#    come from a hand edit. A skill with no frontmatter yields no match → reject.
validate_skill_provenance() {
  local failed=0
  local skill
  while IFS= read -r skill; do
    if awk '
      # Walk only the frontmatter (lines between the first two --- ); END decides via found.
      NR==1 && $0 !~ /^---[[:space:]]*$/ { exit }
      /^---[[:space:]]*$/ { fm++; next }
      fm!=1 { next }
      # A non-indented key (column 0) is a top-level mapping key. metadata: opens the
      # block we care about; any other top-level key closes it (so a TOP-LEVEL
      # github-repo: can never satisfy the guard).
      /^metadata:[[:space:]]*$/ { in_meta=1; next }
      /^[^[:space:]]/ { in_meta=0; next }
      # Inside metadata:, an indented github-repo: with a real value is provenance.
      in_meta && /^[[:space:]]+github-repo:/ {
        v=$0
        sub(/^[[:space:]]+github-repo:[[:space:]]*/, "", v)  # drop the key
        sub(/[[:space:]]+#.*$/, "", v)                        # drop trailing " # comment"
        if (v ~ /^#/) v=""                                    # whole value is a comment ⇒ null
        gsub(/^[[:space:]"'"'"']+|[[:space:]"'"'"']+$/, "", v) # trim spaces and surrounding quotes
        if (v != "") found=1
      }
      END { exit(found ? 0 : 1) }
    ' "$skill"; then
      echo "✓ provenance $skill"
    else
      echo "::error::$skill: missing upstream provenance (metadata.github-repo) — bundled skills must come from 'gh skill install', never hand-authored"
      failed=1
    fi
  done < <(find plugins -type f -path '*/skills/*/SKILL.md' | sort)
  return "$failed"
}

main() {
  validate_marketplace_json "$COPILOT_MANIFEST"
  validate_marketplace_json "$CLAUDE_MANIFEST"
  validate_marketplace_parity
  validate_marketplace_renames
  validate_plugin_json
  validate_marketplace_plugins_parity
  validate_readme_parity
  validate_desired_state_resources
  validate_skill_provenance
}

main "$@"
