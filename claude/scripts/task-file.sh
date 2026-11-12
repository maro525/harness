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
#   task-file.sh lock    <acquire|refresh|release|show> [--repo=DIR]
#                        [--linear-id=ID] [--feature=SLUG] [--runner=NAME]
#                        [--ttl=45m] [--takeover] [--task-file=PATH]
#   task-file.sh legacy  [--repo=DIR]                     in-repo dir, if any
#   task-file.sh root                                     the tasks root
#
# Options:
#   --repo=DIR      repository (or worktree) to resolve against (default: $PWD)
#   --linear-id=ID  Linear issue id; omitted = NOLINEAR
#   --feature=SLUG  short feature name used in the file name (required by `new`)
#   --branch=BR     current branch, used to avoid clobbering a same-named task
#   --runner=NAME   who holds the lock (claude / cursor / pi ...)
#   --ttl=45m       lease lifetime; older leases may be taken over (lock)
#   --takeover      steal a lease that is still fresh (lock)
#   --task-file=P  TASK_FILE to record in the lease (lock)
#   -h, --help      this help
#
# `lock` exists because the TASK_FILE alone cannot stop two orchestrators from
# starting the same issue: `new` keeps one file per branch, so a Claude run and
# a Cursor run on different branches never see each other. The lease is keyed on
# the repository + Linear id (feature slug when there is no issue), lives outside
# the repository, and is refreshed as the runner works.
#
# exit: 0 = ok, 1 = nothing found (find/resolve), 2 = usage error

set -uo pipefail

TASKS_ROOT="${HARNESS_TASKS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/harness/tasks}"
LOCKS_ROOT="${HARNESS_LOCKS_DIR:-$(dirname "$TASKS_ROOT")/locks}"

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
  lock     acquire|refresh|release|show   one runner per task (lease file)
                                         [--runner=NAME] [--ttl=45m] [--takeover]
  legacy   [--repo=DIR]                  <repo>/.claude/docs/decisions, if any
  root                                   the tasks root

Options:
  --repo=DIR      repository (or worktree) to resolve against (default: $PWD)
  --linear-id=ID  Linear issue id (default: NOLINEAR)
  --feature=SLUG  short feature name used in the file name
  --branch=BR     current branch (same issue in two worktrees)
  --runner=NAME   who holds the lock (claude / cursor / pi ...)
  --ttl=45m       lock: lease lifetime (45m / 90s / 2h); older leases may be taken
  --takeover      lock: steal a lease that is still fresh
  --task-file=P   lock: TASK_FILE recorded in the lease
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
RUNNER=""
TTL="45m"
TAKEOVER=0
LOCK_TASK_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo=*) REPO_ARG=${1#*=} ;;
    --feature=*) FEATURE=${1#*=} ;;
    --linear-id=*) LINEAR_ID=${1#*=} ;;
    --branch=*) BRANCH=${1#*=} ;;
    --runner=*) RUNNER=${1#*=} ;;
    --ttl=*) TTL=${1#*=} ;;
    --task-file=*) LOCK_TASK_FILE=${1#*=} ;;
    --takeover) TAKEOVER=1 ;;
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

# ─── task lock (one task, one runner) ─────────────────────────────────
#
# A lease, not a held fd: an orchestrator is a series of separate commands, not
# one long-lived process, so there is nothing to keep open. The runner refreshes
# `updated_epoch` as it works; a lease older than --ttl may be taken over by the
# next acquire (with a warning), a fresh one needs --takeover.

lock_seconds() { # 45m / 90s / 2h / 600
  local t=$1 mult=1 num
  case "$t" in
    *m) mult=60; num=${t%m} ;;
    *s) num=${t%s} ;;
    *h) mult=3600; num=${t%h} ;;
    *) num=$t ;;
  esac
  [[ "$num" =~ ^[0-9]+$ ]] || die "invalid --ttl: $1"
  (( num > 0 )) || die "invalid --ttl: $1"
  printf '%s' $((num * mult))
}

# Repository + Linear id (the identity that two orchestrators share), falling
# back to the feature slug, then to the repository alone.
lock_key() {
  local repo key slugged
  repo=$(repo_dir)
  key=$(repo_key "$repo")
  if [[ -n "$LINEAR_ID" && "$LINEAR_ID" != "NOLINEAR" ]]; then
    printf '%s-%s' "$key" "$LINEAR_ID"
    return 0
  fi
  slugged=$(slug "${FEATURE:-}")
  if [[ -n "$slugged" ]]; then
    printf '%s-task-%s' "$key" "$slugged"
  else
    printf '%s-repo' "$key"
  fi
}

