---
name: team-implement
description: Implementation phase — read design, implement code, return an implementation payload. The caller writes TASK_FILE and posts to Linear. Called by /orchestrate with tier, task-file, linear-id.
context: fork
agent: general-purpose
model: best
color: blue
allowed-tools: Read, Write, Edit, Bash, Grep, Glob, Agent, Skill, AskUserQuestion, SendMessage, TodoWrite, mcp__linear-server__get_issue
---

# team-implement

## 今回の引数

$ARGUMENTS

（引数の置き場所はここだけ。本文の「引数」はこの値を指す。Agent ツール経由で起動された場合は、プロンプトの `ARGUMENTS:` 行が引数）

実装フェーズを担当。コード（実装・テスト）の読み書きと作業ブランチの作成は自分で行う（コミットはしない）。

**TASK_FILE への書き込みと Linear への投稿は行わない。** 結果は OUTPUT フォーマットで呼び出し元（`/orchestrate` STEP 4）に返し、TASK_FILE の更新・Linear コメント投稿・ステータス変更は呼び出し元が行う。TASK_FILE は Read のみ。

## Input

```
引数の形式: "{task description} --tier={S|M|L} --task-file={TASK_FILE} --linear-id={LINEAR_ID}"
```

| 引数 | 説明 |
|---|---|
| `--tier` | orchestrator が判定済み |
| `--task-file` | orchestrator が作成済みのタスクファイルパス |
| `--linear-id` | orchestrator が確認済みの Linear タスク ID |

## 事前準備

実装開始前に必ず TASK_FILE の以下を読む。

1. `## startproject` > `### Brief` — 概要・スコープ・成功基準
2. `## startproject` > `### Design` — 設計方針とその理由
3. `## startproject` > `### Plan` — 実装タスクリスト
4. `## team-review`（差し戻し時のみ存在）— 最新回の critical / major 指摘。**これの修正を最優先する**

## IMPLEMENTATION

feature ブランチで作業し（`## Meta` に `branch:` があれば差し戻しなのでそのブランチを使う）、テストを先に書く（TDD）。

| tier | 体制 |
|---|---|
| S | 自分で実装する |
| M | 自分で実装する（サブエージェントに任せない） |
| L | モジュール単位で分割してサブエージェントに割り当てる（実装・テストまで担当モジュール内で完結）。依存の調整と統合は自分が行う |

S / M は orchestrate から Agent ツール経由（S は sonnet、M は opus）で起動されるため、中で Agent ツールを使わない（Agent の中でさらに Agent が使えるかは未確認。orchestrate.md「tier 別のフェーズ構成」）。

### エスカレーション

`$HOME/.claude/rules/adaptive-execution.md` の Escalation に従って tier を再評価する。引き上げが必要なら**実装を中断**し、OUTPUT の `ESCALATION` に新しい tier と理由を書いて返す。それまでの変更は作業ブランチに残す。tier の更新と計画のやり直しは orchestrate が行う。

### 完了条件

Plan のタスクがすべて完了し、テストがすべて通過したら OUTPUT を返す。変更はコミットしない（レビュー通過後に deploy がコミットする）。

## OUTPUT

以下のフォーマットを最終レスポンスとしてそのまま返す。

```markdown
### IMPLEMENTATION_NOTES

#### 実装サマリー
- 実装したモジュール・ファイル一覧
- 主要な実装判断とその理由

#### 変更ファイル
- path/to/file.ts — 変更内容の概要
- ...

#### テスト
- テストファイルの場所
- カバレッジの概要

#### 残課題・注意点
- レビュアーへの申し送り事項

### LINEAR_COMMENT
（Linear に投稿する実装完了コメント本文）

### BRANCH
feature/{feature-name}

### BASE
（作業ブランチを切ったときにいたブランチ。差し戻し時は `## Meta` の `base:` をそのまま返す）

### ESCALATION
（中断した場合のみ）{新しい tier}: {理由}
```
