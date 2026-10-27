#!/bin/bash
# Sync the harness files under ~/.claude with this repository.
#
# ~/.claude is shared with the dotfiles repo (maro525/_dotfiles), so this
# script names every file it owns and never walks a whole directory. The
# dotfiles side excludes the same names in its sync-claude.sh — keep the two
# lists in step when adding or removing a file here. scripts/ is not walked by
# the dotfiles side (it only scans commands/ hooks/ rules/ skills/), so the
# files under scripts/ need no exclusion there.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$HOME/.claude"
DEST="$SCRIPT_DIR/claude"

HARNESS_FILES=(
  commands/orchestrate.md
  commands/startproject.md
  commands/team-implement.md
  commands/team-review.md
  commands/deploy.md
  rules/adaptive-execution.md
  rules/tool-routing.md
  hooks/agent-router.py
  scripts/linear-ask.sh
  scripts/ai-fallback.sh
  scripts/phase-run.sh
)

# shellcheck source=lib/sync-common.sh
source "$SCRIPT_DIR/lib/sync-common.sh"

sync_common::parse_args "$(basename "$0")" "Sync the harness files under ~/.claude with this repository." "$@"
sync_common::show_header "$(basename "$0")"

for rel in "${HARNESS_FILES[@]}"; do
  mkdir -p "$(dirname "$SOURCE/$rel")" "$(dirname "$DEST/$rel")"
  sync_common::sync_file "$SOURCE/$rel" "$DEST/$rel" "$rel" || true
done

# Keep scripts executable on both sides however they got there (a checkout
# with core.fileMode=false, a copy from a non-executable source, ...).
for rel in "${HARNESS_FILES[@]}"; do
  if [[ "$rel" == scripts/*.sh ]]; then
    for path in "$SOURCE/$rel" "$DEST/$rel"; do
      if [[ -f "$path" ]]; then
        chmod 755 "$path"
      fi
    done
  fi
done

echo ""
echo "Done."
