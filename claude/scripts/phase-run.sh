#!/bin/bash
# phase-run.sh — run one workflow phase through a chosen CLI + model.
#
# The phase definitions (startproject / team-implement / team-review / deploy)
# follow docs/phase-contract.md. This script is the only place that knows how to
# launch each CLI headless, so a phase can move from Claude to pi to OpenCode
# without touching the phase definition.
#
# stdout: the phase's final message (### RESULT + ### SECTION)
# stderr: one line per failed attempt, then PHASE= / RUNNER= / MODEL= / LABEL= / EXIT=
# exit:   0 = a runner completed the phase, 1 = every runner failed, 2 = usage error

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: phase-run.sh --phase={phase} --task-file={TASK_FILE} [options]

  --phase=            startproject | team-implement | team-review | deploy
  --task-file=        path to the TASK_FILE (required)
  --runner=SPEC       claude[:model] | opencode2[:model] | opencode[:model]
                      | pi[:model] | codex[:model] | cline[:model] | auto
                      auto = ~/.claude/scripts/ai-fallback.sh (model + engine chain)
  --phase-map=MAP     "startproject=claude:opus,team-review=pi:ollama-cloud/deepseek-v4.1-flash"
                      (per-phase assignment; --runner wins for a single run)
  --fallback=LIST     runners to try when the chosen one fails
                      (default: claude:opus,opencode2,pi:ollama-cloud/deepseek-v4.1-flash,auto)
  --description=TEXT  task description passed as the first part of $ARGUMENTS
  --tier= --linear-id= --answers-file=   passed through to the phase
  --candidate         add a candidate instead of overwriting (startproject only)
  --timeout=30m       per-attempt timeout (timeout -k 1m)
  --claude-tools=...  --allowedTools for claude
                      (default: Read,Write,Edit,Glob,Grep,Bash)
  --dry-run           print the commands instead of running them
EOF
}

die() {
  printf 'phase-run: %s\n' "$1" >&2
  exit 2
}

PHASES="startproject team-implement team-review deploy"

PHASE=""
TASK_FILE=""
RUNNER=""
PHASE_MAP=""
FALLBACK=""
DESCRIPTION=""
TIER=""
LINEAR_ID=""
ANSWERS=""
CANDIDATE=0
TIMEOUT="30m"
CLAUDE_TOOLS="Read,Write,Edit,Glob,Grep,Bash"
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --phase=*) PHASE=${arg#*=} ;;
    --task-file=*) TASK_FILE=${arg#*=} ;;
    --runner=*) RUNNER=${arg#*=} ;;
    --phase-map=*) PHASE_MAP=${arg#*=} ;;
    --fallback=*) FALLBACK=${arg#*=} ;;
    --description=*) DESCRIPTION=${arg#*=} ;;
    --tier=*) TIER=${arg#*=} ;;
    --linear-id=*) LINEAR_ID=${arg#*=} ;;
    --answers-file=*) ANSWERS=${arg#*=} ;;
    --candidate) CANDIDATE=1 ;;
    --timeout=*) TIMEOUT=${arg#*=} ;;
    --claude-tools=*) CLAUDE_TOOLS=${arg#*=} ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

[[ -n "$PHASE" ]] || die "--phase is required (${PHASES// /, })"
case " $PHASES " in
  *" $PHASE "*) ;;
  *) die "unknown phase: $PHASE (${PHASES// /, })" ;;
esac

[[ -n "$TASK_FILE" ]] || die "--task-file is required"
[[ -f "$TASK_FILE" ]] || die "task file not found: $TASK_FILE"
TASK_FILE=$(cd "$(dirname "$TASK_FILE")" && pwd)/$(basename "$TASK_FILE")

[[ -n "$FALLBACK" ]] ||
  FALLBACK="claude:opus,opencode2,pi:ollama-cloud/deepseek-v4.1-flash,auto"

