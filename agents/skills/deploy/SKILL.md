---
name: deploy
description: Deploy phase of a task file workflow. Commits the reviewed changes on the work branch, pushes it, creates a PR/MR with gh or glab (or pushes to and annotates an existing open PR/MR), and records the result in the deploy section of the task file. Stays on the work branch and leaves the task file uncommitted; committing it and returning to the base branch is left to the caller. Use when a task file's team-review is PASS and the change is ready to become a pull/merge request.
metadata:
  phase: deploy
  writes: "## deploy"
---

# deploy

デプロイフェーズを担当。コミット・push・PR / MR 作成を行い、結果を TASK_FILE の `## deploy` に自分で書き込む。動作検証は team-review で済んでいるので行わない。

**終了後も作業ブランチに留まる**（分岐元には戻らない）。TASK_FILE 自体はコミットせず、作業ブランチ上に未コミットのまま残す。TASK_FILE の `docs(task):` コミット → 同じブランチへの push → 分岐元への復帰は**呼び出し元が行う**（手動で実行したときは自分で行う）。TASK_FILE を gitignore していないリポジトリでは、そのコミットが PR / MR に載る（公開したくなければ `.claude/` を `.gitignore` に入れておく）。

前提: 作業ブランチ作成済み・team-review PASS 済み。作業ブランチに open な PR / MR が既にあれば、新規作成せず**追加 push と本文追記**を行う。

このスキルは Deploy Workflow のみを持つ。単発の git 操作（アドホックなコミット・ブランチ操作）には使わない。

## Input

```
$ARGUMENTS: "{task description} --task-file={TASK_FILE} [--tier=S|M|L] [--linear-id={LINEAR_ID}] [--label={実行者名}]"
```

| 引数 | 説明 |
|---|---|
| `--task-file` | **必須。** 無ければ中止して報告する |
| `--tier` | 省略時は `## Meta` の `tier:`、それも無ければ S |
| `--linear-id` | 省略時は `## Meta` の `linear_id:`。無い／`NOLINEAR` なら Linear には投稿しない |
| `--label` | 実行者名（例 `{ai}/{model}`）。呼び出し元が付ける。書いた見出しの直下の `利用AI:` 行に書く。直接呼ぶときは省略可 |

## 書き込み規約

- 書くのは `## deploy` の節だけ。`## Meta` の `status:` は**絶対に書かない**。`##` 見出しは増やさない（kanban が `##` 見出しで列を判定する。`###` 以下は自由）。`## deploy` の外には何も追記しない
- 新規作成型: `## deploy` に `#### PR / MR` と `#### 申し送り事項` を書く
- 追加 push 型: `## deploy` に既に PR / MR URL があれば上書きせず、末尾に `#### 追加 push（追加依頼 {n}）` を追記する（`### Plan` 末尾に `#### 追加依頼 {n}` が無ければ `#### 追加 push（{YYYY-MM-DD HH:MM}）`）
- 見出しに実行者名を入れない。`--label` があれば、書いた見出し（`#### PR / MR` または `#### 追加 push（…）`）の**すぐ下の行**（空行を挟まない）に `利用AI: {label}` を書く（日時は `- 作成日時:` / `- 日時:` の行にあるので付けない）。無ければこの行は書かない（自分の名前を推定して書かない）
- 節の中に「どの経路で・どのツールから実行されたか」の説明は書かない（実行者は `利用AI:` の行だけで示す）
- 日時は `date '+%Y-%m-%d %H:%M'` の形式。呼び出し元がプロンプトで日時を渡していればその値を使い、無ければ `date` で取る（推定でつくらない）

## git ルール

- **`main` / `master` / `release` / `staging` へ直接 commit / push しない。** 反映は必ず PR / MR 経由。作業ブランチが保護ブランチと同名なら中止して報告する
- 履歴を書き換える操作（`rebase`、`reset --hard`、force push）は**行わない**
- ホスティング CLI は `origin` の URL で判定する: GitHub → `gh`、GitLab（セルフホスト含む）→ `glab`

```bash
git remote get-url origin        # github.com → gh / それ以外の GitLab（セルフホスト含む）→ glab
```

## 対話・外部ツール

