#!/bin/bash
# ai-fallback.sh — run one prompt through a chain of models (and engines),
# skipping the ones that are out of quota or broken. The chain starts with the
# Codex CLI and falls back to OpenCode models.
#
# Usage:
#   ai-fallback.sh <prompt-file>     # prompt read from a file
#   ai-fallback.sh -                 # prompt read from stdin
#   AI_CHAIN="m1 m2 m3" ai-fallback.sh <prompt-file>   # override the chain
#   AI_CHAIN="codex:gpt-6-sol m2" ai-fallback.sh <prompt-file>
#
# The chain (and why it is in this order) is defined in
# ~/.claude/rules/tool-routing.md > "OpenCode リサーチの実行". This script is
# the only executable form of that rule — do not write `opencode run` by hand
# in skills and commands, they must call this script.
#
# Two fallback axes:
#   models  : codex -> github-copilot/gpt-6-astra -> opencode-go/deepseek-v4-pro
#             -> ollama-cloud/deepseek-v4.1-flash   (AI_CHAIN overrides)
#   engines : opencode2 (v2) -> opencode (v1) -> pi  (whichever is installed)
# `codex` / `codex:<model>` is a single-shot candidate run by the Codex CLI
# (`codex exec`, read-only sandbox, non-interactive). It never switches engines:
# any failure moves on to the next model. Plain `codex` uses the model from
# ${CODEX_HOME:-~/.codex}/config.toml and is reported as `codex/<that model>`.
# Every other candidate is `provider/model` and runs on the engine axis below.
# An engine is kept for the whole chain until it fails for a reason that is not
# quota (broken DB, bad install, bad credentials) — then the next engine retries
# the same model. A quota failure never switches engines: the upstream is the
# same, so the next model is what matters.
#
# Contract:
#   stdout : the answer of the first model that succeeded
#   stderr : one `skip: <model> on <engine> (<reason>)` line per attempt, then
#            `AI_ENGINE=<engine>` / `AI_MODEL=<model>` /
#            `AI_SKIPPED=<m1,m2>` (the last one only when something was skipped)
#   exit   : 0 = a model answered, 1 = everything failed, 2 = usage error

set -uo pipefail

CHAIN_DEFAULT="codex github-copilot/gpt-6-astra opencode-go/deepseek-v4-pro ollama-cloud/deepseek-v4.1-flash"
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
               (default: codex github-copilot/gpt-6-astra
                opencode-go/deepseek-v4-pro ollama-cloud/deepseek-v4.1-flash)
               `codex` / `codex:<model>` runs on the Codex CLI; everything else
               is an OpenCode `provider/model`
  AI_TIMEOUT   timeout per attempt (default: 20m)

Codex candidates run `codex exec -s read-only` and fall through to the next
model on any failure (quota, auth, timeout, empty output, non-zero exit).
Engines for provider/model candidates are picked in this order when installed:
opencode2 (v2) -> opencode (v1) -> pi. The chain keeps one engine until it fails for a non-quota reason,
then the next engine retries the same model.

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

ENGINES=()
for engine in opencode2 opencode pi; do
  if command -v "$engine" >/dev/null 2>&1; then
    ENGINES+=("$engine")
  fi
done
HAVE_CODEX=0
if command -v codex >/dev/null 2>&1; then
  HAVE_CODEX=1
