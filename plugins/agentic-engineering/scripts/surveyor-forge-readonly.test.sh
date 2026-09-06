#!/usr/bin/env bash
# Hermetic contract for surveyor-forge-readonly.sh: the wrapper must invoke
# forge-readonly-guard.sh --command and map exit 0 to allow / 1|2 to deny JSON.
# It does not re-prove the classifier's full matrix.
set -euo pipefail

HERE=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
WRAPPER="${HERE}/surveyor-forge-readonly.sh"
GUARD="${HERE}/forge-readonly-guard.sh"
# Capture bash before any PATH strip. Invoking the wrapper as an executable
# under a jq-less PATH fails at the `#!/usr/bin/env bash` shebang (exit 127)
# before the wrapper can emit its jq-missing deny JSON.
BASH_BIN=$(command -v bash)
[ -n "${BASH_BIN}" ] || {
  echo "FAIL: bash not on PATH"
  exit 1
}

pass=0
fail=0
pass() { pass=$((pass + 1)); }
fail() { echo "FAIL: $*" >&2; fail=$((fail + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

hook_stdin() {
  local cmd="$1"
  jq -nc --arg cmd "$cmd" '{tool_name:"Bash",tool_input:{command:$cmd}}'
}

run_wrapper() {
  local stdin="$1"
  shift
  printf '%s\n' "$stdin" | "$@"
}

# --- missing jq fails closed without consulting the guard ---
missing_jq_bin="$TMP/bin"
mkdir -p "$missing_jq_bin"
# PATH with no jq: keep the wrapper and a no-op guard, but not system jq.
cat >"$TMP/noop-guard" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/noop-guard"
out="$(
  PATH="$missing_jq_bin" SURVEYOR_FORGE_READONLY_GUARD="$TMP/noop-guard" \
    run_wrapper "$(hook_stdin 'gh pr view 1')" "$BASH_BIN" "$WRAPPER" 2>/dev/null
  true
)" || true
st="$(
  set +e
  PATH="$missing_jq_bin" SURVEYOR_FORGE_READONLY_GUARD="$TMP/noop-guard" \
    run_wrapper "$(hook_stdin 'gh pr view 1')" "$BASH_BIN" "$WRAPPER" >/dev/null 2>&1
  echo $?
)"
if [ "$st" -ne 0 ] && printf '%s\n' "$out" | grep -q '"permissionDecision":"deny"'; then
  pass
else
  fail "missing jq must deny (st=$st out=$out)"
fi

# --- invalid hook input fails closed WITH the structured deny payload ---
#
# Exit status alone is not the contract. The runtime renders
# hookSpecificOutput.permissionDecision to show the operator WHY a command was
# refused, so a wrapper that exited 2 while printing nothing would satisfy an
# exit-status-only assertion and leave every refusal unexplained. Assert both,
# the same way the missing-jq case above already does.
assert_deny_payload() {
  local label="$1" input="$2" out st
  out="$(printf '%s' "$input" | "$WRAPPER" 2>/dev/null || true)"
  st="$(
    set +e
    printf '%s' "$input" | "$WRAPPER" >/dev/null 2>&1
    echo $?
  )"
  if [ "$st" -ne 0 ] && printf '%s\n' "$out" | grep -q '"permissionDecision":"deny"'; then
    pass
  else
    fail "$label (st=$st out=$out)"
  fi
}

assert_deny_payload "empty stdin must deny" ''
assert_deny_payload "malformed JSON must deny" '{not-json'
assert_deny_payload "missing tool_input.command must deny" '{"tool_name":"Bash","tool_input":{}}'

# --- stub guard: the wrapper must pass --command and map 0 / 1 / 2 ---
cat >"$TMP/stub-guard" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" != "--command" ]; then
  echo "deny: stub expected --command, got ${1:-}" >&2
  exit 1
fi
cmd="${2:-}"
case "$cmd" in
  allow-me) exit 0 ;;
  deny-me)
    echo "deny: stub refused deny-me"
    exit 1
    ;;
  usage-me)
    echo "usage: stub usage"
    exit 2
    ;;
  *)
    echo "deny: stub unexpected command"
    exit 1
    ;;
esac
EOF
chmod +x "$TMP/stub-guard"

st="$(
  set +e
  SURVEYOR_FORGE_READONLY_GUARD="$TMP/stub-guard" \
    run_wrapper "$(hook_stdin 'allow-me')" "$WRAPPER" >/dev/null 2>&1
  echo $?
)"
if [ "$st" -eq 0 ]; then
  pass
else
  fail "stub allow must exit 0 (st=$st)"
fi

