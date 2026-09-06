#!/usr/bin/env bash
# Self-test for recheck-open-prs.sh.
#
# Hermetic: stubs `gh` on PATH and records every call, so nothing here reaches the network or
# mutates a real pull request. Each case asserts the property that makes the script safe to point
# at a live repository — the ORDER of close and reopen, that a PR is never left closed, that an
# armed auto-merge is restored and an unarmed one is not created, and that a listing failure is
# distinguishable from an empty listing.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/recheck-open-prs.sh"

pass=0
fail=0

ok() {
  echo "  ✓ $1"
  pass=$((pass + 1))
}
bad() {
  echo "  ✗ $1"
  shift
  [ "$#" -eq 0 ] || printf '%s\n' "$@" | sed 's/^/      /'
  fail=$((fail + 1))
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Build a stub `gh` whose `pr list` returns $2 and whose mutating verbs append to a call log.
# $3 names a verb that must fail once, so the recovery paths are exercised for real rather than
# reasoned about.
make_gh() {
  local dir="$1" listing="$2" fail_verb="${3:-}"
  mkdir -p "$dir/bin"
  printf '%s\n' "$listing" > "$dir/listing.json"
  cat > "$dir/bin/gh" <<EOF
#!/usr/bin/env bash
log="$dir/calls.log"
case "\$1 \$2" in
  "pr list")
    cat "$dir/listing.json"
    exit 0
    ;;
esac
printf '%s\n' "\$1 \$2 \$3" >> "\$log"
if [ -n "$fail_verb" ] && [ "\$2" = "$fail_verb" ]; then
  exit 1
fi
exit 0
EOF
  chmod +x "$dir/bin/gh"
  : > "$dir/calls.log"
}

run_script() {
  local dir="$1"
  shift
  env PATH="$dir/bin:$PATH" "$SCRIPT" --repo owner/name "$@" 2>&1
}

# Same stubbed PATH, but every argument is the caller's — for the cases that must pass a
# malformed `--repo` rather than the well-formed one run_script supplies.
run_raw() {
  local dir="$1"
  shift
  env PATH="$dir/bin:$PATH" "$SCRIPT" "$@" 2>&1
}

# `grep -c` exits 1 on no match, so a `|| echo 0` fallback prints the count AND the fallback,
# yielding "0\n0" — which every numeric comparison below would then reject. awk always exits 0.
calls() { awk 'END { print NR }' "$1/calls.log"; }

TWO_PRS='[{"number":11,"title":"first","isDraft":false,"autoMergeRequest":null},
          {"number":22,"title":"second","isDraft":true,"autoMergeRequest":{"enabledAt":"2026-01-01T00:00:00Z"}}]'

echo "recheck-open-prs.sh self-test"

# --- usage ---------------------------------------------------------------
d="$WORK/usage"
make_gh "$d" '[]'
out=$(run_raw "$d" --repo); rc=$?
if [ "$rc" -eq 2 ]; then
  ok "a missing --repo value is a usage error"
else
  bad "a missing --repo value is a usage error" "got exit $rc: $out"
fi

d="$WORK/slug"
make_gh "$d" '[]'
out=$(run_raw "$d" --repo not-a-slug); rc=$?
if [ "$rc" -eq 2 ]; then
  ok "a malformed repository slug is refused, never addressed"
else
  bad "a malformed repository slug is refused, never addressed" "got exit $rc: $out"
fi

# --- nothing to do -------------------------------------------------------
d="$WORK/empty"
make_gh "$d" '[]'
out=$(run_script "$d"); rc=$?
if [ "$rc" -eq 0 ] && [ "$(calls "$d")" -eq 0 ] && [[ $out == *"nothing to re-trigger"* ]]; then
  ok "an empty listing exits 0 and mutates nothing"
else
  bad "an empty listing exits 0 and mutates nothing" "exit $rc, $(calls "$d") call(s): $out"
fi

