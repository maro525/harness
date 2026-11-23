#!/bin/bash
# Sync the agent-general skills (phase skills + consult + boss + cleanup) between ~/.agents/skills and this repo.
#
#   ~/.agents/skills/{startproject,team-implement,team-review,deploy,orchestrate,claude-consult,herdr-boss}
#     <->  agents/skills/{name}/
#
# ~/.agents/skills is also managed by `npx skills` (.skill-lock.json), so this
# script touches ONLY the skills listed in AGENT_SKILLS and never
# walks the whole directory.
#
# Cline does not read ~/.agents/skills (it reads ~/.cline/skills), so after the
# sync a symlink ~/.cline/skills/{name} -> ~/.agents/skills/{name} is created
# for each skill that exists in HOME. Existing entries are left alone.
#
# Cursor (WSL) also gets ~/.cursor/skills/{name} -> ~/.agents/skills/{name}
# symlinks. sync-cursor.sh copies the same skills into the *Windows* profile, so
# without this the WSL-side Cursor sees nothing.
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

AGENT_SKILLS=(startproject team-implement team-review deploy orchestrate claude-consult codex-consult herdr-boss herdr-cleanup harness-daily)

# Claude Code does not read ~/.agents/skills, and these are the ones a Claude
# session also needs (housekeeping). consult/phase skills stay out: Claude Code
# has its own commands and the consult skills are for *other* agents.
CLAUDE_SKILLS=(herdr-cleanup harness-daily)
CLAUDE_SKILLS_DIR="$HOME/.claude/skills"
CURSOR_SKILLS="$HOME/.cursor/skills"

# shellcheck source=lib/sync-common.sh
source "$SCRIPT_DIR/lib/sync-common.sh"

# harness is mainly distributed from this repo, so -n copies repo → HOME by
# default (--to-repo reverses it). The lib default stays HOME → repo for dotfiles.
SYNC_COMMON_DEFAULT_DIRECTION=repo-to-home
sync_common::parse_args "$(basename "$0")" \
  "Sync ~/.agents/skills/{${AGENT_SKILLS[*]// /,}} with this repository and link them for Cline." "$@"
sync_common::show_header "$(basename "$0")"

# --- 1. HOME <-> repo (per skill, so npx-managed skills are never touched) ---
for name in "${AGENT_SKILLS[@]}"; do
  # Skip the warning when this run is about to copy repo → HOME anyway.
  if [[ ! -f "$SOURCE/$name/SKILL.md" ]] \
      && ! [[ $INTERACTIVE -eq 0 && "$SYNC_DIRECTION" == "repo-to-home" ]]; then
    echo "Warning: $SOURCE/$name is not yet in HOME." >&2
    echo "         Run with -n (repo → HOME), or interactively and choose (p)." >&2
  fi
  sync_common::sync_directory "$SOURCE/$name" "$DEST/$name" "*" || true
done

# --- 1b. スキルが相対で参照する docs/ を配る -------------------------------
# orchestrate の SKILL.md は「契約は `docs/phase-contract.md`」と相対で書いている。
# ~/.agents/skills/orchestrate/ に docs/ が無いと、子（codex / claude）がタスクの
# リポジトリから辿れずに失敗する（実例: 2026-11-20 06:22 と 07:16 に exit 1）。
# リポジトリの docs/ が正本なので、同期のたびにコピーする（リポジトリには重複を置かない）。
echo ""
echo "Skill docs:"
if [[ -f "$SCRIPT_DIR/docs/phase-contract.md" ]]; then
  mkdir -p "$SOURCE/orchestrate/docs"
  cp "$SCRIPT_DIR/docs/phase-contract.md" "$SOURCE/orchestrate/docs/phase-contract.md"
  echo "  copy  docs/phase-contract.md -> $SOURCE/orchestrate/docs/"
else
  echo "  skip  docs/phase-contract.md（$SCRIPT_DIR/docs に無い）"
fi

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

# --- 3. Claude symlinks (only the ones Claude Code needs) --------------------
echo ""
echo "Claude symlinks ($CLAUDE_SKILLS_DIR):"
for name in "${CLAUDE_SKILLS[@]}"; do
  target="$SOURCE/$name"
  link="$CLAUDE_SKILLS_DIR/$name"

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
  mkdir -p "$CLAUDE_SKILLS_DIR"
  ln -s "$target" "$link"
  echo "  link  $name -> $target"
done

# --- 3b. Cursor (WSL) symlinks ------------------------------------------------
# Cursor は WSL からでも ~/.cursor/skills を読む。sync-cursor.sh は Windows 側の
# プロファイルに**コピー**するので、WSL の Cursor からは見えない。ここでは
# Cline と同じく symlink を張る（~/.agents を正本にするので常に最新）。
# 既存の実ディレクトリは消さない（手で置いたものを壊さない）。
echo ""
echo "Cursor (WSL) symlinks ($CURSOR_SKILLS):"
for name in "${AGENT_SKILLS[@]}"; do
  target="$SOURCE/$name"
  link="$CURSOR_SKILLS/$name"

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
  mkdir -p "$CURSOR_SKILLS"
  ln -s "$target" "$link"
  echo "  link  $name -> $target"
done

# --- 4. pi shadow check -------------------------------------------------------
for name in "${AGENT_SKILLS[@]}"; do
  if [[ -e "$PI_SKILLS/$name" && ! -L "$PI_SKILLS/$name" ]]; then
    echo "Warning: $PI_SKILLS/$name shadows $SOURCE/$name for pi (first match wins)." >&2
    echo "         Remove it by hand after confirming it is the old copy: rm -r $PI_SKILLS/$name" >&2
  fi
done

echo ""
echo "Done."
