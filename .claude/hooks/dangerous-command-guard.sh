#!/bin/bash
#
# dangerous-command-guard.sh — PreToolUse hook.
#
# This file is the source of truth. The copy Claude Code actually runs lives at
# ~/.claude/hooks/dangerous-command-guard.sh and is registered in
# ~/.claude/settings.json, because these rules span both repos. Edit this file,
# then run .claude/hooks/install-guard.sh to sync the live copy — that script
# also reports when the two have drifted apart.
#
# permissions.autoMode.hard_deny is a prompt for a classifier: it only holds
# while auto mode is running it. bypassPermissions runs no classifier and skips
# the prompts that allow/deny rules would raise. A PreToolUse hook still runs —
# and an exit status of 2 stops the tool call *before* permission rules are
# evaluated, so it holds in every mode. The rules that must never bend live
# here rather than in hard_deny alone. The companion `ask` rules in
# ~/.claude/settings.json cover the softer set: bypassPermissions skips every
# prompt except the ones an explicit `ask` rule forces, so `ask` is the one
# rule type that still reaches you there.
#
# Deliberately blunt. It matches the whole command string, so `grep "railway up"`
# is blocked too. A false positive costs one command typed by hand; a missed
# `railway up` costs a production deploy. The same bluntness is what catches
# interpreter escapes: python3 -c '...os.system("railway up")' has the string
# right there in the command.
#
# It fails closed. If jq is missing, or the hook input will not parse, the call
# is refused rather than waved through: a guard that cannot read what it is
# guarding must not approve it. (It used to fail open on both — a missing
# /usr/bin/jq left the tool name empty, which fell through to "not a tool I
# check" and allowed everything.)
#
# This guard is not a sandbox. A determined model can still write a script and
# run it under a name this file has never heard of. It stops the direct,
# plausible mistake — which is the failure mode bypassPermissions actually has.
#
# Speed is part of correctness here: this runs before every Bash, Edit, Write
# and Read call and the latency is paid by the user each time. The Bash rules
# live in one array, and the union of their patterns — built from that array, so
# it cannot drift out of being a superset — is tried first as a single grep. A
# command matching nothing costs one grep instead of one per rule.

set -u

AUDIT="${HOME}/.claude/guard-audit.log"

# ------------------------------------------------------------- the opt-out
#
# The user opts out for a whole session by exporting this before `claude`.
# A command can't set it: hooks inherit Claude Code's environment, not the
# environment of the command being inspected — so prefixing it onto a command
# does nothing, it has to be exported before `claude` starts.
#
# Checked FIRST, before the file-write rules. It used to sit below them, which
# meant the one thing the refusal message tells you to do — relaunch with
# CLAUDE_GUARD_OFF=1 and edit the file — was itself blocked.

[ "${CLAUDE_GUARD_OFF:-}" = "1" ] && exit 0

# ---------------------------------------------------------------- fail closed

tool=""

