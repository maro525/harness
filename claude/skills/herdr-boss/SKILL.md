---
name: herdr-boss
description: Herdr 上で司令塔（boss）として振る舞う。自分では手を動かさず、範囲を絞った仕事を名前付きの子エージェント（別 tab の claude / pi / codex など）に渡してすぐ戻り、inbox に届いた報告を読んで要約する。Use when asked 「司令塔になって」「boss として子に任せて」「herdr で子エージェントに振って」「並行で何人かに任せて」.
user-invocable: true
argument-hint: "[任せたい仕事の概要（省略可）]"
---

# herdr-boss（Claude 版の入口）

手順の正本は汎用版の `~/.agents/skills/herdr-boss/SKILL.md`。**このファイルに手順を写さない。** 読んで、そのとおりに動く。Claude 固有の差分は frontmatter だけ。

- 無いときは harness のチェックアウトで `./sync-agents.sh -n` を流してから読む（`$HARNESS`、未設定なら `~/src/harness`）。手順を推測で組み立てない（`delegate` / `report` / `inbox` の使い方がずれる）
