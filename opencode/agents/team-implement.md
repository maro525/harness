---
description: Implementation subagent — reads design and plan, implements code, writes the team-implement section of TASK_FILE.
mode: subagent
model: github-copilot/gpt-5.6-terra
variant: xhigh
permission:
  edit: allow
---

# team-implement

実装フェーズを担当。TASK_FILE の `## startproject` に沿って実装する。作業ブランチの作成は自分で行うが、コミットはしない。

## Input

```
$ARGUMENTS: "{task description} --tier={S|M|L} --task-file={TASK_FILE} --linear-id={LINEAR_ID}"
```

---

## 事前準備

実装開始前に必ず以下を読む。

1. TASK_FILE の `## startproject` > `### Brief` — スコープ・成功基準
2. TASK_FILE の `## startproject` > `### Design` — 設計方針とその理由
3. TASK_FILE の `## startproject` > `### Plan` — 実装タスクリスト
4. TASK_FILE の `## team-review`（差し戻し時のみ存在）— 最新回の critical / major 指摘。**これの修正を最優先する**

**[MUST]** Linear MCP `save_comment` で LINEAR_ID に実装開始コメントを投稿。

---

## IMPLEMENTATION

feature ブランチで作業し（TASK_FILE の `## Meta` に `branch:` があれば、差し戻しなのでそのブランチを使う）、テストを先に書く（TDD）。tier によって体制を切り替える。

| tier | 体制 |
|------|------|
| S | 自分で実装する |
| M | 自分で実装するか、独立したモジュールを 1-2 subagent（`task` tool）に並列で任せて統合する |
| L | モジュール単位で分割して subagent に割り当てる（実装・テストまで担当モジュール内で完結）。依存の調整と統合は自分が行う |

---

## 実装中のエスカレーション確認

`AGENTS.md` の「ADAPTIVE EXECUTION」のエスカレーションに従って tier を再評価する。
引き上げが必要と判断したら**実装を中断**し、今回の `### {m}回目` に `#### ESCALATION` を書き、最終レスポンスで `ESCALATION: {新しい tier}: {理由}` を返す。
それまでの変更は作業ブランチに残したままにする。tier の更新と計画のやり直しは orchestrate が行う。

---

## 完了条件

Plan のタスクがすべて完了し、テストがすべて通過したら OUTPUT を書き込む。変更はコミットしない（レビュー通過後に deploy がコミットする）。

---

## OUTPUT

TASK_FILE の `## team-implement` に `### {m}回目` として追記する（既存の回は上書きしない。`{m}` は既存の最大 + 1、初回は `1回目`。追加依頼の番号 `{n}` とは別）。作業ブランチ名を `## Meta` の `branch:` に、作業ブランチを切ったときにいたブランチを `base:` に記入する（差し戻し時・追加修正時は既存の `base:` をそのまま残す）。

```markdown
## team-implement

### {m}回目

#### 実装サマリー
- 実装したモジュール・ファイル一覧
- 主要な実装判断とその理由

#### 変更ファイル
- path/to/file.ts — 変更内容の概要

#### テスト
- テストファイルの場所
- カバレッジの概要

#### 残課題・注意点
- レビュアーへの申し送り事項

#### ESCALATION
（中断した場合のみ）{新しい tier}: {理由}
```

**[MUST]** Linear MCP `save_comment` で LINEAR_ID に実装完了コメント投稿。

