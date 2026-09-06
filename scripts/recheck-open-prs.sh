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
# THE TWO THINGS THIS MUST NEVER LEAVE BEHIND
#   A pull request closed, and an auto-merge that was armed before the run and is not after it.
#   Both are tracked in a state directory from BEFORE the mutation that could cause them, and the
#   exit trap settles both from the pull request's ACTUAL state rather than from an assumption
#   about whether a failed call took effect — a request can be applied and still report failure.
#
# Usage:
#   ./scripts/recheck-open-prs.sh --repo OWNER/NAME [--base BRANCH] [--dry-run]
#
# Reads `gh` from PATH and expects it already authenticated with an App token.
# Exit 0 when every selected PR was re-triggered (or none was selected), 1 when any PR could not
# be, 2 on a usage or environment error.
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
# Used to take every field of a pull request's auto-merge request out of ONE response, so a
# transient failure cannot be mistaken for "no custom metadata".
command -v jq > /dev/null 2>&1 || {
  echo "recheck-open-prs: jq is required" >&2
  exit 2
}

state=$(mktemp -d) || exit 2
mkdir -p "$state/closed" "$state/rearm" || exit 2

# How long to wait for the reopened event's check run before declining to re-arm auto-merge.
# Overridable so the self-test does not sleep.
CHECK_WAIT_SECONDS=${RECHECK_CHECK_WAIT_SECONDS:-90}
CHECK_POLL_SECONDS=${RECHECK_CHECK_POLL_SECONDS:-3}

# Restore anything this run may have disturbed. Both loops decide from the pull request's real
# state, because a call that reports failure may still have been applied: `gh pr close` can time
# out after GitHub accepted it, and dropping the record on that nonzero exit would leave the PR
# closed with nothing tracking it.
# shellcheck disable=SC2317,SC2329  # invoked indirectly, by the EXIT trap below. Both codes are
# needed: shellcheck >= 0.11 reports the unused-looking function as SC2329 on its declaration,
# while older versions — including the one CI installs — report every line of its body as
# unreachable, SC2317. A directive naming only one version's code passes here and fails there.
settle() {
  local f n st method headline body sha baseline
  for f in "$state/closed"/*; do
    [ -e "$f" ] || continue
    n=${f##*/}
    st=$(gh pr view "$n" --repo "$repo" --json state --jq '.state' 2> /dev/null) || st=UNKNOWN
    # UNKNOWN reopens too: an unreadable state is not evidence the PR is open, and reopening an
    # already-open pull request costs nothing.
    if [ "$st" = "OPEN" ] || [ "$st" = "MERGED" ]; then
      continue
    fi
    echo "recheck-open-prs: reopening #$n, left closed (state=$st)" >&2
    gh pr reopen "$n" --repo "$repo" > /dev/null 2>&1 \
      || echo "::error::#$n could not be reopened; reopen it by hand" >&2
  done
  for f in "$state/rearm"/*; do
    [ -e "$f" ] || continue
    n=${f##*/}
    st=$(gh pr view "$n" --repo "$repo" --json autoMergeRequest \
      --jq 'if .autoMergeRequest == null then "none" else "armed" end' 2> /dev/null) || st=none
    [ "$st" = "armed" ] && continue
    method=$(cat "$state/rearm/$n/method" 2> /dev/null) || method=""
    headline=$(cat "$state/rearm/$n/headline" 2> /dev/null) || headline=""
    body=$(cat "$state/rearm/$n/body" 2> /dev/null) || body=""
    sha=$(cat "$state/rearm/$n/sha" 2> /dev/null) || sha=""
    baseline=$(cat "$state/rearm/$n/baseline" 2> /dev/null) || baseline=0
    # The same wait the main path performs, and for the same reason: arming auto-merge while the
    # pre-gate green is still the newest result can merge the PR before the new run exists.
    if ! await_fresh_check "$sha" "$baseline"; then
      echo "::error::#$n auto-merge was NOT restored: no check run from the reopen appeared, and arming it now could merge the PR on the pre-gate result. Re-arm it by hand once its checks are running." >&2
      continue
    fi
    echo "recheck-open-prs: restoring auto-merge on #$n" >&2
    rearm "$n" "$method" "$headline" "$body" > /dev/null 2>&1 \
      || echo "::error::#$n auto-merge could not be restored; re-arm it by hand" >&2
  done
  rm -rf "$state"
}

