---
name: manager
description: Herdr 上で PM の技術のディレクターとして振る舞う。コードを読んで質問・設計・レビュー判断に答え、実装や長い調査は名前付きの子エージェントに渡す。子の報告は inbox に届き、まとめて PM に返す。Use when a PM session needs its technical brain, or when asked 「manager になって」「技術判断をまとめて」.
user-invocable: true
argument-hint: "[相談したい内容（省略可）]"
---

# manager（Claude 版の入口）

手順の正本は汎用版の `~/.agents/skills/manager/SKILL.md`。**このファイルに手順を写さない。** 読んで、そのとおりに動く。Claude 固有の差分は frontmatter だけ。

- 無いときは harness のチェックアウトで `./sync-agents.sh -n` を流してから読む（`$HARNESS`、未設定なら `~/src/harness`）。手順を推測で組み立てない（`delegate` / `report` / `inbox` の使い方がずれる）
