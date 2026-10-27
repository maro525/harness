---
description: Deploy subagent — commit the reviewed changes, push the work branch, create the PR/MR via gh (GitHub) or glab (GitLab) CLI (or push to and annotate an existing open PR/MR), update Linear, and stay on the work branch. With --finalize, commits only the task file (docs(task)) to the work branch, pushes it and returns to the base branch. Without --task-file, runs a single ad-hoc git write operation (commit / push / branch / merge etc.).
mode: subagent
model: github-copilot/gpt-5.6-terra
variant: low
permission:
  edit: allow
---

# deploy

git は `AGENTS.md` の「GIT RULES」（保護ブランチ・ホスティング CLI）に従う。

| 引数 | モード |
|------|--------|
| `--task-file` + `--finalize` | **Finalize モード**（`/orchestrate` STEP 6c から呼ばれる。TASK_FILE だけをコミット・push して分岐元へ戻る） |
| `--task-file` あり | **Deploy Workflow モード**（`/orchestrate` STEP 6a から呼ばれる。終了後も作業ブランチに留まる） |
| `--task-file` なし | **Ad-hoc Git モード**（Deploy Workflow の STEP は実行しない） |

## Ad-hoc Git モード

$ARGUMENTS で指示された書き込み系 git 操作（「GIT RULES」の書き込み系）を実行する。

- 履歴を書き換える操作（rebase、`reset --hard`、force push）は実行前にユーザーに確認する
- 完了後、実行したコマンドと結果（コミットハッシュ・ブランチ名・PR/MR URL など）を日本語で簡潔に返す

### /orchestrate 由来の PR ブランチへのガード

コードを変える操作（`add` / `commit` / `push` / `merge` / `rebase` / `cherry-pick` / `revert` / `reset`）の対象ブランチが `/orchestrate` の作った PR / MR のブランチなら、実行せずに**追加修正モードを案内してユーザーに確認する**（「GIT RULES」の「`/orchestrate` で作った PR への追加変更」）。

```bash
# 対象ブランチを branch: に持つ TASK_FILE を探す
grep -l "^- branch: {branch}$" .claude/docs/decisions/task-*.md
```

- 該当 TASK_FILE の `## deploy` に `PR/MR:` の URL があれば対象。案内文: 「このブランチは `/orchestrate` の PR {URL} のものです。追加変更は `/orchestrate "{追加の依頼} --task-file={TASK_FILE}"`（追加修正モード）で team-implement → team-review → deploy を通してください」
- ユーザーが承知のうえで Ad-hoc 実行を明示したときだけ実行し、結果にレビューを通っていない旨を添える
- 対象外（ガードなし）: コードを変えない操作（`checkout` / `switch`、`tag`、`stash list`、ブランチ削除など）と、該当 TASK_FILE が無いブランチ
- **注意:** 上の grep は作業ツリーしか見ない。TASK_FILE を git 管理するリポジトリでは Finalize モード（STEP 6c）後に分岐元へ戻ると対象の TASK_FILE が作業ツリーに無く、分岐元からの操作ではガードが効かない（作業ブランチ上なら効く）。作業ツリーで見つからなければ対象ブランチのツリーも見る: `git grep -l "^- branch: {branch}$" {branch} -- '.claude/docs/decisions/task-*.md'`

---

## Deploy Workflow モード

コミット・push・PR / MR 作成を担当する（動作検証は team-review で済んでいるので行わない）。前提: feature ブランチ作成済み・team-review PASS 済み。作業ブランチに open な PR / MR が既にあれば（`/orchestrate` の追加修正モード）、新規作成せず**追加 push と本文追記**を行う。

**終了後も作業ブランチに留まり、分岐元には戻らない。** `## deploy` の記入（STEP 4）は作業ブランチ上で行い、その後 orchestrator が `status: in-review` を書き、Finalize モード（`--finalize`）が TASK_FILE を `docs(task):` でコミット・push してから分岐元に戻る（`/orchestrate` STEP 6a → 6b → 6c）。

## Input

```
$ARGUMENTS: "{task description} --tier={S|M|L} --task-file={TASK_FILE} --linear-id={LINEAR_ID} [--label={実行者名}]"
```

---

## 事前準備

開始前に必ず TASK_FILE の以下を読む。

