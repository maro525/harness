#!/bin/bash
# orchestrate-parallel.sh — start one orchestrate run per task and return at once.
#
# Each task gets its own git worktree and Herdr tab, so the runs cannot fight
# over the same branch. Three conditions come from
# agents/skills/orchestrate/SKILL.md「並列で回す」:
#
#   1. one task per run — the task lock is keyed on repo + LINEAR_ID, so two runs
#      for the same issue would block each other anyway
#   2. one worktree per run — orchestrate switches branches, commits, pushes and
#      opens a PR; two runs in one working tree would corrupt git state, and the
#      lock would NOT catch it (it is keyed per issue, not per working tree)
#   3. `herdr-agent.sh ask`, not `delegate` — delegate appends the boss protocol,
#      which forbids the phase runner, consult and subagents that orchestrate
#      needs; ask sends the same request without the protocol
#
# Usage:
#   orchestrate-parallel.sh [OPTIONS] TASK...
#
# TASK forms:
#   PROJ-573            Linear id; feature slug = lower-cased id
#   PROJ-573:coupon     Linear id + feature slug
#   :quick-fix          no issue (NOLINEAR); feature slug only
#   path/to/task-*.md   existing TASK_FILE (id and feature from its name)
#
# Options:
#   --repo DIR      repository (default: $PWD)
#   --base REF      base for the branches (default: origin/HEAD, else origin/main)
#   --prefix STR    branch prefix (default: feature/)
#   --kind KIND     agent kind for the session: claude (default) | codex | pi
#   --model MODEL   claude: --model (default: sonnet)
#   --runner NAME   runner recorded in the lock and Linear (default: <kind>)
#   --ensure-only   create the worktrees and tabs, do not send the request
#   --dry-run       print the plan and do nothing
#   -h, --help      this help
#
# exit: 0 = all sessions started, 1 = at least one failed, 2 = usage error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HERDR_AGENT="$SCRIPT_DIR/herdr-agent.sh"
TASK_FILE_SH="$SCRIPT_DIR/task-file.sh"

die() {
  printf 'orchestrate-parallel: %s\n' "$1" >&2
  exit "${2:-2}"
}

usage() {
  cat <<'EOF'
Usage: orchestrate-parallel.sh [OPTIONS] TASK...

  One orchestrate run per task, each in its own git worktree and Herdr tab.

TASK forms:
  PROJ-573            Linear id; feature slug = lower-cased id
  PROJ-573:coupon     Linear id + feature slug
  :quick-fix          no issue (NOLINEAR); feature slug only
  path/to/task-*.md   existing TASK_FILE (id and feature from its name)

Options:
  --repo DIR      repository (default: $PWD)
  --base REF      base for the branches (default: origin/HEAD, else origin/main)
  --prefix STR    branch prefix (default: feature/)
  --kind KIND     agent kind: claude (default) | codex | pi
  --model MODEL   claude: --model (default: sonnet)
  --runner NAME   runner recorded in the lock and Linear (default: <kind>)
  --ensure-only   create the worktrees and tabs, do not send the request
  --dry-run       print the plan and do nothing
  -h, --help      this help
EOF
  exit 0
}

REPO=$PWD
BASE=""
PREFIX="feature/"
KIND=claude
MODEL=sonnet
RUNNER=""
DRY_RUN=0
ENSURE_ONLY=0
TASKS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)        REPO=$2; shift 2 ;;
    --base)        BASE=$2; shift 2 ;;
    --prefix)      PREFIX=$2; shift 2 ;;
    --kind)        KIND=$2; shift 2 ;;
    --model)       MODEL=$2; shift 2 ;;
    --runner)      RUNNER=$2; shift 2 ;;
    --ensure-only) ENSURE_ONLY=1; shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    -h|--help)     usage ;;
    -*)            die "unknown option: $1" ;;
    *)             TASKS+=("$1"); shift ;;
  esac
done

[[ ${#TASKS[@]} -gt 0 ]] || die "no tasks given"
[[ -x "$HERDR_AGENT" ]] || die "herdr-agent.sh not found next to this script"

case "$KIND" in
  claude|codex|pi) ;;
  *) die "--kind must be claude, codex or pi" ;;
esac
RUNNER=${RUNNER:-$KIND}

repo=$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null) ||
  die "not a git repository: $REPO"
if [[ -z "$BASE" ]]; then
  BASE=$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  BASE=${BASE:-origin/main}
fi

slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' |
    LC_ALL=C sed 's/[^a-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

# Session flags for the child: it runs the phase CLI, git and the lock itself,
# so it needs its worktree writable and no approval dialogs.
native_args() {
  case "$KIND" in
    claude) printf '%s\0' --permission-mode auto --model "$MODEL" ;;
    codex)  printf '%s\0' -s workspace-write -a never --no-alt-screen ;;
    pi)     : ;;
  esac
}

