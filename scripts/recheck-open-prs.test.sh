#!/usr/bin/env bash
# Self-test for recheck-open-prs.sh.
#
# Hermetic: stubs `gh` on PATH and records every call, so nothing here reaches the network or
# mutates a real pull request. Each case asserts the property that makes the script safe to point
# at a live repository — the ORDER of close and reopen, that a PR is never left closed, that
# auto-merge is read fresh and restored only where it is armed NOW, that the sweep is complete
# past one API page, and that a malformed listing is distinguishable from an empty one.
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

# Build a stub `gh`:
#   $2  the TSV the paginated `api` listing emits (what the real --jq would produce)
#   $3  a verb whose FIRST call fails; later calls succeed, so the exit trap's retry is exercised
#       as a retry that can actually succeed rather than one that cannot
#   $4  optional per-PR auto-merge states, "<number>=armed|none ..."; default none
# `pr view` answers from a file rewritten per call, which is how the "disabled between the sweep
# and the close" case is expressed.
make_gh() {
  local dir="$1" listing="$2" fail_verb="${3:-}" automerge="${4:-}"
  mkdir -p "$dir/bin" "$dir/state"
  printf '%s' "$listing" > "$dir/listing.tsv"
  local pair
  for pair in $automerge; do
    printf '%s' "${pair#*=}" > "$dir/state/am-${pair%%=*}"
  done
  cat > "$dir/bin/gh" <<EOF
#!/usr/bin/env bash
log="$dir/calls.log"
case "\$1 \$2" in
  "api --paginate")
    if [ -f "$dir/listing-fails" ]; then exit 1; fi
    cat "$dir/listing.tsv"
    exit 0
    ;;
  "pr view")
    printf '%s\n' "pr view \$3" >> "\$log"
    if [ -f "$dir/state/am-\$3" ]; then cat "$dir/state/am-\$3"; else printf 'none'; fi
    printf '\n'
    # A hook the caller can use to change state between the sweep and this PR's close.
    [ -x "$dir/on-view" ] && "$dir/on-view" "\$3"
    exit 0
    ;;
esac
printf '%s\n' "\$1 \$2 \$3" >> "\$log"
if [ -n "$fail_verb" ] && [ "\$2" = "$fail_verb" ] && [ ! -f "$dir/state/failed-$fail_verb" ]; then
  : > "$dir/state/failed-$fail_verb"
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

# Same stubbed PATH, every argument the caller's — for cases that must pass a malformed --repo.
run_raw() {
  local dir="$1"
  shift
  env PATH="$dir/bin:$PATH" "$SCRIPT" "$@" 2>&1
}

calls() { awk 'END { print NR }' "$1/calls.log"; }

TWO_PRS=$'11\tfirst\n22\tsecond\n'

echo "recheck-open-prs.sh self-test"

# --- usage ---------------------------------------------------------------
d="$WORK/usage"
make_gh "$d" ''
out=$(run_raw "$d" --repo)
rc=$?
if [ "$rc" -eq 2 ]; then
  ok "a missing --repo value is a usage error"
else
  bad "a missing --repo value is a usage error" "got exit $rc: $out"
fi

d="$WORK/slug"
make_gh "$d" ''
out=$(run_raw "$d" --repo not-a-slug)
rc=$?
if [ "$rc" -eq 2 ]; then
  ok "a malformed repository slug is refused, never addressed"
else
  bad "a malformed repository slug is refused, never addressed" "got exit $rc: $out"
fi

# --- nothing to do -------------------------------------------------------
d="$WORK/empty"
make_gh "$d" ''
out=$(run_script "$d")
rc=$?
if [ "$rc" -eq 0 ] && [ "$(calls "$d")" -eq 0 ] && [[ $out == *"nothing to re-trigger"* ]]; then
  ok "an empty listing exits 0 and mutates nothing"
else
  bad "an empty listing exits 0 and mutates nothing" "exit $rc, $(calls "$d") call(s): $out"
fi

# --- a failed listing is not an empty one --------------------------------
d="$WORK/listfail"
make_gh "$d" "$TWO_PRS"
: > "$d/listing-fails"
out=$(run_script "$d")
rc=$?
if [ "$rc" -eq 2 ] && [ "$(calls "$d")" -eq 0 ]; then
  ok "a failed listing exits 2 rather than reading as no open PRs"
else
  bad "a failed listing exits 2 rather than reading as no open PRs" \
    "exit $rc, $(calls "$d") call(s): $out"
fi

# --- dry run -------------------------------------------------------------
d="$WORK/dry"
make_gh "$d" "$TWO_PRS"
out=$(run_script "$d" --dry-run)
rc=$?
if [ "$rc" -eq 0 ] && [ "$(calls "$d")" -eq 0 ] && [[ $out == *"would re-trigger #11"* ]] \
  && [[ $out == *"would re-trigger #22"* ]]; then
  ok "--dry-run reports every PR and mutates nothing"
else
  bad "--dry-run reports every PR and mutates nothing" "exit $rc, $(calls "$d") call(s): $out"
fi

# --- the happy path, and the ORDER that makes it safe --------------------
d="$WORK/happy"
make_gh "$d" "$TWO_PRS" "" "22=armed"
out=$(run_script "$d")
rc=$?
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
# Auto-merge is read per PR, not once for the sweep — that is what makes the state current.
if [ "$(grep -c 'pr view' "$d/calls.log")" -eq 2 ]; then
  ok "auto-merge is read once per PR, immediately before closing it"
