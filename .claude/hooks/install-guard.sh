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

if ! /usr/bin/jq -e '.hooks.PreToolUse[]?.hooks[]? | select(.command | test("dangerous-command-guard"))' "$settings" >/dev/null 2>&1; then
  cat <<'EOF'

Not registered yet. Add this to the "hooks" object in ~/.claude/settings.json:

  "PreToolUse": [
    {
      "matcher": "Bash|Edit|Write|NotebookEdit",
      "hooks": [
        { "type": "command", "command": "\"$HOME\"/.claude/hooks/dangerous-command-guard.sh", "timeout": 10 }
      ]
    }
  ]
EOF
else
  echo "registered in $settings"
fi
