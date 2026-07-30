#!/bin/bash
#
# help-sync-record.sh — PostToolUse (Edit|Write) hook.
#
# Notes every code edit that might change user-facing behaviour into a
# per-session marker file. Editing the help content itself clears the marker,
# since the help is evidently being tended to alongside the change.
# help-sync-check.sh reads the marker when the session stops.

input=$(cat)
f=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_response.filePath // empty')
sid=$(printf '%s' "$input" | jq -r '.session_id // "default"')
[ -n "$f" ] || exit 0
marker="${TMPDIR:-/tmp}/claude-scripty-help-pending-$sid"

case "$f" in
  # The help content itself: editing it counts as updating the help.
  */scripty/Models/HelpTopic.swift | */scripty/Views/KeyboardShortcutsView.swift | \
  */templates/help.html | */templates/fragments/shortcuts.html | */static/js/help-center.js)
    rm -f "$marker"
    exit 0 ;;
  # Help presentation, tests and build output: neither a feature change nor a
  # help update, so they leave the marker alone.
  */scripty/Views/HelpView.swift | */scripty/State/HelpPresentation.swift | \
  */scriptyTests/* | */scriptyUITests/* | */src/test/* | */target/*)
    exit 0 ;;
  # Apple client app code; web app code, templates and static assets.
  */scripty/*.swift | */scripty-web/src/main/java/* | */scripty-web/src/main/resources/*)
    printf '%s\n' "$f" >> "$marker" ;;
esac
exit 0
