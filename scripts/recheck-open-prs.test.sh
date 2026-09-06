#!/usr/bin/env bash
# Self-test for recheck-open-prs.sh.
#
# Hermetic: stubs `gh` on PATH and records every call, so nothing here reaches the network or
# mutates a real pull request. The stub keeps per-PR state (open/closed, auto-merge armed or not,
# its commit metadata) and answers reads from it, so the cases below assert what the script leaves
# BEHIND — no pull request closed, no auto-merge lost — rather than only which calls it made.
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

# make_gh <dir> <listing-tsv> [fail-verb] [armed-numbers]
#   fail-verb      that verb's FIRST call fails; later calls succeed, so a recovery path is
#                  exercised as one that can actually complete rather than one that cannot.
#   armed-numbers  space-separated PR numbers that start with auto-merge armed.
# The stub maintains real state under <dir>/db, so "was it left closed" is answerable.
make_gh() {
  local dir="$1" listing="$2" fail_verb="${3:-}" armed="${4:-}"
  mkdir -p "$dir/bin" "$dir/db"
  printf '%s' "$listing" > "$dir/listing.tsv"
  local n
  for n in $armed; do
    printf 'armed' > "$dir/db/am-$n"
    printf 'custom subject %s' "$n" > "$dir/db/headline-$n"
    printf 'custom body %s' "$n" > "$dir/db/body-$n"
  done
  cat > "$dir/bin/gh" <<EOF
#!/usr/bin/env bash
db="$dir/db"
log="$dir/calls.log"
fail_verb="$fail_verb"
verb="\$1 \$2"

# The paginated listing. Asserted on shape as well as content: the query must be passed as GET
# fields, never spliced into the path, or a branch name containing & or # would select something
# else entirely.
if [ "\$verb" = "api --paginate" ]; then
  printf '%s\n' "api \$*" >> "\$log"
  [ -f "$dir/listing-fails" ] && exit 1
  cat "$dir/listing.tsv"
  exit 0
fi

n=\$3
fields=""
prev=""
for a in "\$@"; do
  [ "\$prev" = "--json" ] && fields=\$a
  prev=\$a
done

case "\$verb" in
  "pr view")
    printf '%s\n' "pr view \$n \$fields" >> "\$log"
    [ -f "\$db/viewfail" ] && exit 1
    if [ -f "\$db/closed-\$n" ]; then st=CLOSED; else st=OPEN; fi
    [ -f "\$db/merged-\$n" ] && st=MERGED
    if [ -f "\$db/am-\$n" ]; then
      method=\$(cat "\$db/method-\$n" 2>/dev/null || printf 'SQUASH')
      head=\$(cat "\$db/headline-\$n" 2>/dev/null)
      body=\$(cat "\$db/body-\$n" 2>/dev/null)
      am=\$(printf '{"mergeMethod":"%s","commitHeadline":"%s","commitBody":"%s"}' "\$method" "\$head" "\$body")
    else
      am=null
    fi
    case "\$fields" in
      "state,autoMergeRequest")
        printf '{"state":"%s","autoMergeRequest":%s}\n' "\$st" "\$am"
        ;;
      state)
        printf '%s\n' "\$st"
        ;;
      autoMergeRequest)
        if [ "\$am" = null ]; then printf 'none\n'; else printf 'armed\n'; fi
        ;;
    esac
    # A hook the caller uses to change state between the sweep and this PR's close.
    [ -x "$dir/on-view" ] && "$dir/on-view" "\$n"
    exit 0
    ;;
  "pr close")
    printf '%s\n' "pr close \$n" >> "\$log"
    if [ "\$fail_verb" = "close-applied" ] && [ ! -f "\$db/failed-close" ]; then
      # The ambiguous case: GitHub applies the close, the client still reports failure.
      : > "\$db/failed-close"; : > "\$db/closed-\$n"; rm -f "\$db/am-\$n"; exit 1
    fi
    if [ "\$fail_verb" = "close" ] && [ ! -f "\$db/failed-close" ]; then
      : > "\$db/failed-close"; exit 1
    fi
    : > "\$db/closed-\$n"
    # Closing a pull request clears an armed auto-merge, exactly as GitHub does.
    rm -f "\$db/am-\$n"
    exit 0
    ;;
  "pr reopen")
    printf '%s\n' "pr reopen \$n" >> "\$log"
    if [ "\$fail_verb" = "reopen" ] && [ ! -f "\$db/failed-reopen" ]; then
      : > "\$db/failed-reopen"; exit 1
    fi
    rm -f "\$db/closed-\$n"
    exit 0
    ;;
  "pr merge")
    printf '%s\n' "pr merge \$*" >> "\$log"
    if [ "\$fail_verb" = "merge" ] && [ ! -f "\$db/failed-merge" ]; then
      : > "\$db/failed-merge"; exit 1
    fi
    : > "\$db/am-\$n"
    exit 0
    ;;
