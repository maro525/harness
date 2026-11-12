#!/bin/bash
# claude-consult.sh — thin wrapper around consult.sh (--to claude).
#
# Kept as the stable entry point for the claude-consult skill, the harness
# commands/rules and every existing habit. All behaviour lives in consult.sh;
# codex-consult.sh is the same file with --to codex.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/consult.sh" --to claude "$@"
