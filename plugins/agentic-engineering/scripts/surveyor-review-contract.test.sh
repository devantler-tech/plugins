#!/usr/bin/env bash
# Structural drift guards for the generic surveyor contract (#95).
# These checks pin operative instructions, not a model's compliance with them.
# Each clause is removed independently; a copy outside its section cannot rescue it.
# See docs/surveyor-contract-coverage.md for the consumer split and behavior scenarios.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SURVEYOR="$HERE/../agents/portfolio-surveyor.agent.md"

# Report a harness failure on stderr and stop; contract diagnostics use stdout.
fail() {
  printf 'surveyor review contract: FAIL — %s\n' "$*" >&2
  exit 1
}

# Keep scopes narrower than the whole document: a phrase in an example, digest,
# or another review lane does not establish the operative rule for this lane.
scope() {
  case "$1" in
    budget) START='### 0. Budget sample'; END='### 1. Open PRs' ;;
    claims) START='### 2. Claim branches'; END='### 3. Short-circuit' ;;
    automation) START='### 3. Short-circuit'; END='### 3a. Maintainer-login' ;;
    hygiene) START='### 3b. Hygiene pentad'; END='### 3c. (e) Green-review' ;;
    connector) START='**Connector lane.**'; END='**Check-run lane.**' ;;
    check_run) START='**Check-run lane.**'; END=$'**`self@<sha>`**' ;;
    exemption) START='### 3d. Programmed-bot'; END='### 3e. Review coordination' ;;
    pagination) START='### 6. Reconcile the repo set'; END='## Return —' ;;
    reporting) START='## Return —'; END='## Survey digest —' ;;
    digest_budget) START='## Survey digest —'; END='### Operate' ;;
    digest_operate) START='### Operate'; END='### Advance' ;;
    digest_advance) START='### Advance'; END='### Digest rules' ;;
    digest_rules) START='### Digest rules'; END='' ;;
    *) fail "unknown test scope: $1" ;;
  esac
}

# A small test-only extractor. Both boundaries must exist exactly once, in order
# (the final section ends at the next heading or EOF). Whitespace is immaterial.
section_text() {
  local source=$1
  awk -v start="$START" -v end="$END" '
    index($0, start) == 1 { starts++; start_line = NR; inside = 1 }
    end != "" && index($0, end) == 1 { ends++; end_line = NR; inside = 0 }
    end == "" && inside && /^#/ && index($0, start) != 1 { inside = 0 }
    inside { text = text " " $0 }
    END {
      if (starts != 1 || (end != "" && (ends != 1 || end_line <= start_line))) exit 1
      gsub(/[[:space:]]+/, " ", text)
      sub(/^ /, "", text); sub(/ $/, "", text)
      print text
    }
  ' "$source"
}