out="$(
  SURVEYOR_FORGE_READONLY_GUARD="$TMP/stub-guard" \
    run_wrapper "$(hook_stdin 'deny-me')" "$WRAPPER" 2>/dev/null
  true
)" || true
st="$(
  set +e
  SURVEYOR_FORGE_READONLY_GUARD="$TMP/stub-guard" \
    run_wrapper "$(hook_stdin 'deny-me')" "$WRAPPER" >/dev/null 2>&1
  echo $?
)"
if [ "$st" -ne 0 ] &&
  printf '%s\n' "$out" | grep -q '"permissionDecision":"deny"' &&
  printf '%s\n' "$out" | grep -q 'stub refused deny-me'; then
  pass
else
  fail "stub deny must emit deny JSON carrying the guard reason (st=$st out=$out)"
fi

out="$(
  SURVEYOR_FORGE_READONLY_GUARD="$TMP/stub-guard" \
    run_wrapper "$(hook_stdin 'usage-me')" "$WRAPPER" 2>/dev/null
  true
)" || true
st="$(
  set +e
  SURVEYOR_FORGE_READONLY_GUARD="$TMP/stub-guard" \
    run_wrapper "$(hook_stdin 'usage-me')" "$WRAPPER" >/dev/null 2>&1
  echo $?
)"
if [ "$st" -ne 0 ] && printf '%s\n' "$out" | grep -q '"permissionDecision":"deny"'; then
  pass
else
  fail "stub usage (exit 2) must deny (st=$st out=$out)"
fi

# --- a deny states its reason on stderr as well as in the JSON payload ---
#
# Exit 2 blocks the command regardless of the payload, so the JSON alone is not
# what guarantees the operator learns WHY. A runtime that derives its blocking
# message from stderr would render an unexplained refusal if the wrapper spoke
# only on stdout. Assert the reason reaches stderr, and that it is the guard's
# own reason rather than a generic placeholder.
err="$(
  set +e
  SURVEYOR_FORGE_READONLY_GUARD="$TMP/stub-guard" \
    run_wrapper "$(hook_stdin 'deny-me')" "$WRAPPER" 2>&1 >/dev/null
  true
)"
if printf '%s\n' "$err" | grep -q 'stub refused deny-me'; then
  pass
else
  fail "deny must write the guard reason to stderr (err=$err)"
fi

# The same must hold for a malformed payload, where there is no guard reason to
# forward and the wrapper supplies its own.
err="$(
  set +e
  printf '%s' '{not-json' | "$WRAPPER" 2>&1 >/dev/null
  true
)"
if printf '%s\n' "$err" | grep -q 'deny:'; then
  pass
else
  fail "malformed stdin must write a deny reason to stderr (err=$err)"
fi

# --- real guard: one admitted read and one refused mutation ---
if [ ! -x "$GUARD" ]; then
  fail "forge-readonly-guard.sh missing next to the wrapper"
else
  # The guard admits certified gh reads only once telemetry is pinned off, so
  # supply it here: this block isolates read-vs-mutation, not the telemetry rule.
  export GH_TELEMETRY=0
  st="$(
    set +e
    run_wrapper "$(hook_stdin 'gh pr view 2786 --repo devantler-tech/monorepo --json number,state,headRefOid')" \
      "$WRAPPER" >/dev/null 2>&1
    echo $?
  )"
  if [ "$st" -eq 0 ]; then
    pass
  else
    fail "real guard must allow gh pr view (st=$st)"
  fi

  out="$(
    run_wrapper "$(hook_stdin 'gh pr create --title x')" "$WRAPPER" 2>/dev/null
    true
  )" || true
  st="$(
    set +e
    run_wrapper "$(hook_stdin 'gh pr create --title x')" "$WRAPPER" >/dev/null 2>&1
    echo $?
  )"
  if [ "$st" -ne 0 ] && printf '%s\n' "$out" | grep -q '"permissionDecision":"deny"'; then
    pass
  else
    fail "real guard must deny gh pr create (st=$st out=$out)"
  fi
fi

