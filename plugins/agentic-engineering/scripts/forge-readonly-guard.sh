#!/usr/bin/env bash
#
# forge-readonly-guard.sh
#
# Decides whether a candidate shell command is provably a read against the
# source forge, so a runtime can enforce the portfolio-surveyor's read-only
# boundary by construction instead of trusting the model to honour it.
#
# The surveyor's definition already states the boundary in prose — "your shell
# access exists solely to run the source-forge CLI's read verbs" — and asks
# deployments to enforce it in the permission/guard layer. This is the decision
# procedure that layer calls. It is tool-neutral: a Claude Code PreToolUse hook,
# a Codex approval guard, and a plain wrapper all ask the same question.
#
#   forge-readonly-guard.sh --command '<command>'
#   <command> | forge-readonly-guard.sh --stdin
#
#   exit 0  allowed — every pipeline segment is a recognised read
#   exit 1  denied  — prints `deny: <reason>`
#   exit 2  usage error
#
# Deny by default, in two layers.
#
# LAYER 1 — resolve one literal argument vector, or refuse. The command is
# walked once to split it on unquoted `|` and refuse every construct that could
# smuggle a second command in, then walked again to produce the argv the shell
# itself would build: quotes removed, escapes applied, words split only where
# the shell would split them. Whatever the guard cannot resolve to a literal it
# REFUSES rather than guesses at — brace expansion, ANSI-C quoting and globbing
# all rewrite a word into something the guard never saw, and the rewritten form
# is precisely what classification depends on.
#
# LAYER 2 — classify that argv against an allowlist. A subcommand, a flag, or a
# filter operand that is not positively recognised as a read is denied, so a new
# or renamed verb fails closed rather than passing unnoticed.
#
# The split matters: a guard that classifies command TEXT is re-implementing the
# shell's parser, and it loses. Every bypass found in review was another
# spelling of a word bash rewrites before the program sees it — an attached
# flag, `{a,b}`, `$'\x6d'`, a delimiter inside a sed flag. Resolving argv first
# deletes that whole class instead of blacklisting its members one at a time.
#
# Three limits are deliberate and stated rather than hidden:
#
#   * Parameter expansion is allowed, because the surveyor's own prescriptions
#     use it, and it is the one expansion the guard cannot resolve without
#     knowing the environment. A deployment that also lets the agent set
#     arbitrary environment variables must constrain that separately.
#   * The allowlists are the surveyor's measured vocabulary, not every read a
#     forge CLI offers. Widening one is a reviewed edit here, which is the
#     point — and a false deny reports the flag it did not recognise, so the
#     widening is a one-line change rather than an investigation.
#   * A consuming deployment's own reviewed classifiers are admitted only when
#     that deployment DECLARES them, in the hook environment, as absolute paths
#     (SURVEYOR_FORGE_READONLY_CLASSIFIERS). Declaring a path is a trust
#     assertion the guard cannot verify — see the variable's own note below —
#     so it is deliberately not inferable from the filesystem, from a directory
#     convention, or from anything the classified agent can write. Unset admits
#     nothing.
#   * Git resolves configuration AFTER parsing, so no inspection of argv can show
#     what a configuration key names. Where the effect is unconditional the guard
#     acts: it excludes the remote-contacting verbs, whose URL comes from
#     `remote.<name>.url`, and requires `--no-ext-diff`/`--no-textconv` on a
#     patch-producing read. `core.pager` is the residue — it runs only when git's
#     output is a terminal, so a request to page (`--paginate`) is refused, but a
#     deployment that attaches a TTY should also set `GIT_PAGER=cat`. What argv
#     cannot express, a guard over argv cannot certify.
#   Environment: GitHub CLI's default telemetry creates gh/device-id on an
#     otherwise-allowed read. The guard therefore requires a disabling
#     GH_TELEMETRY (0 or false) in the process environment before it classifies
#     any gh segment; argv cannot carry that value (an env-prefixed command is
#     denied). Deployments must export GH_TELEMETRY=0 in the runtime that
#     invokes gh, the same way a TTY-attached host should set GIT_PAGER=cat.
#
# Written for bash 3.2 so it runs on a stock macOS agent host as well as CI.
#
set -euo pipefail

GUARD_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
DEFAULT_BRANCH_CLASSIFIER="${GUARD_DIR}/classify-default-branch-ci-runs.sh"

# Consumer-declared, stdin-only classifiers (default: none).
#
# The guard bundles exactly one local helper, its own BASH_SOURCE sibling. A
# CONSUMING deployment also ships reviewed classifiers the surveyor is told to
# call — the PR-ownership disclosure classifier is the measured case — and those
# had no allowed shape at all: denied leading (not a forge command) and denied as
# a filter (not on the allowlist). The surveyor's documented fallback is to
# re-derive the match by hand, on a surface its own definition marks hazardous,
# and that substitution has already misread live maintainer PRs.
#
# Colon-separated ABSOLUTE paths, supplied by the same hook configuration that
# supplies SURVEYOR_FORGE_READONLY_SCOPE. Unset — the default — leaves behaviour
# byte-identical to before, so this is strictly additive.
#
# Three properties keep the widening narrow, and all three are enforced below:
#
#   * NON-LEADING ONLY. The pipeline must still start at the forge, so a
#     declared classifier only ever consumes forge output on stdin. It can never
#     be the thing that opens a local file, which is the invariant that keeps
#     `cat ~/.config/gh/hosts.yml` out.
#   * STDIN-ONLY ARGV. Exactly `--input -` and nothing else. No path operand, no
#     repository or PR selector, so argv cannot redirect it at the filesystem or
#     at a second network target.
#   * EXACT ABSOLUTE MATCH. No PATH lookup and no basename comparison, so a
#     same-named script earlier on PATH is not the declared one.
#
# What this CANNOT do is verify that a declared path is in fact a read-only
# filter. Declaring one asserts it, exactly as the allowlists above assert that
# `gh pr list` reads. That is why the list lives in the hook environment — the
# guard's own trust domain, which the classified agent does not write — and why
# an empty value admits nothing rather than everything.
CONSUMER_CLASSIFIERS="${SURVEYOR_FORGE_READONLY_CLASSIFIERS:-}"

deny() {
  printf 'deny: %s\n' "$1"
  exit 1
}

die() {
  printf 'forge-readonly-guard: %s\n' "$1" >&2
  exit 2
}

# Filters with no in-language write primitive: without shell redirection, which
# the scanner already refuses, none of these can create or modify a file. awk is
# absent on purpose — its `print > "file"` needs no shell redirection at all.
#
# Not writing is only half of it: a filter that takes a FILE operand reads local
# state, and `cat ~/.config/gh/hosts.yml` is a credential read wearing a filter's
# name. So a filter may never open the pipeline, and each one is held to a
# whitelist of flags plus a cap on positional operands — enough for the pattern
# or program it needs, never enough for a path.
#
# Per filter: flags that stand alone, flags that consume the next word, and how
# many positional operands the filter legitimately takes on stdin.
FILTER_FLAGS_JQ=" -r -c -e -n -s -j -a -R --tab --slurp --raw-output --compact-output --exit-status --raw-input --null-input --args "
FILTER_VALUE_FLAGS_JQ=" --indent "
FILTER_FLAGS_GREP=" -E -F -i -v -c -o -q -n -h -w -x -s --line-buffered --extended-regexp --fixed-strings --ignore-case --invert-match --count --only-matching --quiet "
FILTER_VALUE_FLAGS_GREP=" -e -m -A -B -C --regexp --max-count --after-context --before-context --context "
FILTER_FLAGS_SORT=" -u -r -n -h -b -f -V --unique --reverse --numeric-sort --version-sort "
FILTER_VALUE_FLAGS_SORT=" -k -t --key --field-separator "
# `sort` is the one filter here that can touch the filesystem at all: past its
# in-memory buffer GNU sort spills to a temporary file. It stays allowed, and the
# reason is what the flag lists must keep true — every spelling that would let a
# caller AIM that write is withheld. `-o`/`--output` names an output file, `-T`/
# `--temporary-directory` chooses where the spill lands, `-S`/`--buffer-size`
# lowers the threshold that triggers it, and `--files0-from` reads a file list;
# none is allowlisted, so the residue is an internal temp file sort creates and
# unlinks in `$TMPDIR`, unreachable from argv. That is a different thing from the
# workspace/credential writes this guard exists to stop.

FILTER_FLAGS_HEADTAIL=" -q -v "
FILTER_VALUE_FLAGS_HEADTAIL=" -n -c --lines --bytes "
FILTER_FLAGS_UNIQ=" -c -d -u -i --count --repeated --unique "
FILTER_FLAGS_WC=" -l -w -c -m --lines --words --chars "
FILTER_FLAGS_CUT=" -s --only-delimited "
FILTER_VALUE_FLAGS_CUT=" -d -f -c -b --delimiter --fields --characters --bytes "
FILTER_FLAGS_TR=" -d -s -c -C --delete --squeeze-repeats --complement "
FILTER_FLAGS_CAT=" -n -b -s --number "