1. `## team-review` の最新回 — PASS/FAIL 判定・申し送り事項
2. `## Meta` の `branch:` / `base:` — push する作業ブランチと、その分岐元
3. `## team-implement` — PR 本文に書く変更内容（新規作成なら全回。追加 push なら `#### 追加依頼 {n}` の「扱い」行に書いた開始回から最新回まで全回。差し戻しがあると追加依頼の本体は最新回より前の回にあるため、最新回だけ読まない）
4. `## deploy` の `PR/MR:` — 既存 PR / MR の URL（あれば追加 push）
5. `## startproject` > `### Plan` の末尾の `#### 追加依頼 {n}` — 追加 push の本文追記に使う番号・依頼内容と、「扱い」行の開始回（追加修正モードのときだけ存在する）。`- issue:` の行があれば、その追加依頼で増えた GitHub / GitLab issue
6. `## Meta` の `linear_id:` / `issue:` — PR / MR に紐づける Linear issue と GitHub / GitLab issue（「紐づけの規則」）

Review が FAIL の場合は PR を作らずに中止し、ユーザーに報告して終了。

### 既存 PR / MR の判定

`## deploy` に URL があればそれを使い、なければ作業ブランチで検索する。

```bash
gh pr list --head {branch} --state all --json number,state,url        # GitHub
glab mr list --source-branch {branch} --all                            # GitLab
```

| 結果 | 動作 |
|------|------|
| なし | 新規作成（STEP 3-A） |
| open | 追加 push（STEP 3-B）。新しい PR / MR は作らない |
| merged / closed | 中止して報告する。追加の変更は通常モードで新しいタスクとして起票する |

---

## 紐づけの規則（Linear issue・GitHub / GitLab issue）

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

---

## STEP 1: COMMIT

作業ブランチ上の未コミット変更（team-implement の実装。レビュー通過済み）をコミットする。メッセージは `## team-implement` の内容から作る（追加 push なら `#### 追加依頼 {n}` の「扱い」行に書いた開始回から最新回まで全回の内容。`追加依頼 {n}` を本文に書く）。TASK_FILE のスコープ外の変更が作業ツリーにあれば巻き込まない。**TASK_FILE 自体はコミットに含めない**（STEP 4 で `## deploy` を書いた後に Finalize モードが `docs(task):` で単独コミットする。`git add -A` は使わずファイルを指定する）。

---

## STEP 2: PUSH

`branch:` のブランチを `origin` に push する。

**追加 push の停止条件:** push 前に `git fetch origin {branch}` し、リモートがローカルの祖先でなければ（`git merge-base --is-ancestor origin/{branch} {branch}` が偽 = 分岐している）push せず中止して報告する。force push・rebase で揃えない（履歴書き換え禁止）。分岐の解消はユーザーが判断する。

---

## STEP 3-A: CREATE PR / MR（既存 PR / MR がない場合）

base は `base:` のブランチ（空ならリポジトリのデフォルトブランチ）、タイトルは `{type}({scope}): {task description} ({LINEAR_ID})` 形式。`{type}` は変更内容に合う Conventional Commits の型（feat / fix / refactor / docs など）。`NOLINEAR` なら ` ({LINEAR_ID})` を付けない。ID は scope に入れない。

PR/MR 本文:
- 変更の概要
- TASK_FILE の `## startproject` > `### Brief` から成功基準
- TASK_FILE の `## team-review` の最新回から申し送り事項
- 末尾に `## 関連`（「紐づけの規則」のテンプレートと禁則）

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

`## team-implement` は差し戻しで複数回になることがあるので、開始回（追加依頼の本体）から最新回（差し戻し対応）まで全回を要約する。team-review は最終回（PASS）だけを書く。

**紐づけの追記:** 既存の本文を読み、次の行のうち本文に**まだ無い行だけ**を上の追記の直後に `### 関連（追加依頼 {n}）` として足す（書く行が無ければ見出しごと省く。書き方と禁則は「紐づけの規則」）。

- `Part of {LINEAR_ID}` — 本文に `{LINEAR_ID}` を含む magic word の行（`Part of` / `Closes` / `Fixes` / `Resolves` / `Refs` / `Related to` など + ID）が無いとき（旧形式の「関連 Linear タスク: {ID}」だけの PR を補う。`NOLINEAR` なら書かない）
- `## Meta` の `issue:` の各要素の行（`Closes {ref}` / `Related to {ref}`）— 同じ行が本文に無いとき（追加依頼で増えた分が入る）

```bash
gh pr view {URL} --json body --jq .body > body.md && printf '\n{追記}\n' >> body.md && gh pr edit {URL} --body-file body.md   # GitHub
glab mr view {IID} --output json | jq -r .description > body.md && printf '\n{追記}\n' >> body.md && glab mr update {IID} --description "$(cat body.md)"   # GitLab
```

---

## STEP 4: RECORD & POST

**[MUST] 作業ブランチに留まったまま、以下をこの順番で実行（4-1 → 4-1b → 4-2 → 4-3）。** 新規作成（STEP 3-A）は「新規作成型」、追加 push（STEP 3-B）は「追加 push 型」。分岐元には戻らない（TASK_FILE のコミット・push と分岐元への復帰は Finalize モードが行う）。

