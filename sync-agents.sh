#!/bin/bash
# Sync the agent-general phase skills between ~/.agents/skills and this repo.
#
#   ~/.agents/skills/{startproject,team-implement,team-review,deploy}
#     <->  agents/skills/{name}/
#
# ~/.agents/skills is also managed by `npx skills` (.skill-lock.json), so this
# script touches ONLY the four phase skills listed in AGENT_SKILLS and never
# walks the whole directory.
#
# Cline does not read ~/.agents/skills (it reads ~/.cline/skills), so after the
# sync a symlink ~/.cline/skills/{name} -> ~/.agents/skills/{name} is created
# for each skill that exists in HOME. Existing entries are left alone.
#
# pi reads ~/.pi/agent/skills before ~/.agents/skills and keeps the first skill
# it finds, so a stale copy there shadows the synced one. This script only
# warns about that; deleting the old copies is a manual step (see
# agents/README.md).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$HOME/.agents/skills"
DEST="$SCRIPT_DIR/agents/skills"
CLINE_SKILLS="$HOME/.cline/skills"
PI_SKILLS="$HOME/.pi/agent/skills"

AGENT_SKILLS=(startproject team-implement team-review deploy)

# shellcheck source=lib/sync-common.sh
source "$SCRIPT_DIR/lib/sync-common.sh"

sync_common::parse_args "$(basename "$0")" \
  "Sync ~/.agents/skills/{${AGENT_SKILLS[*]// /,}} with this repository and link them for Cline." "$@"
sync_common::show_header "$(basename "$0")"

# --- 1. HOME <-> repo (per skill, so npx-managed skills are never touched) ---
for name in "${AGENT_SKILLS[@]}"; do
  if [[ ! -f "$SOURCE/$name/SKILL.md" ]]; then
    echo "Warning: $SOURCE/$name is not yet in HOME." >&2
    echo "         Run interactively and choose (p), or: cp -r agents/skills/$name $SOURCE/" >&2
  fi
  sync_common::sync_directory "$SOURCE/$name" "$DEST/$name" "*" || true
done

# --- 2. Cline symlinks (skip anything that already exists) -------------------
echo ""
echo "Cline symlinks ($CLINE_SKILLS):"
for name in "${AGENT_SKILLS[@]}"; do
  target="$SOURCE/$name"
  link="$CLINE_SKILLS/$name"

  if [[ ! -d "$target" ]]; then
    echo "  skip  $name (no $target yet)"
    continue
  fi
  if [[ -L "$link" ]]; then
    echo "  ok    $name -> $(readlink "$link")"
    continue
  fi
  if [[ -e "$link" ]]; then
    echo "  warn  $link exists and is not a symlink — left alone (remove it to link $target)" >&2
    continue
  fi
  mkdir -p "$CLINE_SKILLS"
  ln -s "$target" "$link"
  echo "  link  $name -> $target"
done

# --- 3. pi shadow check -------------------------------------------------------
for name in "${AGENT_SKILLS[@]}"; do
  if [[ -e "$PI_SKILLS/$name" && ! -L "$PI_SKILLS/$name" ]]; then
    echo "Warning: $PI_SKILLS/$name shadows $SOURCE/$name for pi (first match wins)." >&2
    echo "         Remove it by hand after confirming it is the old copy: rm -r $PI_SKILLS/$name" >&2
  fi
done

echo ""
echo "Done."