# A flag that supplies grep's PATTERN, in any spelling: once one is present the
# remaining positional words are FILES, so the operand cap must drop to zero.
FILTER_PATTERN_FLAGS_GREP=" -e --regexp "

# gh api flags, split by how they are consumed. Anything outside these three
# sets is denied: an unrecognised flag is a flag whose effect on the request
# method — and so on whether this is a read — has not been established.
#
# Two flags a read plainly "needs" are absent on purpose. `--cache <duration>`
# makes gh write a persistent response cache, so the request is a file write in
# everything but name. `--hostname <host>` retargets the request while gh still
# attaches the deployment's credential, which turns any allowed read into a
# token exfiltration to a host the command names. Neither is recoverable by
# validating its value: the effect is the flag.
GH_API_STANDALONE_FLAGS=" --paginate --slurp -i --include --verbose --silent "
GH_API_VALUE_FLAGS=" --jq -q --method -X --header -H --template -t --preview -p "

# Flags for gh's read VERBS (pr list, issue view, …). A read verb is not enough
# on its own: `gh pr view --web` opens a URL through `$BROWSER`, which runs a
# local program the guard never classified. So the verbs are allowlisted too.
GH_VERB_FLAGS=" --draft --no-draft --archived --no-archived --merged --closed --comments --paginate --fork --source --include-prs --exclude-drafts --checks --required "
GH_VERB_VALUE_FLAGS=" -R --repo --state --limit -L --json --jq -q --search --author --owner --assignee --label --milestone --app --branch --workflow --event --user --sort --order --created --updated --language --match --visibility --topic --exclude --head --base --commit --template -t --filter --commenter --merged-at "
# gh switches the request to POST as soon as a field argument is set, UNLESS an
# explicit `--method GET` is also given — then gh serialises it into the query
# string and the request stays a read. So the four FIELD spellings below —
# `-f`, `--raw-field`, `-F`, `--field` — survive on graphql (which has no other way
# to carry a query) and on an explicit GET.
# Two members of this group are NOT covered by that and are denied for every
# method, GET included: `--input` reads a local file as the request body, and a
# field VALUE beginning with `@` makes gh read the file it names. Both are
# independent rules that fire earlier, and neither is widened by an explicit GET.
GH_API_FIELD_FLAGS=" -f --raw-field -F --field --input "

# Value grammars that legitimately begin with a dash. A value-taking flag consumes the
# next word whatever it looks like — gh's flag parser and git's alike — so `--repo --web`
# never reaches gh as a flag. That inertness lives in a parser the guard does not assert,
# and it stops holding the day any value flag grows an optional-value grammar. So the
# guard classifies the consumed word itself (check_consumed_value): a flag-shaped value
# is denied by name unless its flag is listed here, where a leading dash is part of the
# value's own grammar and the value can name no program, host, or file:
#   --search       a server-side query expression (`-label:foo` negates a qualifier)
#   --label, --milestone   free-form server-side filter strings — a label or milestone
#                  title may itself begin with a dash (`--label -bug`)
#   --jq / -q      a jq program (`-1`, `-(.x)`) run by gh's embedded jq; its reach into
#                  the process environment is refused separately by check_gh_flag_value
#   --template/-t  a Go template rendered locally, with no exec or file primitive
#   git --grep, -S, -G, --author, --committer   a regex or pickaxe string matched
#                  against history (`--author -bot` matches authors containing `-bot`)
#   git --since, --until, --after, --before     a date expression, which git's
#                  approxidate parser accepts in free form (`--since -yesterday`)
# Everything else — a count, a path, a ref, a format name — has a grammar no
# dash-letter word can satisfy, so a flag-shaped value there is denied by name.
GH_DASH_VALUE_FLAGS=" --search --label --milestone --jq -q --template -t "
GIT_DASH_VALUE_FLAGS=" --grep -S -G --author --committer --since --until --after --before "

# git options. Read verbs are not enough on their own: several options make git
# write a file or execute a program without any shell syntax for the scanner to
# catch, so options are allowlisted like everything else.
#
# `--paginate` is deliberately absent: it asks git to run `core.pager`, a program
# named by configuration the guard cannot see.
# `--work-tree` is deliberately absent, so it is refused as unrecognised. It
# repoints git at an arbitrary directory while the surveyed repository still
# supplies the index, so an otherwise-allowed `diff` prints the contents of files
# the guard never scoped — a plain read that exfiltrates whatever the caller aims
# it at. Nothing in the surveyor's vocabulary needs it; `-C` reaches another
# repository without detaching the tree from its own repository.
GIT_VALUE_FLAGS=" -C -c --git-dir --exec-path --namespace "
GIT_OK_FLAGS=" --no-pager --no-optional-locks --no-ext-diff --no-textconv --oneline --no-color --color --graph --decorate --no-decorate --abbrev-commit --all --branches --tags --remotes --heads --refs --stat --numstat --shortstat --name-only --name-status --porcelain --short --long --branch --verbose --count --not --reverse --first-parent --merges --no-merges --quiet --verify --symbolic --symbolic-full-name --abbrev-ref --show-toplevel --is-inside-work-tree --is-bare-repository --cached --staged --patch -p --no-patch --raw --text --exit-code --no-renames --topo-order --date-order --left-right --boundary --parents --children --objects --stdin --binary --full-history --follow --no-prefix --numbered "
# Flags a PATCH-PRODUCING git read must CARRY, not merely be allowed to carry.
# Generating patch text is what reaches the two mechanisms whose program comes
# from configuration rather than argv, unconditionally and regardless of whether
# a terminal is attached: `diff.external` replaces the diff engine outright, and a
# `diff.<driver>.textconv` driver named by a gitattributes entry is run over each
# blob. `--no-ext-diff` and `--no-textconv` switch them off.
#
# `diff` and `show` produce a patch by default. `log` does so only when asked, so
# it pays this cost only when a patch flag is present — which is what keeps the
# surveyor's own `git log --oneline` and `git status` unchanged.
# `-u` is deliberately not listed: it means `--untracked-files` to `status`, so
# treating it as a patch flag would tax an ordinary status read. It is not on
# GIT_OK_FLAGS either, so it is refused as unrecognised rather than misread.
GIT_PATCH_VERBS=" show diff "
GIT_PATCH_FLAGS=" -p --patch "
# The documented built-in `--pretty`/`--format` names. Any other bare name is a
# `pretty.<name>` configuration lookup, whose expansion the guard cannot see.
GIT_PRETTY_BUILTINS="oneline short medium full fuller reference email mboxrd raw"
# `status --verbose` prints a STAGED PATCH, so it reaches `diff.external` and the
# textconv drivers exactly as `diff` does — but `status` is not a patch verb and
# `--verbose` is not a patch flag, so neither rule fired and the suppression was
# never demanded. It is the one verb where a non-patch flag produces a patch.
GIT_STATUS_PATCH_FLAGS=" -v --verbose "
GIT_PATCH_REQUIRED_FLAGS=" --no-ext-diff --no-textconv "
# Refreshing the index is when git consults `core.fsmonitor`, which is a HOOK
# PROGRAM named in repository configuration and run before any output appears —
# the same argv-invisible blind spot as `diff.external`, reached by a plain read.
#
# Measured on git 2.50.1 against a repository configuring it, with a DIRTY
# worktree: `status`, `diff` and `ls-files` each execute the hook, while `log`,
# `show`, `rev-parse`, `rev-list`, `cat-file` and `describe --dirty` do not. A
# clean worktree hides most of it — nothing needs refreshing — so the verb set
# comes from the dirty case, which is the state a survey actually meets.
#
# `-c core.fsmonitor=` switches it off and leaves output byte-identical, so this
# takes the patch precedent rather than excluding the verbs: require the
# suppression exactly where the hook is reachable, and leave every other read
# untaxed. Only the empty value is admitted; `-c core.fsmonitor=/path` SETS the
# hook, so `-c` stays denied for every other assignment.
GIT_FSMONITOR_VERBS=" status diff ls-files "
GIT_FSMONITOR_SUPPRESSION="core.fsmonitor="
GIT_OK_VALUE_FLAGS=" -C --git-dir -n --max-count --max-parents --min-parents --since --until --after --before --author --committer --grep --pretty --format --date --unified -U --diff-filter -L -S -G --abbrev --contains --no-contains --merged --no-merged --sort --points-at --glob --exclude "

SEGMENTS=()
WORDS=()