# Emit the stable ID, owning scope, and required clause for each contract.
# The last field may itself contain pipes (the digest's literal grammar).
requirements() {
  cat <<'CLAUSES'
B01|budget|Before any other read, and again immediately before you emit the digest
B02|budget|record `remaining`/`limit` for the **graphql** and **core** budgets at both samples
B03|budget|start sample, still emit the line and mark it `EXHAUSTED_AT_START`
B04|budget|itself fails, emit `budget: unavailable:<one-word reason>` once and continue fail-closed
C01|claims|**any writer namespace the deployment's Writer namespaces section records** — not just the lane you happen to be running in
C02|claims|ends in a **takeover suffix** (`-<issue>-2`, `-3`, …)
C03|claims|**Do not gate this scan on assignees:**
C04|claims|a missing or malformed policy or timestamp makes that candidate's claim join `QUERY-UNKNOWN`
C05|claims|Report a branch that ends in `-<issue>`
A01|automation|When the consumer's contract designates dependency-update bots as automation-owned, a PR whose author is one of those **exact** bot identities is automation-owned
A02|automation|Emit only `AUTOMATION-OWNED (NO-ACTION)` from the cheap search row; do **not** deepen it, inspect its pentad or reviews
A03|automation|or count it against `nothing_on_fire`
A04|automation|Match every trusted identity by **exact login, never a substring**
H01|hygiene|Count all unresolved threads across **all pages**, regardless of author; paginate until exhausted
H02|hygiene|**Count ONLY the newest actual review** from that reviewer
H03|hygiene|Select the newest by the reviews endpoint's **submission timestamp** — not an `updated_at` field
H04|hygiene|a newest review with none means findings are cleared (`body_findings=0`); never fall back to an older review that still had sections
H05|hygiene|report `body_findings=<n>-stale@<sha>` so the orchestrator re-verifies at head rather than treating it as open
R01|connector|require its API author to exactly match the reviewer App/login that the **Trust gate** assigns to this lane
R02|connector|test whether the **head starts with** the extracted sha — never full-length string equality
R03|connector|Require at least a 10-character prefix
R04|connector|report `codex-stale@<sha>`, never `none`
R05|connector|`none` is reserved for a marker that is **absent, malformed, or shorter than 10 characters**
R06|connector|HEAD-MATCH DECIDES FIRST — never rank the two surfaces by recency
R07|connector|a clean pass naming the head wins **even when a findings object exists at an older sha**
R08|connector|Same-sha tie-break: FINDINGS WIN by default
R09|connector|every finding thread carries a later disclosed resolution reply from the exact maintainer login and is resolved
R10|connector|a later authenticated re-request follows the latest such reply
R11|connector|the clean marker names the head and post-dates that re-request
R12|connector|skip the backticks
K01|check_run|The green lives on a check-run — not a review and not a comment
K02|check_run|conclusion alone cannot separate them, so **read `output.title` too**
K03|check_run|`bugbot-findings@<sha>` + details URL ⇒ **NEEDS-FIX**
K04|check_run|`bugbot-error@<sha>` + a LANE-SIGNAL row; `green_review` is `none`
K05|check_run|Match this lane on the CHECK-RUN only, never on its bot login
K06|check_run|An approval, comment, or review object from that login is **never** a green
E01|exemption|Apply that exemption **only** when the consumer's contract names an **exact classifier** and that classifier exits 0
E02|exemption|the complete commit list from the forge's commits endpoint (not a summary field that omits raw committer provenance)
E03|exemption|The last commit must equal the head, so an adaptation commit revokes the exemption
E04|exemption|exit 2 or any query/classifier failure is a survey error and **fails closed**
E05|exemption|report `green_review=exempt-programmed-bot` and never classify them NEEDS-FIX for lacking a review — their (a)–(d) hygiene still counts
P01|pagination|if a result set reaches it, paginate or raise it and say so, rather than surveying a partial list
T01|reporting|**A bare `none` is never emittable**
T02|reporting|**Per-lane, never combined:** an aggregate count lets one lane's stale artifact mask another lane's missed one
T03|reporting|`usage-limit` is the spend-exhausted reason — distinct from `rate-limit` because it states no window and only the maintainer can lift it
D01|digest_budget|budget: graphql=<start>→<end>/<limit> · core=<start>→<end>/<limit>[ · EXHAUSTED_AT_START]
D02|digest_operate|lane_signal=<lane>:<rate-limit|usage-limit|error>@<UTC time>
D03|digest_advance|CLAIMED: assignee=<login>|none(<lane>), claim-branch=<name>, no open PR
D04|digest_rules|**Always emit the `budget:` line.**
D05|digest_rules|Any mandatory query — enumeration, pagination, or a review-surface query — that remains failed after the bounded split recovery contract makes its affected candidates incomplete
D06|digest_rules|An incomplete candidate can never be classified clean: no `CLEAR`, `MERGE-READY`, `REVIEW-READY`, or "no signal"
D07|digest_rules|**(2) Lanes that cannot assign:** the branch alone is enough
D08|digest_rules|Apply the consumer's declared duration and timestamp source from step 2 before using it as selection skip evidence
CLAUSES
}