# The highest check-run id at a commit, or 0. Ids increase, so a larger one later means a NEW
# run exists — which needs no clock and no assumption about either side's timekeeping.
newest_check() {
  gh api "repos/${repo}/commits/$1/check-runs" --jq '[.check_runs[].id] | max // 0' 2> /dev/null
}

# Block until a check run newer than $2 exists at commit $1. Auto-merge means "merge once the
# requirements are met", and immediately after a reopen the newest result at that commit is still
# the PRE-GATE green: arming there can merge the pull request in the window before Actions has
# created the run for the reopen, past the very gate this script exists to apply. Returns
# non-zero if no new run appears, and the caller then declines to arm — an auto-merge a human
# must restore is recoverable, a merge that skipped a gate is not.
await_fresh_check() {
  local sha=$1 baseline=$2 waited=0 now
  [ -n "$sha" ] || return 1
  while [ "$waited" -lt "$CHECK_WAIT_SECONDS" ]; do
    now=$(newest_check "$sha")
    case "$now" in '' | *[!0-9]*) now=0 ;; esac
    [ "$now" -gt "$baseline" ] && return 0
    sleep "$CHECK_POLL_SECONDS"
    waited=$((waited + CHECK_POLL_SECONDS))
  done
  return 1
}

# Re-arm auto-merge exactly as it was: the same strategy, and the same commit metadata.
# Recreating it as a default squash would silently change both the merge behaviour and the
# message someone chose deliberately.
rearm() {
  local n=$1 method=$2 headline=$3 body=$4 flag
  case "$method" in
    MERGE) flag=--merge ;;
    REBASE) flag=--rebase ;;
    # An unknown or missing method falls back to squash, which every ruleset here permits.
    *) flag=--squash ;;
  esac
  set -- "$n" --repo "$repo" --auto "$flag"
  # A rebase carries no commit message of its own, so those flags apply to the other two only.
  if [ "$flag" != "--rebase" ]; then
    [ -z "$headline" ] || set -- "$@" --subject "$headline"
    [ -z "$body" ] || set -- "$@" --body "$body"
  fi
  gh pr merge "$@"
}

trap settle EXIT

