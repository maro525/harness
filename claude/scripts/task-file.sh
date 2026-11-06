#!/bin/bash
# task-file.sh — resolve where a TASK_FILE lives.
#
# TASK_FILEs are NOT stored in the repository. They live under
#
#   ${HARNESS_TASKS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/harness/tasks}/<repo>/
#
# where <repo> is the main repository, i.e. the basename of the git common dir.
# Every worktree of a repository therefore shares one bucket: a task written
# from `nanco-next-cut` is found again from `nanco-next`.
#
# Files that still live in a repository (`<repo>/.claude/docs/decisions/`) keep
# working: `find` and `resolve` look there too, newest sources first.
#
# Usage:
#   task-file.sh dir     [--repo=DIR]                     bucket directory (created)
#   task-file.sh new     [--repo=DIR] --feature=SLUG [--linear-id=ID] [--branch=BR]
#   task-file.sh find    [--repo=DIR] [--linear-id=ID]
#   task-file.sh resolve <path-or-name> [--repo=DIR]
#   task-file.sh legacy  [--repo=DIR]                     in-repo dir, if any
#   task-file.sh root                                     the tasks root
#
# Options:
#   --repo=DIR      repository (or worktree) to resolve against (default: $PWD)
#   --linear-id=ID  Linear issue id; omitted = NOLINEAR
#   --feature=SLUG  short feature name used in the file name (required by `new`)
#   --branch=BR     current branch, used to avoid clobbering a same-named task
#   -h, --help      this help
#
# exit: 0 = ok, 1 = nothing found (find/resolve), 2 = usage error

set -uo pipefail

TASKS_ROOT="${HARNESS_TASKS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/harness/tasks}"

die() {
  printf 'task-file: %s\n' "$1" >&2
  exit 2
}

usage() {
  cat <<'EOF'
Usage: task-file.sh <command> [options]

  dir      [--repo=DIR]                  bucket directory for the repo (created)
  new      --feature=SLUG [--repo=DIR] [--linear-id=ID] [--branch=BR]
                                         path for a new TASK_FILE (not created)
  find     [--repo=DIR] [--linear-id=ID] existing TASK_FILEs (bucket, then legacy)
  resolve  <path-or-name> [--repo=DIR]   absolute path of an existing TASK_FILE
  legacy   [--repo=DIR]                  <repo>/.claude/docs/decisions, if any
  root                                   the tasks root

Options:
  --repo=DIR      repository (or worktree) to resolve against (default: $PWD)
  --linear-id=ID  Linear issue id (default: NOLINEAR)
  --feature=SLUG  short feature name used in the file name
  --branch=BR     current branch (same issue in two worktrees)
  -h, --help      this help

TASK_FILEs live in ${HARNESS_TASKS_DIR:-~/.local/share/harness/tasks}/<repo>/,
where <repo> is the main repository (git common dir), shared by all worktrees.

Exit: 0 = ok, 1 = nothing found (find/resolve/legacy), 2 = usage error.
EOF
}

CMD=""
ARG=""
REPO_ARG=""
FEATURE=""
LINEAR_ID=""
BRANCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo=*) REPO_ARG=${1#*=} ;;
    --feature=*) FEATURE=${1#*=} ;;
    --linear-id=*) LINEAR_ID=${1#*=} ;;
    --branch=*) BRANCH=${1#*=} ;;
    -h|--help) usage; exit 0 ;;
    --*) die "unknown option: $1" ;;
    *)
      if [[ -z "$CMD" ]]; then
        CMD=$1
      elif [[ -z "$ARG" ]]; then
        ARG=$1
      else
        die "unexpected argument: $1"
      fi
      ;;
  esac
  shift
done

[[ -n "$CMD" ]] || { usage >&2; exit 2; }

# ─── repository identity ─────────────────────────────────────────────────────

repo_dir() {
  local dir=${REPO_ARG:-$PWD}
  [[ -d "$dir" ]] || die "not a directory: $dir"
  git -C "$dir" rev-parse --show-toplevel 2>/dev/null ||
    die "not inside a git repository: $dir"
}

