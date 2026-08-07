#!/bin/bash
#
# guard-test.sh — feed guard-cases.tsv through the guard and report failures.
#
#     .claude/hooks/guard-test.sh                 # test the copy in this repo
#     .claude/hooks/guard-test.sh ~/.claude/hooks/dangerous-command-guard.sh
#
# The cases live in a file rather than in this script on purpose. The guard
# matches the whole command string, so a shell command that merely spells out
# `railway up` is blocked — including the command that would run the tests.
# Reading the strings from a file keeps them out of any command line.

set -u

here="$(cd "$(dirname "$0")" && pwd)"
guard="${1:-$here/dangerous-command-guard.sh}"
cases="$here/guard-cases.tsv"

if [ ! -x "$guard" ]; then
  echo "not executable: $guard" >&2
  exit 1
fi

fails=0
total=0
while IFS=$'\t' read -r want tool payload; do
  case "$want" in ''|'#'*) continue ;; esac
  total=$((total + 1))
  case "$tool" in
    Bash)
      json=$(/usr/bin/jq -nc --arg c "$payload" '{tool_name:"Bash",tool_input:{command:$c}}')
      ;;
    mcp__*)
      # An MCP call carries arguments, not a path — the payload column is the
      # tool_input object itself, so a rule can be tested against what the call
      # would actually do and not just against its name.
      json=$(/usr/bin/jq -nc --arg t "$tool" --argjson i "${payload:-\{\}}" \
        '{tool_name:$t,tool_input:$i}')
      ;;
    *)
      json=$(/usr/bin/jq -nc --arg t "$tool" --arg p "${payload/#\~/$HOME}" \
        '{tool_name:$t,tool_input:{file_path:$p}}')
      ;;
  esac
  printf '%s' "$json" | "$guard" >/dev/null 2>&1
  rc=$?
  got=PASS
  [ "$rc" -eq 2 ] && got=BLOCK
  if [ "$got" != "$want" ]; then
    printf 'FAIL want=%-5s got=%-5s %-6s %s\n' "$want" "$got" "$tool" "$payload"
    fails=$((fails + 1))
  fi
done < "$cases"

printf '%d cases, %d failures\n' "$total" "$fails"

# Verdicts are not the whole story. A stray line once left the guard running
# `bash <first word of the command> <the rest>` before any rule was evaluated:
# every case still reported the right verdict, and a blocked restore-mysql.sh
# had already run by the time the block landed. Reading a command must have no
# effect and say nothing.
probe=$(mktemp -d)
cat > "$probe/side-effect.sh" <<'INNER'
#!/bin/bash
: > "$(dirname "$0")/it-ran"
INNER
chmod +x "$probe/side-effect.sh"

noise=$(/usr/bin/jq -nc --arg c "$probe/side-effect.sh --apply" \
  '{tool_name:"Bash",tool_input:{command:$c}}' | "$guard" 2>&1 >/dev/null)

if [ -e "$probe/it-ran" ]; then
  echo "FAIL the guard executed the command it was inspecting" >&2
  fails=$((fails + 1))
fi
if [ -n "$noise" ]; then
  printf 'FAIL the guard wrote to stderr while allowing a command: %s\n' "$noise" >&2
  fails=$((fails + 1))
fi
rm -rf "$probe"

[ "$fails" -eq 0 ]
