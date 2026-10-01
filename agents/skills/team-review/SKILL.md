---
name: team-review
description: Review phase of a task file workflow. Reads the task file's Brief, Design and latest team-implement entry, reviews the uncommitted changes on the work branch from Quality/Logic, Security and Simplify viewpoints, runs tests or a browser check, and appends a PASS/FAIL entry to the team-review section. Use when asked to review an implementation recorded in a task file.
metadata:
  phase: team-review
  writes: "## team-review"
---

# team-review

レビューフェーズを担当。TASK_FILE の `## team-implement` に記録された実装を、作業ブランチ上の未コミット変更として読み、判定を `## team-review` に自分で書き込む。

**レビュー中はコードを変更しない。** 書くのは TASK_FILE の `## team-review` だけ。修正は差し戻し後に team-implement が行う。

## Input

```
$ARGUMENTS: "{task description} --task-file={TASK_FILE} [--tier=S|M|L] [--linear-id={LINEAR_ID}] [--label={実行者名}]"
```

| 引数 | 説明 |
|---|---|
| `--task-file` | **必須。** 無ければ中止して報告する |
| `--tier` | 省略時は `## Meta` の `tier:`、それも無ければ S |
| `--linear-id` | 省略時は `## Meta` の `linear_id:`。無い／`NOLINEAR` なら Linear には投稿しない |
| `--label` | 実行者名（例 `{ai}/{model}`）。見出しの直下の `利用AI:` 行に書く。呼び出し元が付ける。直接呼ぶときは省略可 |

## 書き込み規約

- 書くのは `## team-review` の節だけ。`## Meta` の `status:` は**絶対に書かない**。`##` 見出しは増やさない（kanban が `##` 見出しで列を判定する。`###` 以下は自由）。`## team-review` の外には何も追記しない
- 既存の回は上書きしない。`## team-review` の**末尾**に追記する
- 見出しは `### {m}回目`。見出しに実行者名や日時を入れない。`{m}` は `## team-implement` の最新回の番号（無ければ 1）。同じ m を別の実行者が再レビューしてよく、同じ見出しが既にあってもそのまま並べる（区別は次の `利用AI:` の行で付ける）
- `--label` があれば見出しの**すぐ下の行**（空行を挟まない）に `利用AI: {label}（{YYYY-MM-DD HH:MM}）` を書く。無ければこの行は書かない（自分の名前を推定して書かない）
- 節の中に「どの経路で・どのツールから実行されたか」の説明は書かない（実行者は `利用AI:` の行だけで示す）
- **FAIL でも必ず書く**（差し戻し履歴を残すため）
- 日時は `date '+%Y-%m-%d %H:%M'` の形式。呼び出し元がプロンプトで日時を渡していればその値を使い、無ければ `date` で取る（推定でつくらない）

## 対話・外部ツール

- ユーザーに質問できる環境なら質問してよい。できない（非対話実行）なら止まらず妥当な推定で続行し、置いた前提を節内に `#### 前提（推定）` として残す
- サブエージェント・ブラウザ・Linear 連携は「使えるなら使う、無ければ自分で行い、その旨を節に書く」。再試行やモデル差し替えはしない
- Linear: 連携ツールがあれば `LINEAR_ID` にレビュー結果コメントを投稿し、無ければ投稿しない。Linear のステータスは変えない

---

## 事前準備

レビュー開始前に必ず以下を読む。

1. TASK_FILE の `## startproject` > `### Brief` — スコープ・成功基準
2. TASK_FILE の `## startproject` > `### Design` — 設計方針・意図
3. TASK_FILE の `## team-implement` の最新回 — 実装サマリー・申し送り事項（差し戻し後は前回の `## team-review` の critical / major 指摘が直っているかも確認する）
4. 変更ファイル一覧 — 作業ブランチ上の**未コミット**変更（team-implement はコミットしない）

```bash
git branch --show-current          # `## Meta` の branch: と違えば git switch {branch} してから
git status --porcelain
git diff                           # 追跡済みファイルの差分。未追跡ファイルは個別に読む
```

ブランチの切り替えは「レビュー中はコードを変更しない」の唯一の例外（レビュー対象を揃えるため）。未コミット変更があって切り替えられない場合は、stash や破棄をせず中止して報告する。

レビュー対象から除くもの（除いた旨と理由を節に書く）:

- TASK_FILE 自体
- スコープ外の未コミット変更（Brief の対象外のファイル。別タスクの持ち越し変更など）

変更の性質を判定する（複数該当可）:

| 性質 | 判定基準 | 検証方法 |
|---|---|---|
| ブラウザ表示系 | UI コンポーネント・CSS・レイアウト変更を含む | ブラウザで表示確認 |
| ロジック系 | ビジネスロジック・API・データ処理を含む | テスト実行 |

---

## STEP 1: コードレビュー（観点別・順次）

並列レビュアーは使わず、**同一モデルで観点を分けて順に**レビューする。tier で観点の数を切り替える。

| tier | 観点 |
|---|---|
| S | Quality / Logic |
| M | Quality / Logic、Security |
| L | Quality / Logic、Security、Simplify |

各観点で、指摘を severity（critical / major / minor）付きで列挙する。

### Quality / Logic

変更ファイルを直接読み、正しさ・可読性・既存パターンとの整合・テストの妥当性を見る。

サブエージェント（別コンテキスト）が使えれば、同じ観点のセカンドオピニオンを 1 回だけ取ってよい。変更内容が長いのでプロンプトはファイルに落として渡す。使えない・エラー・空返却なら再試行せず `##### セカンドオピニオン` に「セカンドオピニオン不可: {理由}」と書く。

