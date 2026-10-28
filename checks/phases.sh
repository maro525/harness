#!/bin/bash
# Phase parity check — the 4 phases must be defined for all three systems and
# must satisfy docs/phase-contract.md.
#
# Checked here (structure only; behaviour is reviewed by hand):
#   1. every phase definition exists for claude / opencode / agents skills
#   2. every definition takes --task-file
#   3. the self-writing systems (opencode agents, agents skills) support --label
#      and therefore write 利用AI:
#   4. orchestrator 専権: no phase definition contains a `status:` assignment
#      (the three orchestrators do own it)
#   5. the three orchestrators know all 4 phases and both extra modes (3F / 3P)
#   6. phase-run.sh exists, is executable, and knows every runner
#   7. the sync scripts list the files they distribute
#   8. docs/phase-contract.md still states the contract (RESULT / QUESTIONS /
#      --task-file / status は orchestrator 専権)
#
# Usage: checks/phases.sh
# Exit: 0 = ok / 1 = 不整合

set -uo pipefail

HARNESS=$(cd "$(dirname "$0")/.." && pwd)
PHASES=(startproject team-implement team-review deploy)

fail=0
ng() {
  echo "NG: $*" >&2
  fail=1
}

ok() {
  echo "ok: $*"
}

readonly_path() {
  printf '%s/%s' "$HARNESS" "$1"
}

# --- 1 / 2 / 3 ---------------------------------------------------------------
for phase in "${PHASES[@]}"; do
  claude="claude/commands/$phase.md"
  opencode="opencode/agents/$phase.md"
  skill="agents/skills/$phase/SKILL.md"

  for rel in "$claude" "$opencode" "$skill"; do
    if [[ ! -f $(readonly_path "$rel") ]]; then
      ng "定義が無い: $rel"
      continue
    fi
    grep -q -- '--task-file' "$(readonly_path "$rel")" ||
      ng "--task-file の記述が無い: $rel"
  done

  # The self-writing systems must be able to record who ran them.
  for rel in "$opencode" "$skill"; do
    [[ -f $(readonly_path "$rel") ]] || continue
    grep -q -- '--label' "$(readonly_path "$rel")" ||
      ng "--label の記述が無い: $rel"
    grep -q '利用AI' "$(readonly_path "$rel")" ||
      ng "利用AI の記述が無い: $rel"
  done
done

# --- 4: status is orchestrator-only (except the initial creation) -----------
for phase in "${PHASES[@]}"; do
  for rel in "claude/commands/$phase.md" "opencode/agents/$phase.md" "agents/skills/$phase/SKILL.md"; do
    [[ -f $(readonly_path "$rel") ]] || continue
    while IFS= read -r value; do
      [[ -z "$value" ]] && continue
      if [[ "$value" != "planning" ]]; then
        ng "フェーズ定義が status: $value を書いている（orchestrator 専権）: $rel"
      fi
    done < <(awk -F'status:' '/^[[:space:]]*(-[[:space:]]*)?status:/ { v=$2; gsub(/^[ \t]+|[ \t]+$/, "", v); print v }' "$(readonly_path "$rel")")
  done
done

# --- 5: orchestrators --------------------------------------------------------
for rel in claude/commands/orchestrate.md opencode/commands/orchestrate.md agents/skills/orchestrate/SKILL.md; do
  path=$(readonly_path "$rel")
  if [[ ! -f $path ]]; then
    ng "orchestrator が無い: $rel"
    continue
  fi
  for phase in "${PHASES[@]}"; do
    grep -q -- "$phase" "$path" || ng "$rel に $phase の記述が無い"
  done
  for mode in 3F 3P; do
    grep -q -- "STEP $mode" "$path" || ng "$rel に STEP $mode（$mode モード）が無い"
  done
done

# --- 6: dispatcher -----------------------------------------------------------
dispatcher="claude/scripts/phase-run.sh"
if [[ ! -f $(readonly_path "$dispatcher") ]]; then
  ng "ディスパッチャが無い: $dispatcher"
else
  [[ -x $(readonly_path "$dispatcher") ]] || ng "$dispatcher に実行ビットが無い"
  for runner in claude opencode2 opencode pi codex cline auto; do
    grep -q "^    $runner)" "$(readonly_path "$dispatcher")" ||
      ng "$dispatcher に runner '$runner' が無い"
  done
fi

# --- 7: sync scripts ---------------------------------------------------------
declare -A sync_lists=(
  [sync-claude.sh]="commands/orchestrate.md commands/team-review.md rules/tool-routing.md scripts/phase-run.sh"
  [sync-opencode.sh]="commands/orchestrate.md agents/team-review.md"
  [sync-agents.sh]="startproject team-implement team-review deploy orchestrate"
  [sync-pi.sh]="orchestrate.md"
)
for script in "${!sync_lists[@]}"; do
  path=$(readonly_path "$script")
  if [[ ! -f $path ]]; then
    ng "同期スクリプトが無い: $script"
    continue
  fi
  for entry in ${sync_lists[$script]}; do
    grep -q -- "$entry" "$path" || ng "$script の配布対象に $entry が無い"
  done
done

# --- 7b: pi prompt wrapper ---------------------------------------------------
pi_prompt="pi/prompts/orchestrate.md"
if [[ ! -f $(readonly_path "$pi_prompt") ]]; then
  ng "pi の orchestrate プロンプトが無い: $pi_prompt"
else
  for token in '~/.agents/skills/orchestrate/SKILL.md' '--task-file' '--phase' '--tier'; do
    grep -qF -- "$token" "$(readonly_path "$pi_prompt")" ||
      ng "$pi_prompt に '$token' の記述が無い"
  done
fi

# --- 8: contract -------------------------------------------------------------
contract="docs/phase-contract.md"
if [[ ! -f $(readonly_path "$contract") ]]; then
  ng "契約が無い: $contract"
else
  for token in '--task-file' '### RESULT' '### SECTION' '### QUESTIONS' 'orchestrator 専権'; do
    grep -qF -- "$token" "$(readonly_path "$contract")" ||
      ng "$contract に '$token' の記述が無い"
  done
fi

if [[ $fail -eq 0 ]]; then
  ok "phase parity (${PHASES[*]}) / 3 系統 / orchestrator 3 本 / phase-run.sh"
  exit 0
fi

echo "phases: 不整合あり。docs/phase-contract.md と 3 系統の定義を揃える。" >&2
exit 1