# Discover through the real adapter, then admit and execute the returned literal
# path. Relocating the installation must not require knowing a versioned root.
# Only the external forge response is stubbed; neither guard nor classifier is.
mkdir -p "$TMP/forge-bin"
cat >"$TMP/forge-bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = 'api --paginate --slurp --method GET repos/owner/repo/actions/runs -f head_sha=1111111111111111111111111111111111111111 -f branch=main -F per_page=100' ] || exit 1
printf '%s\n' '{"total_count":1,"workflow_runs":[{"id":10,"workflow_id":11,"event":"push","conclusion":"failure","created_at":"2026-07-14T09:00:00Z","html_url":"https://example.test/fail","name":"CI"}]}'
EOF
chmod +x "$TMP/forge-bin/gh"
for install_dir in "$TMP/install-v1" "$TMP/relocated plugin 'quoted' \$literal"; do
  mkdir -p "$install_dir"
  install_dir=$(CDPATH='' cd -- "$install_dir" && pwd -P)
  cp "$GUARD" "$WRAPPER" "$HERE/classify-default-branch-ci-runs.sh" "$install_dir/"
  for probe in 'classify-default-branch-ci-runs.sh' '/incorrect/install/classify-default-branch-ci-runs.sh'; do
    st=0
    out=$(run_wrapper "$(hook_stdin "$probe")" "$install_dir/surveyor-forge-readonly.sh" 2>"$TMP/discovery.err") || st=$?
    reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
    resolved=$(printf '%s' "$reason" | jq -Rse '
      split("\n") | map(select(startswith("classifier-path-json: ")))
      | if length == 1 then .[0] | ltrimstr("classifier-path-json: ") | fromjson
        else error("missing or ambiguous classifier path") end' -r 2>/dev/null) || resolved=''
    if [ "$st" -eq 2 ] && [ "$resolved" = "$install_dir/classify-default-branch-ci-runs.sh" ] &&
      [ "$(cat "$TMP/discovery.err")" = "$reason" ]; then
      pass
    else
      fail "discovery must deny and carry the exact relocated path in JSON and stderr (st=$st)"
      continue
    fi
    # @sh produces one literal shell word, preserving quotes and dollar signs.
    # This is not eval: only the complete command that passed the guard runs.
    quoted=$(printf '%s' "$resolved" | jq -Rs '@sh' -r)
    cmd="$quoted --repo owner/repo --branch main --head-sha 1111111111111111111111111111111111111111"
    if run_wrapper "$(hook_stdin "$cmd")" "$install_dir/surveyor-forge-readonly.sh" >/dev/null 2>&1; then
      st=0
      result=$(PATH="$TMP/forge-bin:$PATH" bash -c "$cmd" 2>"$TMP/classifier.err") || st=$?
      if [ "$st" -eq 0 ] && [ "$result" = $'11\tfailure\thttps://example.test/fail\tCI\tpush\t\t2026-07-14T09:00:00Z\t10' ]; then
        pass
      else
        fail "discovered guarded classifier must return the named red workflow (st=$st)"
      fi
    else
      fail "the discovered literal remote-mode command must be admitted"
    fi
    st=0
    run_wrapper "$(hook_stdin "$quoted --input -")" "$install_dir/surveyor-forge-readonly.sh" >/dev/null 2>&1 || st=$?
    if [ "$st" -eq 2 ]; then pass; else fail 'discovery must not admit offline input'; fi
  done
  for availability in nonexecutable missing; do
    if [ "$availability" = nonexecutable ]; then
      chmod -x "$install_dir/classify-default-branch-ci-runs.sh"
    else
      rm "$install_dir/classify-default-branch-ci-runs.sh"
    fi
    st=0
    out=$(run_wrapper "$(hook_stdin 'classify-default-branch-ci-runs.sh')" "$install_dir/surveyor-forge-readonly.sh" 2>/dev/null) || st=$?
    if [ "$st" -eq 2 ] && ! printf '%s' "$out" | grep -q 'classifier-path-json:'; then
      pass
    else
      fail "a $availability classifier must deny without a usable path hint"
    fi
  done
done

# --- agent scoping (opt-in): SURVEYOR_FORGE_READONLY_SCOPE ---
#
# A PreToolUse `matcher` filters on tool name only, so a Bash matcher fires for
# every agent — including the engineer's own lane, whose writes are legitimate.
# The runtime does carry the agent identity in the same stdin this wrapper
# already parses (`agent_type`, plus `agent_id` inside a subagent call), so the
# scoping the boundary needs is available here rather than in the matcher.
#
# The gate is OPT-IN and strictly additive: with SURVEYOR_FORGE_READONLY_SCOPE
# unset the wrapper behaves exactly as before, which is what every assertion
# above continues to prove. With it set, the wrapper enforces only when the
# payload positively identifies that agent.
#
# Scoping deliberately fails OPEN while command classification keeps failing
# CLOSED. The two directions are not symmetric: this wrapper exists to constrain
# the surveyor, so if it cannot establish that it IS the surveyor it has no
# mandate to refuse — and refusing would deny every main-thread Bash call the
# moment the hook is installed. Refusing to classify a command, by contrast,
# still denies.

hook_stdin_agent() {
  local cmd="$1" agent="$2"
  jq -nc --arg cmd "$cmd" --arg agent "$agent" \
    '{tool_name:"Bash",agent_id:"sub_1",agent_type:$agent,tool_input:{command:$cmd}}'
}

scoped_status() {
  local stdin="$1" scope="$2"
  set +e
  printf '%s\n' "$stdin" |
    SURVEYOR_FORGE_READONLY_SCOPE="$scope" \
      SURVEYOR_FORGE_READONLY_GUARD="$TMP/stub-guard" "$WRAPPER" >/dev/null 2>&1
  local st=$?
  set -e
  echo "$st"
}

# In scope and mutating: the guard still decides, and still refuses.
st="$(scoped_status "$(hook_stdin_agent 'deny-me' 'portfolio-surveyor')" 'portfolio-surveyor')"
if [ "$st" -ne 0 ]; then
  pass
else
  fail "in-scope mutation must still deny (st=$st)"
fi

# In scope and admitted: the gate must not turn an allow into a deny.
st="$(scoped_status "$(hook_stdin_agent 'allow-me' 'portfolio-surveyor')" 'portfolio-surveyor')"
if [ "$st" -eq 0 ]; then
  pass
else
  fail "in-scope read must still allow (st=$st)"
fi

# A DIFFERENT subagent is out of scope: allow, even though the command is one
# the guard would refuse. This is the assertion that makes a Bash-wide matcher
# safe to install.
st="$(scoped_status "$(hook_stdin_agent 'deny-me' 'Explore')" 'portfolio-surveyor')"
if [ "$st" -eq 0 ]; then
  pass
else
  fail "a different agent must be out of scope and allowed (st=$st)"
fi

# Main thread carries no agent_type at all: out of scope, allow. Without this
# the engineer's own lane could not push once the hook is installed.
st="$(scoped_status "$(hook_stdin 'deny-me')" 'portfolio-surveyor')"
if [ "$st" -eq 0 ]; then
  pass
else
  fail "main-thread call (no agent_type) must be allowed when scoped (st=$st)"
fi

# Unparseable payload while scoped: the agent cannot be identified, so the
# wrapper has no mandate to refuse. Asserted explicitly because it is the one
# place the gate is deliberately more permissive than the unscoped default.
st="$(scoped_status '{not-json' 'portfolio-surveyor')"
if [ "$st" -eq 0 ]; then
  pass
else
  fail "unidentifiable payload must be out of scope when scoped (st=$st)"
fi

# NEGATIVE CONTROL — the gate must not leak into the default mode. With the
# scope UNSET, an out-of-scope-looking agent_type changes nothing and the
# mutation is still refused. If this ever passes as an allow, the opt-in gate
# has silently become the default and every assertion above it is void.
st="$(
  set +e
  printf '%s\n' "$(hook_stdin_agent 'deny-me' 'Explore')" |
    SURVEYOR_FORGE_READONLY_GUARD="$TMP/stub-guard" "$WRAPPER" >/dev/null 2>&1
  echo $?
)"
if [ "$st" -ne 0 ]; then
  pass
