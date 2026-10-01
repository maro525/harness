#!/bin/bash
# Sync the harness files under ~/.claude with this repository.
#
# ~/.claude is shared with the dotfiles repo (maro525/_dotfiles), so this
# script names every file it owns and never walks a whole directory. The
# dotfiles side excludes the same names in its sync-claude.sh — keep the two
# lists in step when adding or removing a file here.

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
)

# shellcheck source=lib/sync-common.sh
source "$SCRIPT_DIR/lib/sync-common.sh"

sync_common::parse_args "$(basename "$0")" "Sync the harness files under ~/.claude with this repository." "$@"
sync_common::show_header "$(basename "$0")"

for rel in "${HARNESS_FILES[@]}"; do
  mkdir -p "$(dirname "$SOURCE/$rel")" "$(dirname "$DEST/$rel")"
  sync_common::sync_file "$SOURCE/$rel" "$DEST/$rel" "$rel" || true
done

echo ""
echo "Done."
