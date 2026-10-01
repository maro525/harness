---
description: Project orchestrator — classify tier, create task file, run startproject → team-implement → team-review → deploy in sequence. With --task-file, runs the followup mode that adds changes to an existing PR/MR.
agent: build
---

# orchestrate

プロジェクト全体のフローを管理する。各フェーズは subagent へ委譲し、Gate 判定・状態管理を担当する。

## Input

```
$ARGUMENTS の形式: "{task description}"
例: "PROJ-573をやりたいです"
例: "カート機能にクーポン適用を追加する"
例（追加修正モード）: "レビュー指摘の型エラーを直す --task-file=.claude/docs/decisions/task-PROJ-573-coupon.md"
```

## 実行原則

**$ARGUMENTS を受け取ったら「モード判定」を行い、通常モードは STEP 0 から、追加修正モードは STEP 3F から開始する。追加の指示がない限り STEP 7 まで完走する。**

- 全 STEP を自律的に順番に実行する。報告・通知はするが応答を待たずに次へ進む
- 質問が必要なら質問し、回答を受け取ったら止まらず続行する
- **[MUST]** の付いたステップは、どの tier でもスキップしない
- Linear への投稿・ステータス変更に失敗したら、黙って飛ばさずユーザーに報告する
- orchestrate はメインのセッション（primary agent）で動き、各フェーズは `@agent` / `task` で subagent として起動する。subagent の起動は同期なので、**返却を受け取るまで次の STEP に進まない**
- 各フェーズ agent は TASK_FILE の自分の節（`## startproject` / `## team-implement` / `## team-review` / `## deploy`）と Linear コメントを自分で書く。orchestrator が書くのは `## Meta`（`tier:` / `status:`）と `#### 追加依頼 {n}`（STEP 3F）だけ
- git は `AGENTS.md` の「GIT RULES」に従う

**原則として止まるのは以下の Gate のみ。** ただし各フェーズが途中でユーザーに確認を求めた場合（startproject の要件ヒアリングなど）は、それに従う。

| Gate | タイミング | 動作 |
|------|-----------|------|
| Gate 1 | startproject が計画提示時に自己判断で発動 | startproject 内でユーザー承認を待つ。orchestrate は返却を待つだけ |
| Gate 2 | team-review の FAIL 時 | ユーザーに報告し判断を待つ |

## モード判定

$ARGUMENTS を受け取ったら最初にモードを決め、判定結果（モードと TASK_FILE）をユーザーに報告して続行する。ユーザーが別のモードを指示したらそれに従う。

| モード | 判定 | 開始 STEP |
|------|------|-----------|
| **通常モード** | 下記に該当しない | STEP 0 |
| **追加修正モード** | (a) `--task-file={TASK_FILE}` で既存の `task-*.md` が指定された、または (b) Linear ID を検出し、`.claude/docs/decisions/task-{LINEAR_ID}-*.md` が存在する | STEP 3F |

- (a) / (b) の存在確認は作業ツリーで行い、無ければ git の履歴でも探す（tracked リポジトリでは STEP 6c 後、PR がマージされるまで TASK_FILE は作業ブランチにしか無く、分岐元の作業ツリーには無い。切り替えは STEP 3F F1）
  - (a): `git log --all --format=%H -1 -- {TASK_FILE}` がコミットを返せば「既存の `task-*.md`」とみなして追加修正モードにし、F1 の「TASK_FILE が作業ツリーに無い場合」の切り替えへ進む。作業ツリーにも履歴にも無ければ、通常モードに落とさず中止して案内する（パスの誤りか、別のリポジトリ）
  - (b): `git log --all --name-only --format= -- '.claude/docs/decisions/task-{LINEAR_ID}-*.md'` で作業ブランチにだけある TASK_FILE も探す
- (b) で該当ファイルが複数あれば `question` tool で選ばせる
- 追加修正モードは、`/orchestrate` が PR / MR を出したタスクに追加の変更（レビュー指摘への対応、仕様の追加など）を加えるときに使う。既存 PR への追加変更は必ずこのモードを通し、orchestrator が直接編集して push しない（`AGENTS.md` の「GIT RULES」の「`/orchestrate` で作った PR への追加変更」）
- 呼び出し形: `/orchestrate "{追加の依頼} --task-file={TASK_FILE}"`（または `/orchestrate "{LINEAR_ID} {追加の依頼}"`）

