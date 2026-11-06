---
name: deploy
description: Deploy phase — commit the reviewed changes, push the work branch, create the PR/MR, return a deploy payload, and stay on the work branch. The caller writes TASK_FILE and updates Linear, then returns to the base branch itself (TASK_FILEs live outside the repository and are never committed). Called by /orchestrate with tier, task-file, linear-id. Without --task-file, runs a single ad-hoc git write operation (commit / push / branch / merge etc.).
context: fork
agent: general-purpose
model: haiku
color: orange
allowed-tools: Read, Write, Edit, Bash, Grep, Glob, AskUserQuestion, TodoWrite, mcp__linear-server__get_issue
---

# deploy

## 今回の引数

$ARGUMENTS

（引数の置き場所はここだけ。本文の「引数」はこの値を指す。Agent ツール経由で起動された場合は、プロンプトの `ARGUMENTS:` 行が引数）

git は `$HOME/.claude/rules/tool-routing.md` の「Git Operations」（保護ブランチ・ホスティング CLI）に従う。

| 引数 | モード |
|---|---|
| `--task-file` あり | **Deploy Workflow モード**（コードの commit → push → PR / MR。終わっても作業ブランチに留まる） |
| `--task-file` あり | **Deploy Workflow モード**（`/orchestrate` STEP 6a から呼ばれる。終了後も作業ブランチに留まる） |
| `--task-file` なし | **Ad-hoc Git モード**（Deploy Workflow の STEP は実行しない） |

## Ad-hoc Git モード

引数で指示された書き込み系 git 操作（「Git Operations」の書き込み系）を実行する。

- 履歴を書き換える操作（rebase、`reset --hard`、force push）は実行前にユーザーに確認する
- 完了後、実行したコマンドと結果（コミットハッシュ・ブランチ名・PR/MR URL など）を日本語で簡潔に返す

### /orchestrate 由来の PR ブランチへのガード

コードを変える操作（`add` / `commit` / `push` / `merge` / `rebase` / `cherry-pick` / `revert` / `reset`）の対象ブランチが `/orchestrate` の作った PR / MR のブランチなら、実行せずに**追加修正モードを案内してユーザーに確認する**（「Git Operations」の「/orchestrate で作った PR への追加変更」）。

```bash
# 対象ブランチを branch: に持つ TASK_FILE を探す（リポジトリ外のバケットを探す）
~/.claude/scripts/task-file.sh dir
~/.claude/scripts/task-file.sh find | xargs grep -l "^- branch: {branch}$"
```

- 該当 TASK_FILE の `## deploy` に `PR/MR:` の URL があれば対象。案内文: 「このブランチは `/orchestrate` の PR {URL} のものです。追加変更は `/orchestrate "{追加の依頼} --task-file={TASK_FILE}"`（追加修正モード）で team-implement → team-review → deploy を通してください」
- ユーザーが承知のうえで Ad-hoc 実行を明示したときだけ実行し、結果にレビューを通っていない旨を添える
- 対象外（ガードなし）: コードを変えない操作（`checkout` / `switch`、`tag`、`stash list`、ブランチ削除など）と、該当 TASK_FILE が無いブランチ
- **注意:** TASK_FILE はリポジトリ外（`~/.local/share/harness/tasks/{repo}/`）にあるので、ブランチを切り替えても探索結果は変わらない。`~/.claude/scripts/task-file.sh find --linear-id={LINEAR_ID}` / `~/.claude/scripts/task-file.sh dir` で探す

## Deploy Workflow モード

コミット・push・PR / MR 作成を担当する（動作検証は team-review で済んでいるので行わない）。前提: feature ブランチ作成済み・team-review PASS 済み。作業ブランチに open な PR / MR が既にあれば（`/orchestrate` の追加修正モード）、新規作成せず**追加 push と本文追記**を行う。

**終了後も作業ブランチに留まり、分岐元には戻らない。** 分岐元への復帰は呼び出し元（`/orchestrate` STEP 6c）が `git switch {base}` で行う。TASK_FILE はリポジトリ外にあり、この command は git で扱わない。

**TASK_FILE への書き込みと Linear への投稿・ステータス変更は行わない。** 結果は OUTPUT フォーマットで呼び出し元（`/orchestrate` STEP 6b）に返し、TASK_FILE の更新・Linear コメント投稿・ステータス変更は呼び出し元が行う。TASK_FILE は Read のみ。

### Input

```
引数の形式: "{task description} --tier={S|M|L} --task-file={TASK_FILE} --linear-id={LINEAR_ID}"
```

| 引数 | 説明 |
|---|---|
| `--tier` | orchestrator が判定済み |
| `--task-file` | orchestrator が作成済みのタスクファイルパス |
| `--linear-id` | orchestrator が確認済みの Linear タスク ID |

### 事前準備

開始前に必ず TASK_FILE の以下を読む。

