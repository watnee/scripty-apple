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
# This guard is not a sandbox. A determined model can still write a script and
# run it under a name this file has never heard of. It stops the direct,
# plausible mistake — which is the failure mode bypassPermissions actually has.

set -u

JQ=/usr/bin/jq
input=$(cat)
tool=$(printf '%s' "$input" | "$JQ" -r '.tool_name // empty')

block() {
  printf 'Blocked by dangerous-command-guard: %s

This rule holds in every permission mode, including bypassPermissions, and is
not something to work around. Say what you wanted to run and why, and let the
user run it themselves.
' "$1" >&2
  exit 2
}

# ---------------------------------------------------------------- file writes

# The guard has to survive the session it is guarding. In bypassPermissions a
# model can otherwise edit the hook, or the settings file that registers it,
# and the next command goes through unexamined.
protected_path() {
  case "$1" in
    "$HOME"/.claude/settings.json|"$HOME"/.claude/hooks/*) return 0 ;;
  esac
  return 1
}

case "$tool" in
  Edit|Write|NotebookEdit)
    path=$(printf '%s' "$input" | "$JQ" -r '.tool_input.file_path // .tool_input.notebook_path // empty')
    [ -n "$path" ] || exit 0
    if protected_path "$path"; then
      block "writing to $path would disarm the guard that is reading this command. Ask the user to make the change, or to relaunch with CLAUDE_GUARD_OFF=1."
    fi
    exit 0
    ;;
  Bash) ;;
  *) exit 0 ;;
esac

cmd=$(printf '%s' "$input" | "$JQ" -r '.tool_input.command // empty')
[ -n "$cmd" ] || exit 0

# One line, single-spaced, so a wrapped or multi-line command matches the same
# patterns a one-liner does.
cmd=$(printf '%s' "$cmd" | tr '\n\t' '  ' | tr -s ' ')

match() { printf '%s' "$cmd" | grep -Eiq "$1"; }

# The user opts out for a whole session by exporting this before `claude`.
# A command can't set it: hooks inherit Claude Code's environment, not the
# environment of the command being inspected.
[ "${CLAUDE_GUARD_OFF:-}" = "1" ] && exit 0

# --------------------------------------------------------------- exemptions

# The read-only stage of the deploy bootstrapper is the one safe entry point.
match 'bootstrap-deploy\.sh[^&|;]* doctor( |$)' && exit 0

# ------------------------------------------------------- the production data

match '(^|[^-[:alnum:]])railway +connect' &&
  block 'railway connect opens a shell on the production database.'

match '(^|[^-[:alnum:]])railway +(run|ssh)\b[^&|;]*\b(mysql|mysqldump|mariadb|flyway)' &&
  block 'this runs a database client against the production environment.'

match '(^|[^-[:alnum:]])railway +(tcp-proxy|proxy)\b' &&
  block 'a tcp proxy to Railway exposes the production database to every local tool.'

match 'restore-mysql\.sh' &&
  block 'restore-mysql.sh overwrites a database from a backup.'

match '(mysql|mysqldump|mariadb)\b[^&|;]*(rlwy\.net|railway\.(app|internal)|proxy\.rlwy)' &&
  block 'this points a database client at the production host.'

match 'flyway[:.-][^&|;]*(clean|repair)|flyway +(clean|repair)' &&
  block 'flyway clean drops the schema and flyway repair rewrites the checksum history. A production repair has to be done deliberately, by hand.'

match 'flyway[^&|;]*(rlwy\.net|railway\.(app|internal))' &&
  block 'this aims Flyway at production rather than the local ./db files.'

# --------------------------------------------------------- the infrastructure

match '(^|[^-[:alnum:]])railway +(up|redeploy|down|delete|init|link|unlink|domain|add|volume)\b' &&
  block 'this mutates the Railway project.'

match '(^|[^-[:alnum:]])railway +(config +apply|variables? +(set|delete)|environment +(new|delete))' &&
  block 'this rewrites Railway configuration or environment variables.'

match '(^|[^-[:alnum:]])wrangler +(deploy|publish|delete)\b' &&
  block 'this publishes to or deletes from Cloudflare.'

match '(^|[^-[:alnum:]])railway +(service|deployment) +(delete|remove)\b' &&
  block 'this deletes a Railway service or deployment.'

match 'bootstrap-deploy\.sh' &&
  block 'bootstrap-deploy.sh mutates deploy infrastructure in every stage except doctor.'

# Outward-facing releases. Not in hard_deny, but they are public and one-way,
# so they are the user's call rather than a step in an unattended run.
match 'xcrun +altool[^&|;]* --upload|xcrun +notarytool +submit|altool[^&|;]* --upload-app' &&
  block 'this uploads a build to App Store Connect.'

match 'gh +pr +(merge|close)\b|gh +release +(create|delete)\b' &&
  block 'this merges, closes, or publishes on GitHub, where other people see it.'

# -------------------------------------------------------------- the secrets

match 'gh +secret +set|gh +auth +token' &&
  block 'this sets or prints a repository secret.'

match 'cf-token\.sh|backup-secrets\.sh|rotate-admin-password\.sh' &&
  block 'this script handles production credentials.'

match 'security +find-(generic|internet)-password[^&|;]* -w' &&
  block 'this prints a password out of the keychain in clear text.'

match '(^| )(cat|bat|less|more|head|tail|open) [^|;&]*(\.env\b|\.env\.|\.credentials\.json|\.netrc|id_rsa|id_ed25519|\.pem\b)' &&
  block 'this prints a credential file. Read what you need from the code that consumes it instead.'

# --------------------------------------------------------- the shared history

match 'git +push[^&|;]*( --force\b| --force-with-lease| -f\b| --mirror| --delete\b| --prune\b)' &&
  block 'this force-pushes or deletes on the remote, rewriting history other checkouts depend on.'

match 'git +push[^&|;]* \+[A-Za-z_]' &&
  block 'a + refspec is a force push in disguise.'

match 'git +push[^&|;]* :[A-Za-z_]' &&
  block 'a : refspec deletes the remote branch.'

match 'git +tag +-d[^&|;]*|git +push[^&|;]* --tags[^&|;]* --force' &&
  block 'this deletes or rewrites a tag other checkouts have already fetched.'

# ---------------------------------------------------------------- the guard

# Only a write *aimed at* the guard counts. Naming the path in a read —
# `jq . ~/.claude/settings.json 2>/dev/null` — stays allowed, so the redirect
# or the mutating verb has to land on the path itself, not merely appear in
# the same command.
#
# Scoped to $HOME, matching protected_path above: a repo's own .claude/hooks/
# is ordinary source and has to stay editable, which is how this file gets
# maintained at all. The guard's own name is matched anywhere, so a copy or a
# rename of it is still covered.
GUARDED="((${HOME}|~|\\\$HOME)/\\.claude/(settings\\.json|hooks/)|dangerous-command-guard)"

match ">>? *[^ |;&]*$GUARDED" &&
  block 'this redirects output over the guard or the settings file that registers it.'

match "(^| )(rm|mv|cp|chmod|chown|truncate|ln|tee|install)( +-[^ ]+)* +[^|;&]*$GUARDED" &&
  block 'this rewrites or removes the guard or the settings file that registers it.'

match "(sed|perl|ruby) +-i[^|;&]*$GUARDED" &&
  block 'this edits the guard or the settings file that registers it in place.'

# ------------------------------------------------------------------- general

match '(curl|wget)[^|]*\| *(sudo +)?(ba|z|d)?sh\b' &&
  block 'piping a download straight into a shell runs code nobody has read.'

exit 0