lease_field() { # file key
  [[ -f "$1" ]] || return 0
  sed -n "s/^$2=//p" "$1" | head -1
}

cmd_lock() {
  local action=${ARG:-} key path now holder age ttl_s runner tmp upd held_ttl
  case "$action" in
    acquire|refresh|release|show) ;;
    *) die "lock needs acquire|refresh|release|show" ;;
  esac

  key=$(lock_key)
  path="$LOCKS_ROOT/$key.lock"
  runner=${RUNNER:-unknown}
  now=$(date +%s)

  if [[ "$action" == "show" ]]; then
    [[ -f "$path" ]] || { printf 'task-file: no lock: %s\n' "$path" >&2; exit 1; }
    printf '%s\n' "$path"
    cat "$path"
    return 0
  fi

  mkdir -p "$LOCKS_ROOT"

  # The read-modify-write runs under a guard file so two acquires cannot both
  # win. The guard is only for this critical section; the lease is the state.
  (
    flock -w 10 9 || die "another lock operation is stuck on $path"

    if [[ "$action" == "acquire" ]]; then
      ttl_s=$(lock_seconds "$TTL")
      if [[ -f "$path" ]]; then
        holder=$(lease_field "$path" runner)
        upd=$(lease_field "$path" updated_epoch)
        upd=${upd:-0}
        age=$(( now - upd ))
        # The holder's own TTL decides when its lease goes stale, not the TTL of
        # the runner that arrives later.
        held_ttl=$(lease_field "$path" ttl)
        [[ -n "$held_ttl" ]] && ttl_s=$(lock_seconds "$held_ttl")
        if [[ $TAKEOVER -eq 1 ]]; then
          printf 'task-file: taking over the lock held by %s\n' "${holder:-?}" >&2
        elif (( age > ttl_s )); then
          printf 'task-file: stale lease of %s (%ss > ttl %ss), taking it over\n' \
            "${holder:-?}" "$age" "$ttl_s" >&2
        else
          printf 'task-file: %s is already running this task (updated %ss ago, ttl %ss)\n' \
            "${holder:-?}" "$age" "$ttl_s" >&2
          sed 's/^/  /' "$path" >&2
          exit 1
        fi
      fi
      {
        printf 'key=%s\n' "$key"
        printf 'runner=%s\n' "$runner"
        printf 'pid=%s\n' "$$"
        printf 'cwd=%s\n' "$PWD"
        printf 'task_file=%s\n' "$LOCK_TASK_FILE"
        printf 'started=%s\n' "$(date -Iseconds)"
        printf 'updated_epoch=%s\n' "$now"
        printf 'ttl=%s\n' "$TTL"
      } >"$path"
      printf '%s\n' "$path"
      exit 0
    fi

    if [[ "$action" == "refresh" ]]; then
      [[ -f "$path" ]] || die "no lock to refresh: $path (acquire first)"
      holder=$(lease_field "$path" runner)
      if [[ "$holder" != "$runner" && $TAKEOVER -ne 1 ]]; then
        die "the lock is held by ${holder:-?}, not $runner (use --takeover)"
      fi
      tmp="$path.tmp.$$"
      { grep -v '^updated_epoch=' "$path"; printf 'updated_epoch=%s\n' "$now"; } >"$tmp" &&
        mv "$tmp" "$path"
      printf '%s\n' "$path"
      exit 0
    fi

    # release
    if [[ ! -f "$path" ]]; then
      printf 'task-file: no lock to release: %s\n' "$path" >&2
      exit 0
    fi
    holder=$(lease_field "$path" runner)
    if [[ "$holder" != "$runner" && $TAKEOVER -ne 1 ]]; then
      die "the lock is held by ${holder:-?}, not $runner (use --takeover)"
    fi
    rm -f "$path"
    printf 'released %s\n' "$path"
  ) 9>"$path.guard"
}

case "$CMD" in
  root) cmd_root ;;
  dir) cmd_dir ;;
  legacy) cmd_legacy ;;
  new) cmd_new ;;
  find) cmd_find ;;
  resolve) cmd_resolve ;;
  lock) cmd_lock ;;
  *) usage >&2; exit 2 ;;
esac
