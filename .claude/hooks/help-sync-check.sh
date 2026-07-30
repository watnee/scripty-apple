#!/bin/bash
#
# help-sync-check.sh — Stop hook.
#
# If code changed this session and the help content was never touched, block
# the stop once and ask Claude to review the help centre. stop_hook_active
# guards against looping: the second stop always goes through.

input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // "default"')
active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false')
marker="${TMPDIR:-/tmp}/claude-scripty-help-pending-$sid"

[ -f "$marker" ] || exit 0
if [ "$active" = "true" ]; then
  rm -f "$marker"
  exit 0
fi

files=$(sort -u "$marker" | head -20)
rm -f "$marker"

jq -n --arg files "$files" '{
  decision: "block",
  reason: ("Code changed this session without a help-content update. Changed files:\n\($files)\n\nCheck whether the in-app help should reflect these changes. Help content for the Apple client lives in scripty/Models/HelpTopic.swift (keyboard shortcuts in scripty/Views/KeyboardShortcutsView.swift); the web help lives in scripty-web at src/main/resources/templates/help.html (shortcuts in templates/fragments/shortcuts.html, search keywords in static/js/help-center.js). If a user-facing behaviour was added, changed or removed, update the matching topics now, following the existing tone and structure of each file — and remember the Apple help deliberately omits web-only features. If nothing user-facing changed, say so in one sentence and finish.")
}'
exit 0
