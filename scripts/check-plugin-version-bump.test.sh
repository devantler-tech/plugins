#!/usr/bin/env bash
# Self-test for check-plugin-version-bump.sh.
#
# Proves the guard PASSES the cases it must not block (no plugin change, a bumped plugin,
# a brand-new plugin, a deleted plugin, an unrelated repo-root change) and FAILS each drift
# it exists to catch (content changed with the version untouched, on any plugin, and an
# unresolvable base ref) — so a refactor that silently weakens it is caught here rather than
# by a stale plugin sitting in every consumer's cache.
#
# Self-contained: builds throwaway git repos, runs the REAL guard against them, and asserts
# exit code + the specific message. No network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/check-plugin-version-bump.sh"

pass=0
fail=0

# Write plugins/<name> with the strict Claude manifest, the portable manifest, and a skill.
make_plugin() {
  local root="$1" name="$2" version="$3" body="${4:-original body}"
  mkdir -p "$root/plugins/$name/.claude-plugin" "$root/plugins/$name/skills/example-skill"
  local pj
  pj=$(printf '{"name":"%s","description":"%s plugin","version":"%s"}' "$name" "$name" "$version")
  printf '%s\n' "$pj" > "$root/plugins/$name/plugin.json"
  printf '%s\n' "$pj" > "$root/plugins/$name/.claude-plugin/plugin.json"
  printf -- '---\nname: example-skill\ndescription: Example\n---\n\n%s\n' "$body" \
    > "$root/plugins/$name/skills/example-skill/SKILL.md"
}

set_version() {
  local root="$1" name="$2" version="$3" f
  for f in "$root/plugins/$name/plugin.json" "$root/plugins/$name/.claude-plugin/plugin.json"; do
    jq --arg v "$version" '.version = $v' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
}

# A repo whose main branch holds two plugins at 1.0.0, with a feature branch checked out.
make_repo() {
  local root="$1"
  mkdir -p "$root"
  git -C "$root" init --quiet --initial-branch=main
  git -C "$root" config user.email test@example.com
  git -C "$root" config user.name "Test"
  # Hermetic: never inherit the caller's signing setup — a contributor with
  # commit.gpgsign enabled would otherwise fail every fixture commit.
  git -C "$root" config commit.gpgsign false
  make_plugin "$root" alpha "1.0.0"
  make_plugin "$root" beta "1.0.0"
  printf 'root\n' > "$root/README.md"
  git -C "$root" add -A
  git -C "$root" commit --quiet -m "base"
  git -C "$root" checkout --quiet -b feature
}

run_guard() { (cd "$1" && "$GUARD" "${2:-main}" "${3:-HEAD}" 2>&1); }

check_pass() {
  local desc="$1" dir="$2" out rc
  out=$(run_guard "$dir"); rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "  ✓ $desc"; pass=$((pass + 1))
  else
    echo "  ✗ $desc — expected exit 0, got $rc"
    printf '%s\n' "$out" | sed 's/^/      /'; fail=$((fail + 1))
  fi
}

check_fail() {
  local desc="$1" pat="$2" dir="$3" base="${4:-main}" out rc
  out=$(run_guard "$dir" "$base"); rc=$?
  if [ "$rc" -ne 0 ] && [[ $out == *"$pat"* ]]; then
    echo "  ✓ $desc"; pass=$((pass + 1))
  else
    echo "  ✗ $desc — expected non-zero exit + message containing '$pat'; got exit $rc"
    printf '%s\n' "$out" | sed 's/^/      /'; fail=$((fail + 1))
  fi
}