### 4-1. Linear コメント

Linear MCP `save_comment` で LINEAR_ID に投稿:

**新規作成型（PR 作成完了コメント）:**
- ブランチ URL
- コミット履歴（`git log --oneline` の出力）
- team-review の結果サマリー
- PR/MR リンク
- 紐づけ（4-3 の `紐づけ:` 行と同じ内容）

**追加 push 型（追加 push 完了コメント）:**
- 追加依頼 {n} の内容
- 追加したコミット（`git log --oneline {base}..{branch}` のうち今回分）
- team-review 最終回（PASS）の結果サマリー
- PR/MR リンク
- 紐づけ（追記した行。無ければ省く）

### 4-1b. Linear issue への PR の添付（新規作成型のみ）

Linear の GitHub / GitLab 連携が無い環境でも issue から PR に辿れるよう、`links` で代わりに添付する。新規作成型で LINEAR_ID が `NOLINEAR` でないときだけ行う（追加 push 型では行わない）。

1. Linear MCP の `get_issue` で LINEAR_ID を取得し、`attachments` の URL に今回の PR/MR URL があるか見る
2. あれば何もしない（連携が自動で添付済み。二重に付けない）
3. 無ければ Linear MCP の `save_issue`（`id: {LINEAR_ID}`, `links: [{url: {PR/MR URL}, title: {PR/MR タイトル}}]`）で追加する（`links` は append-only。description やステータスは渡さない）
4. 結果を 4-3 の申し送り事項に `- Linear 添付: 連携で添付済み | links で追加 | 失敗（{理由}）` として書く。失敗してもフローは止めず、報告するだけにする

### 4-2. Linear ステータスを "In Review" に変更

### 4-3. TASK_FILE 更新

**新規作成型** — TASK_FILE の `## deploy` を記入する（`--label` があれば `### PR / MR` のすぐ下（空行を挟まない）に `利用AI: {label}` を書く。日時は `- 作成日時:` の行にあるので付けない。追加 push 型は `#### 追加 push（…）` の直下に同じく 1 行）:

```markdown
## deploy

### PR / MR
- 作成日時: {timestamp}
- ブランチ: {branch} → {base}
- PR/MR: {PR/MR URL}
- 紐づけ: {LINEAR_ID}（タイトル / 本文 `Part of` / ブランチ名 のうち入ったもの）、{`Closes #12`、`Related to #34` など本文に書いた行} | なし

### 申し送り事項
- 次タスクへの注意点
- team-review の minor 指摘（対応推奨）
- Linear 添付: {4-1b の結果}
- 紐づけの注意（該当時のみ）: base がデフォルトブランチでない（`Closes` は自動では閉じない）／ブランチ名に Linear ID が無い／`issue:` の形式が崩れていて書かなかった要素
```

**追加 push 型** — 既存の `## deploy` は上書きせず、末尾に以下を追記する（`### 申し送り事項` を分けず 1 見出しにまとめる）:

```markdown
#### 追加 push（追加依頼 {n}）
- 日時: {timestamp}
- ブランチ: {branch} → {base}（既存 PR/MR: {URL}）
- コミット: {追加したコミットの hash}
- 本文追記: 「## 追加変更（追加依頼 {n}）」
- 紐づけ: {`### 関連（追加依頼 {n}）` に追記した行} | なし（追記なし）
- 申し送り事項: {次タスクへの注意点・team-review 最終回（PASS）の minor 指摘・紐づけの注意（該当時のみ）}
```

TASK_FILE への書き込みはコミットせず、作業ブランチ上に未コミットのまま残す（orchestrator が `status: in-review` を書いた後、Finalize モードがまとめてコミットする）。完了後、PR/MR URL・コミットハッシュ・現在のブランチ（作業ブランチ）を日本語で簡潔に返す。

---

## Finalize モード

`/orchestrate` STEP 6c から `--finalize --task-file={TASK_FILE}` で呼ばれる。作業ブランチ上で TASK_FILE に書かれた記録（`## deploy`・`status: in-review`）を **TASK_FILE 単独の `docs(task):` コミット**で同じ作業ブランチに push してから分岐元に戻る。Deploy Workflow の STEP は実行しない。Ad-hoc ガードの対象外。

```
$ARGUMENTS: "--finalize --task-file={TASK_FILE} [--linear-id={LINEAR_ID}]"
```

TASK_FILE は読むだけで書かない。履歴書き換え（force push / rebase / amend）は行わない。各手順で中止したら残りは実行せず、中止理由を報告して終わる（中止時は作業ブランチに留まっている）。