- ユーザーに質問できる環境なら質問してよい。できない（非対話実行）なら止まらず妥当な推定で続行し、置いた前提を `## deploy` に `#### 前提（推定）` として残す。**ただし下記の停止条件は推定で突破しない**（中止して報告する）
- Linear: 連携ツールがあれば `LINEAR_ID` にコメントを投稿し、無ければ投稿しない。Linear のステータスは変えない（"In Review" への変更は呼び出し元が行う）

---

## 事前準備

開始前に必ず TASK_FILE の以下を読む。

1. `## team-review` の最新回 — `#### 判定` が **PASS でなければ中止**して報告する（PR は作らない）。申し送り事項は PR 本文に使う
2. `## Meta` の `branch:` / `base:` — push する作業ブランチと、その分岐元。**`branch:` が空なら中止**して報告する
3. `## team-implement` — PR 本文とコミットメッセージに書く変更内容（新規作成なら全回。追加 push なら `#### 追加依頼 {n}` の「扱い」行に書いた開始回から最新回まで全回。差し戻しがあると追加依頼の本体は最新回より前の回にあるため、最新回だけ読まない）
4. `## deploy` の `PR/MR:` — 既存 PR / MR の URL（あれば追加 push）
5. `## startproject` > `### Plan` の末尾の `#### 追加依頼 {n}` — 追加 push の本文追記に使う番号・依頼内容と、「扱い」行の開始回（追加修正のときだけ存在する）

現在のブランチが `branch:` と違えば `git switch {branch}` してから進める。

### 既存 PR / MR の判定

`## deploy` に URL があればそれを使い、なければ作業ブランチで検索する。

```bash
gh pr list --head {branch} --state all --json number,state,url        # GitHub
glab mr list --source-branch {branch} --all                            # GitLab
```

| 結果 | 動作 |
|---|---|
| なし | 新規作成（STEP 3-A） |
| open | 追加 push（STEP 3-B）。新しい PR / MR は作らない |
| merged / closed | **中止**して報告する。追加の変更は新しいタスクとして起票する |

### 停止条件（まとめ）

以下は推定で突破せず、中止して最終メッセージに `pr: 中止（理由）` を書く。

- `--task-file` が無い／TASK_FILE が読めない
- `## team-review` の最新回が PASS でない
- `## Meta` の `branch:` が空、または保護ブランチ名
- 既存 PR / MR が merged / closed
- 追加 push でリモートとローカルが分岐している（STEP 2）

---

## STEP 1: COMMIT

作業ブランチ上の未コミット変更（team-implement の実装。レビュー通過済み）をコミットする。

- **TASK_FILE のスコープ外の変更は巻き込まない**（Brief の対象外のファイル・別タスクの持ち越し変更は `git add` しない。`git add -A` は使わずファイルを指定する）
- **TASK_FILE 自体はコミットしない**（`## deploy` はこの後 STEP 4 で書く。その記録のコミットは呼び出し元が `docs(task):` で行う）
- メッセージは `## team-implement` の内容から作る。追加 push なら本文に `追加依頼 {n}` を書く

```bash
git status --porcelain                       # 対象ファイルを確認
git add {対象ファイル...}
git commit -m "{type}({scope}): {概要}" -m "{本文}"
```

---

## STEP 2: PUSH

`branch:` のブランチを `origin` に push する。

```bash
git push -u origin {branch}
```

**追加 push の停止条件:** push 前に `git fetch origin {branch}` し、リモートがローカルの祖先でなければ push せず中止して報告する。force push・rebase で揃えない（履歴書き換え禁止）。分岐の解消はユーザーが判断する。

```bash
git fetch origin {branch}
git merge-base --is-ancestor origin/{branch} {branch}   # 偽（exit≠0）なら分岐 → 中止
```

---

## STEP 3-A: CREATE PR / MR（既存 PR / MR がない場合）

- base は `base:` のブランチ（空ならリポジトリのデフォルトブランチ）
- タイトルは `{type}({scope}): {task description}`（`{type}` は変更内容に合う Conventional Commits の型: feat / fix / refactor / docs など）

本文に含める内容:

- 変更の概要（`## team-implement` の実装サマリー）
- `## startproject` > `### Brief` の成功基準
- `## team-review` の申し送り事項（minor 指摘）
- 関連 Linear タスク: {LINEAR_ID}（あれば）

