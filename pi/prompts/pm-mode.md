---
description: PM 専任モード — 自分では手を動かさず、判断と実行は Herdr 経由で他の AI に渡す
argument-hint: "\"<依頼>\""
---
Read `~/.agents/skills/pm-mode/SKILL.md` and follow it.

The skill is the source of truth: 役割（PM がやる / やらない）、振り分け（delegate /
consult / orchestrate-parallel / ask）、依頼文と報告の規約、止まる場所。
If the skill is missing, stop and say to run `sync-agents.sh -n` in the harness
checkout first — do not reconstruct the workflow from this prompt.

$ARGUMENTS: $@