note() { printf '%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$2" >>"$AUDIT" 2>/dev/null; }

block() {
  note "${tool:-?}" "$1"
  printf 'Blocked by dangerous-command-guard: %s

This rule holds in every permission mode, including bypassPermissions, and is
not something to work around. Say what you wanted to run and why, and let the
user run it themselves.
' "$1" >&2
  exit 2
}

JQ=/usr/bin/jq
[ -x "$JQ" ] || JQ=$(command -v jq 2>/dev/null || true)
[ -n "$JQ" ] && [ -x "$JQ" ] ||
  block 'jq is not available, so this hook cannot read the tool call it is meant to inspect. A guard that cannot parse its input must not let it through. Install jq, or relaunch with CLAUDE_GUARD_OFF=1 to accept running unguarded.'

# One jq call for everything the rules need. A unit separator joins the fields:
# unlike @tsv it does not escape backslashes, so the command the rules see is
# byte-for-byte the command that would run.
#
# One field per line. Every field has its newlines flattened to spaces first,
# which is what makes that unambiguous — and is also why a path cannot smuggle
# a newline through to split itself across two fields. Runs of spaces in the
# command collapse too, so a wrapped or multi-line command matches the same
# patterns a one-liner does.
#
# No literal control byte appears in this file. An earlier version separated the
# fields with U+001F; one of them was lost in an edit, every field ran together,
# the tool name stopped matching `Bash`, and the guard waved through all 53 of
# the cases it should have blocked. A separator you cannot see in a diff is a
# separator that can go missing without anyone noticing.
raw=$(cat | "$JQ" -r '
    def flat: gsub("[\n\r\t]"; " ");
    (.tool_name // "" | flat),
    ((.tool_input.command // "" | flat) | gsub(" +"; " ")),
    (.tool_input.file_path // .tool_input.notebook_path // "" | flat),
    ((.tool_input // {}) | tojson | flat)
  ' 2>/dev/null) ||
  block 'the hook input was empty or not valid JSON, so this call could not be inspected.'

{
  IFS= read -r tool
  IFS= read -r cmd
  IFS= read -r path
  IFS= read -r payload
} <<EOF
$raw
EOF

# ---------------------------------------------------------------- file writes

# Resolve `.`, `..`, doubled slashes and symlinks without needing the file to
# exist: walk up to the deepest ancestor that does, resolve that with `cd -P`,
# and re-attach the rest. Without it ~/.claude/hooks/../settings.json is a
# different string from ~/.claude/settings.json and walks past the case below.
canon() {
  local p=$1 dir tail real
  case "$p" in "~"|"~/"*) p="$HOME${p#\~}" ;; esac
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  # `cd -P` will not collapse a leading `//` — POSIX lets an implementation
  # treat exactly two leading slashes as its own thing — so //Users/…/settings.json
  # stayed a different string from the path it is.
  while :; do case "$p" in *//*) p=${p//\/\//\/} ;; *) break ;; esac; done
  dir=${p%/*}; tail=${p##*/}
  [ -n "$dir" ] || dir=/
  while [ ! -d "$dir" ] && [ "$dir" != "/" ] && [ -n "$dir" ]; do
    tail="${dir##*/}/$tail"
    dir=${dir%/*}
    [ -n "$dir" ] || dir=/
  done
  real=$(cd -P "$dir" 2>/dev/null && pwd -P) || real=$dir
  printf '%s/%s' "${real%/}" "$tail"
}

HOME_REAL=$(cd -P "$HOME" 2>/dev/null && pwd -P || printf '%s' "$HOME")

# The guard has to survive the session it is guarding. In bypassPermissions a
# model can otherwise edit the hook, or the settings file that registers it,
# and the next command goes through unexamined.
#
# Scoped to $HOME on purpose: a repo's own .claude/hooks/ is ordinary source and
# has to stay editable, which is how this file gets maintained at all. .git/hooks
# is the exception — it is not source, nobody reviews it, and a pre-commit hook
# runs on every commit from then on.
protected_path() {
  case "$1" in
    "$HOME_REAL"/.claude/settings.json|"$HOME_REAL"/.claude/settings.local.json) return 0 ;;
    "$HOME_REAL"/.claude/hooks/*) return 0 ;;
    "$HOME_REAL"/.claude/guard-audit.log) return 0 ;;
    */.git/hooks/*) return 0 ;;
  esac
  return 1
}

# Files that are secrets in themselves. The Bash rules already refuse to `cat`
# these; leaving Read able to open them would be the same hole with a different
# tool name on it.
secret_path() {
  case "${1##*/}" in
    # .env.example and its spellings are documentation — they are committed on
    # purpose and hold placeholder values, so they have to stay readable.
    .env.example|.env.sample|.env.template|.env.dist|.env.defaults) return 1 ;;
    .env|.env.*|*.env) return 0 ;;
    .netrc|.deploy-secrets|.dev.vars) return 0 ;;
    id_rsa|id_dsa|id_ecdsa|id_ed25519|*.pem|*.p12|*.p8) return 0 ;;
    credentials|credentials.json|.credentials.json) return 0 ;;
  esac
  return 1
}

case "$tool" in
  Edit|Write|NotebookEdit)
    [ -n "$path" ] || exit 0
    path=$(canon "$path")
    protected_path "$path" &&
      block "writing to $path would disarm the guard that is reading this command. Ask the user to make the change, or to relaunch with CLAUDE_GUARD_OFF=1."
    exit 0
    ;;
  Read)
    [ -n "$path" ] || exit 0
    path=$(canon "$path")
    secret_path "$path" &&
      block "$path is a credential file. Read what you need from the code that consumes it instead."
    exit 0
    ;;
  mcp__*)
    # An MCP server can delete a database without ever touching a shell, so the
    # Bash rules never see it. Match the tool name and the whole argument blob
    # as text — the same bluntness, one layer up.
    mcpmatch() { printf '%s %s' "$tool" "$payload" | grep -Eiq "$1"; }

    mcpmatch '(d1_database|r2_bucket|kv_namespace|hyperdrive_config|workers?)_(create|delete|update|edit|put|deploy)' &&
      block "$tool mutates Cloudflare infrastructure, which is the same reach as wrangler deploy."

    mcpmatch '_(delete|destroy|purge)($|_)' &&
      block "$tool destroys a remote resource, and an MCP call is not reversible from here."

    mcpmatch 'd1_database_query' &&
      mcpmatch '\b(drop|delete|truncate|alter|insert|update|replace|grant|revoke)\b' &&
      block 'this runs a mutating statement against a D1 database. A read-only SELECT is fine; anything that writes is not.'

    exit 0
    ;;
  Bash) ;;
  *) exit 0 ;;
