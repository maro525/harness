#!/bin/bash
# Sync the pi prompt templates between ~/.pi/agent/prompts and this repository.
#
#   ~/.pi/agent/prompts/{orchestrate}.md  <->  pi/prompts/
#
# ~/.pi/agent also holds pi's own configuration (AGENTS.md, settings.json,
# extensions/, skills/, sessions/), so this script names every file it owns and
# never walks the directory. The orchestrate prompt is a thin wrapper around
# ~/.agents/skills/orchestrate/SKILL.md, which sync-agents.sh distributes; the
# phase dispatch lives in ~/.claude/scripts/phase-run.sh (sync-claude.sh).
#
# After the sync it only WARNS about missing prerequisites and permissions. pi
# denies unapproved bash commands without a TTY, so an incomplete allowlist
# stops the orchestrator at its first phase-run.sh call — check the output.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$HOME/.pi/agent/prompts"
DEST="$SCRIPT_DIR/pi/prompts"

PI_PROMPTS=(orchestrate.md)

AGENT_SKILLS=(startproject team-implement team-review deploy orchestrate)
AGENT_SKILLS_DIR="$HOME/.agents/skills"
PI_OWN_SKILLS="$HOME/.pi/agent/skills"
PHASE_RUN="$HOME/.claude/scripts/phase-run.sh"
PERMISSIONS="$HOME/.pi/agent/extensions/permissions/index.ts"

# shellcheck source=lib/sync-common.sh
source "$SCRIPT_DIR/lib/sync-common.sh"

# harness is mainly distributed from this repo, so -n copies repo → HOME by
# default (--to-repo reverses it).
SYNC_COMMON_DEFAULT_DIRECTION=repo-to-home
sync_common::parse_args "$(basename "$0")" \
  "Sync ~/.pi/agent/prompts/{${PI_PROMPTS[*]// /,}} with this repository." "$@"
sync_common::show_header "$(basename "$0")"

# --- 1. HOME <-> repo (only the files this script owns) ----------------------
mkdir -p "$SOURCE" "$DEST"
for name in "${PI_PROMPTS[@]}"; do
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

# pi reads ~/.pi/agent/skills before ~/.agents/skills and keeps the first copy.
for name in "${AGENT_SKILLS[@]}"; do
  if [[ -e "$PI_OWN_SKILLS/$name" && ! -L "$PI_OWN_SKILLS/$name" ]]; then
    echo "  warn  $PI_OWN_SKILLS/$name shadows the synced skill (first match wins); remove the old copy" >&2
  fi
done

# --- 3. permissions allowlist ------------------------------------------------
echo ""
echo "pi permissions ($PERMISSIONS):"
if [[ ! -f "$PERMISSIONS" ]]; then
  echo "  warn  permissions extension not found — phase-run.sh may be denied without a TTY" >&2
else
  for pattern in '"~/.claude/scripts/**"' "\"$HOME/.claude/scripts/**\"" '"git switch **"'; do
    if grep -qF -- "$pattern" "$PERMISSIONS"; then
      echo "  ok    $pattern"
    else
      echo "  warn  add $pattern to ALLOW_PATTERNS (pi denies unapproved bash without a TTY)" >&2
    fi
  done
fi

echo ""
echo "Done."