# Absolute git common dir: the same path for a clone and all its worktrees.
common_dir() {
  local dir=$1 common
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
    common=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) ||
    return 1
  case "$common" in
    /*) ;;
    *) common=$(cd "$dir" && cd "$common" && pwd) || return 1 ;;
  esac
  printf '%s' "$common"
}

# Bucket name for the repository: "nanco-next" for /src/nanco-next/.git.
repo_key() {
  local common base parent
  common=$(common_dir "$1") || die "cannot resolve the git common dir: $1"
  base=$(basename "$common")
  if [[ "$base" == ".git" ]]; then
    parent=$(dirname "$common")
    base=$(basename "$parent")
  elif [[ "$base" == *.git ]]; then
    base=${base%.git}
  fi
  printf '%s' "$base" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/-/g'
}

# <bucket>, with a hash suffix only when a different repository already holds
# the same directory name. `.origin` records which repository owns the bucket.
bucket_dir() {
  local common key bucket origin
  common=$(common_dir "$1") || die "cannot resolve the git common dir: $1"
  key=$(repo_key "$1")
  bucket="$TASKS_ROOT/$key"
  mkdir -p "$TASKS_ROOT"
  if [[ -f "$bucket/.origin" ]]; then
    origin=$(cat "$bucket/.origin" 2>/dev/null || true)
    if [[ "$origin" != "$common" ]]; then
      bucket="$TASKS_ROOT/$key-$(printf '%s' "$common" | cksum | cut -d' ' -f1)"
    fi
  fi
  mkdir -p "$bucket"
  printf '%s' "$common" >"$bucket/.origin"
  printf '%s' "$bucket"
}

legacy_dir() { printf '%s/.claude/docs/decisions' "$1"; }

slug() {
  printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

# ─── subcommands ────────────────────────────────────────────────────────────

cmd_root() { printf '%s' "$TASKS_ROOT"; }

cmd_dir() {
  local repo
  repo=$(repo_dir)
  bucket_dir "$repo"
}

cmd_legacy() {
  local repo legacy
  repo=$(repo_dir)
  legacy=$(legacy_dir "$repo")
  [[ -d "$legacy" ]] || exit 1
  printf '%s' "$legacy"
}

cmd_new() {
  local repo bucket path suffix n id feature
  repo=$(repo_dir)
  bucket=$(bucket_dir "$repo")
  [[ -n "$FEATURE" ]] || die "--feature is required for new"
  feature=$(slug "$FEATURE")
  [[ -n "$feature" ]] || die "--feature is empty after slugging"
  id=${LINEAR_ID:-NOLINEAR}
  path="$bucket/task-$id-$feature.md"

  if [[ ! -e "$path" ]]; then
    printf '%s\n' "$path"
    return 0
  fi

  # The same task is already recorded: continue that file when it is the same
  # branch, otherwise keep both (two worktrees on one issue).
  if [[ -n "$BRANCH" ]] && grep -qE "^- branch: *$BRANCH *$" "$path" 2>/dev/null; then
    printf '%s\n' "$path"
    return 0
  fi
  if [[ -n "$BRANCH" ]]; then
    suffix=$(slug "$BRANCH")
    if [[ -n "$suffix" && ! -e "$bucket/task-$id-$feature-$suffix.md" ]]; then
      printf '%s\n' "$bucket/task-$id-$feature-$suffix.md"
      return 0
    fi
    path="$bucket/task-$id-$feature-$suffix"
  else
    path="$bucket/task-$id-$feature"
  fi
  n=2
  while [[ -e "$path-$n.md" ]]; do n=$((n + 1)); done
  printf '%s\n' "$path-$n.md"
}

cmd_find() {
  local repo bucket legacy pattern found=0 f
  repo=$(repo_dir)
  bucket=$(bucket_dir "$repo")
  legacy=$(legacy_dir "$repo")
  if [[ -n "$LINEAR_ID" ]]; then
    pattern="task-$LINEAR_ID-*.md"
  else
    pattern="task-*.md"
  fi
  for f in "$bucket"/$pattern; do
    [[ -f "$f" ]] || continue
    printf '%s\n' "$f"
    found=1
  done
  for f in "$legacy"/$pattern; do
    [[ -f "$f" ]] || continue
    printf '%s\n' "$f"
    found=1
  done
  ((found)) || exit 1
}

cmd_resolve() {
  local repo target bucket legacy
  [[ -n "$ARG" ]] || die "resolve needs a path or file name"
  repo=$(repo_dir)
  bucket=$(bucket_dir "$repo")
  legacy=$(legacy_dir "$repo")
  target=$ARG
  if [[ -f "$target" ]]; then
    (cd "$(dirname "$target")" && printf '%s/%s\n' "$(pwd)" "$(basename "$target")")
    return 0
  fi
  # A bare name: look in the bucket first, then in the legacy location.
  local d
  for d in "$bucket" "$legacy"; do
    if [[ -f "$d/$target" ]]; then
      printf '%s\n' "$d/$target"
      return 0
    fi
  done
  exit 1
}

case "$CMD" in
  root) cmd_root ;;
  dir) cmd_dir ;;
  legacy) cmd_legacy ;;
  new) cmd_new ;;
  find) cmd_find ;;
  resolve) cmd_resolve ;;
  *) usage >&2; exit 2 ;;
esac