esac

[ -n "$cmd" ] || exit 0

match() { printf '%s' "$cmd" | grep -Eiq "$1"; }

# --------------------------------------------------------------- exemptions

# An exemption clears the *whole* command, so it may only be granted to one that
# is a single invocation. `bootstrap-deploy.sh doctor && railway up` reads as an
# exempt doctor run to a rule that only looks for the doctor stage, and every
# rule below it is then skipped.
case "$cmd" in
  *bootstrap-deploy.sh*|*observability.sh*|*sync-railway-cloudflare.sh*)
    if ! match '&&|\|\||[;|`]|\$\('; then
      # The read-only stages are the one safe entry point into each of these.
      match 'bootstrap-deploy\.sh[^&|;]* doctor( |$)' && exit 0
      match 'observability\.sh[^&|;]* (doctor|status|up|down)( |$)' && exit 0
      match 'sync-railway-cloudflare\.sh[^&|;]* (status|check)( |$)' && exit 0
    fi
    ;;
esac

# ---------------------------------------------------------------- the guard

# Only a write *aimed at* the guard counts. Naming the path in a read —
# `jq . ~/.claude/settings.json 2>/dev/null` — stays allowed, and so does
# running the guard, so the redirect or the mutating verb has to land on the
# path itself rather than merely appear in the same command.
#
# `hooks(/|\b)` rather than `hooks/`: without it `mv ~/.claude/hooks
# ~/.claude/hooks-off` and `rmdir ~/.claude/hooks` moved the whole directory out
# from under the guard, because neither names a file inside it.
GUARDED="((${HOME}|~|\\\$HOME)/\\.claude/(settings(\\.local)?\\.json|hooks(/|\\b))|dangerous-command-guard|guard-audit\\.log)"

match ">>? *[^ |;&]*$GUARDED" &&
  block 'this redirects output over the guard or the settings file that registers it.'

match "(^| )(rm|rmdir|mv|cp|chmod|chown|chflags|truncate|ln|tee|install|shred|unlink)( +-[^ ]+)* +[^|;&]*$GUARDED" &&
  block 'this rewrites or removes the guard or the settings file that registers it.'

match "(sed|perl|ruby) +-i[^|;&]*$GUARDED" &&
  block 'this edits the guard or the settings file that registers it in place.'

# The verb needs no path of its own if the shell has already been walked into
# the directory: `cd ~/.claude/hooks && rm *.sh` names nothing this rule would
# otherwise recognise.
match "cd +[^|;&]*(${HOME}|~|\\\$HOME)/\\.claude(/hooks)? *(&&|;)" &&
  match '(^| |;|&)(rm|rmdir|mv|cp|chmod|chown|truncate|ln|tee|install|shred|unlink|sed +-i|perl +-i|python3?|node|ruby)\b' &&
  block 'this steps into the guard directory and then rewrites what is in it. Name the file in full so the intent is visible, or ask the user to make the change.'

# ---------------------------------------------------------------- the rules
#
# pattern <TAB> refusal. The union below is built from this array, so a rule
# added here is in the prefilter automatically — there is no second list to keep
# in step, and no way for the prefilter to end up narrower than the rules.