> **公開範囲:** TASK_FILE を gitignore していないリポジトリでは、このコミットで TASK_FILE（設計の検討内容・Linear ID などの社内向けメモ）が作業ブランチに push され、PR / MR に載る。公開したくなければ `.claude/`（または `.claude/docs/decisions/`）を `.gitignore` に入れておく（F-2 で commit / push を飛ばす）。

### F-1: ブランチ確認

`## Meta` の `branch:` / `base:` を読む。`branch:` が空なら中止。現在のブランチが `branch:` でなければ `git switch {branch}`（失敗なら中止）。untracked の TASK_FILE は switch で持ち越されるので、分岐元に取り残された TASK_FILE（過去の deploy で未コミットのまま残ったもの）の回復にも使える。**ただし作業ブランチ側でそのファイルがまだ一度もコミットされていない場合に限る。** ブランチ側で既に git 管理になっていれば、分岐元の未追跡の同名ファイルが `would be overwritten by checkout` で switch を止める（中止になる）。その場合は分岐元のファイルを退避してから作業ブランチ上のものと手で突き合わせる。

### F-2: gitignore 判定

`git check-ignore -q {TASK_FILE}` が真（exit 0）なら commit / push を飛ばして F-5 へ（報告は「コミットなし（gitignore）」）。

### F-3: 混入チェックとコミット

TASK_FILE 以外がコミットに混ざるなら止める。判定はインデックスの中身で行う（作業ツリーに未ステージの無関係な変更があるだけでは止めない。STEP 1 と同じく無関係な変更が作業ツリーに常在する前提）。

**パスの照合:** `git diff --cached --name-only` はリポジトリルート基準の相対パスを返し、TASK_FILE は絶対パスで渡ることが多い。文字列をそのまま比べず、`:(exclude)` で「TASK_FILE 以外に何も無い」ことを見る（`:(exclude)` には絶対パスも相対パスも渡せる）。範囲を指す pathspec は `.` ではなく `:/`（リポジトリルート。`:(top)` と同じ）にする。`.` は cwd 基準なのでサブディレクトリから実行すると範囲が狭まり、外にある混入を見落とす。

```bash
git diff --cached --name-only                                  # 空でなければ中止（他ファイルがステージ済み）
git add -- {TASK_FILE}
git diff --cached --name-only                                  # 空 → 差分なし（コミットせず F-4 へ）
git diff --cached --name-only -- ":/" ":(exclude){TASK_FILE}"  # 空でなければ TASK_FILE 以外が混ざっている → 下記で中止（:/ = リポジトリ全体。cwd に依存しない）
git restore --staged -- {TASK_FILE}                            # 中止時だけ実行（ステージを元に戻す）
git commit -m "{message}"                                      # -a / add -A は使わない
```

メッセージ: 新規 PR なら `docs(task): {LINEAR_ID} の TASK_FILE に deploy 記録を追記`、追加 push なら `docs(task): {LINEAR_ID} の TASK_FILE に追加 push（追加依頼 {n}）を追記`（`## deploy` の末尾の見出しで判別。LINEAR_ID は `--linear-id` か `## Meta` の `linear_id:`）。差分が無ければコミットしない（再実行に安全）。

### F-4: PUSH

```bash
git fetch origin {branch}
git merge-base --is-ancestor origin/{branch} {branch}   # 偽（exit≠0）なら分岐 → 中止（force しない。解消はユーザーが判断）
git rev-list --count origin/{branch}..{branch}          # 0 なら push しない（報告は「push: なし（push 済み）」）
git push origin {branch}
```

`origin/{branch}` が無ければ中止して報告する（Deploy Workflow の STEP 2 で push 済みのはずなので、通常この状況は起きない。起きていれば STEP 2 が失敗している）。

### F-5: 分岐元へ戻る

`git switch {base}`。`base:` が空ならリポジトリのデフォルトブランチ（`git symbolic-ref --short refs/remotes/origin/HEAD` の `origin/` を除いた名前。無ければホスティング CLI で取る: GitHub は `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`、GitLab は `glab repo view --output json | jq -r .default_branch`。使い分けは `origin` の URL）。失敗（作業ツリーの衝突など）なら作業ブランチに留まり、その旨を報告する（commit / push は済んでいるので取り消さない）。

### F-6: 報告

日本語で簡潔に返す（Claude 版の `### FINALIZE` と同じ項目）: `docs(task):` コミットの hash（なし（gitignore）／なし（差分なし））・push 先（`origin/{branch}` ／なし（gitignore）／なし（push 済み））・現在のブランチ（`{base}`。戻れなかったときは `{branch}`）・中止した場合はその理由。**orchestrator はこれを TASK_FILE に書かない**（書くと再び未コミット差分になる）。STEP 7 の deploy 行に添えるだけ。