# Session name (docs/naming.md): `orchestrate-<id>[-<feature>]`, kept inside
# Herdr's 32-char limit. The feature is dropped before anything is truncated, and a
# truncation only ever cuts a whole trailing word.
session_name() { # id-lower [feature]
  local cand="orchestrate-$1"
  if [[ -n "${2:-}" ]] && (( ${#cand} + ${#2} + 1 <= 32 )); then
    cand="$cand-$2"
  fi
  if (( ${#cand} > 32 )); then
    cand=${cand:0:32}
    cand=$(printf '%s' "$cand" | sed 's/-[^-]*$//')
  fi
  printf '%s' "$cand"
}

# TASK -> ID / FEATURE / NAME / BRANCH
parse_task() { # task
  local task=$1 id feature
  if [[ "$task" == *.md ]]; then
    [[ -f "$task" ]] || die "TASK_FILE not found: $task"
    local base_name
    base_name=$(basename "$task" .md)
    base_name=${base_name#task-}
    id=${base_name%%-*}
    feature=${base_name#*-}
    if [[ "$id" == "$base_name" ]]; then feature=$id; fi
    if [[ "$id" == "NOLINEAR" ]]; then id=""; fi
  elif [[ "$task" == *:* ]]; then
    id=${task%%:*}
    feature=${task#*:}
  else
    id=$task
    feature=$task
  fi
  [[ -n "$feature" ]] || die "empty feature for task: $task"
  ID=${id^^}
  FEATURE=$(slug "$feature")
  [[ -n "$FEATURE" ]] || die "feature is empty after slugging: $task"
  if [[ -n "$ID" ]]; then
    NAME=$(session_name "$(slug "$ID")" "$FEATURE")
    BRANCH="${PREFIX}$(slug "$ID")-$FEATURE"
  else
    ID="NOLINEAR"
    NAME=$(session_name "noissue-$FEATURE")
    BRANCH="${PREFIX}${FEATURE}"
  fi
}

started=()
failed=0
seen=""

for task in "${TASKS[@]}"; do
  parse_task "$task"

  case " $seen " in
    *" $ID "*)
      [[ "$ID" == "NOLINEAR" ]] || die "duplicate Linear id in one run: $ID (one run per issue)"
      ;;
  esac
  seen="$seen $ID"

  # A live lease means another orchestrate already owns this issue.
  if [[ "$ID" != "NOLINEAR" && -x "$TASK_FILE_SH" ]] &&
     "$TASK_FILE_SH" lock show --repo="$repo" --linear-id="$ID" >/dev/null 2>&1; then
    printf 'warn: %s already has a task lock — that run will stop at acquire\n' "$ID" >&2
  fi

  echo "== $ID ($FEATURE)"
  echo "   session:  $NAME"
  echo "   branch:   $BRANCH (from $BASE)"
  echo "   worktree: (herdr worktree)"

  if [[ $DRY_RUN -eq 1 ]]; then
    started+=("$NAME|dry-run|$BRANCH")
    continue
  fi

  mapfile -d '' -t args < <(native_args)
  if ! "$HERDR_AGENT" ensure "$NAME" --kind "$KIND" --repo "$repo" \
        --topology worktree --branch "$BRANCH" --base "$BASE" -- "${args[@]}"; then
    printf 'error: could not start %s\n' "$NAME" >&2
    failed=1
    continue
  fi

  if [[ $ENSURE_ONLY -eq 0 ]]; then
    prompt=$(cat <<EOF
orchestrate スキル（~/.agents/skills/orchestrate/SKILL.md）で、このタスクを最後まで回してください。

- Linear: $ID
- feature（TASK_FILE の名前に使う）: $FEATURE
- runner: $RUNNER
- このセッションはすでに $BRANCH の worktree で起動しています（ブランチを切り替えない）
- 実行ロック: STEP 2 で \`task-file.sh lock acquire --linear-id=$ID --feature=$FEATURE --runner=$RUNNER\`、
  各 STEP で refresh、STEP 7 または中止時に release
- Linear はあなたが書く（コメント / ステータス / description。フェーズは触らない）
- 終わったら、この pane に最終報告（やったこと / PR の URL / 残っているもの）を出して終了
EOF
)
    if ! printf '%s\n' "$prompt" | "$HERDR_AGENT" ask "$NAME" - --no-wait; then
      printf 'error: could not send the request to %s\n' "$NAME" >&2
      failed=1
      continue
    fi
  fi

  started+=("$NAME|started|$BRANCH")
done

echo ""
if [[ ${#started[@]} -gt 0 ]]; then
  printf '%-28s %-10s %s\n' SESSION STATE BRANCH
  for row in "${started[@]}"; do
    IFS='|' read -r name state branch <<<"$row"
    printf '%-28s %-10s %s\n' "$name" "$state" "$branch"
  done
fi

if [[ $DRY_RUN -eq 0 && ${#started[@]} -gt 0 ]]; then
  echo ""
  echo "Follow:  $HERDR_AGENT read {session} --lines 60"
  echo "Status:  $HERDR_AGENT list"
  echo "Cleanup: $HERDR_AGENT close {session}   (or: $HERDR_AGENT reap)"
fi

echo ""
[[ $failed -eq 0 ]] && echo "Done." || echo "Done with failures (see above)." >&2
exit "$failed"
