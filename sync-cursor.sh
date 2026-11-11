#!/bin/bash
# Distribute ~/.agents/skills into the skill directories Cursor reads.
#
#   ~/.agents/skills/<name>/  --copy-->  {profile}/.cursor/skills/<name>/
#                                        {profile}/.claude/skills/<name>/  (Windows only)
#
# Cursor reads user-level skills from ~/.cursor/skills and ~/.claude/skills
# (project-level ones from <repo>/.cursor/skills); it does NOT read
# ~/.agents/skills. Its own bundled skills sit in ~/.cursor/skills-cursor with a
# .sync-manifest.json and are never touched here.
#
# Unlike Cline, which is served with a symlink by sync-agents.sh, Cursor needs
# real copies: a symlink created from WSL on /mnt/c is a WSL-only reparse point
# that the Windows build of Cursor cannot resolve. For the same reason the
# Windows profile is preferred when a WSL/Windows mount is reachable, and
# $HOME/.cursor/skills (WSL-side Cursor) is the fallback.
#
# This is the one sync script that is NOT a HOME <-> repo sync: it is a one-way
# mirror of the skills this script owns. Every run re-copies the trees and prunes
# the skill directories that disappeared from ~/.agents/skills; what was
# distributed is recorded in <dest>/.harness-managed. A name that also exists in
# Cursor's bundled skills-cursor/ is reported as a collision, and which side
# Cursor picks is not documented.
#
# The Windows profile gets both directories because a Cursor session was seen
# listing only ~/.cursor/skills-cursor and ~/.claude/skills. On the WSL side
# ~/.claude/skills is NOT filled: it belongs to the dotfiles repo, whose
# sync-claude.sh walks that directory per skill.
#
# ~/.agents/skills is also managed by `npx skills` (.skill-lock.json), so only
# directories are copied (never the lock file) and --exclude narrows the set
# (--exclude-cloudflare drops the vendor bundle, see
# SYNC_COMMON_CLOUDFLARE_SKILLS in lib/sync-common.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$HOME/.agents/skills"
MANIFEST_NAME=".harness-managed"

# shellcheck source=lib/sync-common.sh
source "$SCRIPT_DIR/lib/sync-common.sh"

DRY_RUN=0
PRUNE=1
EXCLUDES=()
DEST_ARGS=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Copy ~/.agents/skills into the skill directories Cursor reads. Default dests:
the first Cursor profile under /mnt/c/Users/* ({profile}/.cursor/skills and
{profile}/.claude/skills), else \$HOME/.cursor/skills.

Options:
      --dest DIR           Copy into DIR instead of the detected defaults
                           (repeatable; skips the second default directory)
      --exclude NAME       Skip skill NAME (repeatable)
      --exclude-cloudflare Skip the Cloudflare plugin bundle (vendor docs)
      --no-prune           Keep copies of skills that left ~/.agents/skills
      --dry-run            Show what would change, write nothing
  -h, --help               Show this help message and exit
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dest)
      [[ $# -ge 2 ]] || { echo "Error: --dest needs a directory" >&2; exit 1; }
      DEST_ARGS+=("$2")
      shift 2
      ;;
    --dest=*)
      DEST_ARGS+=("${1#*=}")
      shift
      ;;
    --exclude)
      [[ $# -ge 2 ]] || { echo "Error: --exclude needs a skill name" >&2; exit 1; }
      EXCLUDES+=("$2")
      shift 2
      ;;
    --exclude=*)
      EXCLUDES+=("${1#*=}")
      shift
      ;;
    --exclude-cloudflare)
      EXCLUDES+=("${SYNC_COMMON_CLOUDFLARE_SKILLS[@]}")
      shift
      ;;
    --no-prune)
      PRUNE=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Error: unknown option '$1'" >&2
      usage
      ;;
  esac
done

# Print the home directory of the first Cursor profile found under /mnt/c/Users.
# Windows profiles that are not a real user home are skipped. Falls back to
# $HOME (WSL-side Cursor). Returns 1 when neither exists.
detect_profile() {
  local profile
  for profile in /mnt/c/Users/*/; do
    profile="${profile%/}"
    case "$(basename "$profile")" in
      "All Users"|"Default"|"Default User"|Public|defaultuser0) continue ;;
    esac
    if [[ -d "$profile/.cursor" ]]; then
      printf '%s\n' "$profile"
      return 0
    fi
  done
  if [[ -d "$HOME/.cursor" ]]; then
    printf '%s\n' "$HOME"
    return 0
  fi
  return 1
}

# Mirror one skill directory. Echoes the number of changed entries (0 = the copy
# was already up to date). rsync is preferred because it also deletes files that
# were dropped inside a skill; cp -a is the fallback (it never deletes).
mirror_tree() {
  local src="$1"
  local dst="$2"

  if command -v rsync >/dev/null 2>&1; then
    # --no-perms/--no-owner/--no-group: a drvfs (Windows) mount reports fixed
    # permissions, so a plain -a would report every file as changed every run.
    rsync -rlt --no-perms --no-owner --no-group --delete --itemize-changes \
      "$src/" "$dst/" | wc -l
    return 0
  fi

  if [[ -e "$dst" ]] && diff -rq "$src" "$dst" >/dev/null 2>&1; then
    echo 0
    return 0
  fi
  mkdir -p "$dst"
  cp -a "$src/." "$dst/"
  echo 1
}

if [[ ! -d "$SRC" ]]; then
  echo "Error: $SRC not found." >&2
  echo "       Install the skills first (./sync-agents.sh -n, or npx skills)." >&2
  exit 1
fi

