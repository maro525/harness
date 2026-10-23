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
例（issue の紐づけ）: "PROJ-573をやりたいです --issue=closes:#12,#34"
例（追加修正モード）: "レビュー指摘の型エラーを直す --task-file=.claude/docs/decisions/task-PROJ-573-coupon.md"
```

### `--issue`（GitHub / GitLab issue の紐づけ）

```
--issue={ref}[,{ref}...]
{ref} = [closes:|refs:]{#N | owner/repo#N | URL}
```

- 接頭辞なしは `refs`（参照だけ。PR / MR 本文は `Related to {ref}`）。閉じるのは `closes:` を明示したときだけ（本文は `Closes {ref}`）。`#N` を本文やタスク説明から自動で拾うことはしない（誤ってクローズするため）
- URL は GitHub の `https://github.com/{owner}/{repo}/issues/{N}`、GitLab の `https://{host}/{group}/{project}/-/issues/{N}` を受け付け、そのまま使う（`#N` に変換しない）
- **正規化:** 各要素を `closes {ref}` / `refs {ref}` にして `, ` でつなぐ（例: `--issue=closes:#12,#34` → `closes #12, refs #34`）。これが `ISSUE_REFS` で、`## Meta` の `- issue:` 行に書く。同じ `{ref}` が重複したら 1 つにまとめ、`closes` と `refs` が両方あれば `closes` を残す
- **検証:** 上の形に当てはまらない要素が 1 つでもあれば、TASK_FILE を作る前（追加修正モードでは Meta に書く前）に中止し、正しい書き方を示して案内する（推測で直さない）
- `--issue=…` は task description から取り除いてから各フェーズに渡す。フェーズには引数で渡さず、`## Meta` の `issue:` で受け渡す（deploy が読む）
- `--issue` が無ければ `ISSUE_REFS` は空で、GitHub / GitLab issue は紐づけない（`issue:` の行が無い旧 TASK_FILE も同じ扱い）
- Linear issue は `--issue` と関係なく `LINEAR_ID` で紐づく（タイトル末尾の `({LINEAR_ID})`・本文の `Part of {LINEAR_ID}`・ブランチ名。`agents/deploy.md`「紐づけの規則」）

## 実行原則

**$ARGUMENTS を受け取ったら「モード判定」を行い、通常モードは STEP 0 から、追加修正モードは STEP 3F から開始する。追加の指示がない限り STEP 7 まで完走する。**

- 全 STEP を自律的に順番に実行する。報告・通知はするが応答を待たずに次へ進む
- 質問が必要なら質問し、回答を受け取ったら止まらず続行する。ユーザーへの質問は「状態管理」の「質問の中継（Linear）」に従う（Linear の issue コメントに投稿して返信を待つ。キーが無い・`NOLINEAR` なら `question` tool）
- **[MUST]** の付いたステップは、どの tier でもスキップしない
- Linear への投稿・ステータス変更・description 更新に失敗したら、黙って飛ばさずユーザーに報告する
- orchestrate はメインのセッション（primary agent）で動き、各フェーズは `@agent` / `task` で subagent として起動する。subagent の起動は同期なので、**返却を受け取るまで次の STEP に進まない**
- 各フェーズ agent は TASK_FILE の自分の節（`## startproject` / `## team-implement` / `## team-review` / `## deploy`）と Linear コメントを自分で書く。orchestrator が TASK_FILE に書くのは `## Meta`（`tier:` / `status:` / `issue:`）と `#### 追加依頼 {n}`（STEP 3F）だけ（description 更新は TASK_FILE を読んで Linear にだけ書く）
- git は `AGENTS.md` の「GIT RULES」に従う

**原則として止まるのは以下の Gate のみ。** ただし各フェーズが途中でユーザーに確認を求めた場合（startproject の要件ヒアリングなど）は、それに従う。

| Gate | タイミング | 動作 |
|------|-----------|------|
| Gate 1 | startproject が計画提示時に自己判断で発動 | startproject が `GATE1: pending` で返したら orchestrator が「質問の中継」で承認を聞く。`approved` / `revised` なら startproject 内で承認済み |
| Gate 2 | team-review の FAIL 時 | ユーザーに報告し「質問の中継」で判断を聞く |

## モード判定

$ARGUMENTS を受け取ったら最初にモードを決め、判定結果（モードと TASK_FILE）をユーザーに報告して続行する。ユーザーが別のモードを指示したらそれに従う。

| モード | 判定 | 開始 STEP |
|------|------|-----------|
| **通常モード** | 下記に該当しない | STEP 0 |
| **追加修正モード** | (a) `--task-file={TASK_FILE}` で既存の `task-*.md` が指定された、または (b) Linear ID を検出し、`.claude/docs/decisions/task-{LINEAR_ID}-*.md` が存在する | STEP 3F |

- (a) / (b) の存在確認は作業ツリーで行い、無ければ git の履歴でも探す（tracked リポジトリでは STEP 6c 後、PR がマージされるまで TASK_FILE は作業ブランチにしか無く、分岐元の作業ツリーには無い。切り替えは STEP 3F F1）
  - (a): `git log --all --format=%H -1 -- {TASK_FILE}` がコミットを返せば「既存の `task-*.md`」とみなして追加修正モードにし、F1 の「TASK_FILE が作業ツリーに無い場合」の切り替えへ進む。作業ツリーにも履歴にも無ければ、通常モードに落とさず中止して案内する（パスの誤りか、別のリポジトリ）
  - (b): `git log --all --name-only --format= -- '.claude/docs/decisions/task-{LINEAR_ID}-*.md'` で作業ブランチにだけある TASK_FILE も探す
- (b) で該当ファイルが複数あれば「質問の中継」で選ばせる（phase 名 `mode`）
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
- issue: {ISSUE_REFS。--issue が無ければ空}

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

**[MUST]** 「状態管理」の「Linear の description 更新」を行う（この時点は Brief 未記入なので task description を概要に使う）。

続けて「質問の中継（Linear）」の `ASK_MODE` を決める（`--check`）。

---

## STEP 3: startproject を実行

subagent を呼び出して計画フェーズを委譲する:

```
@startproject "{task description} --tier={tier} --task-file={TASK_FILE} --linear-id={LINEAR_ID} --ask={ASK_MODE}"
```

startproject は質問があると `### QUESTIONS` を返して終了する（`--ask=linear`、または `question` tool が届かないとき）。「質問の中継」で聞いて回答ファイルを作り、`--answers-file={ASK_LOG}` を足して同じ引数で再起動する（1 フェーズ 3 往復まで）。

**Gate 1:** startproject が自己判断で発動する（詳細は `agents/startproject.md`）。`GATE1: pending` で返ってきたら（startproject は計画を TASK_FILE に書き、計画コメントを投稿済み）、description を更新してから「質問の中継」で承認を聞く。承認なら `GATE1` を `approved` として STEP 4 へ（再起動しない）。修正なら `--answers-file={ASK_LOG}` を足して再起動し、`GATE1: revised` の返却を待つ。
**[MUST]** 「状態管理」の「Linear の description 更新」を行う。

返却後、`GATE1` が `pending` 以外なら即 STEP 4 へ進む（`pending` は上の Gate 1 の手順で承認を聞いてから）。`GATE1`（`auto-approved` / `approved` / `revised`。`pending` は聞いた結果の値に置き換える）は STEP 7 の完了報告に含める。

---

## STEP 3F: 追加修正モード

通常モードの STEP 0〜3 の代わりに実行し、STEP 4 に合流する。追加依頼も team-implement → team-review → deploy を必ず通す（orchestrator が直接編集して push しない）。F1〜F5 を順に実行し、途中で止まるのは前提不成立のときだけ。

### F1: TASK_FILE を読む

指定された TASK_FILE から以下を読み、「状態管理」の変数を復元する。

| 読む場所 | 復元するもの |
|------|------|
| `# Task: {LINEAR_ID} — {task description}`（先頭行） | 元の task description |
| `## Meta` の `linear_id:` / `tier:` / `status:` / `branch:` / `base:` | `LINEAR_ID` / `tier` / 前提確認の材料 |
| `## Meta` の `issue:` | `ISSUE_REFS`（行が無い・空なら空） |
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
- issue: {今回の --issue を正規化したもの。--issue が無ければこの行は書かない}
```

前提行は「そのまま追加」のときの文言。F3 で再設計した場合は F3 の手順 4 の文言に差し替える。

`--issue` があれば、同時に `## Meta` の `issue:` に追記する（既存の要素の後ろに `, ` でつなぎ、重複は「`--issue`」の正規化どおりまとめる。行が無い旧 TASK_FILE なら `base:` の次に `- issue:` 行を足す）。`ISSUE_REFS` も更新する。deploy の STEP 3-B が本文に無い行だけを `### 関連（追加依頼 {n}）` として既存 PR / MR に追記する。

以降の task description は `"{元の task description}（追加依頼 {n}: {追加の依頼}）"` とする。

### F5: STEP 4 へ

「状態管理」に従い `status` を `implementing` に戻し、Linear を "In Progress" にし、**[MUST]** 「状態管理」の「Linear の description 更新」を行ってから STEP 4 を実行する。STEP 4 → 5 → 6 → 7 は通常モードと同じ（実装・レビューは `{m}回目` として追記。STEP 6 は 6a で既存 PR / MR へ追加 push して `#### 追加 push（追加依頼 {n}）` を `## deploy` の末尾に追記し、6b で `in-review` に戻し、6c でその記録を `docs(task):` として同じブランチに push する。Gate 2 の差し戻しも同じ）。

> **kanban の副作用:** `## deploy` が埋まった TASK_FILE の `status` を `implementing` に戻すため、追加修正中は kanban が deploy 列に stale（status が古い）として表示する。仕様として許容する。STEP 6b で `in-review` に戻ると解消する。また tracked リポジトリでは 6c 後、分岐元を checkout している間は TASK_FILE が作業ツリーに無く kanban に表示されない（PR マージ後に表示される）。これも仕様として許容する。

---

## STEP 4: team-implement を実行

**完了次第即 STEP 5 へ。**

開始時に「状態管理」に従い TASK_FILE の `status` を `implementing` に、Linear のステータスを "In Progress" に変更し、続けて「Linear の description 更新」を行う。

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

開始時に「状態管理」に従い TASK_FILE の `status` を `reviewing` に更新し、続けて「Linear の description 更新」を行う。

```
@team-review "{task description} --tier={tier} --task-file={TASK_FILE} --linear-id={LINEAR_ID}"
```

team-review は TASK_FILE の `## team-review` に `### {m}回目` として追記する（FAIL の場合も必ず書き込む）。Gate 2 で STEP 4 に戻ったら、次の実装・レビューは m+1 回目として追記する（上書きしない）。

**Gate 2:**
- PASS → 即 STEP 6
- FAIL → ユーザーに報告し、「質問の中継」で判断を聞く（phase 名 `gate2`。STEP 4 に戻る場合は `status` を `implementing` に戻す）。報告の前に「Linear の description 更新」を行う（`status` は `reviewing` のまま、フェーズ欄が「レビュー差し戻し（判断待ち）」になる）

---

## STEP 6: deploy を実行

開始時に「状態管理」に従い TASK_FILE の `status` を `deploying` に更新し、続けて「Linear の description 更新」を行う。

6a → 6b → 6c を順に実行し、**完了次第即 STEP 7 へ。** deploy 後の TASK_FILE の記録（`## deploy`・`status: in-review`）を作業ブランチ上でコミット・push してから分岐元に戻るための 3 段構造（6a の後は作業ブランチに留まっている）。

### 6a: @deploy（コード commit → push → PR / MR → `## deploy` 記入）

```
@deploy "{task description} --tier={tier} --task-file={TASK_FILE} --linear-id={LINEAR_ID}"
```

deploy はコミット・push・PR / MR 作成を行い、**作業ブランチに留まったまま** `## deploy` を記入して Linear を "In Review" にする（TASK_FILE 自体はコードのコミットに含めない。分岐元には戻らない）。既存の PR / MR があれば（追加修正モード）新規作成せず追加 push と本文追記を行い、`## deploy` は上書きせず `#### 追加 push（追加依頼 {n}）` を末尾に追記する（詳細は `agents/deploy.md`）。

PR / MR のタイトル末尾の `({LINEAR_ID})`・本文末尾の `## 関連`（`Part of {LINEAR_ID}` と `## Meta` の `issue:` の行）と、Linear issue への PR の添付（連携で添付されていなければ `save_issue` の `links` で代わりに添付。新規作成型のみ）も deploy agent が行う（`agents/deploy.md`「紐づけの規則」・4-1b）。

### 6b: `status` を `in-review` に（作業ブランチ上）

orchestrator が「状態管理」に従い `## Meta` の `status` を `in-review` にする（6c でコミットされるので、STEP 7 ではなくここで書く）。

**[MUST]** 「状態管理」の「Linear の description 更新」を行う（6a で deploy が `## deploy` に書いた PR / MR の URL を含める）。

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
- Issue: {ISSUE_REFS | なし}

### 各フェーズのサマリー
- startproject: ...（Gate 1: {GATE1}）
- team-implement: ...
- team-review: ...
- deploy: ...

### 質問
- {phase}: {質問の要旨} → {回答の要旨}（{Linear | ターミナル}）
- ログ: .claude/logs/ask-{LINEAR_ID}-….md
```

「### 質問」は質問しなかったら「なし」の 1 行にする。

deploy 行には PR / MR の URL、`## deploy` の `紐づけ:` 行（追加 push は追記した行）、`Linear 添付:` の結果（新規作成型のみ）、紐づけの申し送り（base がデフォルトブランチでない・ブランチ名に ID が無い）があればそれに加えて 6c の結果（`docs(task):` コミットの hash・push 先・現在のブランチ。中止ならその理由）を添える（TASK_FILE には書かない）。**現在のブランチは必ず示す**（6c を実行しなかった・中止したときは作業ブランチに留まっている。`git branch --show-current` で確認する）。`status` は 6b で `in-review` にしてあるので STEP 7 では書かない。

追加修正モードでは startproject 行を「（追加修正モード: スキップ）」または再設計時の結果にし、deploy 行に既存 PR / MR の URL を書く。

---

## 状態管理

以下を変数として保持し、全フェーズに引数で渡す:

| 変数 | 設定タイミング |
|------|---------------|
| `tier` | STEP 0（追加修正モードは STEP 3F F1 で `## Meta` の `tier:` から復元。F3 の再設計で更新） |
| `LINEAR_ID` | STEP 1（追加修正モードは STEP 3F F1 で `## Meta` の `linear_id:` から復元） |
| `TASK_FILE` | STEP 2（追加修正モードは $ARGUMENTS または Linear ID から特定） |
| `ISSUE_REFS` | 「Input」の「`--issue`」で正規化（無ければ空）。STEP 2 で `## Meta` の `issue:` に書く。追加修正モードは STEP 3F F1 で `issue:` から復元し、F4 で追記。フェーズには渡さず `## Meta` で受け渡す |
| `ASK_MODE` | STEP 2 の直後（追加修正モード・モード判定では最初に質問が要った時点）。`linear` / `terminal`。「質問の中継（Linear）」 |
| `SESSION_INFO` | その実行で最初に「Linear の description 更新」をするとき 1 回だけ集め、以降は使い回す（フェーズには渡さない）。「実行セッション情報の取得」 |

作業ブランチとその分岐元は、引数ではなく TASK_FILE の `## Meta` の `branch:` / `base:` で受け渡す（STEP 4 で team-implement が記入。追加修正モードでは既存の値をそのまま使う）。

### TASK_FILE の `status` と Linear ステータス

各 STEP の開始時に orchestrator が `## Meta` の `status` を更新する（フェーズ agent は更新しない）。例外は `in-review` で、STEP 6b（deploy 返却後、作業ブランチ上）で書き、6c の `docs(task):` コミットに含める。`done` には orchestrator はしない。PR がマージされた後に人間が変更する。

| タイミング | status | Linear ステータス | description 更新 | 実行者 |
|------|--------|------|------|------|
| STEP 2（作成時） | `planning` | — | ✓ | orchestrator |
| STEP 3 完了後（startproject 返却直後） | `planning` のまま | — | ✓ | orchestrator |
| STEP 3F F5（追加修正の開始 = STEP 4 開始と同じ） | `implementing` | "In Progress" | ✓ | orchestrator |
| STEP 4 開始（Gate 2 で戻った場合も） | `implementing` | "In Progress" | ✓ | orchestrator |
| STEP 5 開始 | `reviewing` | — | ✓ | orchestrator |
| Gate 2 の FAIL | `reviewing` のまま | — | ✓（差し戻し・判断待ちを表示） | orchestrator |
| STEP 6 開始 | `deploying` | — | ✓ | orchestrator |
| STEP 6a（deploy 内） | — | "In Review" | — | deploy agent |
| STEP 6b（deploy 返却後、作業ブランチ上） | `in-review`（PR を出してマージ待ち） | — | ✓（PR / MR URL を含める） | orchestrator |
| STEP 7 | —（報告のみ。書き込みなし） | — | — | — |

### Linear の description 更新

issue を開けば現状が分かるよう、description 末尾の管理セクションを TASK_FILE から作り直して置き換える。コメント投稿（履歴）とは別物で、description は常に最新の要約。

`LINEAR_ID` が `NOLINEAR` なら何もしない。

1. 直前に Linear MCP の `get_issue` で最新の description を取得する
2. 行頭が `## 🤖 Orchestrate` の行を探し、その行から末尾までを捨てる（無ければ全文を残す）。それより上（人の記述）は一字も変えない
3. 残りの末尾の空行を整え、空行 1 つ + 下のテンプレートを連結する（「実行セッション」は `SESSION_INFO` から。未取得ならここで「実行セッション情報の取得」を行う）
4. Linear MCP の `save_issue` で description だけ更新する（タイトル・ステータス等は渡さない）
5. 失敗したら黙って飛ばさず報告する。フローは止めない

- HTML コメント（`<!-- -->`）は Linear で消える可能性があるので目印に使わない。目印は見出し行そのもの
- 管理セクションの中で `## ` レベルの見出しを使わない（`###` まで）

**テンプレート:**

```markdown
## 🤖 Orchestrate
> orchestrate が自動更新するセクション。この見出しより下は毎回書き換わるため、追記は見出しより上に書く。

### 概要・目的
{Brief の Goal と Scope を 2〜4 行に要約。Brief が未記入（STEP 2 時点）なら task description}

### 大まかな方法
{Design の採用方針を 1〜3 行に要約。未記入なら「（計画中）」}

### 具体的な方法
{Plan の各項目を `- [ ]` のチェックリストで。`## team-implement` に最新回があれば `- [x]`。`#### 追加依頼 {n}` は「追加依頼 {n}: {依頼内容}」の 1 項目にする。未記入なら「（計画中）」}

### 現在のフェーズ
- フェーズ: {status}（{表示名}）{回数があれば「・{m}回目」、Gate 2 の FAIL なら「・レビュー差し戻し（判断待ち）」}
- Tier: {tier}
- PR / MR: {`## deploy` の URL。無ければ「—」}
- 更新: {YYYY-MM-DD HH:MM}（`date '+%Y-%m-%d %H:%M'`）

### 実行セッション
> 最後にこのセクションを更新した orchestrate のセッション。追加修正を別セッションで実行すると、そのセッションに置き換わる。
- ツール: OpenCode {version}
- モデル: {自身のモデル ID（`provider/model`）}
- セッション ID: `{session_id}`（推定。再開: `{cwd}` で `opencode -s {session_id}`）
- セッション URL: —
- 実行者: {Linear の表示名}（git: {git_user}）
- ホスト / 環境: {host}（{os}{wsl があれば「・WSL {wsl}」}）
- リポジトリ / ブランチ: {origin} / {`## Meta` の `branch:`。空なら `base:`}
```

status の表示名: `planning`=計画中 / `implementing`=実装中 / `reviewing`=レビュー中 / `deploying`=デプロイ中 / `in-review`=PR レビュー待ち。

#### 実行セッション情報の取得

`SESSION_INFO` はその orchestrate 実行で最初の description 更新の直前に 1 回だけ集め、以降の更新では使い回す（毎回変わるのは「更新」の時刻と `branch:` だけ）。取れなかった値は「—」にする（行ごと消さない。テンプレートの見出しと項目は固定）。

```bash
printf '%s=%s\n' \
  version "$(opencode --version 2>/dev/null)" \
  host "$(hostname)" \
  os "$(uname -sr)" \
  wsl "${WSL_DISTRO_NAME:-}" \
  cwd "$(pwd)" \
  git_user "$(git config --get user.name)" \
  origin "$(git remote get-url origin 2>/dev/null | sed -E 's#://[^/@]*@#://#')"
timeout 30 opencode session list -n 1 --format json < /dev/null
```

| 項目 | 出どころ・注意 |
|---|---|
| `session_id` | OpenCode は bash tool にセッション ID を渡さない（渡すのは `OPENCODE=1` / `OPENCODE_PID` / `OPENCODE_RUN_ID` で、`OPENCODE_RUN_ID` はプロセス単位の ID でありセッション ID ではない。1.14 系で確認）。代わりに `opencode session list` の先頭（最近更新された順）の `id`（`ses_…`）を使い、その `directory` が `cwd` と一致するときだけ採用する。同じディレクトリで別の OpenCode を同時に動かしていると別セッションを指しうるので「推定」と付ける。取れなければ「—」 |
| セッション URL | ローカルのセッションに URL は無い（共有 URL は `--share` 時だけで、取得手段は未確認）ので常に「—」 |
| モデル | 環境変数には無い。orchestrator 自身のモデル ID を書く |
| 実行者 | Linear MCP の `get_user`（`query: "me"`）の `displayName`（無ければ `name`）。呼べなければ「—」にして git の `user.name` だけを書く |
| `origin` | URL に埋め込まれた認証情報（`https://{token}@…`）は sed で落とす |

- 環境変数は上のように**名前を指定して**読む。`env` / `printenv` / `set` で一覧を出さない（トークンが出力に残る）
- 載せない: `OPENCODE_PID` / `OPENCODE_SERVER_PASSWORD` などの PID・認証情報、API キー、メールアドレス（`get_user` が返しても書かない）
- セッションの履歴は持たない。過去のセッションは Linear のコメント履歴と description の版履歴で追える

### 質問の中継（Linear）

投稿と待機は `~/.claude/scripts/linear-ask.sh`（harness の `sync-claude.sh` で配布。Linear の個人 API キーが要る）で行う。Claude Code 版（`~/.claude/commands/orchestrate.md` の同名節）は API キーを使わず Linear MCP と background の `sleep` タイマーで中継するが、OpenCode には完了通知もタスク停止も無いので、この版はスクリプトで**フォアグラウンド**で待ち、ターミナル先着は無い。目印 `[claude-q:…]`・返信の判定（目印を含まない最古の返信）・ログの形式は両版で共通。

| 質問箇所 | phase 名 |
|---|---|
| STEP 3 の startproject の `### QUESTIONS`（ヒアリング・Gate 1） | `startproject` |
| Gate 2 の FAIL 判断 | `gate2` |
| モード判定 (b) の TASK_FILE 選択 | `mode` |

STEP 1 の Linear ID の質問は対象外（ターミナルのまま）。

**ASK_MODE:** `LINEAR_ID` が `NOLINEAR` かユーザーの指示があれば `terminal`。それ以外は `~/.claude/scripts/linear-ask.sh --check` が exit 0 なら `linear`、3（キー不備）/ 4（API 失敗）/ スクリプトが無ければ `terminal` にして理由を報告する。キーはスクリプトが `LINEAR_API_KEY` か `~/.config/harness/linear.env`（600）から読む。orchestrator はキーを読まない・表示しない。`terminal` は `question` tool で聞く。

**手順（`linear`）:**

1. `ASK_LOG=.claude/logs/ask-{LINEAR_ID}-{phase}-{YYYYMMDD-HHMM}.md` に質問（startproject なら `### QUESTIONS` を `#### STATE` ごと）を書き、`{ASK_LOG}.body.md` に投稿本文を Claude Code 版のテンプレートで書く（返信で答えてもらう旨は残し、先頭の `@{MENTION}` 行（API 経由の投稿で通知されるかは未検証）・「ターミナルで答えても構いません」・末尾の `[claude-q:{MARK}]` 行は書かない。目印はスクリプトが付ける）
2. `COMMENT_ID` を `uuidgen`（無ければ `/proc/sys/kernel/random/uuid`）で決め、まず投稿だけ行う: `~/.claude/scripts/linear-ask.sh --issue {LINEAR_ID} --body-file {ASK_LOG}.body.md --comment-id {COMMENT_ID} --post-only < /dev/null`。exit 0 なら stdout の `comment_url:` と質問の要旨をユーザーに示す
3. 同じ `--comment-id` で `--post-only` を外し `--timeout 540` を付けて**フォアグラウンド**で待つ（bash tool の timeout に収まる長さ。bash tool の上限は実機未検証）。exit 2 なら同じコマンドを再実行する（投稿し直さずに待ち直す。合計 4 時間まで。超えたら `question` tool）。手順 2・3 で exit 3 / 4 なら理由を報告して `question` tool に切り替える
4. exit 0 なら stdout の `---` より下が回答。`ASK_LOG` に回答・`comment_url`・`reply_url`・返信者（`reply_author`）を追記して続行する（startproject は `--answers-file={ASK_LOG}` で再起動。Gate 1 の承認は再起動しない）

- 往復は 1 フェーズ 3 回まで。4 回目は `question` tool で聞く
- 返信者は問わない（`reply_author` は `ASK_LOG` に残す）。目印 `[claude-q:…]` はスクリプトが付け、部分一致で自分の投稿を除外する

---

$ARGUMENTS
