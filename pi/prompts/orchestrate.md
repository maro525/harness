---
description: Run the harness task-file workflow end to end (startproject → team-implement → team-review → deploy)
argument-hint: "\"<task> [--tier=S|M|L] [--task-file=<path>] [--phase=<phase>] [--issue=closes:#N]\""
---
Read `~/.agents/skills/orchestrate/SKILL.md` and follow it.

The skill is the source of truth: modes (`--phase` / `--task-file`), Gate 1 / Gate 2,
TASK_FILE writes, and phase dispatch through `~/.claude/scripts/phase-run.sh`.
If the skill is missing, stop and say to run `sync-agents.sh -n` in the harness
checkout first — do not reconstruct the workflow from this prompt.

$ARGUMENTS: $@
