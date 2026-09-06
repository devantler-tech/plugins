#!/usr/bin/env bash
# Re-trigger the required checks on every open pull request targeting the default branch.
#
# WHY THIS EXISTS
#   A pull-request workflow runs only on that PR's own `pull_request` events. Every PR already
#   open when a new required gate lands on the default branch therefore keeps the green
#   `CI - Required Checks` result it earned BEFORE the gate existed, and the branch rule keyed on
#   that check name is satisfied by the stale run. Such a PR can merge without the new gate ever
#   having run against it — exactly the class of change (a version left unbumped, a synced skill
#   hand-edited) each gate was added to stop.
#
#   The repository's ruleset does not set `strict_required_status_checks_policy`, which is
#   GitHub's own mechanism for this ("require branches to be up to date before merging"), and it
#   is declared org-wide and Observe-only, so it is not this repository's to flip. This script is
#   the repository-scoped equivalent: after the gate lands, ask every open PR to run again.
#
# WHY CLOSE-AND-REOPEN, AND NOT A RE-RUN
#   Re-running a workflow run reuses the ORIGINAL event's `GITHUB_SHA` and `GITHUB_REF`. For a
#   `pull_request` run that ref is `refs/pull/N/merge`, so a re-run replays the merge commit as it
#   stood before the gate landed — with the old workflow file. Only a NEW `pull_request` event
#   resolves the merge ref again and picks the new gate up. Of the events that do so, `reopened`
#   is the only one that does not move the PR's head: a push (`synchronize`) would invalidate
#   every green review at the current head and cannot reach a fork's branch at all.
#
# WHY AN APP TOKEN IS REQUIRED
#   Events produced with the repository's `GITHUB_TOKEN` do not start new workflow runs, so a
#   reopen performed with it would be silent. The caller must pass a token from the repository's
#   GitHub App — the same reason `update-agent-skills.yaml` mints one to open its PR.
#
# Usage:
#   ./scripts/recheck-open-prs.sh --repo OWNER/NAME [--base BRANCH] [--dry-run]
#
# Reads `gh` from PATH and expects it already authenticated with an App token.
# Exit 0 when every selected PR was re-triggered (or none was selected), 1 when any PR could not
# be, 2 on a usage or environment error. A PR is never left closed: the exit trap reopens
# anything this script closed and did not reopen.
set -uo pipefail

usage() {
  cat >&2 <<'EOF'
usage: recheck-open-prs.sh --repo OWNER/NAME [--base BRANCH] [--dry-run]
EOF
  exit 2
}

repo=""
base="main"
dry_run=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || usage
      repo=$2
      shift 2
      ;;
    --base)
      [ "$#" -ge 2 ] || usage
      base=$2
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    *) usage ;;
  esac
done

[ -n "$repo" ] || usage
# A malformed slug would silently address a different repository, so it is validated rather
# than passed through.
case "$repo" in
  */*/*) usage ;;
  */*) ;;
  *) usage ;;
esac

command -v gh > /dev/null 2>&1 || {
  echo "recheck-open-prs: gh is required" >&2
  exit 2
}

# Records a PR from the moment closing it is ATTEMPTED until it is reopened. The trap is what
# makes a crash, a cancelled job, or an API failure mid-sequence safe. The record is written
# before the close rather than after it, because a close that succeeds and then fails to be
# recorded would leave a closed PR the trap knows nothing about; a record whose close never
# happened costs only a harmless reopen of an already-open PR.
pending=$(mktemp) || exit 2
# shellcheck disable=SC2317,SC2329  # invoked indirectly, by the EXIT trap below. Both codes are
# needed: shellcheck >= 0.11 reports the unused-looking function as SC2329 on its declaration,
# while older versions — including the one CI installs — report every line of its body as
# unreachable, SC2317. A directive naming only one version's code passes here and fails there.
reopen_pending() {
  local n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    echo "recheck-open-prs: reopening #$n left closed by an interrupted run" >&2
    gh pr reopen "$n" --repo "$repo" > /dev/null 2>&1 || {
      echo "::error::#$n could not be reopened; reopen it by hand" >&2
    }
  done < "$pending"
  rm -f "$pending"
}
trap reopen_pending EXIT

