#!/bin/bash
# claude-consult.sh — ask a read-only Claude for a design consultation from
# another agent (Cursor / pi / Cline). Claude can only Read / Grep / Glob: no
# MCP servers, no edits, no shell.
#
# Usage:
#   claude-consult.sh [-m model] [-r session_id] [-t timeout] <prompt-file>
#   claude-consult.sh [-m model] [-r session_id] [-t timeout] -   # stdin
#
# Run it from the repository you want to discuss: Claude reads files relative to
# the cwd, and `--resume` only finds a session started from the same cwd. This
# script never cd's.
#
# Contract:
#   stdout : the answer body
#   files  : <prompt-file minus extension>.answer.md (answer) and .json (raw
#            output). For stdin, files go to ./claude-consult.{answer.md,json}
#   stderr : `AI_MODEL=claude/<model>` and `SESSION_ID=<id>`
#            (same key=value convention as ai-fallback.sh)
#   exit   : 0 = answered, 1 = failed, 2 = usage error

set -euo pipefail

MODEL=${CLAUDE_CONSULT_MODEL:-opus}
TIMEOUT=${CLAUDE_CONSULT_TIMEOUT:-20m}
ALLOWED_TOOLS="Read,Grep,Glob"
RESUME_ID=""

usage() {
  cat <<'EOF2'
Usage: claude-consult.sh [-m model] [-r session_id] [-t timeout] <prompt-file> | -

  prompt-file  file holding the question (use - for stdin)
  -m model     claude model alias or id (default: $CLAUDE_CONSULT_MODEL or opus)
  -r id        resume an earlier consultation (SESSION_ID from stderr);
               must be run from the same cwd as the first call
  -t timeout   timeout for the call (default: $CLAUDE_CONSULT_TIMEOUT or 20m)

Claude runs read-only: --permission-mode plan, tools Read/Grep/Glob only,
--strict-mcp-config (no MCP servers).

Exit: 0 = answered, 1 = failed, 2 = usage error.
EOF2
}

while getopts ":m:r:t:h" opt; do
  case "$opt" in
    m) MODEL=$OPTARG ;;
    r) RESUME_ID=$OPTARG ;;
    t) TIMEOUT=$OPTARG ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))

src=${1:-}
if [[ -z "$src" ]]; then
  usage >&2
  exit 2
fi
for cmd in claude jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: $cmd is not installed" >&2
    exit 1
  fi
done

if [[ "$src" == "-" ]]; then
  prompt=$(cat)
  base="claude-consult"
else
  if [[ ! -f "$src" ]]; then
    echo "error: prompt file not found: $src" >&2
    exit 2
  fi
  prompt=$(cat "$src")
  base="${src%.*}"
fi
if [[ -z "$prompt" ]]; then
  echo "error: empty prompt" >&2
  exit 2
fi
answer_file="$base.answer.md"
raw_file="$base.json"

args=(-p --model "$MODEL" --permission-mode plan --tools "$ALLOWED_TOOLS"
      --strict-mcp-config --output-format json)
[[ -n "$RESUME_ID" ]] && args+=(--resume "$RESUME_ID")

# stdin must not be an open pipe, or claude hangs.
rc=0
timeout -k 1m "$TIMEOUT" claude "${args[@]}" "$prompt" < /dev/null > "$raw_file" || rc=$?
if (( rc != 0 )); then
  echo "error: claude exited with $rc (see $raw_file)" >&2
  exit 1
fi

# Output is an array of events in recent versions and a single object in older
# ones; take the last `result` event either way.
result=$(jq -c 'if type == "array" then map(select(.type == "result")) | last else . end' "$raw_file" 2>/dev/null || true)
if [[ -z "$result" || "$result" == "null" ]]; then
  echo "error: no result event in $raw_file" >&2
  exit 1
fi
if [[ "$(jq -r '.is_error // false' <<<"$result")" == "true" ]]; then
  echo "error: claude reported an error: $(jq -r '.result // .subtype // "unknown"' <<<"$result")" >&2
  exit 1
fi

jq -r '.result // empty' <<<"$result" > "$answer_file"
if [[ ! -s "$answer_file" ]]; then
  echo "error: empty answer (see $raw_file)" >&2
  exit 1
fi

cat "$answer_file"
echo "AI_MODEL=claude/$MODEL" >&2
echo "SESSION_ID=$(jq -r '.session_id // empty' <<<"$result")" >&2