---

## STEP 0: CLASSIFY

`AGENTS.md` の「ADAPTIVE EXECUTION」の基準で tier を判定する。

判定結果と根拠をユーザーに日本語で報告。上書き指示がない限り即 STEP 1 へ。

**tier=XS の場合:** 直接実装を提案してここで終了する（STEP 1 以降は S / M / L のみ）。

---

## STEP 1: LINEAR タスク確認

`$ARGUMENTS` から Linear ID（例: `PROJ-573`）を検出する。

**ID 検出時:**
- LINEAR_ID として使用
- Linear MCP の `get_issue` でタスク詳細を取得してタスク説明を補完
- 即 STEP 2 へ

**ID 未検出時:**
- ユーザーに Linear タスク ID または URL を質問
- 既存タスクがあれば ID を取得、なければ Linear MCP の `save_issue` で新規作成
- 回答を受け取ったら即 STEP 2 へ

---

## STEP 2: タスクファイル作成

```
TASK_FILE = .claude/docs/decisions/task-{LINEAR_ID}-{feature}.md
```

feature は LINEAR_ID のタスク内容から短いスネークケースで命名。

**初期テンプレート:**

```markdown
# Task: {LINEAR_ID} — {task description}

## Meta
- linear_id: {LINEAR_ID}
- tier: {tier}
- created: {timestamp}
- status: planning
- branch:
- base:

## startproject
### Brief
<!-- startproject が記入 -->

### Design
<!-- startproject が記入 -->

### Plan
<!-- startproject が記入 -->

## team-implement
<!-- team-implement が記入 -->

## team-review
<!-- team-review が記入 -->

## deploy
<!-- deploy が記入 -->
```

`##` 見出しはプロセス名で固定する（kanban がこの見出しでフェーズを判定する）。

---

## STEP 3: startproject を実行

subagent を呼び出して計画フェーズを委譲する:

```
@startproject "{task description} --tier={tier} --task-file={TASK_FILE} --linear-id={LINEAR_ID}"
```

startproject 内で質問が発生した場合はユーザーが回答。回答後は startproject が続行。

**Gate 1:** startproject が自己判断で発動し、ユーザーの承認（または修正）が済んでから返ってくる（詳細は `agents/startproject.md`）。
返却後は `GATE1` の値に関わらず即 STEP 4 へ進む。`GATE1`（`auto-approved` / `approved` / `revised`）は STEP 7 の完了報告に含める。

---

## STEP 3F: 追加修正モード

通常モードの STEP 0〜3 の代わりに実行し、STEP 4 に合流する。追加依頼も team-implement → team-review → deploy を必ず通す（orchestrator が直接編集して push しない）。F1〜F5 を順に実行し、途中で止まるのは前提不成立のときだけ。

### F1: TASK_FILE を読む

指定された TASK_FILE から以下を読み、「状態管理」の変数を復元する。

| 読む場所 | 復元するもの |
|------|------|
| `# Task: {LINEAR_ID} — {task description}`（先頭行） | 元の task description |
| `## Meta` の `linear_id:` / `tier:` / `status:` / `branch:` / `base:` | `LINEAR_ID` / `tier` / 前提確認の材料 |
| `## deploy` の `PR/MR:` | 既存 PR / MR の URL |
| `## startproject` > `### Plan` の `#### 追加依頼 {n}` | 追加依頼の通し番号 n（既存の最大 + 1 を次の n にする） |
| `## team-implement` / `## team-review` の `### {m}回目` | 実装・レビューの回数 m（既存の最大 + 1 を次の m にする） |

n と m は独立に数える（差し戻しで m だけ増えることがある）。