DESTS=()
if [[ ${#DEST_ARGS[@]} -gt 0 ]]; then
  DESTS=("${DEST_ARGS[@]}")
else
  if ! profile="$(detect_profile)"; then
    echo "Error: no Cursor profile found (~/.cursor or /mnt/c/Users/*/.cursor)." >&2
    echo "       Pass --dest DIR, e.g. /mnt/c/Users/<you>/.cursor/skills." >&2
    exit 1
  fi
  DESTS=("$profile/.cursor/skills")
  # Cursor also reads {profile}/.claude/skills. Only the Windows profile gets
  # that copy: on the WSL side the directory is the dotfiles repo's (its
  # sync-claude.sh walks ~/.claude/skills and would pull the skills into it).
  if [[ "$profile" == /mnt/* ]]; then
    DESTS+=("$profile/.claude/skills")
  fi
fi

echo "=== $(basename "$0") ==="
echo "Source: $SRC"
printf 'Dest:   %s\n' "${DESTS[@]}"
if [[ ${#EXCLUDES[@]} -gt 0 ]]; then
  echo "Exclude: ${EXCLUDES[*]}"
fi
if [[ $PRUNE -eq 0 ]]; then
  echo "Prune:   off"
fi
if [[ $DRY_RUN -eq 1 ]]; then
  echo "Mode:    dry-run (nothing is written)"
fi
echo ""

total_copied=0
total_same=0
total_skipped=0
total_pruned=0
linux_only=()

# Windows-native Cursor has no ~/.claude/scripts, so the skills that call those
# scripts cannot run there. The prefix is matched literally (the skills spell it
# as ~/..., $HOME/... or a bare .claude/...), so only the tail is searched for.
for dest in "${DESTS[@]}"; do
  [[ "$dest" == /mnt/*/Users/* ]] || continue
  for src_dir in "$SRC"/*/; do
    name="$(basename "${src_dir%/}")"
    sync_common::path_excluded "$name" ${EXCLUDES[@]+"${EXCLUDES[@]}"} && continue
    if grep -qsF '.claude/scripts/' "$src_dir/SKILL.md"; then
      linux_only+=("$name")
    fi
  done
  break
done

for DEST in "${DESTS[@]}"; do
  if [[ ${#DESTS[@]} -gt 1 ]]; then
    echo "--- $DEST"
  fi

  if [[ $DRY_RUN -eq 0 ]]; then
    mkdir -p "$DEST"
  fi

  copied=0
  same=0
  skipped=0
  pruned=0
  managed=()

  # --- 1. prune copies of skills that left HOME ------------------------------
  if [[ $PRUNE -eq 1 && -f "$DEST/$MANIFEST_NAME" ]]; then
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      # Still distributed (and re-copied below) or deliberately excluded.
      if [[ -d "$SRC/$name" ]]; then
        continue
      fi
      if sync_common::path_excluded "$name" ${EXCLUDES[@]+"${EXCLUDES[@]}"}; then
        continue
      fi
      if [[ ! -d "$DEST/$name" ]]; then
        continue
      fi

      if [[ $DRY_RUN -eq 1 ]]; then
        echo "  prune $name (dry-run)"
      else
        rm -rf -- "${DEST:?}/$name"
        echo "  prune $name"
      fi
      pruned=$((pruned + 1))
    done <"$DEST/$MANIFEST_NAME"
  fi

  # --- 2. copy every skill directory ---------------------------------------
  for src_dir in "$SRC"/*/; do
    src_dir="${src_dir%/}"
    name="$(basename "$src_dir")"

    if sync_common::path_excluded "$name" ${EXCLUDES[@]+"${EXCLUDES[@]}"}; then
      skipped=$((skipped + 1))
      continue
    fi

    if [[ ! -f "$src_dir/SKILL.md" ]]; then
      echo "  skip  $name (no SKILL.md)"
      skipped=$((skipped + 1))
      continue
    fi

    managed+=("$name")

    # Cursor's bundled skills (~/.cursor/skills-cursor) may use the same name.
    if [[ -e "$(dirname "$DEST")/skills-cursor/$name/SKILL.md" ]]; then
      echo "  warn  $name also exists in Cursor's bundled skills-cursor/ (collision)"
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
      echo "  copy  $name (dry-run)"
      copied=$((copied + 1))
      continue
    fi

    changed="$(mirror_tree "$src_dir" "$DEST/$name")"
    if [[ "$changed" -eq 0 ]]; then
      echo "  same  $name"
      same=$((same + 1))
    else
      echo "  copy  $name"
      copied=$((copied + 1))
    fi
  done

  # --- 3. record what this script owns -------------------------------------
  if [[ $DRY_RUN -eq 0 ]]; then
    printf '%s\n' ${managed[@]+"${managed[@]}"} >"$DEST/$MANIFEST_NAME"
  fi

  echo ""
  echo "$DEST: copied $copied, unchanged $same, skipped $skipped, pruned $pruned"

  total_copied=$((total_copied + copied))
  total_same=$((total_same + same))
  total_skipped=$((total_skipped + skipped))
  total_pruned=$((total_pruned + pruned))
done

# --- 4. summary ------------------------------------------------------------
echo ""
if [[ ${#DESTS[@]} -gt 1 ]]; then
  echo "Total: copied $total_copied, unchanged $total_same, skipped $total_skipped, pruned $total_pruned"
fi
echo "Managed skills are listed in each destination's $MANIFEST_NAME"

if [[ ${#linux_only[@]} -gt 0 ]]; then
  echo ""
  echo "Note: these call ~/.claude/scripts, which does not exist for a Windows-native"
  echo "      Cursor — they only work when Cursor runs inside WSL:"
  printf '      %s\n' "${linux_only[@]}"
fi

echo ""
echo "Done."