```bash
gh pr create --base {base} --head {branch} --title "{title}" --body-file body.md            # GitHub
glab mr create --target-branch {base} --source-branch {branch} --title "{title}" --description "$(cat body.md)"   # GitLab
```

---

## STEP 3-B: 既存 PR / MR に本文追記（open な PR / MR がある場合）

タイトル・base は変えない。本文の**末尾**に以下を追記する（既存の本文は消さない）。

```markdown
## 追加変更（追加依頼 {n}）
- 依頼内容: {`#### 追加依頼 {n}` の依頼内容}
- 変更の概要: {`## team-implement` の「扱い」行に書いた開始回から最新回まで全回のサマリー}
- コミット: {追加したコミットの hash}
- team-review 最終回（PASS）: {回数と申し送り事項（minor）}
```

`## team-implement` は差し戻しで複数回になることがあるので、開始回（追加依頼の本体）から最新回（差し戻し対応）まで全回を要約する。team-review は最終回（PASS）だけを書く。`#### 追加依頼 {n}` が無い場合は見出しを `## 追加変更（{YYYY-MM-DD HH:MM}）` にし、依頼内容の行は省く。

```bash
gh pr view {URL} --json body --jq .body > body.md && printf '\n{追記}\n' >> body.md && gh pr edit {URL} --body-file body.md   # GitHub
glab mr view {IID} --output json | jq -r .description > body.md && printf '\n{追記}\n' >> body.md && glab mr update {IID} --description "$(cat body.md)"   # GitLab（IID は URL 末尾の番号）
```

---

## STEP 4: 書き込みと報告

**[MUST]** 作業ブランチに留まったまま、TASK_FILE の `## deploy` を記入する（分岐元には戻らない）。

**新規作成型:**

```markdown
#### PR / MR
利用AI: {label}
- 作成日時: {timestamp}
- ブランチ: {branch} → {base}
- PR/MR: {PR/MR URL}

#### 申し送り事項
- 次タスクへの注意点
- team-review の minor 指摘（対応推奨）
```

**追加 push 型**（既存の `## deploy` は上書きせず、末尾に追記する。`#### 申し送り事項` を分けず 1 見出しにまとめる）:

```markdown
#### 追加 push（追加依頼 {n}）
利用AI: {label}
- 日時: {timestamp}
- ブランチ: {branch} → {base}（既存 PR/MR: {URL}）
- コミット: {追加したコミットの hash}
- 本文追記: 「## 追加変更（追加依頼 {n}）」
- 申し送り事項: {次タスクへの注意点・team-review 最終回（PASS）の minor 指摘}
```

非対話実行で推定した前提があれば、書いた見出し（`利用AI:` の行があればその後）の直後に `#### 前提（推定）` を添える。

**[MUST]** Linear 連携ツールがあれば `LINEAR_ID` にコメントを投稿する（ステータスは変えない）。

- 新規作成型: ブランチ URL・コミット履歴（`git log --oneline {base}..{branch}`）・team-review の結果サマリー・PR/MR リンク
- 追加 push 型: 追加依頼 {n} の内容・追加したコミット・team-review 最終回（PASS）の結果サマリー・PR/MR リンク

---

## 最終メッセージ

必ずこの形で終える。TASK_FILE への書き込みは作業ブランチ上で未コミットのまま残す（コミット・push と分岐元への復帰は呼び出し元が行う）。TASK_FILE に書けなかった場合（サンドボックス等）は `written: no` とし、呼び出し元が `SECTION` の内容を代筆する。中止した場合は TASK_FILE には何も書かず、`written: no（中止）` と `pr: 中止（理由）` で返す（`SECTION` には中止理由を `### 中止` として書く。これは報告用で、呼び出し元も代筆しない）。

```markdown
### RESULT
- phase: deploy
- task_file: {絶対パス}
- written: yes | no（理由）
- section: `## deploy` > `#### PR / MR` | `#### 追加 push（…）` | `### 中止`
- linear: posted | 未投稿（理由）
- pr: {PR/MR URL} | 中止（理由）

### SECTION
{書いた節を見出し（### …）から丸ごとそのまま。written: no のときも必ず出す}
```