1. `## team-review` の最新回 — PASS/FAIL 判定・申し送り事項
2. `## Meta` の `branch:` / `base:` — push する作業ブランチと、その分岐元
3. `## team-implement` — PR 本文に書く変更内容（新規作成なら全回。追加 push なら `#### 追加依頼 {n}` の「扱い」行に書いた開始回から最新回まで全回。差し戻しがあると追加依頼の本体は最新回より前の回にあるため、最新回だけ読まない）
4. `## deploy` の `PR/MR:` — 既存 PR / MR の URL（あれば追加 push）
5. `## startproject` > `### Plan` の末尾の `#### 追加依頼 {n}` — 追加 push の本文追記に使う番号・依頼内容と、「扱い」行の開始回（追加修正モードのときだけ存在する）。`- issue:` の行があれば、その追加依頼で増えた GitHub / GitLab issue
6. `## Meta` の `linear_id:` / `issue:` — PR / MR に紐づける Linear issue と GitHub / GitLab issue（「紐づけの規則」）

Review が FAIL なら PR を作らずに中止し、ユーザーに報告して終了する。

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
| merged / closed | 中止して報告する。追加の変更は通常モードで新しいタスクとして起票する |

### 紐づけの規則（Linear issue・GitHub / GitLab issue）

PR / MR を Linear issue と GitHub / GitLab issue に機械的に紐づける。材料は `## Meta` の `linear_id:` と `issue:`（`--linear-id` があればそちらを優先）。`issue:` の行が無い・空なら GitHub / GitLab issue は紐づけない（旧 TASK_FILE と互換）。

| 対象 | 書く場所 | 書き方 |
|---|---|---|
| Linear | タイトル末尾 | ` ({LINEAR_ID})`（新規作成のときだけ。既存 PR / MR のタイトルは変えない） |
| Linear | 本文末尾の `## 関連` | `Part of {LINEAR_ID}`（non-closing。マージしても Linear の状態は動かない。`Refs` は GitLab で magic word にならないので使わない） |
| GitHub / GitLab issue | 本文末尾の `## 関連` | `issue:` の `closes {ref}` → `Closes {ref}`、`refs {ref}` → `Related to {ref}`（`{ref}` は `#N` / `owner/repo#N` / URL をそのまま） |

`issue:` の形式は `- issue: closes #12, refs #34`（`, ` 区切り。各要素は `closes {ref}` か `refs {ref}`）。形式が崩れていたら推測で直さず、その要素は書かずに申し送りで知らせる。

本文テンプレート（`## 関連` は本文の**最後**に置く）:

```markdown
## 関連
Part of NSKETCH-1983
Closes #12
Related to #34
```

禁則（magic word として読ませるため）:
- Linear ID は大文字のまま書く。参照は 1 行に 1 つ（行頭に `- ` や `*` を付けない）
- `## 関連` の参照行はコードフェンスやインラインコード（`` ` ``）の中に書かない（上のテンプレートのフェンスは説明用。実際の本文には付けない）
- 行頭を `/` にしない（GitLab が quick action として扱う）
- `NOLINEAR` なら Linear の行は書かない。書く行が 1 つも無ければ `## 関連` ごと書かない

申し送りの判定（OUTPUT の申し送り事項に書く）:
- **base がデフォルトブランチでない:** `Closes` は GitHub では base がデフォルトブランチの PR でしか効かず、GitLab もデフォルトブランチへのマージで閉じる。`Closes` の行がある PR / MR で base ≠ デフォルトブランチなら「マージしても #N は自動では閉じない」と書く（行はそのまま書く）。デフォルトブランチは `git symbolic-ref --short refs/remotes/origin/HEAD` の `origin/` を除いた名前（無ければ GitHub は `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`、GitLab は `glab repo view --output json | jq -r .default_branch`）
- **ブランチ名に ID が無い:** `branch:` に `{LINEAR_ID}` を小文字にした文字列が含まれなければ「ブランチ名に Linear ID が無い（タイトル・本文で紐づけ）」と書く（deploy はブランチ名を変えない）

### STEP 1: COMMIT

作業ブランチ上の未コミット変更（team-implement の実装。レビュー通過済み）をコミットする。メッセージは `## team-implement` の内容から作る（追加 push なら `#### 追加依頼 {n}` の「扱い」行に書いた開始回から最新回まで全回の内容。`追加依頼 {n}` を本文に書く）。TASK_FILE のスコープ外の変更が作業ツリーにあれば巻き込まない。**TASK_FILE はリポジトリ外にあるので、そもそもコミット対象に入らない**（`git add -A` は使わずファイルを指定する）。

### STEP 2: PUSH

`branch:` のブランチを `origin` に push する。

**追加 push の停止条件:** push 前に `git fetch origin {branch}` し、リモートがローカルの祖先でなければ（`git merge-base --is-ancestor origin/{branch} {branch}` が偽 = 分岐している）push せず中止して報告する。force push・rebase で揃えない（履歴書き換え禁止）。分岐の解消はユーザーが判断する。

### STEP 3-A: CREATE PR / MR（既存 PR / MR がない場合）

