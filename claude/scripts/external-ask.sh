#!/bin/bash
# external-ask.sh — ask another model one question, one shot, no session.
#
# The replacement for `consult.sh -b print` and `consult.sh --to pi`: a single
# question to a different family, answered on stdout, with no Herdr tab and no
# saved conversation. For anything that needs a session (a review you can
# follow up, a design discussion), use the external-review skill instead.
#
#   external-ask.sh --to pi|codex [-m MODEL] [-t TIMEOUT] [-o FILE] <prompt-file> | -
#   echo "question" | external-ask.sh --to pi -m google/gemini-3-flash-preview -
#
# Why the flags for pi: a draft or a research answer does not need the caller's
# AGENTS.md, skills, MCP servers or tools. Loading them made the same request
# take 232s instead of 66s (measured 2026-11), and it made the answer's shape
# depend on whatever the caller had configured. Pass --tools to allow them.
#
# stdout : the answer body
# stderr : ANSWER_FILE=<path> / AI_MODEL=<target>/<model>
# exit   : 0 = answered, 1 = failed (auth, quota, timeout, empty), 2 = usage

set -uo pipefail

PROG=$(basename "$0")
TARGET=""
MODEL=""
TIMEOUT=${EXTERNAL_ASK_TIMEOUT:-20m}
OUT=""
TOOLS=0

die() {
  echo "$PROG: $1" >&2
  exit "${2:-1}"
}

usage() {
  cat <<'EOF'
usage: external-ask.sh --to pi|codex [-m MODEL] [-t TIMEOUT] [-o FILE] <prompt-file> | -

  --to TARGET     pi | codex（別ファミリを名指しする）
  -m, --model M   モデル。pi は必須（例 google/gemini-3-flash-preview）、codex は省略可
  -t, --timeout T 期限（既定 20m。20m / 600s / 600）
  -o, --out FILE  回答の置き場所（既定: $TMPDIR/external-ask-<target>-<日時>.md）
  --tools         pi にツールを渡す（既定は外す: 下書き・調べものには要らない）
  -h, --help

  stdout に本文、stderr に ANSWER_FILE と AI_MODEL=<target>/<model>。
  1 回で終わり。失敗しても別モデルに切り替えない。
EOF
}

need_value() { (( $2 >= 2 )) || die "$1 needs a value" 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to) need_value "$1" $#; TARGET=$2; shift 2 ;;
    -m | --model) need_value "$1" $#; MODEL=$2; shift 2 ;;
    -t | --timeout) need_value "$1" $#; TIMEOUT=$2; shift 2 ;;
    -o | --out) need_value "$1" $#; OUT=$2; shift 2 ;;
    --tools) TOOLS=1; shift ;;
    -h | --help) usage; exit 0 ;;
    --) shift; break ;;
    -) break ;;
    -*) usage >&2; exit 2 ;;
    *) break ;;
  esac
done

case "$TARGET" in
  pi | codex) ;;
  "") die "--to is required (pi | codex)" 2 ;;
  *) die "unknown --to: $TARGET (pi | codex)" 2 ;;
esac
[[ -n "$MODEL" || "$TARGET" == "codex" ]] ||
  die "--model is required for pi (e.g. google/gemini-3-flash-preview)" 2

prompt=""
if [[ "${1:-}" == "-" || $# -eq 0 ]]; then
  prompt=$(cat) # stdin (no argument also reads stdin: `cat q.md | external-ask.sh --to pi -`)
else
  [[ -f "$1" ]] || die "prompt file not found: $1" 2
  prompt=$(cat "$1")
fi
[[ -n "${prompt//[[:space:]]/}" ]] || die "empty prompt" 2

# 20m / 600s / 600 -> seconds
num=${TIMEOUT%[smh]}
unit=${TIMEOUT#"$num"}
case "$unit" in
  m) mult=60 ;;
  s) mult=1 ;;
  h) mult=3600 ;;
  "") mult=1 ;;
  *) die "invalid --timeout: $TIMEOUT" 2 ;;
esac
[[ "$num" =~ ^[0-9]+$ ]] || die "invalid --timeout: $TIMEOUT" 2
timeout_s=$((num * mult))

[[ -n "$OUT" ]] ||
  OUT="${TMPDIR:-/tmp}/external-ask-${TARGET}-$(date +%Y%m%d-%H%M%S).md"
mkdir -p "$(dirname "$OUT")" 2>/dev/null || die "cannot create $(dirname "$OUT")"
raw="${OUT%.md}.log"
: >"$OUT"

model_label=${MODEL:-default}
rc=0
case "$TARGET" in
  pi)
    args=(-p --no-session --no-mcp --no-extensions --no-skills --no-context-files)
    ((TOOLS)) || args+=(--no-tools)
    args+=(--model "$MODEL")
    timeout -k 1m "${timeout_s}s" pi "${args[@]}" -- "$prompt" \
      </dev/null >"$OUT" 2>"$raw" || rc=$?
    ;;
  codex)
    args=(exec -s read-only --ephemeral --skip-git-repo-check --color never -o "$OUT")
    [[ -n "$MODEL" ]] && args+=(-m "$MODEL")
    timeout -k 1m "${timeout_s}s" codex "${args[@]}" -- "$prompt" \
      </dev/null >"$raw" 2>&1 || rc=$?
    ;;
esac

if ((rc != 0)); then
  [[ -s "$raw" ]] && { echo "$PROG: $TARGET exited with $rc（$raw を見る）" >&2; tail -n 5 "$raw" >&2; }
  die "$TARGET did not answer" 1
fi
if [[ ! -s "$OUT" ]]; then
  echo "$PROG: $TARGET returned nothing（$raw を見る）" >&2
  exit 1
fi
[[ -n "$(tail -c 1 "$OUT")" ]] && echo >>"$OUT"

echo "ANSWER_FILE=$OUT" >&2
echo "AI_MODEL=$TARGET/$model_label" >&2
cat "$OUT"