# `gh pr list --limit N` fetches at most N, so any cap silently skips the pull requests past it
# and leaves them on the pre-gate result — the exact failure this script exists to prevent, just
# further down the list. `gh api --paginate` walks every page instead.
#
# The query parameters are passed as GET fields rather than interpolated into the path: a branch
# name may legally contain `&` or `#`, which spliced into a query string would silently select a
# different set of pull requests. `--method GET` is what keeps gh from turning the fields into a
# POST body.
#
# Auto-merge is deliberately NOT read here. A snapshot taken now could be minutes old by the time
# a given PR is processed, and re-arming from it would restore an auto-merge someone disabled in
# between — a merge nobody asked for. It is read per PR, immediately before closing.
if ! prs=$(gh api --paginate --method GET "repos/${repo}/pulls" \
  -f state=open -f base="$base" -F per_page=100 \
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
  # ONE read, capturing everything this PR's handling depends on. Splitting it across calls made
  # a transient failure on a later call indistinguishable from "no custom metadata", which would
  # then be restored as GitHub's default message — a silent change to someone's chosen commit.
  # A failed read leaves the PR untouched: closing it without knowing its state would risk both
  # reversing a deliberate closure and dropping an armed auto-merge.
  if ! snapshot=$(gh pr view "$number" --repo "$repo" --json state,autoMergeRequest,headRefOid) \
    || [ -z "$snapshot" ]; then
    echo "::error::#$number state could not be read; left untouched"
    failed=$((failed + 1))
    continue
  fi

  pr_state=$(printf '%s' "$snapshot" | jq -r '.state // ""')
  # The listing is a snapshot; a maintainer may have closed or merged this PR since. Reopening it
  # would reverse that deliberate act, and the `autoMergeRequest` read alone would not have
  # noticed — it succeeds for a closed pull request too.
  if [ "$pr_state" != "OPEN" ]; then
    echo "  skipped #$number — no longer open (state=${pr_state:-unknown})"
    continue
  fi

  automerge=$(printf '%s' "$snapshot" | jq -r 'if .autoMergeRequest == null then "none" else "armed" end')
  if [ "$automerge" = "armed" ]; then
    # Capture the strategy and commit metadata before the close clears the request, so the
    # restore puts back what was there rather than a default squash.
    mkdir -p "$state/rearm/$number"
    printf '%s' "$snapshot" | jq -r '.autoMergeRequest.mergeMethod // ""' > "$state/rearm/$number/method"
    printf '%s' "$snapshot" | jq -r '.autoMergeRequest.commitHeadline // ""' > "$state/rearm/$number/headline"
    printf '%s' "$snapshot" | jq -r '.autoMergeRequest.commitBody // ""' > "$state/rearm/$number/body"
    head_sha=$(printf '%s' "$snapshot" | jq -r '.headRefOid // ""')
    printf '%s' "$head_sha" > "$state/rearm/$number/sha"
    # The high-water mark of check runs at this commit BEFORE the reopen, so "a run from the
    # reopen exists" is answerable afterwards without trusting any clock.
    check_baseline=$(newest_check "$head_sha")
    case "$check_baseline" in '' | *[!0-9]*) check_baseline=0 ;; esac
    printf '%s' "$check_baseline" > "$state/rearm/$number/baseline"
  fi

  # Close and reopen produce the `reopened` event that resolves a fresh merge ref. The head is
  # untouched, so a green review at the current head stays current. The record is written first
  # and is NOT removed when the close reports failure: a close can be applied and still report
  # one, and only the trap's read of the real state can tell those apart.
  : > "$state/closed/$number"
  if ! gh pr close "$number" --repo "$repo" > /dev/null; then
    echo "::error::#$number could not be closed; skipped without re-triggering"
    failed=$((failed + 1))
    continue
  fi

  if ! gh pr reopen "$number" --repo "$repo" > /dev/null; then
    echo "::error::#$number was closed but could not be reopened"
    failed=$((failed + 1))
    continue
  fi
  rm -f "$state/closed/$number"

  if [ "$automerge" = "armed" ]; then
    method=$(cat "$state/rearm/$number/method" 2> /dev/null) || method=""
    headline=$(cat "$state/rearm/$number/headline" 2> /dev/null) || headline=""
    body=$(cat "$state/rearm/$number/body" 2> /dev/null) || body=""
    # Wait for the reopen's own check run before arming. Until it exists the newest result at
    # this commit is the pre-gate green, and `--auto` merges as soon as the requirements read as
    # met — which would take the pull request past the gate this run is applying.
    if ! await_fresh_check "$head_sha" "$check_baseline"; then
      echo "::error::#$number was re-triggered, but auto-merge was NOT restored: no check run from the reopen appeared within ${CHECK_WAIT_SECONDS}s, and arming it now could merge the PR on the pre-gate result. Re-arm it by hand once its checks are running."
      rm -rf "$state/rearm/$number"
      failed=$((failed + 1))
      continue
    fi
    if ! rearm "$number" "$method" "$headline" "$body" > /dev/null; then
      # Left in the rearm set on purpose: once the close has cleared the request, a later run
      # cannot tell that this PR ever had auto-merge armed, so the obligation has to survive
      # here or it is lost for good. The trap retries it.
      echo "::error::#$number was re-triggered but its auto-merge could not be re-armed"
      failed=$((failed + 1))
      continue
    fi
    rm -rf "$state/rearm/$number"
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