base は `base:` のブランチ（空ならリポジトリのデフォルトブランチ）、タイトルは `{type}({scope}): {task description} ({LINEAR_ID})`（`{type}` は変更内容に合う Conventional Commits の型: feat / fix / refactor / docs など。`NOLINEAR` なら ` ({LINEAR_ID})` を付けない。ID は scope に入れない）。

本文に含める内容:
- 変更の概要
- `## startproject` > `### Brief` の成功基準
- `## team-review` の申し送り事項（minor 指摘）
- 末尾に `## 関連`（「紐づけの規則」のテンプレートと禁則）

### STEP 3-B: 既存 PR / MR に本文追記（open な PR / MR がある場合）

タイトル・base は変えない。本文の**末尾**に以下を追記する（既存の本文は消さない）。

```markdown
## 追加変更（追加依頼 {n}）
- 依頼内容: {`#### 追加依頼 {n}` の依頼内容}
- 変更の概要: {`## team-implement` の「扱い」行に書いた開始回から最新回まで全回のサマリー}
- コミット: {追加したコミットの hash}
- team-review 最終回（PASS）: {回数と申し送り事項（minor）}
```

`## team-implement` は差し戻しで複数回になることがあるので、開始回（追加依頼の本体）から最新回（差し戻し対応）まで全回を要約する。team-review は最終回（PASS）だけを書く。

**紐づけの追記:** 既存の本文を読み、次の行のうち本文に**まだ無い行だけ**を上の追記の直後に `### 関連（追加依頼 {n}）` として足す（書く行が無ければ見出しごと省く。書き方と禁則は「紐づけの規則」）。

- `Part of {LINEAR_ID}` — 本文に `{LINEAR_ID}` を含む magic word の行（`Part of` / `Closes` / `Fixes` / `Resolves` / `Refs` / `Related to` など + ID）が無いとき（旧形式の「関連 Linear タスク: {ID}」だけの PR を補う。`NOLINEAR` なら書かない）
- `## Meta` の `issue:` の各要素の行（`Closes {ref}` / `Related to {ref}`）— 同じ行が本文に無いとき（追加依頼で増えた分が入る）

```bash
gh pr view {URL} --json body --jq .body > body.md && printf '\n{追記}\n' >> body.md && gh pr edit {URL} --body-file body.md   # GitHub
glab mr view {IID} --output json | jq -r .description > body.md && printf '\n{追記}\n' >> body.md && glab mr update {IID} --description "$(cat body.md)"   # GitLab
```

### STEP 4: OUTPUT を返す

分岐元には戻らず、作業ブランチに留まったまま以下のフォーマットを最終レスポンスとしてそのまま返す。新規作成（STEP 3-A）は「新規作成型」、追加 push（STEP 3-B）は「追加 push 型」。

**新規作成型:**

```markdown
### DEPLOY

#### PR / MR
- 作成日時: {timestamp}
- ブランチ: {branch} → {base}
- PR/MR: {PR/MR URL}
- 紐づけ: {LINEAR_ID}（タイトル / 本文 `Part of` / ブランチ名 のうち入ったもの）、{`Closes #12`、`Related to #34` など本文に書いた行} | なし

#### 申し送り事項
- 次タスクへの注意点
- team-review の minor 指摘（対応推奨）
- 紐づけの注意（該当時のみ）: base がデフォルトブランチでない（`Closes` は自動では閉じない）／ブランチ名に Linear ID が無い／`issue:` の形式が崩れていて書かなかった要素

### LINEAR_COMMENT
（Linear に投稿する PR 作成完了コメント本文。以下を含める）
- ブランチ URL
- コミット履歴（`git log --oneline` の出力）
- team-review の結果サマリー
- PR/MR リンク
- 紐づけ（`紐づけ:` 行と同じ内容）
```

Linear issue への PR の添付（GitHub 連携が無いときの `links` による代替）は deploy では行わない。呼び出し元（`/orchestrate` STEP 6b）が行う。

**追加 push 型**（呼び出し元は `## deploy` の末尾に追記する。`#### 申し送り事項` を分けず 1 見出しにまとめる）:

```markdown
### DEPLOY

#### 追加 push（追加依頼 {n}）
- 日時: {timestamp}
- ブランチ: {branch} → {base}（既存 PR/MR: {URL}）
- コミット: {追加したコミットの hash}
- 本文追記: 「## 追加変更（追加依頼 {n}）」
- 紐づけ: {`### 関連（追加依頼 {n}）` に追記した行} | なし（追記なし）
- 申し送り事項: {次タスクへの注意点・team-review 最終回（PASS）の minor 指摘・紐づけの注意（該当時のみ）}

### LINEAR_COMMENT
（Linear に投稿する追加 push 完了コメント本文。以下を含める）
- 追加依頼 {n} の内容
- 追加したコミット（`git log --oneline {base}..{branch}` のうち今回分）
- team-review 最終回（PASS）の結果サマリー
- PR/MR リンク
- 紐づけ（追記した行。無ければ省く）
```