### Security（tier M 以上）

以下のチェックリストを変更コードに照合し、違反・懸念を severity 付きで列挙する。

- [ ] API キー・パスワード等の秘密情報がハードコードされていない（環境変数から取得）
- [ ] 外部入力（リクエスト・ファイル・環境変数）を検証している
- [ ] SQL は文字列連結でなくパラメータ化クエリ
- [ ] ユーザー入力を HTML に埋め込む前にエスケープしている（テンプレートの自動エスケープが有効）
- [ ] エラーメッセージが接続文字列・内部パスなど攻撃者に有用な情報を含まない（詳細はログへ）
- [ ] ログに秘密情報・個人情報を出していない
- [ ] 新しい依存はバージョンを固定している（`==`）。不要な依存を増やしていない

### Simplify（tier L）

変更ファイルを読み、過剰な複雑さ・重複・再利用できる既存コードの観点で指摘する。**コードは書き換えない**（指摘のみ）。

---

## STEP 2: 統合

- 重複する指摘は 1 件にまとめ、severity を引き上げる
- 矛盾する指摘はより厳しい方を採用する
- minor 指摘はまとめて申し送り事項へ

---

## STEP 3: 動作検証

変更の性質に応じて実行する（両方該当なら両方）。

- **ブラウザ表示系:** 対象ページを開いて操作し、各状態を確認する。使うツールは問わない。ブラウザを操作できる環境でなければ「未実施: {理由}」と書く
- **ロジック系:** プロジェクトのテストを実行し、新規実装に対応するテストがあるかも確認する。テストが無い・実行できない場合は「未実施: {理由}」と書く

---

## STEP 4: 判定

統合レビュー結果と動作検証結果をもとに判定する。

| severity | 定義 | 判定への影響 |
|---|---|---|
| critical | セキュリティ脆弱性・データ破損リスク・テスト失敗 | FAIL 確定 |
| major | バグ・大きな設計問題・表示崩れ | FAIL |
| minor | 改善提案・命名・スタイル・リファクタリング推奨 | PASS（申し送りとして記録） |

- **PASS** — critical / major がゼロ
- **FAIL** — critical または major が 1 件以上

---

## STEP 5: 書き込み

**[MUST]** TASK_FILE の `## team-review` の末尾に以下を追記する（FAIL でも必ず書く）。

```markdown
### {m}回目
利用AI: {label}（{YYYY-MM-DD HH:MM}）

#### 判定: PASS / FAIL

#### 前提（推定）
（非対話実行で推定した前提があるときのみ）

#### コードレビュー統合結果

##### Quality / Logic
- [severity] 指摘内容

##### セカンドオピニオン
- [severity] 指摘内容（取れなかった場合は「セカンドオピニオン不可: {理由}」）

##### Security
- [severity] 指摘内容（tier S では「対象外」）

##### Simplify
- [severity] 指摘内容（tier S / M では「対象外」）

##### 統合サマリー
- 複数観点で共通の指摘（severity 引き上げ）
- 個別の指摘
- レビュー対象から除いたファイルとその理由

#### 動作検証結果

##### ブラウザ表示確認（該当時）
- 確認したページ・状態
- 問題点（あれば）／未実施: {理由}

##### テスト実行結果（該当時）
- 実行コマンド
- 結果サマリー
- 失敗したテスト（あれば）

#### 申し送り事項（minor）
- deploy フェーズへの注意点
- リファクタリング推奨（次タスクで対応）
```

**[MUST]** Linear 連携ツールがあれば `LINEAR_ID` に PASS / FAIL とサマリーをコメント投稿する（ステータスは変えない）。

---

## 最終メッセージ

必ずこの形で終える。TASK_FILE に書けなかった場合（サンドボックス等）は `written: no` とし、呼び出し元が `SECTION` の内容を代筆する。

```markdown
### RESULT
- phase: team-review
- task_file: {絶対パス}
- written: yes | no（理由）
- section: `## team-review` > `### {m}回目`
- linear: posted | 未投稿（理由）
- verdict: PASS | FAIL

### SECTION
{書いた節を見出し（### …）から丸ごとそのまま。written: no のときも必ず出す}
```