# Drop $1 from the pending record. Rewritten wholesale rather than appended to, so the file is
# always the exact set of PRs currently closed by this run.
forget_pending() {
  local keep
  if ! keep=$(grep -v -x -- "$1" "$pending"); then
    keep=""
  fi
  if [ -z "$keep" ]; then
    : > "$pending"
  else
    printf '%s\n' "$keep" > "$pending"
  fi
}

# `gh pr list --limit N` fetches at most N, so any cap silently skips the pull requests past it
# and leaves them on the pre-gate result — the exact failure this script exists to prevent, just
# further down the list. `gh api --paginate` walks every page instead, so the sweep is complete
# however many are open.
#
# Auto-merge is deliberately NOT read here. A snapshot taken now could be minutes old by the time
# a given PR is processed, and re-arming from it would restore an auto-merge someone disabled in
# between — a merge nobody asked for. It is read per PR, immediately before closing.
if ! prs=$(gh api --paginate "repos/${repo}/pulls?state=open&base=${base}&per_page=100" \
  --jq '.[]|[(.number|tostring), (.title // "")]|@tsv'); then
  echo "recheck-open-prs: could not list open pull requests" >&2
  exit 2
fi

count=$(printf '%s' "$prs" | awk 'NF { n++ } END { print n + 0 }')

if [ "$count" -eq 0 ]; then
  echo "recheck-open-prs: no open pull requests targeting $base — nothing to re-trigger"
  exit 0
fi

echo "recheck-open-prs: re-triggering required checks on $count open PR(s) targeting $base"

failed=0
done_count=0

while IFS=$'\t' read -r number title; do
  [ -n "$number" ] || continue
  # A line that is not a PR number means the listing was not what it claimed to be. Failing here
  # keeps a malformed response from being read as a shorter list of real pull requests.
  case "$number" in
    '' | *[!0-9]*)
      echo "recheck-open-prs: open pull request listing is malformed near '$number'" >&2
      exit 2
      ;;
  esac

  if [ "$dry_run" -eq 1 ]; then
    echo "  would re-trigger #$number — $title"
    done_count=$((done_count + 1))
    continue
  fi

  # Read auto-merge fresh, immediately before closing, so the decision to restore it is based on
  # the state that is true now rather than when the sweep started. A read that fails leaves the
  # PR untouched: closing it without knowing would risk silently dropping an armed auto-merge.
  if ! automerge=$(gh pr view "$number" --repo "$repo" --json autoMergeRequest \
    --jq 'if .autoMergeRequest == null then "none" else "armed" end'); then
    echo "::error::#$number auto-merge state could not be read; left untouched"
    failed=$((failed + 1))
    continue
  fi

  # Close and reopen produce the `reopened` event that resolves a fresh merge ref. The head is
  # untouched, so a green review at the current head stays current.
  printf '%s\n' "$number" >> "$pending"
  if ! gh pr close "$number" --repo "$repo" > /dev/null; then
    # Never closed, so nothing to recover.
    forget_pending "$number"
    echo "::error::#$number could not be closed; skipped without re-triggering"
    failed=$((failed + 1))
    continue
  fi

  if ! gh pr reopen "$number" --repo "$repo" > /dev/null; then
    echo "::error::#$number was closed but could not be reopened"
    failed=$((failed + 1))
    continue
  fi
  forget_pending "$number"

  # Closing a PR clears an armed auto-merge request, so restore one that was armed. The
  # repository allows squash only, so the method is not a guess.
  if [ "$automerge" = "armed" ]; then
    if ! gh pr merge "$number" --repo "$repo" --auto --squash > /dev/null; then
      echo "::error::#$number was re-triggered but its auto-merge could not be re-armed"
      failed=$((failed + 1))
      continue
    fi
    echo "  re-triggered #$number and re-armed auto-merge — $title"
  else
    echo "  re-triggered #$number — $title"
  fi
  done_count=$((done_count + 1))
  # `printf '%s\n'`, never `printf '%s'`: command substitution strips the trailing newline, so
  # feeding the value back without one makes `read` return false on the final line and drops the
  # last pull request from the sweep — silently, and reported as a smaller total.
done < <(printf '%s\n' "$prs")

echo "recheck-open-prs: $done_count of $count re-triggered"
if [ "$failed" -gt 0 ]; then
  echo "::error::$failed pull request(s) could not be re-triggered; their required checks are still the pre-gate result"
  exit 1
fi
exit 0