RULES=(
# ------------------------------------------------------- the production data
'(^|[^-[:alnum:]])railway +connect	railway connect opens a shell on the production database.'
'(^|[^-[:alnum:]])railway +ssh\b	railway ssh opens a shell inside a running production service.'
'(^|[^-[:alnum:]])railway +run\b	railway run executes with the production environment injected, which hands the command every production secret. Run it against the local environment instead.'
'(^|[^-[:alnum:]])railway +(tcp-proxy|proxy)\b	a tcp proxy to Railway exposes the production database to every local tool.'
'restore-mysql\.sh	restore-mysql.sh overwrites a database from a backup.'
'backup-mysql\.sh|railway-mysql-backups\.sh	this dumps the production database using the production credentials. Backups run in CI, not from a session.'
'(mysql|mysqldump|mariadb)\b[^&|;]*(rlwy\.net|railway\.(app|internal)|proxy\.rlwy)	this points a database client at the production host.'
'flyway[:.-][^&|;]*(clean|repair)|flyway +(clean|repair)	flyway clean drops the schema and flyway repair rewrites the checksum history. A production repair has to be done deliberately, by hand.'
'flyway[^&|;]*(rlwy\.net|railway\.(app|internal))	this aims Flyway at production rather than the local ./db files.'
# --------------------------------------------------------- the infrastructure
'(^|[^-[:alnum:]])railway +(up|redeploy|down|delete|init|link|unlink|domain|add|volume)\b	this mutates the Railway project.'
'(^|[^-[:alnum:]])railway +(config +apply|variables? +(set|delete)|environment +(new|delete))	this rewrites Railway configuration or environment variables.'
'(^|[^-[:alnum:]])railway +(service|deployment) +(delete|remove)\b	this deletes a Railway service or deployment.'
'(^|[^-[:alnum:]])(npx +)?wrangler +(deploy|publish|delete|rollback|versions +(deploy|upload)|secret +(put|delete)|d1 +execute|r2 +object +(put|delete))	this publishes to, writes to, or deletes from Cloudflare.'
'bootstrap-deploy\.sh	bootstrap-deploy.sh mutates deploy infrastructure in every stage except doctor.'
'observability\.sh	this observability.sh stage attaches a public domain to a Railway service. doctor/status/up/down are allowed.'
'sync-railway-cloudflare\.sh	this sync-railway-cloudflare.sh stage copies production secrets between providers. status/check are allowed.'
# ------------------------------------------------------ outward-facing releases
# Public and one-way, so they are the user's call rather than a step in an
# unattended run.
'xcrun +altool[^&|;]* --upload|xcrun +notarytool +submit|altool[^&|;]* --upload-app	this uploads a build to App Store Connect.'
'(^|[^-[:alnum:]])(fastlane +(deliver|pilot|release|supply)|xcodebuild +[^&|;]*-exportArchive)	this ships a build to Apple. A release goes out when the user decides it does.'
'gh +pr +(merge|close)\b|gh +release +(create|delete|upload)\b	this merges, closes, or publishes on GitHub, where other people see it.'
'(^|[^-[:alnum:]])gh +(repo +delete|workflow +(run|enable|disable)|api +[^&|;]*(-X|--method) +(POST|PUT|PATCH|DELETE))	this mutates the GitHub repository or fires a workflow.'
'ship-mobile-changes\.sh[^&|;]* --(apply|prune)\b	this cherry-picks onto main and pushes, or deletes remote branches. Prefer --ensure-pr and let CI ship it.'
'(^|[^-[:alnum:]])(npm +publish|yarn +publish|pnpm +publish|pod +trunk +push|gem +push|cargo +publish|twine +upload)	this publishes a package to a public registry, and a published version cannot be taken back.'
# -------------------------------------------------------------- the secrets
'gh +secret +set|gh +auth +(token|refresh)	this sets or prints a repository secret or an auth token.'
'cf-token\.sh|backup-secrets\.sh|rotate-admin-password\.sh	this script handles production credentials.'
'security +find-(generic|internet)-password[^&|;]* -w	this prints a password out of the keychain in clear text.'
'(^| )(cat|bat|less|more|head|tail|open|strings|xxd|base64) [^|;&]*(\.env\b|\.env\.|\.credentials\.json|\.netrc|\.deploy-secrets|\.dev\.vars|id_rsa|id_ed25519|\.pem\b|\.p8\b|\.p12\b)	this prints a credential file. Read what you need from the code that consumes it instead.'
'(^| )(echo|printf|print) [^|;&]*\$\{?[A-Za-z_]*(API_?KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL)	this prints a secret held in the environment into the transcript.'
'(^| )(env|printenv)( |$)[^|;&]*\| *(grep|rg|ag)[^|;&]*(key|token|secret|password|cred)	this sifts the environment for secrets and prints them into the transcript.'
'(curl|wget|nc)\b[^;&]*(-d +@|--data(-binary|-raw)? +@|-T +|--upload-file +|-F +[^ ]*@)[^ ]*(\.env|\.pem|\.netrc|credential|id_rsa|id_ed25519|\.deploy-secrets|\.dev\.vars|\.aws/|\.ssh/|\.claude/)	this uploads a credential file to a network endpoint.'
# --------------------------------------------------------- the shared history
# `git -c ...` and `git --git-dir=...` sit between the verb and the flag, so the
# older `git +push` spelling stepped over them. Anything up to the next command
# separator counts as one git invocation.
'git\b[^&|;]*\bpush\b[^&|;]*( --force\b| --force-with-lease| --force-if-includes| -f\b| --mirror| --delete\b| --prune\b)	this force-pushes or deletes on the remote, rewriting history other checkouts depend on.'
'git\b[^&|;]*\bpush\b[^&|;]* \+[A-Za-z_]	a + refspec is a force push in disguise.'
'git\b[^&|;]*\bpush\b[^&|;]* :[A-Za-z_]	a : refspec deletes the remote branch.'
'git +tag +-d[^&|;]*|git +push[^&|;]* --tags[^&|;]* --force|git +update-ref +-d\b	this deletes or rewrites a ref other checkouts have already fetched.'
'git +reflog +(expire|delete)|git +gc +[^&|;]*--prune=(now|all)	this destroys the reflog, which is the last way back to work that was reset away.'
'git +config +[^&|;]*(--global|--system)[^&|;]*(hooksPath|credential|core\.editor|alias\.|url\..*insteadOf)	this rewrites global git configuration, which changes what every later git command does.'
'setup-git-hooks\.sh	this installs a git hook that runs on every commit from then on.'
'(^| )(sudo +)?rm +(-[a-z]* )*-[a-z]*[rR][a-z]* +[^|;&]*\.claude/worktrees	deleting a worktree directory by hand strands whatever is uncommitted inside it, and no branch listing will show that it is gone. Check git status there, commit, then use git worktree remove.'
# ------------------------------------------------------------- the machine
'(^| )(crontab|launchctl +(load|unload|bootstrap|bootout|enable|disable)|systemsetup|csrutil|spctl +--master-disable|nvram)\b	this changes what the machine runs outside this session, and it outlives it.'
'(^| )(sudo +)?rm +(-[a-z]* )*-[a-z]*[rR][a-z]* +[^|;&]*(/|~|\$HOME|\$\{HOME\})( |/?$)	a recursive delete aimed at the home directory or the filesystem root takes far more than the thing you meant.'
'chmod +(-R +)?(0?777|a\+w)\b	making a tree world-writable is not a fix for a permissions error.'
'(^| )(history +-c|rm +[^|;&]*\.(zsh|bash)_history)	this erases the shell history, which is where the record of what happened lives.'
# ------------------------------------------------------------------- general
'(curl|wget)[^|]*\| *(sudo +)?(ba|z|d|k)?sh\b	piping a download straight into a shell runs code nobody has read.'
)

# The union of every pattern above, as one grep. Built from the array, so it is
# a superset by construction and can never be narrower than the rules it stands
# in for.
union=""
for rule in "${RULES[@]}"; do
  union="${union:+$union|}(${rule%%	*})"
done

match "$union" || exit 0

# Something in there matched. Find which, so the refusal can say why.
for rule in "${RULES[@]}"; do
  match "${rule%%	*}" && block "${rule#*	}"
done

exit 0