**TASK_FILE が作業ツリーに無い場合**（tracked リポジトリでは STEP 6c 後、PR がマージされるまで TASK_FILE は作業ブランチにしか無い。モード判定 (a) の履歴探しから来た場合もここ）: `git log --all --format=%H -1 -- {TASK_FILE}` でコミットを見つけ、`git branch -a --contains {hash}` で作業ブランチを特定し、`@deploy "git switch {branch}"`（Ad-hoc Git モード。`switch` はガード対象外）で切り替えてから読む。`git branch -a --contains` は `remotes/origin/{branch}` の形でも返すので、`switch` には `remotes/origin/` を除いたローカル名を渡す（ローカルに無ければ `git switch` がリモート追跡ブランチから作る）。複数のブランチが返れば（起きやすいのは PR マージ後に分岐元を pull していないとき: 作業ブランチと `remotes/origin/main` の両方が返る）`## Meta` の `branch:` と一致するものを選ぶ。この時点では TASK_FILE が作業ツリーに無いので、`## Meta` は `git show {hash}:{TASK_FILE のリポジトリルート基準の相対パス}` で読む（例: `git show {hash}:.claude/docs/decisions/task-{LINEAR_ID}-….md`。`{rev}:{path}` の path に絶対パスは渡せない）。見つからなければ中止して案内する。

### F2: 前提確認

以下をすべて満たすときだけ続行する。読み取り系なので orchestrator が直接実行してよい。

| 条件 | 確認方法 |
|------|------|
| `status` が `in-review` | `## Meta` |
| `branch:` が空でない | `## Meta` |
| `## deploy` に PR / MR URL がある | `## deploy` の `PR/MR:` |
| その PR / MR が open | GitHub: `gh pr view {URL} --json state --jq .state` が `OPEN` ／ GitLab: `glab mr view {IID} --output json` の `state` が `opened`（IID は URL 末尾の番号） |

不成立なら理由別に案内して終了する（STEP 4 以降は実行しない）。

| 不成立の理由 | 案内 |
|------|------|
| `status` が `planning` / `implementing` / `reviewing` / `deploying` | 通常フローの途中で止まっている。該当 STEP から再開するかユーザーに確認する |
| `status` が `done`、または PR / MR が merged / closed | 既存 PR には追加できない。通常モードで新しいタスクとして起票するか確認し、了承なら STEP 0 から実行する |
| `branch:` が空、または `## deploy` に URL がない | deploy が済んでいない。STEP 6 から再開するかユーザーに確認する |

### F3: 規模判定

追加依頼**単体**を `AGENTS.md` の「ADAPTIVE EXECUTION」の基準で見る。以下のいずれかに当たれば「再設計」、それ以外は「そのまま追加」とし、判定と根拠をユーザーに報告して続行する。

- 元の `tier` より上になる
- Hard Trigger に当たる
- `### Design` の「採用した方針」を変える
- 独立した機能を複数含む

**再設計の場合**（STEP 4 のエスカレーションと同形）:

1. `tier` 変数と `## Meta` の `tier:` を更新する（`status` はこの時点では変えない）
2. F4 で `#### 追加依頼 {n}` を追記する
3. 新しい tier で STEP 3 を実行する。再設計であることを startproject に伝えるため、task description は `"{元の task description}（再設計: 追加依頼 {n}: {追加の依頼}）"` にする（F4 の「以降の task description」より前にこの形で呼ぶ）。startproject は `agents/startproject.md`「再実行時の上書き」に従い `## startproject` を上書きする（Brief / Design / Plan は既存 PR で実装済みの部分と追加依頼を踏まえて書き直し、`#### 追加依頼 {n}` は書かない）
4. 上書き後の `### Plan` 末尾に orchestrator が `#### 追加依頼 {n}` を再掲し、F5 へ進む。書き直した Plan には追加依頼が含まれるので、再掲時は F4 テンプレートの前提行を次に差し替える（そのまま再掲すると「この追加依頼だけを実装する」が新 Plan と矛盾し、再設計部分の実装が飛ばされる）:
   `- 前提: 上の Plan のうち既存 PR で実装済みの部分を除いて実装する（この追加依頼を含む再設計分が対象）`

### F4: 追加依頼を記録

orchestrator が `### Plan` の末尾に以下を追記する（既存の Plan は消さない。`####` 見出しは kanban の見出し判定に影響しない）。

```markdown
#### 追加依頼 {n}
- 依頼日時: {timestamp}
- 依頼内容: {追加の依頼}
- 対象: {変更するファイル・機能の見込み}
- 既存 PR: {PR/MR URL}
- 扱い: team-implement / team-review の {m}回目
- 前提: 上の Plan は既存 PR で実装済み。この追加依頼だけを実装する
```

前提行は「そのまま追加」のときの文言。F3 で再設計した場合は F3 の手順 4 の文言に差し替える。

以降の task description は `"{元の task description}（追加依頼 {n}: {追加の依頼}）"` とする。