# Check a supplied definition without changing it. Print every missing rule on
# stdout and return 1 if any rule or section is missing; otherwise return 0.
check_contract() {
  local source=$1 id group clause text missing=0 START END
  while IFS='|' read -r id group clause; do
    scope "$group"
    if ! text=$(section_text "$source"); then
      printf 'missing section: %s (%s)\n' "$group" "$id"
      missing=1
    elif [[ "$text" != *"$clause"* ]]; then
      printf 'missing contract: %s\n' "$id"
      missing=1
    fi
  done < <(requirements)
  return "$missing"
}

# Test-only entrypoint for an explicit RED check on a separately mutated file.
if [ "${1:-}" = '--check' ] && [ "$#" -eq 2 ]; then
  check_contract "$2"
  exit
fi
[ "$#" -eq 0 ] || fail 'usage: surveyor-review-contract.test.sh [--check FILE]'

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
check_contract "$SURVEYOR" || fail 'the shipped definition lost an operative contract'

# Boundary order matters independently of clause presence. Preserve every line
# while moving the connector's end before its start, then try rescuing a removed
# clause from a later example. Neither malformed definition may be accepted.
scope connector
awk -v start="$START" -v end="$END" '
  { lines[NR] = $0 }
  index($0, start) == 1 { starting = NR }
  index($0, end) == 1 { ending = NR }
  END {
    for (i = 1; i <= NR; i++) {
      if (i == starting) print lines[ending]
      if (i != ending) print lines[i]
    }
  }
' "$SURVEYOR" > "$WORK/reordered.md"
awk '
  { gsub(/Require at least a 10-character prefix/, ""); print }
  END { print "\n## Non-operative example\nRequire at least a 10-character prefix" }
' "$WORK/reordered.md" > "$WORK/reordered-rescued.md"
awk -v end="$END" 'index($0, end) != 1' "$SURVEYOR" > "$WORK/missing-end.md"
awk -v end="$END" '{ print; if (index($0, end) == 1) print }' "$SURVEYOR" > "$WORK/repeated-end.md"
for boundary in reordered reordered-rescued missing-end repeated-end; do
  if check_contract "$WORK/$boundary.md" > "$WORK/output"; then
    fail "$boundary: malformed section boundaries were accepted"
  fi
  grep -Fq 'missing section: connector (' "$WORK/output" || fail "$boundary: unrelated rejection"
done

# Replace just one already-validated section. The replacement retains its start
# marker and its neighboring section; the other sections remain byte-identical.
replace_section() {
  local replacement=$1
  awk -v start="$START" -v end="$END" -v replacement="$replacement" '
    index($0, start) == 1 { inside = 1; print replacement; next }
    inside && end != "" && index($0, end) == 1 { inside = 0 }
    !inside { print }
  ' "$SURVEYOR"
}

total=0
while IFS='|' read -r id group clause; do
  scope "$group"
  text=$(section_text "$SURVEYOR")
  tail_text=${text#*"$clause"}
  [[ "$tail_text" != *"$clause"* ]] || fail "$id: mutation is ambiguous (clause occurs twice)"

  # Reflowing the same content is a positive control for the mutation renderer.
  replace_section "$text" > "$WORK/reflow.md"
  check_contract "$WORK/reflow.md" > "$WORK/output" || fail "$id: whitespace-only reflow was rejected"

  mutated=${text/"$clause"/}
  [ "$mutated" != "$text" ] || fail "$id: removal made no change"
  replace_section "$mutated" > "$WORK/mutant.md"
  printf '\n## Non-operative example\n%s\n' "$clause" >> "$WORK/mutant.md"
  if check_contract "$WORK/mutant.md" > "$WORK/output"; then
    fail "$id: out-of-section wording rescued the removed contract"
  fi
  grep -Fxq "missing contract: $id" "$WORK/output" || fail "$id: mutation failed for an unrelated reason"
  total=$((total + 1))
done < <(requirements)

: > "$WORK/empty.md"
if check_contract "$WORK/empty.md" > "$WORK/output"; then
  fail 'an empty definition was accepted'
fi

printf 'surveyor review contract: PASS (%s clauses; each removal rejected, each reflow accepted; four malformed boundaries and empty definition rejected)\n' "$total"