# Walk the command one character at a time, tracking quote state, splitting on
# unquoted `|` and refusing every other unquoted construct that could smuggle a
# second command in — or rewrite a word into one the guard never classified.
# `${VAR}` is a parameter expansion the guard deliberately tolerates; `${VAR:-…}`
# and its relatives are not the same thing. Every one of them carries text INSIDE
# the expansion that becomes argv when the variable is unset or empty — so
# `gh api "${UNSET:---method}" "${UNSET:-POST}" repos/x/y` is a POST that needs no
# control over the environment at all. A plain name expands to whatever the
# environment holds, which is the documented limit; an operator expands to text
# written in the command itself, which is a bypass.
check_expansion() {
  local body=$1
  if [[ ! "$body" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    deny 'a parameter expansion carrying an operator can synthesize arguments — expand it yourself'
  fi
}

scan_segments() {
  local s=$1
  local n=${#s}
  local state=none
  local cur=''
  local i=0 ch nxt prev='' j ec rt d w t

  while [ "$i" -lt "$n" ]; do
    ch=${s:$i:1}
    nxt=${s:$((i + 1)):1}

    if [ "$state" = single ]; then
      if [ "$ch" = "'" ]; then state=none; fi
      cur=$cur$ch
      prev=$ch
      i=$((i + 1))
      continue
    fi

    if [ "$state" = double ]; then
      case "$ch" in
        \\)
          # Bash DELETES a backslash-newline before the program sees it, so
          # `query="muta\<newline>tion{x}"` reaches gh as `mutation{x}` while the
          # text the guard reads contains no such keyword.
          case "$nxt" in
            $'\n' | $'\r') deny 'a line continuation is removed before the command sees it' ;;
          esac
          cur=$cur$ch$nxt
          prev=$nxt
          i=$((i + 2))
          continue
          ;;
        '`') deny 'backtick command substitution is not a read' ;;
        '$')
          case "$nxt" in
            '(') deny 'dollar-paren command substitution is not a read' ;;
            '{')
              j=$((i + 2))
              ec=''
              while [ "$j" -lt "$n" ] && [ "${s:$j:1}" != '}' ]; do
                ec=$ec${s:$j:1}
                j=$((j + 1))
              done
              check_expansion "$ec"
              ;;
          esac
          ;;
        '"') state=none ;;
      esac
      cur=$cur$ch
      prev=$ch
      i=$((i + 1))
      continue
    fi

    case "$ch" in
      # An unquoted `#` that STARTS a word begins a comment: bash discards it and
      # everything after it. The scanner would otherwise keep reading those words
      # as real arguments — so `git show HEAD # --no-ext-diff --no-textconv`
      # classifies as fully suppressed while the shell executes only
      # `git show HEAD`, and the configured diff/textconv program runs after all.
      # Every required-flag check in this guard is defeated the same way, which is
      # why this is refused at the parser rather than per verb. Mid-word `#` is
      # ordinary data (`issues#1`) and is untouched.
      '#')
        if [ -z "$prev" ] || [ "$prev" = ' ' ] || [ "$prev" = $'\t' ]; then
          deny 'an unquoted # starts a shell comment, so the words after it are discarded before the command runs'
        fi
        cur=$cur$ch
        ;;
      "'")
        state=single
        cur=$cur$ch
        ;;
      '"')
        state=double
        cur=$cur$ch
        ;;
      \\)
        case "$nxt" in
          $'\n' | $'\r') deny 'a line continuation is removed before the command sees it' ;;
        esac
        cur=$cur$ch$nxt
        prev=$nxt
        i=$((i + 2))
        continue
        ;;
      '`') deny 'backtick command substitution is not a read' ;;
      '$')
        case "$nxt" in
          '(') deny 'dollar-paren command substitution is not a read' ;;
          "'") deny "ANSI-C quoting \$'…' rewrites the word before the command sees it" ;;
          '"') deny 'locale-translation quoting $"…" rewrites the word before the command sees it' ;;
          # A POSITIONAL or SPECIAL parameter, unbraced. `${9}` already fails
          # check_expansion, but `$9` never reached it, and the difference is not
          # cosmetic: an execution shell normally has no ninth argument, so `$9`
          # expands to NOTHING and splices the words either side of it together —
          # `-f 'muta'$9'tion{x}'` is classified as the literal `muta$9tion{x}`
          # and executed as `mutation{x}`. That needs no control over the
          # environment, only the knowledge that the parameter is unset.
          [0-9] | '*' | '@' | '#' | '?' | '-' | '!' | '$')
            deny "the parameter expansion \$$nxt is removed or rewritten before the command sees it — expand it yourself"
            ;;
          '{')
            j=$((i + 2))
            ec=''
            while [ "$j" -lt "$n" ] && [ "${s:$j:1}" != '}' ]; do
              ec=$ec${s:$j:1}
              j=$((j + 1))
            done
            check_expansion "$ec"
            ;;
        esac
        cur=$cur$ch
        ;;
      # Brace expansion turns one word into several — a flag, an operand, a path
      # the guard never classified. `${…}` is parameter expansion, which is
      # allowed by documented exception, so only a brace NOT introduced by `$`
      # is refused.
      '{')
        if [ "$prev" != '$' ]; then
          deny 'brace expansion rewrites the word before the command sees it — quote it'
        fi
        cur=$cur$ch
        ;;
      # Pathname expansion has the same property: a matching filename becomes an
      # argument the guard never saw, and a crafted one can be a flag.
      '*' | '?' | '[')
        deny "pathname expansion '$ch' rewrites the word before the command sees it — quote it"
        ;;
      '<')
        if [ "$nxt" = '(' ]; then deny 'process substitution <( ) is not a read'; fi
        deny 'input redirection is not a read'
        ;;
      '>')
        if [ "$nxt" = '(' ]; then deny 'process substitution >( ) is not a read'; fi
        # Two redirection targets provably create NO file: duplicating a file
        # descriptor (`2>&1`) and the null device (`2>/dev/null`). Both are
        # ordinary read idioms — merging or silencing stderr — and refusing them
        # denied 17 of 120 measured surveyor commands that write nothing at all.
        # Everything that can name a file still denies, including `>&word`,
        # which bash treats as `&>word` and which DOES write one.
        j=$((i + 1))
        rt=''
        if [ "${s:$j:1}" = '&' ]; then
          j=$((j + 1))
          d=''
          while [ "$j" -lt "$n" ]; do
            case "${s:$j:1}" in [0-9]) d=$d${s:$j:1}; j=$((j + 1)) ;; *) break ;; esac
          done
          # A bare `>&` with no digits is `&>`, and `>&-` closes a descriptor;
          # only a digit run followed by a word boundary is a duplication.
          if [ -n "$d" ]; then
            case "${s:$j:1}" in '' | ' ' | $'\t' | $'\n' | $'\r' | '|' | ';' | '&' | '<' | '>') rt=dup ;; esac
          fi
        else
          while [ "$j" -lt "$n" ]; do
            case "${s:$j:1}" in ' ' | $'\t') j=$((j + 1)) ;; *) break ;; esac
          done
          w=''
          while [ "$j" -lt "$n" ]; do
            case "${s:$j:1}" in ' ' | $'\t' | $'\n' | $'\r' | '|' | ';' | '&' | '<' | '>') break ;; *) w=$w${s:$j:1}; j=$((j + 1)) ;; esac
          done
          # Exact match only: `/dev/nullx` is a file, and a quoted spelling is
          # left to deny rather than unquoted here on a guess.
          if [ "$w" = '/dev/null' ]; then rt=null; fi
        fi
        if [ -n "$rt" ]; then
          # The redirection is not part of argv. Drop the target, and drop a
          # leading fd digit run only when it is a WORD of its own — in
          # `foo2>/dev/null` bash reads `foo2` as an argument, not a descriptor.
          case "$cur" in
            *[0-9])
              t=$cur
              while [ -n "$t" ]; do
                case "$t" in *[0-9]) t=${t%?} ;; *) break ;; esac
              done
              case "$t" in '' | *' ' | *$'\t') cur=$t ;; esac
              ;;
          esac
          prev='>'
          i=$j
          continue
        fi
        deny 'output redirection writes a file'
        ;;
      ';') deny 'chaining with ; can carry a write' ;;
      '&') deny '& backgrounding or && chaining can carry a write' ;;
      '|')
        SEGMENTS[${#SEGMENTS[@]}]=$cur
        cur=''
        ;;
      $'\n' | $'\r') deny 'a newline can carry a second command' ;;
      *) cur=$cur$ch ;;
    esac
    prev=$ch
    i=$((i + 1))
  done

  if [ "$state" != none ]; then
    deny 'unbalanced quoting — the command cannot be classified'
  fi
  SEGMENTS[${#SEGMENTS[@]}]=$cur
}

# Second pass: build the literal argument vector the shell would pass to the
# program. Quotes are REMOVED rather than left on the word, which is the whole
# difference between classifying argv and classifying text — `grep -E 'a b'` is
# one operand to grep, and a scanner that splits on whitespace reads it as two
# and denies an ordinary read.
#
# Everything this pass cannot resolve was already refused by scan_segments, so
# it only has to apply quote removal and escaping.
tokenize_segment() {
  local s=$1
  local n=${#s}
  local i=0 ch nxt
  local state=none
  local cur='' started=0

  WORDS=()
  while [ "$i" -lt "$n" ]; do
    ch=${s:$i:1}

    if [ "$state" = single ]; then
      if [ "$ch" = "'" ]; then
        state=none
      else
        cur=$cur$ch
      fi
      i=$((i + 1))
      continue
    fi

    if [ "$state" = double ]; then
      if [ "$ch" = "\\" ]; then
        nxt=${s:$((i + 1)):1}
        case "$nxt" in
          '"' | "\\" | '$' | '`')
            cur=$cur$nxt
            i=$((i + 2))
            ;;
          *)
            cur=$cur$ch
            i=$((i + 1))
            ;;
        esac
        continue
      fi
      if [ "$ch" = '"' ]; then
        state=none
        i=$((i + 1))
        continue
      fi
      cur=$cur$ch
      i=$((i + 1))
      continue
    fi

    case "$ch" in
      "'")
        state=single
        started=1
        ;;
      '"')
        state=double
        started=1
        ;;
      \\)
        nxt=${s:$((i + 1)):1}
        cur=$cur$nxt
        started=1
        i=$((i + 1))
        ;;
      ' ' | $'\t')
        if [ "$started" -eq 1 ]; then
          WORDS[${#WORDS[@]}]=$cur
          cur=''
          started=0
        fi
        ;;
      *)
        cur=$cur$ch
        started=1
        ;;
    esac
    i=$((i + 1))
  done

  if [ "$started" -eq 1 ]; then WORDS[${#WORDS[@]}]=$cur; fi
}

# Split one argv word into a flag name and, when the word carries its value
# attached, that value. `--method=GET`, `-XGET` and `-fbody=hi` are all forms gh
# and the filters accept, and a check that only understands the separated form
# reads every attached one as "flag absent".
#
# Reports through globals: FLAG_NAME, FLAG_VALUE, FLAG_HAS_VALUE.
FLAG_NAME=''
FLAG_VALUE=''
FLAG_HAS_VALUE=0
split_flag() {
  local w=$1
  FLAG_NAME=''
  FLAG_VALUE=''
  FLAG_HAS_VALUE=0
  case "$w" in
    --*=*)
      FLAG_NAME=${w%%=*}
      FLAG_VALUE=${w#*=}
      FLAG_HAS_VALUE=1
      ;;
    --*) FLAG_NAME=$w ;;
    -?) FLAG_NAME=$w ;;
    -?*)
      FLAG_NAME=${w:0:2}
      FLAG_VALUE=${w:2}
      FLAG_HAS_VALUE=1
      ;;
    *) FLAG_NAME=$w ;;
  esac
}

