#!/bin/bash
# Sync the Codex prompt templates between ~/.codex/prompts and this repository.
#
#   ~/.codex/prompts/orchestrate.md  <->  codex/prompts/
#
# ~/.codex also holds Codex's own configuration, so this script names every file
# it owns and never walks the directory. The orchestrate prompt is a thin wrapper
# around ~/.agents/skills/orchestrate/SKILL.md, which sync-agents.sh distributes;
# the phase dispatch lives in ~/.claude/scripts/phase-run.sh (sync-claude.sh).
#
# Codex has no permission allowlist, so after the sync this only WARNS about
# missing prerequisites.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$HOME/.codex/prompts"
DEST="$SCRIPT_DIR/codex/prompts"

CODEX_PROMPTS=(orchestrate.md)

AGENT_SKILLS=(startproject team-implement team-review deploy orchestrate)
AGENT_SKILLS_DIR="$HOME/.agents/skills"
PHASE_RUN="$HOME/.claude/scripts/phase-run.sh"

# shellcheck source=lib/sync-common.sh
source "$SCRIPT_DIR/lib/sync-common.sh"

# harness is mainly distributed from this repo, so -n copies repo → HOME by
# default (--to-repo reverses it).
SYNC_COMMON_DEFAULT_DIRECTION=repo-to-home
sync_common::parse_args "$(basename "$0")" \
  "Sync ~/.codex/prompts/{${CODEX_PROMPTS[*]// /,}} with this repository." "$@"
sync_common::show_header "$(basename "$0")"

# --- 1. HOME <-> repo (only the files this script owns) ----------------------
mkdir -p "$SOURCE" "$DEST"
for name in "${CODEX_PROMPTS[@]}"; do
  sync_common::sync_file "$SOURCE/$name" "$DEST/$name" "$name" || true
done

# --- 2. prerequisites (warn only; never block the sync) ----------------------
echo ""
echo "Prerequisites:"
for name in "${AGENT_SKILLS[@]}"; do
  if [[ -f "$AGENT_SKILLS_DIR/$name/SKILL.md" ]]; then
    echo "  ok    $AGENT_SKILLS_DIR/$name"
  else
    echo "  warn  missing $AGENT_SKILLS_DIR/$name — run: ./sync-agents.sh -n" >&2
  fi
done

if [[ -x "$PHASE_RUN" ]]; then
  echo "  ok    $PHASE_RUN"
else
  echo "  warn  missing $PHASE_RUN — run: ./sync-claude.sh -n" >&2
fi

echo ""
echo "Done."