# Phase definitions live in the harness checkout (agents/skills) — the same
# place orchestrate STEP 3P reads them from.
if [[ -z "${HARNESS:-}" ]]; then
  for candidate in "$HOME/src/harness" "$(cd "$(dirname "$0")/../.." && pwd)"; do
    if [[ -f "$candidate/agents/skills/$PHASE/SKILL.md" ]]; then
      HARNESS=$candidate
      break
    fi
  done
fi

if [[ -n "${HARNESS:-}" && -f "$HARNESS/agents/skills/$PHASE/SKILL.md" ]]; then
  SKILL="$HARNESS/agents/skills/$PHASE/SKILL.md"
elif [[ -f "$HOME/.agents/skills/$PHASE/SKILL.md" ]]; then
  SKILL="$HOME/.agents/skills/$PHASE/SKILL.md"
else
  die "phase definition not found: set HARNESS to the harness checkout (looked for agents/skills/$PHASE/SKILL.md)"
fi

REPO=$(git -C "$(dirname "$TASK_FILE")" rev-parse --show-toplevel 2>/dev/null ||
  git rev-parse --show-toplevel 2>/dev/null || true)
[[ -n "$REPO" ]] || die "not inside a git repository: $TASK_FILE"

map_runner() {
  local entry
  local -a entries=()
  [[ -n "$PHASE_MAP" ]] || return 0
  IFS=',' read -ra entries <<<"$PHASE_MAP"
  for entry in "${entries[@]}"; do
    case "$entry" in
      "$PHASE="*) printf '%s' "${entry#*=}"; return 0 ;;
    esac
  done
}

spec_cli() { printf '%s' "${1%%:*}"; }
spec_model() { [[ "$1" == *:* ]] && printf '%s' "${1#*:}"; return 0; }

spec_label() {
  local model
  model=$(spec_model "$1")
  if [[ -n "$model" ]]; then
    printf '%s/%s' "$(spec_cli "$1")" "$model"
  else
    printf '%s' "$(spec_cli "$1")"
  fi
}

build_prompt() { # label
  local args=""
  [[ -n "$DESCRIPTION" ]] && args+="$DESCRIPTION "
  args+="--task-file=$TASK_FILE"
  [[ -n "$TIER" ]] && args+=" --tier=$TIER"
  [[ -n "$LINEAR_ID" ]] && args+=" --linear-id=$LINEAR_ID"
  [[ -n "$ANSWERS" ]] && args+=" --answers-file=$ANSWERS"
  ((CANDIDATE)) && args+=" --candidate"
  [[ -n "$1" ]] && args+=" --label=$1"
  cat <<EOF
Read $SKILL and follow it.

Working directory: $REPO
Task file: $TASK_FILE (relative paths are resolved from $REPO)

\$ARGUMENTS: "$args"
EOF
}

build_cmd() { # spec prompt tmpdir -> fills global CMD
  local spec=$1 prompt=$2 tmp=$3
  local cli model
  cli=$(spec_cli "$spec")
  model=$(spec_model "$spec")
  CMD=()
  case "$cli" in
    claude)
      # --allowedTools is variadic: the "=" form keeps the prompt from being
      # swallowed as another tool name.
      CMD=(claude -p --model "${model:-opus}" --permission-mode acceptEdits
        "--allowedTools=$CLAUDE_TOOLS" "$prompt")
      ;;
    opencode2)
      CMD=(opencode2 run --standalone --agent build --auto)
      [[ -n "$model" ]] && CMD+=(-m "$model")
      CMD+=("$prompt")
      ;;
    opencode)
      CMD=(opencode run --agent build --dangerously-skip-permissions)
      [[ -n "$model" ]] && CMD+=(-m "$model")
      CMD+=("$prompt")
      ;;
    pi)
      CMD=(pi -p --no-session)
      [[ -n "$model" ]] && CMD+=(--model "$model")
      CMD+=("$prompt")
      ;;
    codex)
      CMD=(codex exec -s workspace-write
        -c "sandbox_workspace_write.writable_roots=[\"$REPO/.git\"]"
        -o "$tmp/last.md")
      [[ -n "$model" ]] && CMD+=(-m "$model")
      CMD+=("$prompt")
      ;;
    cline)
      CMD=(cline --json --auto-approve true -t 1800)
      [[ -n "$model" ]] && CMD+=(-m "$model")
      CMD+=("$prompt")
      ;;
    auto)
      printf '%s' "$prompt" >"$tmp/prompt.txt"
      CMD=("${HOME}/.claude/scripts/ai-fallback.sh" "$tmp/prompt.txt")
      ;;
    *) return 1 ;;
  esac
}