else
  bad "auto-merge is read once per PR, immediately before closing it" "$log"
fi
# Restored only where it was armed. Arming one that was not is a merge nobody asked for.
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

# --- auto-merge disabled between the sweep and the close -----------------
# The window CodeRabbit named: a snapshot taken at listing time would re-arm an auto-merge the
# user turned off in between. Reading per PR is what closes it, so the state is changed after
# the listing and before this PR's own read.
d="$WORK/amrace"
make_gh "$d" "$TWO_PRS" "" "11=armed 22=armed"
cat > "$d/on-view" <<EOF
#!/usr/bin/env bash
# Once #11 has been read, the user disables auto-merge on #22.
[ "\$1" = "11" ] && printf 'none' > "$d/state/am-22"
exit 0
EOF
chmod +x "$d/on-view"
out=$(run_script "$d")
rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep -c 'pr merge 11' "$d/calls.log")" -eq 1 ] \
  && [ "$(grep -c 'pr merge 22' "$d/calls.log")" -eq 0 ]; then
  ok "auto-merge disabled after the listing is not re-armed"
else
  bad "auto-merge disabled after the listing is not re-armed" "exit $rc" "$(cat "$d/calls.log")"
fi

# --- the sweep is complete past one API page -----------------------------
# `gh pr list --limit N` caps at N and silently drops the rest, which is this script's own
# failure mode one level down. 101 PRs is one more than that cap.
d="$WORK/many"
many=$(awk 'BEGIN { for (i = 1; i <= 101; i++) printf "%d\tpr %d\n", i, i }')
make_gh "$d" "$many"
out=$(run_script "$d" --dry-run)
rc=$?
if [ "$rc" -eq 0 ] && [[ $out == *"on 101 open PR(s)"* ]] && [[ $out == *"would re-trigger #101"* ]]; then
  ok "every PR past the 100-item cap is swept"
else
  bad "every PR past the 100-item cap is swept" "exit $rc: $(printf '%s' "$out" | tail -3)"
fi

# --- a failing reopen must be reported, and the retry must WORK ----------
d="$WORK/reopenfail"
make_gh "$d" "$TWO_PRS" reopen
out=$(run_script "$d")
rc=$?
if [ "$rc" -eq 1 ] && [[ $out == *"could not be reopened"* ]]; then
  ok "a failing reopen exits nonzero and names the PR"
else
  bad "a failing reopen exits nonzero and names the PR" "exit $rc: $out"
fi
# The trap is the safety net, and the stub fails only the FIRST reopen — so this asserts the
# retry actually succeeds, not merely that one was attempted.
if [ "$(grep -c 'pr reopen 11' "$d/calls.log")" -ge 2 ] \
  && [[ $out != *"could not be reopened; reopen it by hand"* ]]; then
  ok "the exit trap retries a PR left closed, and the retry succeeds"
else
  bad "the exit trap retries a PR left closed, and the retry succeeds" "$(cat "$d/calls.log")" "$out"
fi

# --- a failing close leaves that PR untouched ----------------------------
d="$WORK/closefail"
make_gh "$d" "$TWO_PRS" close
out=$(run_script "$d")
rc=$?
# #11's close fails, so it is never reopened and never recorded as closed; #22 proceeds normally.
if [ "$rc" -eq 1 ] && [ "$(grep -c 'pr reopen 11' "$d/calls.log")" -eq 0 ]; then
  ok "a PR that could not be closed is never reopened, and the run fails"
else
  bad "a PR that could not be closed is never reopened, and the run fails" \
    "exit $rc" "$(cat "$d/calls.log")"
fi

# --- an unreadable auto-merge state leaves the PR untouched --------------
d="$WORK/amfail"
make_gh "$d" "$TWO_PRS"
cat > "$d/bin/gh" <<EOF
#!/usr/bin/env bash
log="$d/calls.log"
case "\$1 \$2" in
  "api --paginate") cat "$d/listing.tsv"; exit 0 ;;
  "pr view") printf '%s\n' "pr view \$3" >> "\$log"; exit 1 ;;
esac
printf '%s\n' "\$1 \$2 \$3" >> "\$log"
exit 0
EOF
chmod +x "$d/bin/gh"
out=$(run_script "$d")
rc=$?
if [ "$rc" -eq 1 ] && [ "$(grep -c 'pr close' "$d/calls.log")" -eq 0 ] \
  && [[ $out == *"auto-merge state could not be read"* ]]; then
  ok "a PR whose auto-merge state cannot be read is left untouched"
else
  bad "a PR whose auto-merge state cannot be read is left untouched" \
    "exit $rc" "$(cat "$d/calls.log")" "$out"
fi

# --- a malformed listing is an error, never a shorter list ---------------
d="$WORK/badlisting"
make_gh "$d" $'11\tfirst\nnot-a-number\tsecond\n'
out=$(run_script "$d" --dry-run)
rc=$?
if [ "$rc" -eq 2 ] && [[ $out == *"malformed"* ]]; then
  ok "a malformed listing fails closed rather than reading as a shorter list"
else
  bad "a malformed listing fails closed rather than reading as a shorter list" "exit $rc: $out"
fi

echo "-----------------------------------------"
echo "recheck-open-prs.sh self-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