esac
printf '%s\n' "\$verb \$n" >> "\$log"
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
# Left closed? The stub's own state, not an inference from the call log.
count_state() {
  local dir=$1 prefix=$2 f c=0
  for f in "$dir"/"$prefix"*; do
    [ -e "$f" ] && c=$((c + 1))
  done
  printf '%s' "$c"
}
left_closed() { count_state "$1/db" closed-; }
armed_count() { count_state "$1/db" am-; }

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
if [ "$rc" -eq 0 ] && [[ $out == *"nothing to re-trigger"* ]] \
  && [ "$(grep -c '^pr ' "$d/calls.log")" -eq 0 ]; then
  ok "an empty listing exits 0 and mutates nothing"
else
  bad "an empty listing exits 0 and mutates nothing" "exit $rc: $out" "$(cat "$d/calls.log")"
fi

# --- a failed listing is not an empty one --------------------------------
d="$WORK/listfail"
make_gh "$d" "$TWO_PRS"
: > "$d/listing-fails"
out=$(run_script "$d")
rc=$?
if [ "$rc" -eq 2 ] && [ "$(grep -c '^pr ' "$d/calls.log")" -eq 0 ]; then
  ok "a failed listing exits 2 rather than reading as no open PRs"
else
  bad "a failed listing exits 2 rather than reading as no open PRs" "exit $rc: $out"
fi

# --- the branch reaches the API as a field, not as path text -------------
# A branch may legally contain `&` or `#`; spliced into a query string it would select a
# different set of pull requests, or truncate the query outright.
d="$WORK/encode"
make_gh "$d" ''
out=$(run_script "$d" --base 'release&state=closed')
rc=$?
api=$(grep '^api ' "$d/calls.log")
if [ "$rc" -eq 0 ] && [[ $api == *"--method GET"* ]] \
  && [[ $api == *"-f base=release&state=closed"* ]] && [[ $api != *"repos/owner/name/pulls?"* ]]; then
  ok "the base branch is passed as a GET field, never spliced into the path"
else
  bad "the base branch is passed as a GET field, never spliced into the path" "exit $rc" "$api"
fi

# --- dry run -------------------------------------------------------------
d="$WORK/dry"
make_gh "$d" "$TWO_PRS"
out=$(run_script "$d" --dry-run)
rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep -c '^pr ' "$d/calls.log")" -eq 0 ] \
  && [[ $out == *"would re-trigger #11"* ]] && [[ $out == *"would re-trigger #22"* ]]; then
  ok "--dry-run reports every PR and mutates nothing"
else
  bad "--dry-run reports every PR and mutates nothing" "exit $rc: $out" "$(cat "$d/calls.log")"
fi

# --- the happy path, and the ORDER that makes it safe --------------------
d="$WORK/happy"
make_gh "$d" "$TWO_PRS" "" "22"
out=$(run_script "$d")
rc=$?
log=$(cat "$d/calls.log")
if [ "$rc" -eq 0 ] && [ "$(left_closed "$d")" -eq 0 ]; then
  ok "every PR is left open"
else
  bad "every PR is left open" "exit $rc" "$log"
fi
if [ "$(grep -n 'pr close 11' "$d/calls.log" | cut -d: -f1)" -lt \
  "$(grep -n 'pr reopen 11' "$d/calls.log" | cut -d: -f1)" ]; then
  ok "close precedes reopen for the same PR"
else
  bad "close precedes reopen for the same PR" "$log"
fi
if [ "$(grep -c 'pr view 11 state,autoMergeRequest' "$d/calls.log")" -ge 1 ] \
  && [ "$(grep -c 'pr view 22 state,autoMergeRequest' "$d/calls.log")" -ge 1 ]; then
  ok "state and auto-merge are read per PR, immediately before closing it"
else
  bad "state and auto-merge are read per PR, immediately before closing it" "$log"
fi
if [ "$(grep -c 'pr merge 22' "$d/calls.log")" -eq 1 ] \
  && [ "$(grep -c 'pr merge 11' "$d/calls.log")" -eq 0 ]; then
  ok "auto-merge is re-armed only on the PR that had it armed"
else
  bad "auto-merge is re-armed only on the PR that had it armed" "$log"
fi
# The maintainer's chosen squash message must survive the round trip; recreating the request with
# defaults would discard it silently.
if [[ $log == *"--subject custom subject 22"* ]] && [[ $log == *"--body custom body 22"* ]]; then
  ok "a custom auto-merge subject and body are restored, not defaulted"
else
  bad "a custom auto-merge subject and body are restored, not defaulted" "$log"
fi
if [[ $log == *"pr close 22"* ]]; then
  ok "a draft PR is re-triggered too"
else
  bad "a draft PR is re-triggered too" "$log"
fi

# --- auto-merge disabled between the sweep and the close -----------------
d="$WORK/amrace"
make_gh "$d" "$TWO_PRS" "" "11 22"
cat > "$d/on-view" <<EOF
#!/usr/bin/env bash
# Once #11 has been read, the user disables auto-merge on #22.
[ "\$1" = "11" ] && rm -f "$d/db/am-22"
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
if [ "$(left_closed "$d")" -eq 0 ] && [[ $out != *"reopen it by hand"* ]]; then
  ok "the exit trap reopens a PR left closed, and the retry succeeds"
