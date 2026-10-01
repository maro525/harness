---
name: startproject
description: Planning phase for a task file — read the codebase, clarify requirements, research and design, then write Brief / Design / Plan into the startproject section of TASK_FILE (or append a labeled candidate plan). Use when asked to plan, kick off, or design a task that has (or needs) a TASK_FILE.
metadata:
  phase: startproject
  writes: "## startproject"
---

# startproject

計画フェーズ（PHASE 1〜3）を担当する。成果物は TASK_FILE の `## startproject` に**自分で書き込む**。
このフェーズでは作業ツリーのファイルを TASK_FILE 以外変更しない（コードは書かない）。コードベースを読む・git 履歴を見る・テスト構造を確認するのは自分で行う。

## Input

```
$ARGUMENTS: "{task description} --task-file={TASK_FILE} [--tier=S|M|L] [--linear-id={LINEAR_ID}] [--label={実行者名}]"
```

| 引数 | 説明 |
|---|---|
| `--task-file` | **必須**。存在しなければ「TASK_FILE の新規作成」のテンプレートから作る |
| `--tier` | 省略時は `## Meta` の `tier:`、それも無ければ S |
| `--linear-id` | 省略時は `## Meta` の `linear_id:`。無い／`NOLINEAR` なら Linear には投稿しない |
| `--label` | 実行者名（例 `{ai}/{model}`）。あれば**候補モード**（`### 案 {k}` を追記し、見出しの直下に `利用AI: {label}（{日時}）` を書く）、なければ**上書きモード**（`### Brief` / `### Design` / `### Plan` を書く） |

### tier の意味

| tier | 目安 |
|---|---|
| XS | 1 ファイル・ロジック変更なし |
| S | 1〜3 ファイル・単一パターン |
| M | 4〜10 ファイル・複数パターン |
| L | 10 ファイル以上・アーキテクチャ変更 |

Hard Trigger（DB スキーマ変更・認証認可・決済・公開 API の変更・新規コア依存の追加）に当たれば自動的に L。
コードベースを読んで tier が指定より上だと分かったら、Brief にその根拠を書く（`## Meta` の `tier:` は書き換えない。判断は呼び出し元が行う）。

## 書き込み規約

- 書くのは `## startproject` の中だけ。**`## Meta` の `status:` は絶対に書かない**。`branch:` / `base:` にも触らない。`## startproject` の外には何も追記しない
- `##` 見出しを増やさない（かんばんが `##` 見出しで列を判定する。`###` 以下は自由）
- 見出しに実行者名や日時を入れない（`### 案 {k}` のまま）。実行者は見出しの**すぐ下の行**（空行を挟まない）に `利用AI: {label}（{YYYY-MM-DD HH:MM}）` と書く。`--label` が無ければこの行は書かない（自分の名前を推定して書かない）
- 節の中に「どの経路で・どのツールから実行されたか」の説明は書かない（実行者は `利用AI:` の行だけで示す）
- 日時は `date '+%Y-%m-%d %H:%M'` の形式。呼び出し元がプロンプトで日時を渡していればその値を使い、無ければ `date` で取る（推定でつくらない）

| モード | 書き方 |
|---|---|
| 候補モード（`--label` あり） | `## startproject` の**末尾**に `### 案 {k}` を追記し、直下に `利用AI: {label}（{YYYY-MM-DD HH:MM}）`、その下に `#### Brief` / `#### Design` / `#### Plan`。k は既存の `### 案 {k}` の最大 + 1（初回は 1）。既存の `### Brief` / `### Design` / `### Plan` と他の `### 案` には触らない（採用・昇格と `採用:` の行は呼び出し元が書く） |
| 上書きモード（`--label` なし） | `### Brief` / `### Design` / `### Plan` を書く（既にあれば上書き）。既存の `### 案 {k}` は残す |

候補モードの形:

```markdown
### 案 {k}
利用AI: {label}（{YYYY-MM-DD HH:MM}）

#### Brief
…

#### Design
…

#### Plan
…
```

### TASK_FILE の新規作成

`--task-file` のパスにファイルが無いときだけ、次のテンプレートで作成してから自分の節を書く（`status: planning` を書くのはこの作成時だけ）。

```markdown
# Task: {LINEAR_ID} — {task description}

## Meta
- linear_id: {LINEAR_ID または NOLINEAR}
- tier: {tier}
- created: {YYYY-MM-DD HH:MM}
- status: planning
- branch:
- base:

## startproject
## team-implement
## team-review
## deploy
```

### 再実行時の上書き（上書きモードのみ）

以下のいずれかで再実行された場合は、既存の `### Brief` / `### Design` / `### Plan` を追記ではなく書き直す。