fi
if [[ ${#ENGINES[@]} -eq 0 && $HAVE_CODEX -eq 0 ]]; then
  echo "ai-fallback: no engine found (codex / opencode2 / opencode / pi)" >&2
  exit 1
fi

# `codex` -> codex/<model from config.toml> (codex/default when unreadable),
# `codex:<model>` -> codex/<model>. Only the top-level `model` key is read,
# never anything else from config.toml (it may hold credentials).
codex_model_label() {
  local name
  if [[ "$1" == codex:* ]]; then
    printf 'codex/%s' "${1#codex:}"
    return
  fi
  name=$(awk '
    /^[[:space:]]*\[/ { exit }
    /^[[:space:]]*model[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*(#.*)?$/, "")
      print; exit
    }' "${CODEX_HOME:-$HOME/.codex}/config.toml" 2>/dev/null | tr -d "\"'")
  printf 'codex/%s' "${name:-default}"
}

# codex exec: read-only sandbox, no session file, final message to $3.
# Plain `codex` passes no -m so config.toml decides the model.
run_codex() { # candidate raw err last
  local model_args=()
  if [[ "$1" == codex:* ]]; then
    model_args=(-m "${1#codex:}")
  fi
  timeout -k 1m "$TIMEOUT" codex exec -s read-only --ephemeral \
    --skip-git-repo-check --color never -o "$4" ${model_args[@]+"${model_args[@]}"} \
    -- "$prompt" </dev/null >"$2" 2>"$3"
}

# pi knows the OpenCode Go plan under a different provider name.
pi_model() {
  case "$1" in
    opencode-go/*) printf 'oc-sdk-go/%s' "${1#opencode-go/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# OpenCode can exit 0 with empty output on a quota failure, so the logs are the
# only place that failure shows up. v1 writes one log per session, v2 appends to
# a single opencode.log — so callers compare the size before/after the run and
# only look at what was appended.
newest_log() {
  ls -t "${HOME}/.local/share/opencode/log"/*.log 2>/dev/null | head -n 1
}

log_size() {
  local f
  f=$(newest_log)
  if [[ -n "$f" && -f "$f" ]]; then
    wc -c <"$f" | tr -d ' '
  else
    printf '0'
  fi
}

run_candidate() { # engine model out err
  case "$1" in
    opencode2)
      # --standalone: private server per run (the background service keeps
      # state between runs) and the only mode where server logs reach stderr.
      timeout -k 1m "$TIMEOUT" opencode2 run --standalone --agent plan \
        --print-logs --log-level error -m "$2" "$prompt" </dev/null >"$3" 2>"$4"
      ;;
    opencode)
      timeout -k 1m "$TIMEOUT" opencode run --agent plan \
        --print-logs --log-level ERROR -m "$2" "$prompt" </dev/null >"$3" 2>"$4"
      ;;
    pi)
      timeout -k 1m "$TIMEOUT" pi -p --no-session --model "$(pi_model "$2")" \
        "$prompt" </dev/null >"$3" 2>"$4"
      ;;
  esac
}

tmpdir=$(mktemp -d) || { echo "ai-fallback: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmpdir"' EXIT

ei=0
SKIPPED=()

succeed() { # engine model-label
  printf 'AI_ENGINE=%s\n' "$1" >&2
  printf 'AI_MODEL=%s\n' "$2" >&2
  if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    printf 'AI_SKIPPED=%s\n' "$(printf '%s,' "${SKIPPED[@]}" | sed 's/,$//')" >&2
  fi
  exit 0
}

record_skip() { # model-label
  case " ${SKIPPED[*]-} " in
    *" $1 "*) ;;
    *) SKIPPED+=("$1") ;;
  esac
}

for model in $CHAIN; do
  case "$model" in
    codex | codex:*)
      label=$(codex_model_label "$model")
      if [[ $HAVE_CODEX -eq 0 ]]; then
        printf 'skip: %s on codex (not installed)\n' "$label" >&2
        record_skip "$label"
        continue
      fi
      raw="$tmpdir/codex.raw"
      err="$tmpdir/codex.err"
      last="$tmpdir/codex.last"
      : >"$raw"
      : >"$err"
      : >"$last"

      run_codex "$model" "$raw" "$err" "$last"
      rc=$?

      # Success is judged on the exit code and the final message only: the
      # transcript can mention "quota" (the prompt itself may), so it is
      # grepped only once the run has already failed.
      reason=""
      if [[ $rc -eq 124 || $rc -eq 137 ]]; then
        reason="timeout"
      elif [[ $rc -eq 0 && -s "$last" ]]; then
        cat "$last"
        # -o writes the message without a trailing newline.
        [[ -n "$(tail -c 1 "$last")" ]] && echo
        succeed codex "$label"
      elif cat "$err" "$raw" | grep -qiE '429|insufficient_quota|rate.?limit|quota|usage limit'; then
        reason="quota"
      elif cat "$err" "$raw" | grep -qiE '401|403|unauthorized|invalid credential|not logged in'; then
        reason="auth"
      elif [[ $rc -ne 0 ]]; then
        reason="exit ${rc}"
      else
        reason="empty output"
      fi

      printf 'skip: %s on codex (%s)\n' "$label" "$reason" >&2
      grep -m1 -iE 'error' "$err" | cut -c1-160 | sed 's/^/  ↳ /' >&2
      record_skip "$label"
      continue
      ;;
  esac

  if [[ ${#ENGINES[@]} -eq 0 ]]; then
    printf 'skip: %s on none (no engine)\n' "$model" >&2
    record_skip "$model"
    continue
  fi

  while :; do
    engine=${ENGINES[$ei]}
    out="$tmpdir/out"
    err="$tmpdir/err"
    : >"$out"
    : >"$err"
    offset=$(log_size)

    run_candidate "$engine" "$model" "$out" "$err"
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
      log=$(newest_log)
      if [[ -n "$log" ]] && tail -c "+$((offset + 1))" "$log" 2>/dev/null |
        grep -qiE '429|insufficient_quota|rate.?limit'; then
        reason="quota (log)"
      elif grep -qi 'ERROR' "$err"; then
        reason="error"
      else
        reason="empty output"
      fi
    fi

    if [[ -z "$reason" ]]; then
      cat "$out"
      succeed "$engine" "$model"
    fi

    printf 'skip: %s on %s (%s)\n' "$model" "$engine" "$reason" >&2
    if [[ "$reason" == "error" ]]; then
      grep -m1 -i 'ERROR' "$err" | cut -c1-160 | sed 's/^/  ↳ /' >&2
    fi

    if [[ "$reason" != quota* && $((ei + 1)) -lt ${#ENGINES[@]} ]]; then
      ei=$((ei + 1))
      echo "ai-fallback: ${engine} unusable (${reason}) - switching to ${ENGINES[$ei]}" >&2
      continue
    fi

    # Record the model only once every engine has given up on it.
    record_skip "$model"
    break
  done
done

echo "ai-fallback: every candidate failed (${CHAIN})" >&2
exit 1