else
  fail "unscoped mode must ignore agent_type and still deny (st=$st)"
fi

# --- an out-of-scope allow is SILENT unless explicitly tracing ---
#
# Installed on a `Bash` matcher this path is taken by every main-thread call in
# every lane. A line here would print on essentially every command the engineer
# runs, and the one message that matters -- a DENY -- would be lost in it.
err="$(
  set +e
  printf '%s\n' "$(hook_stdin 'deny-me')" |
    SURVEYOR_FORGE_READONLY_SCOPE='portfolio-surveyor' \
      SURVEYOR_FORGE_READONLY_GUARD="$TMP/stub-guard" "$WRAPPER" 2>&1 >/dev/null
  true
)"
if [ -z "$err" ]; then
  pass
else
  fail "out-of-scope allow must be silent by default (err=$err)"
fi

# ...but stays diagnosable, so an operator verifying an install can tell
# "allowed, out of scope" from "allowed, the guard admitted it".
err="$(
  set +e
  printf '%s\n' "$(hook_stdin 'deny-me')" |
    SURVEYOR_FORGE_READONLY_DEBUG=1 SURVEYOR_FORGE_READONLY_SCOPE='portfolio-surveyor' \
      SURVEYOR_FORGE_READONLY_GUARD="$TMP/stub-guard" "$WRAPPER" 2>&1 >/dev/null
  true
)"
if printf '%s\n' "$err" | grep -q 'out of scope'; then
  pass
else
  fail "debug tracing must explain an out-of-scope allow (err=$err)"
fi

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