# Exact-match a resolved argv word. Compares whole words rather than substrings,
# so `--no-pager` is not satisfied by some longer flag that merely contains it.
words_contain() {
  local want=$1 w
  for w in "${WORDS[@]}"; do
    if [ "$w" = "$want" ]; then return 0; fi
  done
  return 1
}

# `-c name=value` is two adjacent words, and only the pair carries the meaning:
# `-c` alone sets nothing and the value alone is a pathspec. Reporting through
# the exit status keeps this callable directly — a helper that returned the
# index through stdout would run in a subshell and lose it.
words_contain_pair() {
  local first=$1 second=$2 i=0
  local n=${#WORDS[@]}
  while [ "$i" -lt "$((n - 1))" ]; do
    if [ "${WORDS[$i]}" = "$first" ] && [ "${WORDS[$((i + 1))]}" = "$second" ]; then
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# The first non-flag word in WORDS at or after $1, skipping flags and the values
# they consume ($2 is a space-delimited set of value-taking flags).
#
# Reports through the globals SUB_WORD and SUB_INDEX rather than stdout, because
# a caller needs both the word and where it sat — and reading the word through
# `$(...)` would run this in a subshell, where the index assignment dies with it.
SUB_WORD=''
SUB_INDEX=-1
find_subcommand() {
  local i=$1
  local value_flags=$2
  local w

  SUB_WORD=''
  SUB_INDEX=-1
  while [ "$i" -lt "${#WORDS[@]}" ]; do
    w=${WORDS[$i]}
    case "$w" in
      --)
        i=$((i + 1))
        continue
        ;;
      -*)
        case "$value_flags" in
          *" $w "*) i=$((i + 2)) ;;
          *) i=$((i + 1)) ;;
        esac
        continue
        ;;
      *)
        SUB_WORD=$w
        SUB_INDEX=$i
        return 0
        ;;
    esac
  done
  return 0
}

# GraphQL is served over POST, so the method cannot separate a read from a write
# here — the operation keyword does. The spec has exactly three operation types,
# and an anonymous `{ … }` document is a query, so refusing the other two is
# exhaustive rather than a blacklist with gaps. The check runs on the RESOLVED
# field value, which is what makes it exhaustive: `$'\x6dutation'` and
# `'mutation'` are the same word by the time it is asked.
check_graphql_document() {
  local v=$1
  if [[ "$v" =~ (^|[^A-Za-z])[Mm][Uu][Tt][Aa][Tt][Ii][Oo][Nn]([^A-Za-z]|$) ]]; then
    deny 'GraphQL mutation is a write'
  fi
  if [[ "$v" =~ (^|[^A-Za-z])[Ss][Uu][Bb][Ss][Cc][Rr][Ii][Pp][Tt][Ii][Oo][Nn]([^A-Za-z]|$) ]]; then
    deny 'GraphQL subscription is not a bounded read'
  fi
  return 0
}

classify_gh_api() {
  local api_at=$1 i=1 w name val
  local n=${#WORDS[@]}
  local endpoint='' seen_endpoint=0
  local field_count=0 method_count=0
  local field_values='' m
  # An ARRAY, not a string. `set -euo pipefail` does not disable pathname
  # expansion, so iterating an unquoted string would expand a method value of `*`
  # against the current directory — and a file named `GET` there would then read
  # as an allowed method.
  local methods=()

  # gh takes the LAST method flag it is given, so a first harmless one is not
  # evidence of anything: collect every occurrence and hold them all to the
  # allowed method, which makes the check independent of that precedence.
  while [ "$i" -lt "$n" ]; do
    # `gh` accepts attached api flags before the subcommand. Classify the whole
    # argv around the located `api` word so those flags cannot escape the
    # request-policy checks below.
    if [ "$i" -eq "$api_at" ]; then
      i=$((i + 1))
      continue
    fi
    w=${WORDS[$i]}
    case "$w" in
      --)
        i=$((i + 1))
        continue
        ;;
      -*) ;;
      *)
        if [ "$seen_endpoint" -eq 0 ]; then
          # An absolute URL lets the endpoint choose the outbound host. That is a
          # destination decision, and under this deployment's egress rules the
          # destination is never taken from text the agent read. A relative path
          # can only ever address the configured forge.
          case "$w" in
            *://*) deny 'gh api endpoint is an absolute URL, which chooses the outbound host' ;;
          esac
          endpoint=$w
          seen_endpoint=1
        fi
        i=$((i + 1))
        continue
        ;;
    esac

    split_flag "$w"
    name=$FLAG_NAME
    val=$FLAG_VALUE

    if [ "$FLAG_HAS_VALUE" -eq 0 ]; then
      case "$GH_API_STANDALONE_FLAGS" in
        *" $name "*)
          i=$((i + 1))
          continue
          ;;
      esac
    fi

    case "$GH_API_FIELD_FLAGS$GH_API_VALUE_FLAGS" in
      *" $name "*) ;;
      *) deny "gh api flag '$w' is not on the read-only allowlist" ;;
    esac

    if [ "$FLAG_HAS_VALUE" -eq 0 ]; then
      if [ $((i + 1)) -ge "$n" ]; then deny "gh api $name needs a value"; fi
      val=${WORDS[$((i + 1))]}
      check_consumed_value 'gh api' "$GH_DASH_VALUE_FLAGS" "$name" "$val"
      i=$((i + 1))
    fi

    case "$GH_API_FIELD_FLAGS" in
      *" $name "*)
        field_count=$((field_count + 1))
        if [ "$name" = --input ]; then
          deny 'gh api --input reads a local file and makes the request a POST'
        fi
        # `@value` makes gh read that path and send its contents — a credential
        # read wearing a field's name.
        case "$val" in
          *=@*) deny "gh api $name reads the local file named after @" ;;
          @*) deny "gh api $name reads the local file named after @" ;;
        esac
        field_values="$field_values
