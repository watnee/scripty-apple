#!/bin/bash
#
# install-guard.sh — copy dangerous-command-guard.sh to where Claude Code runs it.
#
# Refuses to run unless stdout is a terminal. Claude's Bash tool captures its
# output, so it can never be a terminal there — which is the point. The guard
# blocks Claude from editing the live copy directly; without this check, an
# install script in the repo would hand back the same power one step removed.
#
# Run it yourself after editing the guard:
#
#     .claude/hooks/install-guard.sh
#
# With no arguments it reports drift and does nothing else.

set -eu

src="$(cd "$(dirname "$0")" && pwd)/dangerous-command-guard.sh"
dst="$HOME/.claude/hooks/dangerous-command-guard.sh"
settings="$HOME/.claude/settings.json"

if [ ! -f "$src" ]; then
  echo "no guard at $src" >&2
  exit 1
fi

if [ ! -f "$dst" ]; then
  echo "not installed yet: $dst is missing"
elif cmp -s "$src" "$dst"; then
  echo "in sync: $dst matches this repo"
else
  echo "drifted from this repo:"
  diff -u "$dst" "$src" || true
fi

matcher=$(/usr/bin/jq -r '
    .hooks.PreToolUse[]? | select(.hooks[]?.command | test("dangerous-command-guard")) | .matcher // ""
  ' "$settings" 2>/dev/null | head -1)

if [ -z "$matcher" ]; then
  cat <<'EOF'

Not registered yet. Add this to the "hooks" object in ~/.claude/settings.json:

  "PreToolUse": [
    {
      "matcher": "Bash|Edit|Write|NotebookEdit|Read|mcp__.*",
      "hooks": [
        { "type": "command", "command": "\"$HOME\"/.claude/hooks/dangerous-command-guard.sh", "timeout": 10 }
      ]
    }
  ]
EOF
else
  echo "registered in $settings"

  # A rule the matcher never routes to the guard is a rule that does not exist.
  # The guard inspects Read (credential files) and MCP calls (a connector can
  # delete a database without touching a shell), and both were added after the
  # original matcher was written — so an installed guard can be fully up to date
  # and still be deaf to half of itself.
  missing=""
  for t in Bash Edit Write NotebookEdit Read mcp__cloudflare__d1_database_delete; do
    printf '%s' "$t" | grep -Eq "^($matcher)$" || missing="$missing $t"
  done

  if [ -n "$missing" ]; then
    cat <<EOF

The matcher in $settings is:

  "$matcher"

which does not route these to the guard:$missing

Rules for them are in the guard and will simply never run. Widen it to:

  "matcher": "Bash|Edit|Write|NotebookEdit|Read|mcp__.*"
EOF
  fi
fi

if [ ! -t 1 ]; then
  cat >&2 <<'EOF'

Not a terminal, so nothing was installed. Run this script yourself from a shell,
or copy the file by hand. This check exists so that an agent cannot reinstall
the guard it is not allowed to edit.
EOF
  exit 1
fi

if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
  exit 0
fi

mkdir -p "$(dirname "$dst")"
cp "$src" "$dst"
chmod +x "$dst"
echo "installed $dst"