else
  bad "the exit trap reopens a PR left closed, and the retry succeeds" \
    "$(left_closed "$d") still closed" "$out"
fi

# --- a close that was APPLIED but reported failure -----------------------
# The dangerous shape: a lost response or a timeout. Dropping the record on a nonzero exit would
# leave the PR closed with nothing tracking it, so the trap must decide from the real state.
d="$WORK/closeambiguous"
make_gh "$d" "$TWO_PRS" close-applied
out=$(run_script "$d")
rc=$?
if [ "$(left_closed "$d")" -eq 0 ]; then
  ok "a close that reported failure but was applied is still reopened"
else
  bad "a close that reported failure but was applied is still reopened" \
    "exit $rc" "$(ls -1 "$d/db")" "$out"
fi

# --- a failing close that really did not apply ---------------------------
d="$WORK/closefail"
make_gh "$d" "$TWO_PRS" close
out=$(run_script "$d")
rc=$?
if [ "$rc" -eq 1 ] && [ "$(left_closed "$d")" -eq 0 ]; then
  ok "a PR whose close failed is left open, and the run fails"
else
  bad "a PR whose close failed is left open, and the run fails" "exit $rc" "$(cat "$d/calls.log")"
fi

# --- a transient re-arm failure is recovered, not lost -------------------
# Once the close has cleared the request, a later run cannot tell the PR ever had auto-merge
# armed — so if this run drops the obligation, it is gone for good.
d="$WORK/mergefail"
make_gh "$d" "$TWO_PRS" merge "22"
out=$(run_script "$d")
rc=$?
if [ "$rc" -eq 1 ] && [ "$(armed_count "$d")" -eq 1 ] && [[ $out != *"re-arm it by hand"* ]]; then
  ok "a transient re-arm failure is retried by the exit trap and restored"
else
  bad "a transient re-arm failure is retried by the exit trap and restored" \
    "exit $rc, armed=$(armed_count "$d")" "$out"
fi

# --- an unreadable auto-merge state leaves the PR untouched --------------
d="$WORK/amfail"
make_gh "$d" "$TWO_PRS"
: > "$d/db/viewfail"
out=$(run_script "$d")
rc=$?
if [ "$rc" -eq 1 ] && [ "$(grep -c 'pr close' "$d/calls.log")" -eq 0 ] \
  && [[ $out == *"state could not be read"* ]]; then
  ok "a PR whose state cannot be read is left untouched"
else
  bad "a PR whose state cannot be read is left untouched" \
    "exit $rc" "$(cat "$d/calls.log")" "$out"
fi

# --- the original merge strategy survives the round trip -----------------
# Recreating a merge-commit or rebase auto-merge as a squash would change the merge behaviour the
# maintainer chose, not just its message.
d="$WORK/strategy"
make_gh "$d" "$TWO_PRS" "" "11 22"
printf 'REBASE' > "$d/db/method-11"
printf 'MERGE' > "$d/db/method-22"
out=$(run_script "$d")
rc=$?
log=$(cat "$d/calls.log")
if [ "$rc" -eq 0 ] && [[ $log == *"pr merge 11 --repo owner/name --auto --rebase"* ]] \
  && [[ $log == *"pr merge 22 --repo owner/name --auto --merge"* ]]; then
  ok "the original auto-merge strategy is restored, not replaced with squash"
else
  bad "the original auto-merge strategy is restored, not replaced with squash" "exit $rc" "$log"
fi
# A rebase carries no commit message, so the message flags must not ride along with it.
if [[ $log != *"--rebase --subject"* ]] && [[ $log == *"--merge --subject custom subject 22"* ]]; then
  ok "commit metadata accompanies a merge or squash, never a rebase"
else
  bad "commit metadata accompanies a merge or squash, never a rebase" "$log"
fi

# --- a PR closed after the listing is left alone -------------------------
# The listing is a snapshot. Reopening a pull request the maintainer closed in the meantime would
# reverse a deliberate act, and a read of auto-merge alone would not notice: it succeeds for a
# closed pull request too.
d="$WORK/closedafter"
make_gh "$d" "$TWO_PRS"
cat > "$d/on-view" <<EOF
#!/usr/bin/env bash
# While #11 is being handled, the maintainer closes #22.
[ "\$1" = "11" ] && : > "$d/db/closed-22"
exit 0
EOF
chmod +x "$d/on-view"
out=$(run_script "$d")
rc=$?
if [ "$rc" -eq 0 ] && [ "$(grep -c 'pr close 22' "$d/calls.log")" -eq 0 ] \
  && [ "$(grep -c 'pr reopen 22' "$d/calls.log")" -eq 0 ] && [[ $out == *"skipped #22"* ]]; then
  ok "a PR closed after the listing is skipped, not reopened"
else
  bad "a PR closed after the listing is skipped, not reopened" "exit $rc" "$(cat "$d/calls.log")" "$out"
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