### F5: STEP 4 へ

「状態管理」に従い `status` を `implementing` に戻し、Linear を "In Progress" にして STEP 4 を実行する。STEP 4 → 5 → 6 → 7 は通常モードと同じ（実装・レビューは `{m}回目` として追記。STEP 6 は 6a で既存 PR / MR へ追加 push して `#### 追加 push（追加依頼 {n}）` を `## deploy` の末尾に追記し、6b で `in-review` に戻し、6c でその記録を `docs(task):` として同じブランチに push する。Gate 2 の差し戻しも同じ）。

> **kanban の副作用:** `## deploy` が埋まった TASK_FILE の `status` を `implementing` に戻すため、追加修正中は kanban が deploy 列に stale（status が古い）として表示する。仕様として許容する。STEP 6b で `in-review` に戻ると解消する。また tracked リポジトリでは 6c 後、分岐元を checkout している間は TASK_FILE が作業ツリーに無く kanban に表示されない（PR マージ後に表示される）。これも仕様として許容する。

---

## STEP 4: team-implement を実行

**完了次第即 STEP 5 へ。**

開始時に「状態管理」に従い TASK_FILE の `status` を `implementing` に、Linear のステータスを "In Progress" に変更する。

```
@team-implement "{task description} --tier={tier} --task-file={TASK_FILE} --linear-id={LINEAR_ID}"
```

team-implement は TASK_FILE の `## team-implement` に `### {m}回目` として追記し、`## Meta` の `branch:` / `base:` に作業ブランチとその分岐元を記入する。変更はコミットしない（deploy がコミットする）。

`{m}` は実装・レビューの回数（`## team-implement` の既存の最大 + 1。初回は `### 1回目`）。`{n}` は追加依頼の通し番号にだけ使う（STEP 3F）。

### 4-1. エスカレーション

team-implement が `ESCALATION: {新しい tier}: {理由}` を返した場合（tier の引き上げで中断した）:

1. ユーザーに新しい tier と理由を報告する
2. `tier` 変数と `## Meta` の `tier:` を更新する（`status` は `implementing` のまま。`planning` に戻すと kanban が「status が古い」と警告するため）
3. 新しい tier で STEP 3 からやり直す。startproject は `## startproject` を上書きする。作業ブランチ上の変更はそのまま引き継ぐ

### 4-2. 完了確認

`ESCALATION` がなく、TASK_FILE の `## team-implement` の最新回と `branch:` / `base:` が記入されていることを確認してから STEP 5 へ進む。

---

## STEP 5: team-review を実行

```
@team-review "{task description} --tier={tier} --task-file={TASK_FILE} --linear-id={LINEAR_ID}"
```

team-review は TASK_FILE の `## team-review` に `### {m}回目` として追記する（FAIL の場合も必ず書き込む）。Gate 2 で STEP 4 に戻ったら、次の実装・レビューは m+1 回目として追記する（上書きしない）。

**Gate 2:**
- PASS → 即 STEP 6
- FAIL → ユーザーに報告し判断を待つ（STEP 4 に戻る場合は `status` を `implementing` に戻す）

---

## STEP 6: deploy を実行

6a → 6b → 6c を順に実行し、**完了次第即 STEP 7 へ。** deploy 後の TASK_FILE の記録（`## deploy`・`status: in-review`）を作業ブランチ上でコミット・push してから分岐元に戻るための 3 段構造（6a の後は作業ブランチに留まっている）。

### 6a: @deploy（コード commit → push → PR / MR → `## deploy` 記入）

```
@deploy "{task description} --tier={tier} --task-file={TASK_FILE} --linear-id={LINEAR_ID}"
```

deploy はコミット・push・PR / MR 作成を行い、**作業ブランチに留まったまま** `## deploy` を記入して Linear を "In Review" にする（TASK_FILE 自体はコードのコミットに含めない。分岐元には戻らない）。既存の PR / MR があれば（追加修正モード）新規作成せず追加 push と本文追記を行い、`## deploy` は上書きせず `#### 追加 push（追加依頼 {n}）` を末尾に追記する（詳細は `agents/deploy.md`）。

### 6b: `status` を `in-review` に（作業ブランチ上）

orchestrator が「状態管理」に従い `## Meta` の `status` を `in-review` にする（6c でコミットされるので、STEP 7 ではなくここで書く）。

