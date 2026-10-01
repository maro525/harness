---
name: team-implement
description: Implementation phase for a task file — read Brief / Design / Plan, work on a feature branch with tests first, then append an implementation report to the team-implement section of TASK_FILE without committing. Use when asked to implement a planned task or fix review findings recorded in a TASK_FILE.
metadata:
  phase: team-implement
  writes: "## team-implement / ## Meta の branch: と base:"
---

# team-implement

実装フェーズを担当する。TASK_FILE の `## startproject` に沿ってコード（実装・テスト）を書き、作業ブランチの作成も自分で行う。
結果は TASK_FILE の `## team-implement` に**自分で書き込む**。**コミットはしない**（レビュー通過後に deploy が行う）。

## Input

```
$ARGUMENTS: "{task description} --task-file={TASK_FILE} [--tier=S|M|L] [--linear-id={LINEAR_ID}] [--label={実行者名}]"
```

| 引数 | 説明 |
|---|---|
| `--task-file` | **必須**。存在しなければ中止して報告する（計画フェーズが先） |
| `--tier` | 省略時は `## Meta` の `tier:`、それも無ければ S |
| `--linear-id` | 省略時は `## Meta` の `linear_id:`。無い／`NOLINEAR` なら Linear には投稿しない |
| `--label` | 実行者名（例 `{ai}/{model}`）。見出しの直下の `利用AI:` 行に書く。直接呼ぶときは省略可 |

## 書き込み規約

- 書くのは `## team-implement` と、`## Meta` の `branch:` / `base:` だけ。**`## Meta` の `status:` は絶対に書かない**。それ以外の場所には何も追記しない
- `##` 見出しを増やさない（かんばんが `##` 見出しで列を判定する。`###` 以下は自由）
- `## team-implement` の**末尾**に `### {m}回目` を追記する。見出しに実行者名や日時を入れない。m は既存の `### {m}回目` の最大 + 1（初回は 1）。追加依頼の番号 `{n}` とは別に数える
- `--label` があれば見出しの**すぐ下の行**（空行を挟まない）に `利用AI: {label}（{YYYY-MM-DD HH:MM}）` を書く。無ければこの行は書かない（自分の名前を推定して書かない）
- 節の中に「どの経路で・どのツールから実行されたか」の説明は書かない（実行者は `利用AI:` の行だけで示す）
- 既存の回は上書きしない
- 日時は `date '+%Y-%m-%d %H:%M'` の形式。呼び出し元がプロンプトで日時を渡していればその値を使い、無ければ `date` で取る（推定でつくらない）

## 対話と外部ツール

- ユーザーに質問できる環境なら質問してよい。できない（非対話実行・応答が返らない）なら止まらず妥当な推定で続行し、置いた前提を今回の回の `#### 前提（推定）` に残す
- サブエージェント・Linear 連携は「使えるなら使う、無ければ自分で行い、その旨を節に書く」。再試行やモデルの差し替えはしない
- Linear: 連携ツールがあれば LINEAR_ID に実装完了コメントを投稿し、無ければ投稿しない。Linear のステータスは変えない

## 事前準備

実装開始前に必ず TASK_FILE の以下を読む。

1. `## startproject` > `### Brief` — 概要・スコープ・成功基準
2. `## startproject` > `### Design` — 設計方針とその理由
3. `## startproject` > `### Plan` — 実装タスクリスト
4. `### Plan` 末尾の `#### 追加依頼 {n}`（追加修正時のみ存在）— その「前提」行に従う。既存 PR で実装済みの部分は実装しない
5. `## team-review`（差し戻し時のみ存在）— 最新回の critical / major 指摘。**これの修正を最優先する**
6. `## Meta` の `branch:` / `base:` — 作業ブランチの有無

`### Brief` / `### Design` / `### Plan` が無く `### 案 {k}` だけがある場合は、候補が未採用なので中止して報告する（採用は呼び出し元が行う）。

## ブランチ

| `## Meta` の `branch:` | 動作 |
|---|---|
| あり（差し戻し・追加修正） | そのブランチに切り替えて使う。`base:` は既存の値を残す |
| なし | 現在のブランチを base として `git checkout -b feature/{短い名前}` で作成する |

- **main / master / release / staging 上では作業しない。** そこにいたら必ず feature ブランチを切る
- 切り替え前後で作業ツリーにスコープ外の未コミット変更があっても触らない（stash・破棄・巻き込みをしない）

## IMPLEMENTATION

テストを先に書く（TDD）。tier によって体制を切り替える。

| tier | 体制 |
|---|---|
| S | 自分で実装する |
| M | 自分で実装する。サブエージェントが使えれば、独立したモジュールを 1〜2 個並列に任せて統合してもよい |
| L | モジュール単位で分割し、サブエージェントが使えれば各モジュールを割り当てる（実装・テストまで担当モジュール内で完結）。依存の調整と統合は自分が行う。使えなければ自分で順に実装する |

実装中の原則:

- Plan の順序と Design の方針に従う。方針を変える必要が出たら、変えた理由を `#### 実装サマリー` に書く
- 差し戻し時は critical / major の修正を先に済ませ、前回の指摘ごとに対応内容を `#### 実装サマリー` に書く
- TASK_FILE のスコープ外のファイルは変更しない

### エスカレーション

実装中に次のいずれかに当たったら tier を引き上げる必要がある。

- 変更ファイル数が tier の上限（S: 3、M: 10）を超える
- 未解決の設計上の質問が積み上がる
- 新規依存（ライブラリ・サービス）の追加が必要になる
- Hard Trigger（DB スキーマ変更・認証認可・決済・公開 API の変更）に触れた

該当したら**実装を中断**し、今回の `### {m}回目` に `#### ESCALATION` を書き、最終メッセージの `escalation:` に新しい tier と理由を書く。それまでの変更は作業ブランチに残したままにする。tier の更新と計画のやり直しは呼び出し元が行う。

### 完了条件

Plan のタスクがすべて完了し、テストがすべて通過したら書き込みへ進む。**変更はコミットしない。**

## 書き込み

**[MUST]** `## team-implement` の末尾に今回の回を追記し、`## Meta` の `branch:` に作業ブランチ、`base:` に分岐元を記入する（差し戻し・追加修正では既存の `base:` をそのまま残す）。

```markdown
### {m}回目
利用AI: {label}（{YYYY-MM-DD HH:MM}）

#### 実装サマリー
- 実装したモジュール・ファイル一覧
- 主要な実装判断とその理由
- （差し戻し時）前回の critical / major 指摘への対応

#### 変更ファイル
- path/to/file — 変更内容の概要

#### テスト
- テストファイルの場所
- 実行コマンドと結果（通過数・失敗数）

#### 残課題・注意点
- レビュアーへの申し送り事項

#### 前提（推定）
（質問できずに推定した前提があるときだけ）

#### ESCALATION
（中断した場合のみ）{新しい tier}: {理由}
```

Linear 連携ツールがあれば、LINEAR_ID に実装完了コメント（実装サマリー・変更ファイル数・テスト結果・ブランチ名）を投稿する。

## 最終メッセージ

最後に必ず次の形で終える（TASK_FILE に書けなかった環境では、呼び出し元がこの内容を代筆する）。

```markdown
### RESULT
- phase: team-implement
- task_file: {絶対パス}
- written: yes | no（理由）
- section: `## team-implement` > `### {m}回目`
- linear: posted | 未投稿（理由）
- branch: {branch}
- base: {base}
- escalation: なし | {新しい tier}: {理由}

### SECTION
{書いた節を見出し（### …）から丸ごとそのまま。written: no のときも必ず出す}
```