# --- dry run -------------------------------------------------------------
d="$WORK/dry"
make_gh "$d" "$TWO_PRS"
out=$(run_script "$d" --dry-run); rc=$?
if [ "$rc" -eq 0 ] && [ "$(calls "$d")" -eq 0 ] && [[ $out == *"would re-trigger #11"* ]] \
  && [[ $out == *"would re-trigger #22"* ]]; then
  ok "--dry-run reports every PR and mutates nothing"
else
  bad "--dry-run reports every PR and mutates nothing" "exit $rc, $(calls "$d") call(s): $out"
fi

# --- the happy path, and the ORDER that makes it safe --------------------
d="$WORK/happy"
make_gh "$d" "$TWO_PRS"
out=$(run_script "$d"); rc=$?
log=$(cat "$d/calls.log")
if [ "$rc" -eq 0 ] && [[ $log == *"pr close 11"* ]] && [[ $log == *"pr reopen 11"* ]]; then
  ok "each PR is closed and reopened"
else
  bad "each PR is closed and reopened" "exit $rc" "$log"
fi
# Close BEFORE reopen for the same PR: the reverse order would leave it closed.
if [ "$(grep -n 'pr close 11' "$d/calls.log" | cut -d: -f1)" -lt \
  "$(grep -n 'pr reopen 11' "$d/calls.log" | cut -d: -f1)" ]; then
  ok "close precedes reopen for the same PR"
else
  bad "close precedes reopen for the same PR" "$log"
fi
# Auto-merge: restored only where it was armed. Arming one that was not is a merge the
# maintainer never asked for.
if [ "$(grep -c 'pr merge 22' "$d/calls.log")" -eq 1 ] \
  && [ "$(grep -c 'pr merge 11' "$d/calls.log")" -eq 0 ]; then
  ok "auto-merge is re-armed only on the PR that had it armed"
else
  bad "auto-merge is re-armed only on the PR that had it armed" "$log"
fi
# A draft is re-triggered like any other PR: a draft is exactly where a stale gate hides longest.
if [[ $log == *"pr close 22"* ]]; then
  ok "a draft PR is re-triggered too"
else
  bad "a draft PR is re-triggered too" "$log"
fi

# --- a failing reopen must be reported, not swallowed --------------------
d="$WORK/reopenfail"
make_gh "$d" "$TWO_PRS" reopen
out=$(run_script "$d"); rc=$?
if [ "$rc" -eq 1 ] && [[ $out == *"could not be reopened"* ]]; then
  ok "a failing reopen exits nonzero and names the PR"
else
  bad "a failing reopen exits nonzero and names the PR" "exit $rc: $out"
fi
# The trap is the safety net: every PR the script closed and could not reopen is retried on
# exit, so the closed window never outlives the run silently.
if [ "$(grep -c 'pr reopen 11' "$d/calls.log")" -ge 2 ]; then
  ok "the exit trap retries a PR left closed"
else
  bad "the exit trap retries a PR left closed" "$(cat "$d/calls.log")"
fi

# --- a failing close leaves that PR untouched ----------------------------
d="$WORK/closefail"
make_gh "$d" "$TWO_PRS" close
out=$(run_script "$d"); rc=$?
if [ "$rc" -eq 1 ] && [ "$(grep -c 'pr reopen' "$d/calls.log")" -eq 0 ]; then
  ok "a PR that could not be closed is never reopened, and the run fails"
else
  bad "a PR that could not be closed is never reopened, and the run fails" \
    "exit $rc" "$(cat "$d/calls.log")"
fi

# --- a listing that is not JSON is an error, never an empty listing ------
d="$WORK/badjson"
make_gh "$d" 'not json at all'
out=$(run_script "$d"); rc=$?
if [ "$rc" -eq 2 ] && [ "$(calls "$d")" -eq 0 ]; then
  ok "an unparseable listing fails closed rather than reading as no open PRs"
else
  bad "an unparseable listing fails closed rather than reading as no open PRs" \
    "exit $rc, $(calls "$d") call(s): $out"
fi

echo "-----------------------------------------"
echo "recheck-open-prs.sh self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