### 6c: @deploy --finalize（TASK_FILE を commit → push → 分岐元へ）

```
@deploy "--finalize --task-file={TASK_FILE} --linear-id={LINEAR_ID}"
```

TASK_FILE だけを `docs(task):` でコミットして同じ作業ブランチに push し、分岐元（`base:`）に戻る（TASK_FILE が gitignore のリポジトリでは commit / push せず戻るだけ）。**結果は TASK_FILE に書かない**（書くと再び未コミット差分になる）。STEP 7 の deploy 行に添える。中止（他ファイルがステージ済み・リモートと分岐・分岐元へ戻れない等）ならその理由をユーザーに報告する。中止時は**作業ブランチに留まったまま**で、残った変更はそのまま（履歴は書き換えない）。

**6b と 6c の間で中断した場合**（`in-review` 済み・TASK_FILE 未コミット・作業ブランチ上）: 記録は失われない。次の追加修正モードは F2（`in-review`）を通り、その 6c で今回の記録と追加 push の記録がまとめて `docs(task):` コミットになる。先に回収したければ `@deploy "--finalize --task-file={TASK_FILE} --linear-id={LINEAR_ID}"` を単独で実行してよい（差分が無ければ何もせず分岐元に戻るだけなので再実行に安全）。

---

## STEP 7: 完了報告

ユーザーに日本語で最終サマリーを報告:

```
## 完了: {task description}

- Linear: {LINEAR_ID}
- Tier: {tier}
- Task File: {TASK_FILE}
- Mode: 通常 | 追加修正（追加依頼 {n}、{m}回目）

### 各フェーズのサマリー
- startproject: ...（Gate 1: {GATE1}）
- team-implement: ...
- team-review: ...
- deploy: ...
```

deploy 行には PR / MR の URL に加えて 6c の結果（`docs(task):` コミットの hash・push 先・現在のブランチ。中止ならその理由）を添える（TASK_FILE には書かない）。**現在のブランチは必ず示す**（6c を実行しなかった・中止したときは作業ブランチに留まっている。`git branch --show-current` で確認する）。`status` は 6b で `in-review` にしてあるので STEP 7 では書かない。

追加修正モードでは startproject 行を「（追加修正モード: スキップ）」または再設計時の結果にし、deploy 行に既存 PR / MR の URL を書く。

---

## 状態管理

以下を変数として保持し、全フェーズに引数で渡す:

| 変数 | 設定タイミング |
|------|---------------|
| `tier` | STEP 0（追加修正モードは STEP 3F F1 で `## Meta` の `tier:` から復元。F3 の再設計で更新） |
| `LINEAR_ID` | STEP 1（追加修正モードは STEP 3F F1 で `## Meta` の `linear_id:` から復元） |
| `TASK_FILE` | STEP 2（追加修正モードは $ARGUMENTS または Linear ID から特定） |

作業ブランチとその分岐元は、引数ではなく TASK_FILE の `## Meta` の `branch:` / `base:` で受け渡す（STEP 4 で team-implement が記入。追加修正モードでは既存の値をそのまま使う）。

### TASK_FILE の `status` と Linear ステータス

各 STEP の開始時に orchestrator が `## Meta` の `status` を更新する（フェーズ agent は更新しない）。例外は `in-review` で、STEP 6b（deploy 返却後、作業ブランチ上）で書き、6c の `docs(task):` コミットに含める。`done` には orchestrator はしない。PR がマージされた後に人間が変更する。

| タイミング | status | Linear ステータス | 実行者 |
|------|--------|------|------|
| STEP 2（作成時） | `planning` | — | orchestrator |
| STEP 3F F5（追加修正の開始 = STEP 4 開始と同じ） | `implementing` | "In Progress" | orchestrator |
| STEP 4 開始（Gate 2 で戻った場合も） | `implementing` | "In Progress" | orchestrator |
| STEP 5 開始 | `reviewing` | — | orchestrator |
| STEP 6 開始 | `deploying` | — | orchestrator |
| STEP 6a（deploy 内） | — | "In Review" | deploy agent |
| STEP 6b（deploy 返却後、作業ブランチ上） | `in-review`（PR を出してマージ待ち） | — | orchestrator |
| STEP 7 | —（報告のみ。書き込みなし） | — | — |

---

$ARGUMENTS