$val"
        i=$((i + 1))
        continue
        ;;
    esac

    check_gh_flag_value "$name" "$val"

    case "$name" in
      --method | -X)
        methods+=("$(printf '%s' "$val" | tr '[:lower:]' '[:upper:]')")
        # Counted separately: `set -u` under bash 3.2 makes "${methods[@]}" an
        # error on an empty array, so a plain counter is the portable way to ask
        # "was a method given at all?" below.
        method_count=$((method_count + 1))
        ;;
    esac
    i=$((i + 1))
  done

  if [ "$endpoint" = graphql ]; then
    for m in ${methods+"${methods[@]}"}; do
      if [ "$m" != POST ] && [ "$m" != GET ]; then
        deny "gh api graphql --method $m is not a read"
      fi
    done
    while IFS= read -r m; do
      if [ -n "$m" ]; then check_graphql_document "$m"; fi
    done <<EOF
$field_values
EOF
    return 0
  fi

  for m in ${methods+"${methods[@]}"}; do
    if [ "$m" != GET ]; then deny "gh api --method $m is not a read"; fi
  done

  # A field argument switches gh to POST *unless* an explicit GET method is given,
  # in which case gh serialises the fields into the query string — still a read.
  # The loop above already denied every non-GET method, so reaching here with a
  # method means that method is GET. No method at all means gh's POST default.
  # This narrows only the METHOD question: the @file and --input denials are
  # independent, fire earlier, and are unaffected.
  if [ "$field_count" -gt 0 ] && [ "$method_count" -eq 0 ]; then
    deny 'gh api field arguments make the request a POST without an explicit --method GET'
  fi

  if [ "$seen_endpoint" -eq 0 ]; then
    deny 'gh api needs an endpoint to be classified'
  fi
  return 0
}

# Flags on an allowed gh read verb. Deny by default, exactly as for `gh api`:
# the verb says what gh will fetch, the flags say what else it will do.
# An allowlisted gh flag can still carry its effect in its VALUE, and two of them do.
#
#   * `--repo` takes `[HOST/]OWNER/REPO`, so a host in that value retargets the request
#     while gh still attaches a credential for it — the same outbound-destination and
#     token-disclosure effect that keeps `--hostname` off the allowlist entirely. Only
#     the bare `OWNER/REPO` form is admitted.
#   * `--jq` is evaluated by gh's OWN formatter, which enables `env` exactly as the
#     standalone tool does — so `--jq 'env.GH_TOKEN'` prints the credential without a
#     `jq` process ever appearing in the pipeline for the filter classifier to inspect.
#
# Both are value-level, so an allowlist keyed on the flag NAME cannot see either.
check_gh_flag_value() {
  local name=$1 val=$2

  case "$name" in
    -R | --repo)
      case "$val" in
        *://* | */*/*)
          deny "gh $name value names a host, which chooses the outbound destination"
          ;;
      esac
      ;;
    --jq | -q)
      # shellcheck disable=SC2016  # the literal characters are the pattern
      case "$val" in
        *'$ENV'*) deny "gh $name exposes the process environment through \$ENV" ;;
      esac
      if [[ "$val" =~ (^|[^A-Za-z0-9_.])env([^A-Za-z0-9_]|$) ]]; then
        deny "gh $name env exposes the process environment"
      fi
      ;;
  esac
}

# A word consumed as a flag's value that is itself flag-shaped. Only a flag whose value
# grammar begins with a dash ($2 names that family's set) may take it; for every other
# flag the guard would be handing a flag it never classified to a parser it does not
# assert. Denied by name, so the message points at the word to remove.
#
# Flag-shaped means a dash followed by a letter or a second dash. A dash followed by a
# digit is a NUMBER, never a flag — `--max-count -1` (unlimited), `-n -1`, and the
# relative date `--since -1.day` are all documented, read-only git grammars — so it is
# admitted for every value flag: no flag's name starts with a digit, so nothing the
# guard classifies can hide behind one.
check_consumed_value() {
  local prog=$1 dash_flags=$2 name=$3 val=$4
  case "$val" in
    -[0-9]*) ;;
    -?*)
      case "$dash_flags" in
        *" $name "*) ;;
        *) deny "$prog $name consumed '$val' as its value, but that word is flag-shaped and $name takes no dash-leading value; the guard classifies it as a flag rather than trusting the parser to keep it inert" ;;
      esac
      ;;
  esac
}

