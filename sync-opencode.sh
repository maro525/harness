#!/bin/bash
# Sync the harness files under ~/.config/opencode with this repository.
#
# ~/.config/opencode is shared with the dotfiles repo (maro525/_dotfiles), so
# this script names every file it owns. The dotfiles side excludes the same
# names in its sync-opencode.sh — keep the two lists in step.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$HOME/.config/opencode"
DEST="$SCRIPT_DIR/opencode"

HARNESS_FILES=(
  commands/orchestrate.md
  commands/startproject.md
  commands/team-implement.md
  commands/team-review.md
  commands/deploy.md
  agents/startproject.md
  agents/team-implement.md
  agents/team-review.md
  agents/deploy.md
)

# shellcheck source=lib/sync-common.sh
source "$SCRIPT_DIR/lib/sync-common.sh"

# harness is mainly distributed from this repo, so -n copies repo → HOME by
# default (--to-repo reverses it). The lib default stays HOME → repo for dotfiles.
SYNC_COMMON_DEFAULT_DIRECTION=repo-to-home
sync_common::parse_args "$(basename "$0")" "Sync the harness files under ~/.config/opencode with this repository." "$@"
sync_common::show_header "$(basename "$0")"

for rel in "${HARNESS_FILES[@]}"; do
  mkdir -p "$(dirname "$SOURCE/$rel")" "$(dirname "$DEST/$rel")"
  sync_common::sync_file "$SOURCE/$rel" "$DEST/$rel" "$rel" || true
done

# Cross-repo 参照チェック（checks/crossrefs.sh の「契約」を参照）。
# dotfiles の opencode/AGENTS.md の節名や harness のファイル名を変えたときに、
# 相手側の参照が壊れていないかを確認する。失敗しても同期は成功扱い（警告のみ）。
if [[ -f "$SCRIPT_DIR/checks/crossrefs.sh" ]]; then
  bash "$SCRIPT_DIR/checks/crossrefs.sh" ||
    echo "Warning: cross-repo 参照チェックに失敗（上記 NG を確認）" >&2
fi

echo ""
echo "Done."
