#!/bin/bash
# codex-consult.sh — thin wrapper around consult.sh (--to codex).
#
# Same consultation flow as claude-consult.sh, with Codex CLI as the target:
#   consult / review  `codex -s read-only -a never`     (answers in markers only)
#   implement         `codex -s workspace-write -a never`
#   -b print          one-shot `codex exec -s read-only`
# Sessions live in their own Herdr tabs under the consult-codex[-<role>] agent
# names, so a codex consult and a claude consult can run side by side.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/consult.sh" --to codex "$@"