check_gh_verb_flags() {
  local i=1 w name val
  local n=${#WORDS[@]}

  while [ "$i" -lt "$n" ]; do
    w=${WORDS[$i]}
    case "$w" in
      --)
        i=$((i + 1))
        continue
        ;;
      -*) ;;
      *)
        # A POSITIONAL can name the host too, so skipping every one of them
        # reopens exactly the hole `--hostname` and `--repo`'s value were closed
        # for: `gh pr view https://example.com/x/y/pull/1` and
        # `gh repo view example.com/x/y` both send an AUTHENTICATED request to
        # that host. The credential travels with the destination, so this is
        # exfiltration on a read, not merely a wrong lookup. An in-repo endpoint
        # (`repos/owner/name/pulls`) carries no dotted host and is unaffected.
        case "$w" in
          *://*) deny "gh positional '$w' names a host, which retargets the authenticated request" ;;
          *.*/*) deny "gh positional '$w' names a host, which retargets the authenticated request" ;;
        esac
        i=$((i + 1))
        continue
        ;;
    esac

    split_flag "$w"
    name=$FLAG_NAME
    case "$GH_VERB_FLAGS$GH_VERB_VALUE_FLAGS" in
      *" $name "*) ;;
      *) deny "gh flag '$w' is not on the read-only allowlist" ;;
    esac

    if [ "$FLAG_HAS_VALUE" -eq 1 ]; then
      check_gh_flag_value "$name" "$FLAG_VALUE"
    else
      case "$GH_VERB_VALUE_FLAGS" in
        *" $name "*)
          # A TRAILING bare `--json` is gh's field-vocabulary diagnostic: gh
          # prints the subcommand's field list and exits nonzero WITHOUT
          # contacting the forge. The surveyor's definition requires that probe
          # before any ad hoc JSON read, so denying it makes the mandated
          # discovery step unreachable. Admitted only as the final word, and
          # only for `--json` — every other value flag still needs its value,
          # and a value that IS present goes through the normal field check.
          if [ "$name" = "--json" ] && [ $((i + 1)) -ge "$n" ]; then
            i=$((i + 1))
            continue
          fi
          if [ $((i + 1)) -ge "$n" ]; then deny "gh $name needs a value"; fi
          val=${WORDS[$((i + 1))]}
          check_consumed_value gh "$GH_DASH_VALUE_FLAGS" "$name" "$val"
          check_gh_flag_value "$name" "$val"
          i=$((i + 1))
          ;;
      esac
    fi
    i=$((i + 1))
  done
}

classify_gh() {
  local sub sub2 sub_at

  # GH_TELEMETRY is an environment class, not argv: an env-prefixed command is
  # already denied, so the disabling value must already be in the process
  # environment. 0 and false are the documented GitHub CLI disable values.
  case "${GH_TELEMETRY-}" in
    0|false) ;;
    *)
      printf '%s\n' 'deny: export GH_TELEMETRY=0 before any gh read (prevents gh/device-id telemetry writes)'
      return 1
      ;;
  esac

  find_subcommand 1 ' '
  sub=$SUB_WORD
  sub_at=$SUB_INDEX
  if [ -z "$sub" ]; then deny 'gh needs a subcommand to be classified'; fi

  if [ "$sub" = api ]; then
    classify_gh_api "$sub_at"
    return 0
  fi

  find_subcommand $((sub_at + 1)) ' '
  sub2=$SUB_WORD

  case "$sub" in
    pr)
      case "$sub2" in
        list | view | diff | checks | status) check_gh_verb_flags; return 0 ;;
        *) deny "gh pr ${sub2:-<none>} is not a read verb" ;;
      esac
      ;;
    issue)
      case "$sub2" in
        list | view) check_gh_verb_flags; return 0 ;;
        *) deny "gh issue ${sub2:-<none>} is not a read verb" ;;
      esac
      ;;
    search)
      case "$sub2" in
        issues | prs | repos | code | commits) check_gh_verb_flags; return 0 ;;
        *) deny "gh search ${sub2:-<none>} is not on the read allowlist" ;;
      esac
      ;;
    repo)
      case "$sub2" in
        list | view) check_gh_verb_flags; return 0 ;;
        *) deny "gh repo ${sub2:-<none>} is not a read verb" ;;
      esac
      ;;
    run)
      case "$sub2" in
        list | view) check_gh_verb_flags; return 0 ;;
        *) deny "gh run ${sub2:-<none>} is not a read verb" ;;
      esac
      ;;
    release)
      case "$sub2" in
        list | view) check_gh_verb_flags; return 0 ;;
        *) deny "gh release ${sub2:-<none>} is not a read verb" ;;
      esac
      ;;
    label)
      case "$sub2" in
        list) check_gh_verb_flags; return 0 ;;
        *) deny "gh label ${sub2:-<none>} is not a read verb" ;;
      esac
      ;;
    *) deny "gh $sub is not on the read-only allowlist" ;;
  esac
}

# A read verb is not enough for git. Several of its options turn a read into
# arbitrary local execution — `-c protocol.ext.allow=always` with an `ext::` URL
# runs a shell command as a "transport", `--upload-pack` names the program git
# executes for the remote side — and several make git write a file itself, with
# no shell redirection for the scanner to catch (`git diff --output=PATH`). So
# the verb's options are allowlisted too, and an option this guard has not
# established the effect of is denied by default.
#
# The admitted verbs read the LOCAL object database only. None of them contacts
# a remote, and that is the boundary rather than a coincidence: git resolves a
# remote's URL from configuration AFTER the command line is parsed, so argv can
# never show what a named remote points at. A repository carrying
# `remote.origin.url = ext::sh -c …` turns the innocuous-looking
# `git ls-remote origin` into local execution, and no amount of inspecting that
# argv reveals it. Resolving the remote here would mean reading repository
# config the guard does not own and racing whoever may rewrite it before git
# runs. Excluding the remote-contacting verbs removes the question instead of
# answering it unreliably — and costs nothing, because the surveyor's definition
# prescribes only `git log/status`.
classify_git() {
  local sub i w name
  local n=${#WORDS[@]}

  i=1
  while [ "$i" -lt "$n" ]; do
    w=${WORDS[$i]}
    case "$w" in
      -c)
        # The one assignment that REMOVES an execution path rather than adding
        # one. Matched as an exact pair so `-c core.fsmonitor=/evil` — which
        # installs the hook — still falls through to the denial below.
        if [ "$((i + 1))" -lt "$n" ] &&
          [ "${WORDS[$((i + 1))]}" = "$GIT_FSMONITOR_SUPPRESSION" ]; then
          i=$((i + 2))
          continue
        fi
        deny "git $w can make a read execute a command"
        ;;
      --config-env | --exec-path | --upload-pack | --receive-pack)
        deny "git $w can make a read execute a command"
        ;;
      -c=* | --config-env=* | --exec-path=* | --upload-pack=* | --receive-pack=*)
        deny "git ${w%%=*} can make a read execute a command"
        ;;
      *::*) deny "git transport '$w' can execute a local command" ;;
    esac
    i=$((i + 1))
  done

  find_subcommand 1 "$GIT_VALUE_FLAGS"
  sub=$SUB_WORD
  if [ -z "$sub" ]; then deny 'git needs a subcommand to be classified'; fi

  case "$sub" in
    log | status | show | diff | rev-parse | rev-list | ls-files | cat-file | describe)
      ;;
    ls-remote | fetch | pull | push | clone | remote | submodule)
      deny "git $sub contacts a remote, whose URL argv cannot show"
      ;;
    *) deny "git $sub is not a read verb" ;;
  esac

  # A patch-producing read reaches `diff.external` and the textconv drivers, whose
  # programs are named in repository configuration the guard cannot see — the same
  # blind spot that excludes the remote-contacting verbs. Here the flags that
  # switch them off do exist, so require them rather than exclude the verb.
  local req patch=0 pf
  case "$GIT_PATCH_VERBS" in
    *" $sub "*) patch=1 ;;
  esac
  # Only the patch-CAPABLE verbs infer a patch from a flag. `-p` means something
  # else elsewhere — to `cat-file` it is pretty-print — and inferring a patch
  # there denies a legitimate read while naming a remedy that cannot work, since
  # `cat-file` rejects `--no-ext-diff` outright. A guard whose fix is impossible
  # is worse than one that never fired: it makes the read unreachable.
  local flagverb=0
  case "$sub" in
    log | diff | show) flagverb=1 ;;
    status)
      for pf in $GIT_STATUS_PATCH_FLAGS; do
        if words_contain "$pf"; then
          patch=1
          break
        fi
      done
      ;;
  esac
  if [ "$patch" -eq 0 ] && [ "$flagverb" -eq 1 ]; then
    for pf in $GIT_PATCH_FLAGS; do
      if words_contain "$pf"; then
        patch=1
        break
      fi
    done
  fi
  # Patch flags also arrive ATTACHED, and an exact-word scan cannot see them:
  # `git log -pU3 -1` is patch output to git and three unrecognised characters to
  # a `words_contain "-p"` test, so the textconv/diff.external suppression is
  # never demanded. Short options cluster, so inspect the cluster's letters; and
  # `-U<n>`/`--unified` request patch context, which implies a patch.
  if [ "$patch" -eq 0 ] && [ "$flagverb" -eq 1 ]; then
    local wi=1 ww
    while [ "$wi" -lt "$n" ]; do
      ww=${WORDS[$wi]}
      case "$ww" in
        --unified=* | --unified) patch=1 ;;
        --*) ;;
        -[0-9]*) ;;
        -*[pU]*) patch=1 ;;
      esac
      [ "$patch" -eq 1 ] && break
      wi=$((wi + 1))
    done
  fi
  case "$GIT_FSMONITOR_VERBS" in
    *" $sub "*)
      if ! words_contain_pair '-c' "$GIT_FSMONITOR_SUPPRESSION"; then
        deny "git $sub refreshes the index and must pass -c $GIT_FSMONITOR_SUPPRESSION; without it repository configuration can name a hook program git executes"
      fi
      # The same index refresh REWRITES `.git/index` to cache stat information,
      # which is a file write inside a command this guard certifies as a read —
      # touching a tracked file with unchanged contents is enough to trigger it.
      # `--no-optional-locks` is git's own switch for exactly this class.
      if ! words_contain '--no-optional-locks'; then
        deny "git $sub refreshes the index and must pass --no-optional-locks; without it the read rewrites .git/index"
      fi
      ;;
  esac

  # `%G?` and its siblings ask git to VERIFY a signature, which runs the program
  # named by `gpg.program` — a third config-named execution path, independent of
  # the diff drivers and the fsmonitor hook, and reachable from a plain
  # `git log --format=…`. The placeholders are a documented, closed set.
#
  # Scanning argv for a literal `%G` is not sufficient, because a format NAME
  # resolves through repository configuration: `pretty.evil=format:%G?` makes
  # `--pretty=evil` carry the placeholder without it appearing in the command at
  # all. So the value is restricted rather than searched — a built-in format name,
  # or an explicit format string the guard can read and reject. Git silently
  # ignores a `pretty.<name>` that shadows a built-in, so the built-ins are safe.
  local fi=1 fw fval
  while [ "$fi" -lt "$n" ]; do
    fw=${WORDS[$fi]}
    fval=''
    case "$fw" in
      --format=* | --pretty=*) fval=${fw#*=} ;;
      --format | --pretty) fval=${WORDS[$((fi + 1))]:-} ;;
    esac
    if [ -n "$fval" ]; then
      case "$fval" in
        *%G*) deny "a %G signature placeholder makes git run the configured gpg.program" ;;
      esac
      case " $GIT_PRETTY_BUILTINS " in
        *" $fval "*) ;;
        *)
          case "$fval" in
            format:* | tformat:* | %*) ;;
            *) deny "a --pretty/--format NAME resolves through repository configuration, which can name a %G placeholder git verifies with gpg.program; use a built-in format or an explicit format: string" ;;
          esac
          ;;
      esac
    fi
    fi=$((fi + 1))
  done

  if [ "$patch" -eq 1 ]; then
    for req in $GIT_PATCH_REQUIRED_FLAGS; do
      if ! words_contain "$req"; then
        deny "git $sub produces a patch and must pass $req; without it configuration can name the program git runs"
      fi
    done
  fi

  i=1
  while [ "$i" -lt "$n" ]; do
    w=${WORDS[$i]}
    case "$w" in
      # Everything after `--` is a pathspec, never an option.
      --) return 0 ;;
      # `git log -5` — the obsolete bare-count form, which the surveyor uses.
      -[0-9]*)
        i=$((i + 1))
        continue
        ;;
      # The fsmonitor suppression, already proven an exact pair above. Skipping
      # both words keeps its value from being read as a stray pathspec operand.
      -c)
        i=$((i + 2))
        continue
        ;;
      -*) ;;
      *)
        i=$((i + 1))
        continue
        ;;
    esac

    split_flag "$w"
    name=$FLAG_NAME
    case "$GIT_OK_FLAGS$GIT_OK_VALUE_FLAGS" in
      *" $name "*) ;;
      *) deny "git option '$w' is not on the read-only allowlist" ;;
    esac

    if [ "$FLAG_HAS_VALUE" -eq 0 ]; then
      case "$GIT_OK_VALUE_FLAGS" in
        *" $name "*)
          if [ $((i + 1)) -lt "${#WORDS[@]}" ]; then
            check_consumed_value git "$GIT_DASH_VALUE_FLAGS" "$name" "${WORDS[$((i + 1))]}"
          fi
          i=$((i + 1))
          ;;
      esac
    fi
    i=$((i + 1))
  done
  return 0
}

# A filter never opens the pipeline (see classify_segment) and never takes a path.
# Flags come from a per-filter whitelist and positional operands are capped at
# what the filter genuinely needs — a pattern or a program, never a file.
classify_filter() {
  local prog=$1 flags=$2 value_flags=$3 cap=$4
  local i=1 w name operands=0 comps comp k operands_only=0
  local n=${#WORDS[@]}

  while [ "$i" -lt "$n" ]; do
    w=${WORDS[$i]}
    # `--` ends option parsing for the filter as well: every later word is an
    # operand, so `head -- -qv` names a FILE, not two flags. Counting those words
    # as operands is what lets the cap refuse the read.
    if [ "$operands_only" -eq 1 ]; then
      operands=$((operands + 1))
      i=$((i + 1))
      continue
    fi
    case "$w" in
      --)
        operands_only=1
        i=$((i + 1))
        continue
        ;;
      -*) ;;
      *)
        # jq reads local state without touching the filesystem: `env` and `$ENV`
        # both emit the whole process environment, so `jq -n env` prints
        # GH_TOKEN straight into the command's output. The operand cap cannot
        # see that — it counts words, and this is one word.
        if [ "$prog" = jq ]; then
          # shellcheck disable=SC2016  # the literal characters are the pattern
          case "$w" in
            *'$ENV'*) deny 'jq exposes the process environment through $ENV' ;;
          esac
          if [[ "$w" =~ (^|[^A-Za-z0-9_.])env([^A-Za-z0-9_]|$) ]]; then
            deny 'jq env exposes the process environment'
          fi
          # `include`/`import` load jq code from a FILE in the surveyed tree, so
          # the filter this guard inspects is no longer the filter jq runs: an
          # `evil.jq` defining `leak` as `env.GH_TOKEN` turns the innocuous text
          # `include "evil"; leak` into a credential print. Scanning the literal
          # operand cannot see borrowed code, so the loading forms are refused.
          if [[ "$w" =~ (^|[^A-Za-z0-9_.])(include|import)([^A-Za-z0-9_]|$) ]]; then
            deny 'jq include/import loads filter code from a file the guard never sees'
          fi
        fi
        operands=$((operands + 1))
        i=$((i + 1))
        continue
        ;;
    esac

    # head/tail still accept the obsolete bare-count form (`head -20`).
    case "$prog:$w" in
      head:-[0-9]* | tail:-[0-9]*)
        i=$((i + 1))
        continue
        ;;
    esac

    split_flag "$w"
    name=$FLAG_NAME

    # POSIX bundles boolean short flags into one word: `-sc` is `-s -c`. A
    # name-keyed lookup read that as the unknown name `-sc` and denied a read
    # whose every component it already admits (agent-plugins#186). Only a word
    # whose LEADING flag takes a value is an attached-value spelling (`-A3`,
    # `-n20`); every other multi-character short word is a bundle, admitted only
    # when each component is an allowlisted boolean. One unknown or one
    # value-taking component denies the word and names that component, so the
    # caller can fix the spelling instead of guessing which character offended.
    case "$w" in
      --*) ;;
      -??*)
        case "$value_flags" in
          *" $name "*) ;;
          *)
            comps=${w#-}
            k=0
            while [ "$k" -lt "${#comps}" ]; do
              comp="-${comps:$k:1}"
              case "$value_flags" in
                *" $comp "*) deny "$prog flag '$w' bundles the value-taking component '$comp'; spell it as its own word" ;;
              esac
              case "$flags" in
                *" $comp "*) ;;
                *) deny "$prog flag '$w' is not on the read-only allowlist: component '$comp'" ;;
              esac
              k=$((k + 1))
            done
            i=$((i + 1))
            continue
            ;;
        esac
        ;;
    esac

    if [ "$FLAG_HAS_VALUE" -eq 0 ]; then
      case "$flags" in
        *" $name "*)
          i=$((i + 1))
          continue
          ;;
      esac
    fi

    case "$value_flags" in
      *" $name "*) ;;
      *) deny "$prog flag '$w' is not on the read-only allowlist" ;;
    esac

    # A pattern supplied by a flag — in EITHER spelling — means every remaining
    # positional word is a file, so the operand cap drops to zero.
    if [ "$prog" = grep ]; then
      case "$FILTER_PATTERN_FLAGS_GREP" in
        *" $name "*) cap=0 ;;
      esac
    fi

    if [ "$FLAG_HAS_VALUE" -eq 0 ]; then i=$((i + 1)); fi
    i=$((i + 1))
  done

  if [ "$operands" -gt "$cap" ]; then
    deny "$prog takes at most $cap operand(s) here; a further operand would read a file"
  fi
  return 0
}

# One reviewed plugin helper is a compound forge read rather than a generic
# filter: it performs a fixed paginated Actions GET in memory and classifies the
# result. Match the exact sibling of this guard, never a basename or caller-
# supplied path, then admit only its remote-mode argument shape. Offline
# `--input` can read an arbitrary local file and therefore remains denied.
classify_default_branch_ci() {
  local i=1 w repo='' branch='' head_sha=''
  local n=${#WORDS[@]}

  while [ "$i" -lt "$n" ]; do
    w=${WORDS[$i]}
    case "$w" in
      --repo)
        [ -z "$repo" ] || deny 'default-branch classifier repeats --repo'
        i=$((i + 1))
        [ "$i" -lt "$n" ] || deny 'default-branch classifier --repo needs a value'
        repo=${WORDS[$i]}
        ;;
      --branch)
        [ -z "$branch" ] || deny 'default-branch classifier repeats --branch'
        i=$((i + 1))
        [ "$i" -lt "$n" ] || deny 'default-branch classifier --branch needs a value'
        branch=${WORDS[$i]}
        ;;
      --head-sha)
        [ -z "$head_sha" ] || deny 'default-branch classifier repeats --head-sha'
        i=$((i + 1))
        [ "$i" -lt "$n" ] || deny 'default-branch classifier --head-sha needs a value'
        head_sha=${WORDS[$i]}
        ;;
      *) deny "default-branch classifier argument '$w' is not the guarded remote-mode shape" ;;
    esac
    i=$((i + 1))
  done

  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    deny 'default-branch classifier repository is not OWNER/REPO'
  [ -n "$branch" ] || deny 'default-branch classifier needs --branch'
  [[ "$head_sha" =~ ^[0-9a-fA-F]{40}$ ]] ||
    deny 'default-branch classifier head sha is not full length'
  return 0
}

# sed is allowed by shape, not by exclusion: a plain substitution or a line
# print/delete, and nothing else. `w` writes a file and `e` executes a command,
# and both hide in a flag position that a blacklist keeps missing — including
# behind further delimiters, which is why the substitution is parsed to its
# THIRD delimiter rather than split on its last one. `s/a/b/w/tmp/g` writes
# /tmp/g, and everything after the last `/` is just `g`.
check_sed_script() {
  local s=$1
  local delim tail n i ch count=0

  if [[ "$s" =~ ^[0-9,\$]*[pd]$ ]]; then return 0; fi

  case "$s" in
    s?*) ;;
    *) deny "sed script '$s' is not a plain substitution" ;;
  esac

  delim=${s:1:1}
  case "$delim" in
    [A-Za-z0-9] | "\\" | '') deny "sed substitution delimiter '$delim' is not supported here" ;;
  esac

  n=${#s}
  i=2
  while [ "$i" -lt "$n" ]; do
    ch=${s:$i:1}
    if [ "$ch" = "\\" ]; then
      i=$((i + 2))
      continue
    fi
    if [ "$ch" = "$delim" ]; then
      count=$((count + 1))
      if [ "$count" -eq 2 ]; then break; fi
    fi
    i=$((i + 1))
  done

  if [ "$count" -ne 2 ]; then deny "sed script '$s' is not a complete substitution"; fi

  tail=${s:$((i + 1))}
  if [[ ! "$tail" =~ ^[gpIiMm0-9]*$ ]]; then
    deny "sed flags '$tail' may write a file or execute a command"
  fi
  return 0
}

# sed's syntax is `sed [-n] {script-only-if-no-other-script} [input-file]…`, so
# only the FIRST positional word is a script — every one after it is a file sed
# opens INSTEAD of the pipeline. `sed -n p p` reads a file named `p` from the
# working directory, and both words pass the script shape independently, so a
# per-word check cannot catch it. Track whether the script has been taken.
classify_sed() {
  local i=1 a
  local n=${#WORDS[@]}
  local have_script=0

  while [ "$i" -lt "$n" ]; do
    a=${WORDS[$i]}
    case "$a" in
      -n | -E | -r | --regexp-extended | --quiet | --silent | --) ;;
      -e | --expression)
        i=$((i + 1))
        if [ "$i" -ge "$n" ]; then deny 'sed -e needs a script'; fi
        check_sed_script "${WORDS[$i]}"
        # A script supplied by -e means every positional word is a file.
        have_script=1
        ;;
      -i | --in-place | -i* | --in-place=*) deny 'sed -i rewrites a file in place' ;;
      -f | --file) deny 'sed -f takes its script from a file' ;;
      -*) deny "sed flag '$a' is not on the read-only allowlist" ;;
      *)
        if [ "$have_script" -eq 1 ]; then
          deny "sed operand '$a' is an input file, not a script"
        fi
        check_sed_script "$a"
        have_script=1
        ;;
    esac
    i=$((i + 1))
  done
}

# Is $1 one of the consumer-declared classifier paths?
#
# Splitting on ':' is done by assigning IFS for a single unquoted expansion and
# restoring it immediately, because bash 3.2 has no `readarray`. A relative
# entry is SKIPPED rather than denied: the comparison is against the argv word
# the tokenizer resolved, and only an absolute path identifies one file.
is_consumer_classifier() {
  local prog=$1 entry saved_ifs=$IFS found=1 reglob=0
  # No empty-string early return: an empty value splits to zero words, so the
  # loop below never runs and `found` stays 1. Ablation confirmed a guard there
  # separates no input from any other, and a conjunct that cannot fail is not a
  # protection — it only reads like one.
  #
  # PATHNAME EXPANSION IS DISABLED FOR THE SPLIT. `set -- $VAR` both splits AND
  # globs, so a declaration containing `*`, `?` or `[…]` would expand against
  # the filesystem: the declared set silently becomes whatever happens to exist,
  # and the result depends on the process's current directory rather than on
  # what the deployment wrote. That is the same word-rewriting hazard this guard
  # refuses everywhere else — an entry must mean exactly the characters in it.
  # Restore only if this shell did not already have noglob set.
  case $- in
    *f*) : ;;
    *)
      reglob=1
      set -f
      ;;
  esac
  IFS=':'
  # shellcheck disable=SC2086 # deliberate word split on the IFS set above; globbing is off
  set -- $CONSUMER_CLASSIFIERS
  IFS=$saved_ifs
  [ "$reglob" -eq 1 ] && set +f
  for entry in "$@"; do
    case "$entry" in
      /*) [ "$entry" = "$prog" ] && found=0 ;;
      *) : ;;
    esac
  done
  return "$found"
}

# A declared classifier accepts exactly `--input -`, and nothing else.
#
# The flag is REQUIRED rather than optional. A bare invocation would rely on the
# script defaulting to stdin, which is a property of that script rather than of
# this argv, and this guard certifies argv. Requiring the explicit form means a
# classifier that later grows a file or network mode cannot reach it from here
# without this allowlist being widened in review.
classify_consumer_classifier() {
  local i=1 w saw_stdin=0
  local n=${#WORDS[@]}

  while [ "$i" -lt "$n" ]; do
    w=${WORDS[$i]}
    case "$w" in
      --input)
        [ "$saw_stdin" -eq 0 ] || deny 'declared classifier repeats --input'
        i=$((i + 1))
        [ "$i" -lt "$n" ] || deny 'declared classifier --input needs a value'
        [ "${WORDS[$i]}" = '-' ] ||
          deny 'declared classifier --input must be the stdin form, not a path'
        saw_stdin=1
        ;;
      *) deny "declared classifier argument '$w' is not the stdin-only shape" ;;
    esac
    i=$((i + 1))
  done

  [ "$saw_stdin" -eq 1 ] || deny 'declared classifier needs --input -'
  return 0
}

# Classify one parsed pipeline segment. $1 is its command text and $2 its
# zero-based position. Return only for an admitted read; deny exits the guard.
# A classifier discovery hint supplies path data while keeping the probe denied.
classify_segment() {
  local seg=$1
  local index=$2
  local prog=''

  tokenize_segment "$seg"

  if [ "${#WORDS[@]}" -gt 0 ]; then prog=${WORDS[0]}; fi
  if [ -z "$prog" ]; then deny 'empty pipeline segment — || chaining or a stray |'; fi

  # The pipeline must START at the forge. A filter in first position has nothing
  # to filter, so it is reading something local instead — which is how
  # `cat ~/.config/gh/hosts.yml` would otherwise pass as a "safe filter".
  if [ "$index" -eq 0 ]; then
    case "$prog" in
      gh | git | "$DEFAULT_BRANCH_CLASSIFIER") ;;
      classify-default-branch-ci-runs.sh | */classify-default-branch-ci-runs.sh)
        # Discovery remains a denial. Only the guard's own executable sibling
        # supplies the hint; caller text is never reflected into this record.
        # JSON keeps path characters as data. Missing jq or encoding failure
        # leaves discovery unknown without changing command admission.
        local path_json=''
        if [ -x "$DEFAULT_BRANCH_CLASSIFIER" ]; then
          path_json=$(jq -cn --arg path "$DEFAULT_BRANCH_CLASSIFIER" '$path' 2>/dev/null) || path_json=''
        fi
        if [ -n "$path_json" ]; then
          deny "$(printf 'default-branch classifier requires its installed absolute path\nclassifier-path-json: %s' "$path_json")"
        fi
        deny 'default-branch classifier path is unavailable; report QUERY-UNKNOWN'
        ;;
      *) deny "a read must begin with a forge command, not '$prog'" ;;
    esac
  fi

  case "$prog" in
    gh) classify_gh ;;
    git) classify_git ;;
    "$DEFAULT_BRANCH_CLASSIFIER") classify_default_branch_ci ;;
    sed) classify_sed ;;
    jq) classify_filter jq "$FILTER_FLAGS_JQ" "$FILTER_VALUE_FLAGS_JQ" 1 ;;
    grep) classify_filter grep "$FILTER_FLAGS_GREP" "$FILTER_VALUE_FLAGS_GREP" 1 ;;
    sort) classify_filter sort "$FILTER_FLAGS_SORT" "$FILTER_VALUE_FLAGS_SORT" 0 ;;
    head | tail) classify_filter "$prog" "$FILTER_FLAGS_HEADTAIL" "$FILTER_VALUE_FLAGS_HEADTAIL" 0 ;;
    uniq) classify_filter uniq "$FILTER_FLAGS_UNIQ" ' ' 0 ;;
    wc) classify_filter wc "$FILTER_FLAGS_WC" ' ' 0 ;;
    cut) classify_filter cut "$FILTER_FLAGS_CUT" "$FILTER_VALUE_FLAGS_CUT" 0 ;;
    tr) classify_filter tr "$FILTER_FLAGS_TR" ' ' 2 ;;
    cat) classify_filter cat "$FILTER_FLAGS_CAT" ' ' 0 ;;
    *)
      # LAST, so a declared path can never shadow a built-in classification: if
      # a deployment declares `/usr/bin/git`, git's own rules still apply and
      # the declaration only ever narrows.
      #
      # The index test is a SECOND line of defence and is deliberately kept
      # even though ablation shows it currently separates no input: the
      # leading-position check above already denies a declared classifier at
      # index 0, because that allowlist holds only `gh`, `git` and this guard's
      # own sibling. Unlike the empty-value guard removed from
      # is_consumer_classifier, this one is not merely redundant arithmetic —
      # it holds a security invariant (a declared classifier never OPENS a
      # pipeline, so it never reads local state) that would otherwise rest
      # entirely on a list three hundred lines away. Widen that list and this
      # is what still stops a declared path leading. The test suite pins the
      # behaviour; it cannot pin which of the two checks produced it.
      if [ "$index" -gt 0 ] && is_consumer_classifier "$prog"; then
        classify_consumer_classifier
      else
        deny "'$prog' is not on the read-only allowlist"
      fi
      ;;
  esac
}

main() {
  local command='' have=0 seg

  while [ $# -gt 0 ]; do
    case "$1" in
      --command)
        if [ $# -lt 2 ]; then die '--command needs a value'; fi
        command=$2
        have=1
        shift 2
        ;;
      --stdin)
        command=$(cat)
        have=1
        shift
        ;;
      -h | --help)
        # Print the header comment to wherever it actually ends, rather than to a
        # line number: a fixed range silently truncates the moment the header
        # grows, which is how `--help` came to stop mid-sentence inside the third
        # documented limit and drop the residue note entirely.
        awk 'NR>=3 { if (/^#/) { sub(/^# ?/, ""); print; next } exit }' "${BASH_SOURCE[0]}"
        exit 0
        ;;
      *) die "unknown argument: $1" ;;
    esac
  done

  if [ "$have" -ne 1 ]; then die 'need --command <command> or --stdin'; fi
  if [[ ! "$command" =~ [^[:space:]] ]]; then die 'the command is empty'; fi

  scan_segments "$command"
  local idx=0
  for seg in "${SEGMENTS[@]}"; do
    classify_segment "$seg" "$idx"
    idx=$((idx + 1))
  done

  printf 'allow\n'
}

main "$@"