tmpdir=$(mktemp -d) || { echo "phase-run: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$tmpdir"' EXIT

# Attempt order: the chosen runner (or this phase's map entry) first, then the
# fallback chain, without duplicates.
primary=${RUNNER:-$(map_runner)}
[[ -n "$primary" ]] || primary=${FALLBACK%%,*}
attempts=("$primary")
IFS=',' read -ra chain <<<"$FALLBACK"
for spec in "${chain[@]}"; do
  [[ -n "$spec" ]] || continue
  duplicate=0
  for existing in "${attempts[@]}"; do
    if [[ "$existing" == "$spec" ]]; then
      duplicate=1
      break
    fi
  done
  ((duplicate == 0)) && attempts+=("$spec")
done

if ((DRY_RUN)); then
  printf '# phase=%s skill=%s repo=%s\n' "$PHASE" "$SKILL" "$REPO"
  for spec in "${attempts[@]}"; do
    label=$(spec_label "$spec")
    prompt=$(build_prompt "$label")
    if ! build_cmd "$spec" "$prompt" "$tmpdir"; then
      printf '# unknown runner: %s\n' "$spec"
      continue
    fi
    printf 'cd %q &&' "$REPO"
    printf ' %q' "${CMD[@]}"
    printf '\n'
  done
  exit 0
fi

last_index=$((${#attempts[@]} - 1))
for i in "${!attempts[@]}"; do
  spec=${attempts[i]}
  label=$(spec_label "$spec")
  prompt=$(build_prompt "$label")
  if ! build_cmd "$spec" "$prompt" "$tmpdir"; then
    printf 'phase-run: unknown runner: %s\n' "$spec" >&2
    continue
  fi

  out="$tmpdir/out"
  err="$tmpdir/err"
  : >"$out"
  : >"$err"
  (cd "$REPO" && timeout -k 1m "$TIMEOUT" "${CMD[@]}" </dev/null >"$out" 2>"$err")
  rc=$?

  if [[ $rc -eq 0 && -s "$out" ]]; then
    used_model=$(spec_model "$spec")
    if [[ "$(spec_cli "$spec")" == "auto" ]]; then
      used_model=$(grep -m1 '^AI_MODEL=' "$err" | cut -d= -f2-)
      [[ -n "$used_model" ]] && label="auto/${used_model}"
    fi
    cat "$out"
    printf 'PHASE=%s\n' "$PHASE" >&2
    printf 'RUNNER=%s\n' "$(spec_cli "$spec")" >&2
    printf 'MODEL=%s\n' "${used_model:-default}" >&2
    printf 'LABEL=%s\n' "$label" >&2
    printf 'EXIT=0\n' >&2
    exit 0
  fi

  reason="exit ${rc}"
  [[ $rc -eq 124 || $rc -eq 137 ]] && reason="timeout"
  [[ $rc -eq 0 && ! -s "$out" ]] && reason="empty output"
  printf 'phase-run: %s failed (%s)\n' "$spec" "$reason" >&2
  grep -m1 -iE 'error|quota|unauthor|invalid' "$err" | cut -c1-160 | sed 's/^/  ↳ /' >&2
  if ((i < last_index)); then
    printf 'phase-run: trying %s\n' "${attempts[i + 1]}" >&2
  fi
done

printf 'PHASE=%s\n' "$PHASE" >&2
printf 'EXIT=1\n' >&2
printf 'phase-run: every runner failed for phase %s\n' "$PHASE" >&2
exit 1
