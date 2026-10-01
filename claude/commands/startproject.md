---
name: startproject
description: Project kickoff — understand codebase, research/design, return a plan payload. Read-only; the caller performs all writes. Called by /orchestrate with tier, task-file, linear-id.
context: fork
agent: Plan
model: best
color: red
allowed-tools: Read, Bash, Grep, Glob, AskUserQuestion, TodoWrite, mcp__linear-server__get_issue, mcp__firecrawl__firecrawl_search, mcp__firecrawl__firecrawl_scrape, mcp__firecrawl__firecrawl_map
---

# startproject

## 今回の引数

$ARGUMENTS

（引数の置き場所はここだけ。本文の「引数」はこの値を指す。Agent ツール経由で起動された場合は、プロンプトの `ARGUMENTS:` 行が引数）

計画フェーズ（Phase 1–3）を担当。

**読み取り専用（`agent: Plan`）。** Write / Edit / Agent が無いため、TASK_FILE への書き込み・Linear への投稿・サブエージェント（Agent ツール）の起動は行わない。成果物は OUTPUT フォーマットで呼び出し元（`/orchestrate`）に返し、**書き込みと Linear 投稿は呼び出し元が行う**。

`agent: Plan` では CLAUDE.md が自動ロードされない。必要なら `Read` で `$HOME/.claude/CLAUDE.md` とプロジェクトの `CLAUDE.md` を読む。

## Input

```
引数の形式: "{task description} --tier={S|M|L} --task-file={TASK_FILE} --linear-id={LINEAR_ID}"
```

| 引数 | 説明 |
|---|---|
| `--tier` | orchestrator が判定済み |
| `--task-file` | orchestrator が作成済みのタスクファイルパス（Read のみ） |
| `--linear-id` | orchestrator が確認済みの Linear タスク ID |

## PHASE 1: UNDERSTAND

1. コードベースを読む（構造・既存パターン・関連コード・テスト構造・git 履歴）
2. 要件ヒアリング（目的・スコープ・技術要件・成功基準・最終デザイン）
3. プロジェクト概要書を作成し OUTPUT の `BRIEF` に含める
   - Current State / Goal / Scope / Constraints / Success Criteria
   - ヒアリングで決まった要件は、理由も添えて Scope / Constraints に書く

## PHASE 2: RESEARCH & DESIGN

成果物はすべて OUTPUT の `DESIGN` に含める（採用した方針とその理由 / 検討して却下した案 / 主要な変更ファイル）。ファイルは作成しない。
Agent ツールが無いため、リサーチはサブエージェント経由ではなく**直接実行する**（`context: fork` でコンテキストは隔離済み）。

引数に「opencodeに相談」「opencode相談」「opencodeで設計」等のキーワードがあれば、tier に関係なく OpenCode に相談する。それ以外は tier で切り替える。

### tier=S
`/orchestrate` の通常フローでは S で startproject は呼ばれない（orchestrate が自分で計画する）。直接呼ばれた場合はリサーチはしない。Phase 1 の理解から方針を 1-2 行で `DESIGN` に書いて Phase 3 へ進む。

### tier=M
OpenCode に設計相談する（Bash から直接実行）。呼び出し方・待ち方・失敗時の扱いは `$HOME/.claude/rules/tool-routing.md` の「OpenCode リサーチの実行」に従う。呼べなければ OpenCode なしで設計し、`DESIGN` に「OpenCode 不可: {理由}」と書く。

### tier=L
二系統を**同時に開始**する（firecrawl の呼び出しと opencode のバックグラウンド起動を同一メッセージで出す）。

| 系統 | 実行方法 | 役割 |
|---|---|---|
| 一次情報 | firecrawl MCP（`firecrawl_search` → `firecrawl_scrape`） | 公式ドキュメント・リリースノートを出典 URL 付きで調査 |
| 実装知見 | `timeout -k 1m 20m opencode run --agent plan -m github-copilot/gpt-5.6-sol "{question}" < /dev/null`（background Bash） | 設計上の勘所・落とし穴を調査 |

結果はファイルに保存せず統合して `DESIGN` にまとめる。**食い違いは firecrawl の一次情報を優先**し、相違点と採用した方を `DESIGN` に残す。

## PHASE 3: PLAN

1. 実装タスクリストを作成する。`TodoWrite` を使ってよいがフォーク終了時に消えるため、**必ず OUTPUT の `PLAN` にテキストとして含める**
2. Linear への計画完了コメント本文を作成し、OUTPUT の `LINEAR_COMMENT` に含める（投稿は呼び出し元）
3. 承認フローを自己判断する

**自動承認 → 呼び出し元へ即返す:** タスクの解釈が一意で、実装方針に選択肢がなく自明

**Gate 1 発動 → ユーザー承認を待つ:**
- タスクの解釈が複数考えられる
- 実装方針に大きなトレードオフがある（例: 既存コード大幅変更 vs 新規作成）
- スコープが曖昧で確認が必要
- tier=L かつリスクが高い

Gate 1 発動時は `AskUserQuestion` で計画を日本語で提示し、**判断が必要な理由と選択肢を明示**して承認を求める。承認されたら即呼び出し元へ返す。差し戻しならフィードバックをもとに計画を修正する。

## OUTPUT

以下のフォーマットを最終レスポンスとしてそのまま返す。

```markdown
### BRIEF
（Current State / Goal / Scope / Constraints / Success Criteria）

### DESIGN
（採用した方針と理由 / 却下した案 / 主要な変更ファイル。tier=S は1-2行）

### PLAN
1. ...
2. ...

### LINEAR_COMMENT
（Linear に投稿する計画完了コメント本文）

### GATE1
auto-approved | approved | revised
```