| 再実行の経路 | 見分け方 |
|---|---|
| エスカレーション後 | `## team-implement` の最新回に `#### ESCALATION` がある |
| 追加修正の再設計 | task description に `（再設計: 追加依頼 {n}: …）` が含まれる |

再設計で再実行された場合:

- 書き直す前に既存の `## startproject`、`### Plan` 末尾の `#### 追加依頼 {n}`、`## team-implement` / `## team-review` / `## deploy` を読み、**既存 PR で実装済みの部分**と**追加依頼の内容**を把握する
- Plan では実装済みの項目にその旨を書き、追加依頼を含む再設計分が実装対象だと分かるようにする
- `#### 追加依頼 {n}` は自分では書かない（上書きで消えてよい。呼び出し元が `### Plan` 末尾に再掲する）
- `## Meta` の `branch:` / `base:` と `## team-implement` 以降の節には触らない

## 対話と外部ツール

- ユーザーに質問できる環境なら質問してよい。できない（非対話実行・応答が返らない）なら止まらず妥当な推定で続行し、置いた前提を Brief の `**前提（推定）**` 項目に残す
- サブエージェント・Web 検索・設計相談・Linear 連携は「使えるなら使う、無ければ自分で行い、その旨を Design に書く」。再試行やモデルの差し替えはしない
- Linear: 連携ツールがあれば LINEAR_ID に計画完了コメントを投稿し、無ければ投稿しない。Linear のステータスは変えない

## PHASE 1: UNDERSTAND

1. コードベースを読む（構造・既存パターン・関連コード・テスト構造・git 履歴。`git log --oneline -20` など読み取り系のみ）
2. 要件を確認する（目的・スコープ・技術要件・成功基準・最終形）。質問できなければ推定して続行する
3. プロジェクト概要書（Brief）を作る
   - `**Current State**` / `**Goal**` / `**Scope**` / `**Constraints**` / `**Success Criteria**`
   - 確認（または推定）で決まった要件は、理由も添えて Scope / Constraints に書く
   - 推定した前提があれば `**前提（推定）**` 項目にまとめる

## PHASE 2: RESEARCH & DESIGN

Design に書く内容: **採用した方針とその理由** / **検討して却下した案** / **主要な変更ファイル**。外部ファイルは作らない。全 tier で書く。

| tier | 進め方 |
|---|---|
| S | リサーチはしない。PHASE 1 の理解から方針を 1〜2 行で書く |
| M | 設計相談（サブエージェントや別モデルへの相談）が使えれば行い、結果を統合して書く。使えなければ自分で設計し「設計相談不可: {理由}」と書く |
| L | 外部リサーチ（公式ドキュメント・リリースノートを出典 URL 付きで）と設計を行う。Web 検索が使えなければ自分の知識で設計し「外部リサーチ不可: {理由}」と書く |

リサーチ結果と自分の理解が食い違ったら、**出典のある一次情報を優先**し、相違点と採用した方を Design に残す。

## PHASE 3: PLAN

1. 実装タスクリストを番号付きで作る（順序・依存・変更ファイル・テスト方針が分かる粒度）
2. **[MUST]** 「書き込み規約」に従って TASK_FILE に Brief / Design / Plan を書き込む
3. Linear 連携ツールがあれば、LINEAR_ID に計画完了コメント（Brief の要約・Plan の項目数・Gate 1 の結果）を投稿する
4. 承認フロー（Gate 1）を自己判断する

### Gate 1（承認判断）

**自動承認（`gate1: auto-approved`）:** タスクの解釈が一意で、実装方針に選択肢がなく自明。

**Gate 1 発動:** 次のいずれかに当たる。

- タスクの解釈が複数考えられる
- 実装方針に大きなトレードオフがある（例: 既存コードの大幅変更 vs 新規作成）
- スコープが曖昧で確認が必要
- tier=L かつリスクが高い

| 環境 | 動作 |
|---|---|
| 質問できる（上書きモード） | 計画を日本語で提示し、判断が必要な理由と選択肢を明示して承認を待つ。承認なら `gate1: approved`、修正が入れば計画を直して `gate1: revised` |
| 候補モード（`--label` あり）または非対話環境 | 待たない。Design に `**判断が必要な点**` として選択肢と推奨を書き、`gate1: 要確認` とする |

## 最終メッセージ

最後に必ず次の形で終える（TASK_FILE に書けなかった環境では、呼び出し元がこの内容を代筆する）。

```markdown
### RESULT
- phase: startproject
- task_file: {絶対パス}
- written: yes | no（理由）
- section: `## startproject` > `### 案 {k}` または `### Brief / ### Design / ### Plan`
- linear: posted | 未投稿（理由）
- gate1: auto-approved | approved | revised | 要確認

### SECTION
{書いた節を見出し（### …）から丸ごとそのまま。written: no のときも必ず出す}
```
