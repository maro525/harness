#!/bin/bash
# ai-fallback.sh — run one prompt through a chain of models, skipping the ones
# that are out of quota.
#
# Usage:
#   ai-fallback.sh <prompt-file>     # prompt read from a file
#   ai-fallback.sh -                 # prompt read from stdin
#   AI_CHAIN="m1 m2 m3" ai-fallback.sh <prompt-file>   # override the chain
#
# The chain (and why it is in this order) is defined in
# ~/.claude/rules/tool-routing.md > "OpenCode リサーチの実行". This script is
# the only executable form of that rule — do not write `opencode run` by hand
# in skills and commands, they must call this script.
#
# Contract:
#   stdout : the answer of the first model that succeeded
#   stderr : one `skip: <model> (<reason>)` line per skipped candidate, then
#            `AI_ENGINE=<opencode|pi>` / `AI_MODEL=<model>` /
#            `AI_SKIPPED=<m1,m2>` (the last one only when something was skipped)
#   exit   : 0 = a model answered, 1 = every model failed, 2 = usage error

set -uo pipefail

CHAIN_DEFAULT="github-copilot/gpt-6-astra opencode-go/deepseek-v4-pro ollama-cloud/deepseek-v4.1-flash"
CHAIN=${AI_CHAIN:-$CHAIN_DEFAULT}
TIMEOUT=${AI_TIMEOUT:-20m}

usage() {
  cat <<'EOF'
Usage: ai-fallback.sh <prompt-file> | -

  prompt-file  file holding the prompt (long prompts are passed as an argument,
               so keep it under ARG_MAX — every realistic research prompt is)
  -            read the prompt from stdin

Environment:
  AI_CHAIN     space-separated candidate models, first try first
               (default: github-copilot/gpt-6-astra opencode-go/deepseek-v4-pro
                ollama-cloud/deepseek-v4.1-flash)
  AI_TIMEOUT   timeout per candidate (default: 20m)

Exit: 0 = answered, 1 = all candidates failed, 2 = usage error.
EOF
}

src=${1:-}
case "$src" in
  ''|-h|--help)
    usage
    [[ -n "$src" ]] && exit 0
    exit 2
    ;;
esac

if [[ "$src" == "-" ]]; then
  prompt=$(cat)
else
  if [[ ! -f "$src" ]]; then
    echo "ai-fallback: prompt file not found: $src" >&2
    exit 2
  fi
  prompt=$(cat "$src")
fi

if [[ -z "${prompt//[[:space:]]/}" ]]; then
  echo "ai-fallback: prompt is empty" >&2
  exit 2
fi

# OpenCode is the primary engine. Where it is not installed at all, the same
# chain runs through pi (`opencode-go/*` is the same plan as pi's `oc-sdk-go/*`).
ENGINE=opencode
if ! command -v opencode >/dev/null 2>&1; then
  ENGINE=pi
fi

pi_model() {
  case "$1" in
    opencode-go/*) printf 'oc-sdk-go/%s' "${1#opencode-go/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Newest OpenCode session log — OpenCode can exit 0 with empty output on a 429,
# so the log is the only place the quota failure shows up in that case.
latest_log() {
  ls -t "${HOME}/.local/share/opencode/log"/*.log 2>/dev/null | head -n 1
}

tmpdir=$(mktemp -d) || { echo "ai-fallback: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmpdir"' EXIT

SKIPPED=()

for model in $CHAIN; do
  out="$tmpdir/out"
  err="$tmpdir/err"
  : >"$out"
  : >"$err"

  if [[ "$ENGINE" == opencode ]]; then
    # --print-logs --log-level ERROR: OpenCode answers a 429 / DB failure with
    # exit 0 and empty stdout, so the reason only exists on stderr. The answer
    # itself is on stdout and is not affected.
    timeout -k 1m "$TIMEOUT" opencode run --agent plan --print-logs --log-level ERROR \
      -m "$model" "$prompt" </dev/null >"$out" 2>"$err"
  else
    timeout -k 1m "$TIMEOUT" pi -p --no-session --model "$(pi_model "$model")" "$prompt" \
      </dev/null >"$out" 2>"$err"
  fi
  rc=$?

  reason=""
  if [[ $rc -eq 124 || $rc -eq 137 ]]; then
    reason="timeout"
  elif grep -qiE '429|insufficient_quota|rate.?limit|quota' "$err"; then
    reason="quota"
  elif grep -qiE '401|403|unauthorized|invalid credential' "$err"; then
    reason="auth"
  elif [[ $rc -ne 0 ]]; then
    reason="exit ${rc}"
  elif [[ ! -s "$out" ]]; then
    log=$(latest_log)
    if [[ -n "$log" ]] && grep -qiE '429|insufficient_quota|rate.?limit' "$log"; then
      reason="quota (log)"
    elif grep -qi 'ERROR' "$err"; then
      reason="error"
    else
      reason="empty output"
    fi
  fi

  if [[ -n "$reason" ]]; then
    printf 'skip: %s (%s)\n' "$model" "$reason" >&2
    if [[ "$reason" == "error" ]]; then
      grep -m1 -i 'ERROR' "$err" | cut -c1-160 | sed 's/^/  ↳ /' >&2
    fi
    SKIPPED+=("$model")
    # A quota failure says nothing about the engine, but an OpenCode-side error
    # (broken DB, bad install) does: the other candidates would hit the same
    # wall, so switch the engine instead of burning through the chain.
    if [[ "$ENGINE" == opencode && "$reason" != quota* ]] && command -v pi >/dev/null 2>&1; then
      echo "ai-fallback: opencode unusable ($reason) - switching to pi" >&2
      ENGINE=pi
    fi
    continue
  fi

  cat "$out"
  printf 'AI_ENGINE=%s\n' "$ENGINE" >&2
  printf 'AI_MODEL=%s\n' "$model" >&2
  if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    printf 'AI_SKIPPED=%s\n' "$(printf '%s,' "${SKIPPED[@]}" | sed 's/,$//')" >&2
  fi
  exit 0
done

echo "ai-fallback: every candidate failed (${CHAIN})" >&2
exit 1