commit_all() { git -C "$1" add -A && git -C "$1" commit --quiet -m "${2:-change}"; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fresh() { local d; d=$(mktemp -d "$WORK/case-XXXXXX"); make_repo "$d"; printf '%s' "$d"; }

echo "check-plugin-version-bump.sh self-test"

# --- cases that must NOT be blocked ---
check_pass "no plugin change passes" "$(fresh)"

d=$(fresh)
printf 'changed root doc\n' > "$d/README.md"
commit_all "$d" "docs only"
check_pass "repo-root change outside plugins/ passes" "$d"

d=$(fresh)
make_plugin "$d" alpha "1.0.0" "edited body"
set_version "$d" alpha "1.0.1"
commit_all "$d" "content + bump"
check_pass "content change with a version bump passes" "$d"

d=$(fresh)
make_plugin "$d" gamma "1.0.0"
commit_all "$d" "new plugin"
check_pass "brand-new plugin passes (nothing to bump from)" "$d"

d=$(fresh)
rm -rf "$d/plugins/beta"
commit_all "$d" "remove plugin"
check_pass "deleted plugin passes (no version to bump)" "$d"

# A bump alone, with no other content change, is still a legitimate change.
d=$(fresh)
set_version "$d" alpha "2.0.0"
commit_all "$d" "bump only"
check_pass "version-only change passes" "$d"

# --- the drift the guard exists to catch ---
d=$(fresh)
make_plugin "$d" alpha "1.0.0" "edited body"
commit_all "$d" "content, no bump"
check_fail "content change without a version bump fails" \
  "alpha: shipped content changed but the version is still 1.0.0" "$d"

# The offending file list is what makes the failure actionable — pin it.
d=$(fresh)
make_plugin "$d" alpha "1.0.0" "edited body"
commit_all "$d" "content, no bump"
check_fail "failure names the changed file" \
  "plugins/alpha/skills/example-skill/SKILL.md" "$d"

# The remediation must name every manifest that has to move, or the fix takes several rounds.
d=$(fresh)
make_plugin "$d" alpha "1.0.0" "edited body"
commit_all "$d" "content, no bump"
check_fail "failure names the marketplace manifests to bump" \
  ".github/plugin/marketplace.json" "$d"

# Catching only the first plugin would let a second stale plugin ship in the same change.
d=$(fresh)
make_plugin "$d" alpha "1.0.0" "edited body"
make_plugin "$d" beta "1.0.0" "edited body"
commit_all "$d" "two plugins, no bumps"
check_fail "a second unbumped plugin is also reported" \
  "beta: shipped content changed but the version is still 1.0.0" "$d"

# Bumping one plugin must not excuse the other.
d=$(fresh)
make_plugin "$d" alpha "1.0.0" "edited body"
set_version "$d" alpha "1.0.1"
make_plugin "$d" beta "1.0.0" "edited body"
commit_all "$d" "one bumped, one not"
check_fail "an unbumped plugin fails even when a sibling bumped" \
  "beta: shipped content changed but the version is still 1.0.0" "$d"

# --- fail-closed on an unusable base ---
d=$(fresh)
make_plugin "$d" alpha "1.0.0" "edited body"
commit_all "$d" "content, no bump"
check_fail "an unresolvable base ref fails closed" \
  "Cannot resolve a merge base" "$d" "origin/does-not-exist"

# An UNREADABLE base manifest is not an ABSENT one (#167). In a partial clone a promisor-object
# fetch failure makes `git show base:<manifest>` fail exactly like a missing path would, and
# treating that as "new plugin" lets the gate pass on a plugin that already ships. Reproduce the
# shape hermetically: the base tree still lists the manifest, but its blob is gone.
d=$(fresh)
make_plugin "$d" alpha "1.0.0" "edited body"
set_version "$d" alpha "1.0.1"
commit_all "$d" "content + bump"
blob=$(git -C "$d" rev-parse "main:plugins/alpha/.claude-plugin/plugin.json")
rm -f "$d/.git/objects/${blob:0:2}/${blob:2}"
# Control: the fixture must make the base manifest unreadable while its tree entry survives,
# or the case below would pass for a reason other than the one it pins.
if git -C "$d" show "main:plugins/alpha/.claude-plugin/plugin.json" >/dev/null 2>&1; then
  echo "  ✗ fixture control: base manifest is still readable after removing its blob"; fail=$((fail + 1))
elif [ -z "$(git -C "$d" ls-tree main -- "plugins/alpha/.claude-plugin/plugin.json")" ]; then
  echo "  ✗ fixture control: base tree no longer lists the manifest"; fail=$((fail + 1))
else
  echo "  ✓ fixture control: base manifest listed but unreadable"; pass=$((pass + 1))
fi
check_fail "an unreadable base manifest fails closed instead of reading as a new plugin" \
  "could not be read" "$d"

# The genuinely-absent case must keep passing: the fix distinguishes the two, it does not
# collapse them into one failure.
d=$(fresh)
make_plugin "$d" gamma "1.0.0"
commit_all "$d" "new plugin"
check_pass "a manifest genuinely absent at the base still reads as a new plugin" "$d"

echo "-----------------------------------------"
echo "check-plugin-version-bump.sh self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
