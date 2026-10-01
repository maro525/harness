---
name: team-review
description: Review phase — parallel reviewers by tier (S: Claude / M: +OpenCode, Security / L: +Simplify), browser check or test execution; returns a review payload. The caller writes TASK_FILE and posts to Linear. Called by /orchestrate with tier, task-file, linear-id.
context: fork
agent: general-purpose
model: opus
color: yellow
allowed-tools: Read, Write, Bash, Grep, Glob, Agent, Skill, AskUserQuestion, TodoWrite, mcp__linear-server__get_issue
---

# team-review

## 今回の引数

$ARGUMENTS

（引数の置き場所はここだけ。本文の「引数」はこの値を指す。Agent ツール経由で起動された場合は、プロンプトの `ARGUMENTS:` 行が引数）

レビューフェーズを担当。

**TASK_FILE への書き込みと Linear への投稿は行わない。** 結果は OUTPUT フォーマットで呼び出し元（`/orchestrate` STEP 5）に返し、TASK_FILE の更新・Linear コメント投稿は呼び出し元が行う。TASK_FILE は Read のみ。

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

レビュー開始前に必ず以下を読む。

1. TASK_FILE の `## startproject` > `### Brief` — スコープ・成功基準
2. TASK_FILE の `## startproject` > `### Design` — 設計方針・意図
3. TASK_FILE の `## team-implement` の最新回 — 実装サマリー・申し送り事項（差し戻し後は前回の `## team-review` の指摘が直っているかも確認する）
4. 変更ファイル一覧（作業ブランチ上の未コミット変更。team-implement はコミットしない）

変更の性質を判定する（複数該当可）:

| 性質 | 判定基準 | 検証方法 |
|---|---|---|
| ブラウザ表示系 | UI コンポーネント・CSS・レイアウト変更を含む | ブラウザで表示確認 |
| ロジック系 | ビジネスロジック・API・データ処理を含む | テスト実行 |

## STEP 1: コードレビュー（並列）

tier に応じたレビュアーを同時に起動する。**レビュー中はコードを変更しない**（修正は差し戻しで team-implement が行う）。

| tier | レビュアー |
|---|---|
| S | Claude |
| M | Claude / OpenCode / Security |
| L | Claude / OpenCode / Security / Simplify |

S は orchestrate から Agent ツール経由（sonnet）で起動されるため、Claude レビュアーは自分が担当し、Agent ツールは使わない（orchestrate.md「tier 別のフェーズ構成」）。

| レビュアー | 方法 |
|---|---|
| Claude | 変更ファイルを直接読み、Quality / Logic の観点でレビュー |
| OpenCode | 下記。観点は Claude と同じ（別モデルによるセカンドオピニオン） |
| Security | `$HOME/.claude/rules/security.md` のルールを変更コードに照合し、違反・懸念を severity 付きで列挙 |
| Simplify | 変更ファイルを読み、過剰な複雑さ・重複・再利用できる既存コードの観点で指摘する（`/simplify` はコードを書き換えるので使わない） |

### OpenCode Reviewer

変更内容が長いのでプロンプトはファイルに落として渡す。呼び出し方・待ち方・失敗時の扱いは `$HOME/.claude/rules/tool-routing.md` の「OpenCode リサーチの実行」に従う。呼べなければこのレビュアーは飛ばし、結果に「OpenCode 不可: {理由}」と書く。

```bash
timeout -k 1m 20m opencode run --agent plan -m github-copilot/gpt-5.6-sol "$(cat {prompt_file})" < /dev/null
```

プロンプトの中身:
```
DO NOT USE ANY TOOLS.
以下のコード変更をレビューしてください。Quality / Logic の観点で問題点と改善提案を列挙してください。

{変更ファイルの内容}
```

## STEP 2: 統合

- 重複する指摘は 1 件にまとめ、severity を引き上げる
- 矛盾する指摘はより厳しい方を採用
- minor 指摘はまとめて申し送り事項へ

## STEP 3: 動作検証

変更の性質に応じて実行する（両方該当なら両方）。

- **ブラウザ表示系:** 対象ページを開いて操作し、各状態のスクリーンショットを記録する。使うツールは問わない
- **ロジック系:** プロジェクトのテストを実行し、新規実装に対応するテストがあるかも確認する

## STEP 4: 判定

統合レビュー結果と動作検証結果をもとに判定する。

| severity | 定義 | 判定への影響 |
|---|---|---|
| critical | セキュリティ脆弱性・データ破損リスク・テスト失敗 | FAIL 確定 |
| major | バグ・大きな設計問題・表示崩れ | FAIL |
| minor | 改善提案・命名・スタイル・リファクタリング推奨 | PASS（申し送りとして記録） |

- **PASS** — critical / major がゼロ
- **FAIL** — critical または major が 1 件以上

## OUTPUT

以下のフォーマットを最終レスポンスとしてそのまま返す。

```markdown
### VERDICT
PASS | FAIL

### REVIEW

#### コードレビュー統合結果

##### Claude Reviewer
- [severity] 指摘内容

##### OpenCode Reviewer
- [severity] 指摘内容

##### Security Reviewer
- [severity] 指摘内容（security.md ルール参照）

##### Simplify Reviewer
- [severity] 指摘内容

##### 統合サマリー
- 複数レビュアー共通の指摘（severity 引き上げ）
- 個別の指摘

#### 動作検証結果

##### ブラウザ表示確認（該当する場合）
- 確認したページ・状態
- 問題点（あれば）

##### テスト実行結果（該当する場合）
- 実行コマンド
- 結果サマリー
- 失敗したテスト（あれば）

#### 申し送り事項（minor）
- deploy フェーズへの注意点
- リファクタリング推奨（次タスクで対応）

### LINEAR_COMMENT
（Linear に投稿するレビュー結果コメント本文。PASS/FAIL + サマリー）
```
