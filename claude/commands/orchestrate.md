---
name: orchestrate
description: Project orchestrator — classify tier, create task file, run startproject → team-implement → team-review → deploy in sequence. With --task-file, adds changes to an existing PR/MR (followup mode); with --phase and --ai, runs one phase of an existing task file with an external CLI (pi / cline / opencode / codex).
model: opus[1m]
color: green
allowed-tools: Read, Write, Edit, Bash, Grep, Glob, Agent, Skill, AskUserQuestion, TodoWrite, mcp__linear-server__get_issue, mcp__linear-server__save_issue, mcp__linear-server__save_comment, mcp__linear-server__list_issue_statuses
---

# orchestrate

## 今回の引数

$ARGUMENTS

（引数の置き場所はここだけ。本文の「引数」はこの値を指す。Agent ツール経由で起動された場合は、プロンプトの `ARGUMENTS:` 行が引数）

プロジェクト全体のフローを管理する。各 command の実行・Gate 判定・状態管理を担当し、タスクの実行自体は各 command に委譲する。

## Input

```
引数の形式: "{task description}"
例: "PROJ-573をやりたいです"
例: "カート機能にクーポン適用を追加する"
例（追加修正モード）: "レビュー指摘の型エラーを直す --task-file=.claude/docs/decisions/task-PROJ-573-coupon.md"
例（フェーズ指定モード）: "--task-file=.claude/docs/decisions/task-PROJ-573-coupon.md --phase=team-review --ai=pi"
例（フェーズ指定モード・候補の採用）: "--task-file=.claude/docs/decisions/task-PROJ-573-coupon.md --phase=startproject --adopt=案 2"
```

## 実行原則

**引数を受け取ったら「モード判定」を行い、通常モードは STEP 0 から、追加修正モードは STEP 3F から、フェーズ指定モードは STEP 3P から開始する。通常・追加修正モードは追加の指示がない限り STEP 7 まで完走する。フェーズ指定モードは 1 フェーズを 1 回実行して STEP 7 の報告で終わる。**

- 全 STEP を自律的に順番に実行する。報告・通知はするが応答を待たずに次へ進む
- 質問が必要なら質問し、回答を受け取ったら止まらず続行する
- **[MUST]** の付いたステップは、どの tier でもスキップしない
- Linear への投稿・ステータス変更に失敗したら、黙って飛ばさずユーザーに報告する
- orchestrate はメインのセッションで動き、各 command は fork（バックグラウンド）で動く。command を起動したら**完了通知で返却を受け取るまで次の手順に進まない**
- 各 command は TASK_FILE への書き込みと Linear への投稿をしない（startproject は Write / Edit を持たない）。OUTPUT フォーマットで返却するので、**書き込みと Linear 投稿は orchestrator が行う**。返却が OUTPUT フォーマットに従っていなければ、command に整形し直させてから書き込む
- git は `$HOME/.claude/rules/tool-routing.md` の「Git Operations」に従う。deploy は 6a（`/deploy`: コード commit → push → PR / MR。作業ブランチに留まる）→ 6b（orchestrator が作業ブランチ上で `## deploy` と `status: in-review` を書く）→ 6c（`/deploy --finalize`: TASK_FILE だけを `docs(task):` でコミット・push して分岐元へ戻る）の 3 段で、TASK_FILE の記録が分岐元に未コミットで取り残されないようにする

**原則として止まるのは以下の Gate のみ。** ただし各 command が途中でユーザーに確認を求めた場合（startproject の要件ヒアリングなど）は、それに従う。

| Gate | タイミング | 動作 |
|---|---|---|
| Gate 1 | startproject が計画提示時に自己判断で発動（tier=S は orchestrate が解釈に迷ったときだけ。STEP 3） | startproject 内でユーザー承認を待つ。orchestrate は返却を待つだけ |
| Gate 2 | team-review の FAIL 時 | ユーザーに報告し判断を待つ |

## モード判定

引数を受け取ったら最初にモードを決め、判定結果（モードと TASK_FILE）をユーザーに報告して続行する。ユーザーが別のモードを指示したらそれに従う。

| モード | 判定 | 開始 STEP |
|---|---|---|
| **通常モード** | 下記に該当しない | STEP 0 |
| **フェーズ指定モード** | `--phase={startproject\|team-implement\|team-review\|deploy}` がある（`--task-file` 必須） | STEP 3P |
| **追加修正モード** | `--phase` がなく、(a) `--task-file={TASK_FILE}` で既存の `task-*.md` が指定された、または (b) Linear ID を検出し、`.claude/docs/decisions/task-{LINEAR_ID}-*.md` が存在する | STEP 3F |

- (a) / (b) の存在確認は作業ツリーで行い、無ければ git の履歴でも探す（tracked リポジトリでは STEP 6c 後、PR がマージされるまで TASK_FILE は作業ブランチにしか無く、分岐元の作業ツリーには無い。切り替えは STEP 3F F1）
  - (a): `git log --all --format=%H -1 -- {TASK_FILE}` がコミットを返せば「既存の `task-*.md`」とみなして追加修正モードにし、F1 の「TASK_FILE が作業ツリーに無い場合」の切り替えへ進む。作業ツリーにも履歴にも無ければ、通常モードに落とさず中止して案内する（パスの誤りか、別のリポジトリ）
  - (b): `git log --all --name-only --format= -- '.claude/docs/decisions/task-{LINEAR_ID}-*.md'` で作業ブランチにだけある TASK_FILE も探す
- (b) で該当ファイルが複数あれば `AskUserQuestion` で選ばせる
- フェーズ指定モードは、既存 TASK_FILE の 1 フェーズだけを **別の AI（pi / cline / opencode / codex）** で 1 回実行し、結果を次の回・次の候補として TASK_FILE に追記するときに使う。Claude の command は呼ばず、`~/.agents/skills/{phase}/SKILL.md`（一般向けフェーズ定義）を外部 CLI に読ませる。CLI の呼び出し表は harness リポジトリの `agents/README.md`「外部 CLI のフェーズ実行」（`~/.claude` には同期されないので、読み方は STEP 3P P2）。TASK_FILE の見出しは通常モードと同じ（`### {m}回目` / `### 案 {k}`）で、使った AI は見出しの直下の `利用AI:` 行で示す（STEP 3P P1）
- 呼び出し形: `/orchestrate "--task-file={TASK_FILE} --phase={phase} --ai={pi|cline|opencode|codex}[:{model}]"`、候補の採用は `/orchestrate "--task-file={TASK_FILE} --phase=startproject --adopt=案 {k}"`
- 追加修正モードは、`/orchestrate` が PR / MR を出したタスクに追加の変更（レビュー指摘への対応、仕様の追加など）を加えるときに使う。既存 PR への追加変更は必ずこのモードを通し、orchestrator が直接編集して push しない（`$HOME/.claude/rules/tool-routing.md` の「/orchestrate で作った PR への追加変更」）
- 呼び出し形: `/orchestrate "{追加の依頼} --task-file={TASK_FILE}"`（または `/orchestrate "{LINEAR_ID} {追加の依頼}"`）

## tier 別のフェーズ構成

通常・追加修正モードの STEP 3〜6 は、tier で起動方法とモデルを変える（フェーズ指定モードは対象外）。

| tier | STEP 3 startproject | STEP 4 team-implement | STEP 5 team-review | STEP 6 deploy |
|---|---|---|---|---|
| S | 起動しない（orchestrate が計画する。STEP 3 の「tier=S」） | Agent・`sonnet` | Agent・`sonnet` | Skill（haiku） |
| M | Skill（best） | Agent・`opus` | Skill（opus） | Skill（haiku） |
| L | Skill（best） | Skill（best） | Skill（opus） | Skill（haiku） |

- **Skill:** `/{phase} "{引数}"` で呼ぶ。モデルは command の frontmatter の `model:` で決まり、呼び出し側からは変えられない
- **Agent:** frontmatter と違うモデルで動かすときに使う。Agent ツールに command 定義を読ませて起動する（下記）。`best` は Agent の `model` に指定できないので、`best` を使うフェーズは Skill で呼ぶ
- Agent で起動したフェーズはサブエージェントを使わない（team-implement の S / M、team-review の S はどれも自分で作業する体制）。Agent の中でさらに Agent が使えるかは確認していないため、Agent 経由に移すフェーズを増やすときは、その command の体制が Agent ツールを使わないことを先に確かめる
- Agent も Skill と同じく、完了通知で返却を受け取るまで次の手順に進まない

```
Agent(
  subagent_type: "general-purpose",
  model: "{表のモデル}",
  description: "{phase} ({tier})",
  prompt: """
Read $HOME/.claude/commands/{phase}.md and follow it exactly as your instructions for this run. Ignore its YAML frontmatter.

ARGUMENTS: "{task description} --tier={tier} --task-file={TASK_FILE} --linear-id={LINEAR_ID}"

Do not use the Agent tool; do all the work yourself. End your final message with the OUTPUT format the command specifies.
"""
)
```

## STEP 0: CLASSIFY

`$HOME/.claude/rules/adaptive-execution.md` の基準で tier を判定し、結果と根拠をユーザーに報告する。上書き指示がない限り即 STEP 1 へ進む。

**tier=XS の場合:** 直接実装を提案してここで終了する（STEP 1 以降は S / M / L のみ）。

## STEP 1: LINEAR タスク確認

引数から Linear ID（例: `PROJ-573`）を検出する。

- **検出できた場合:** LINEAR_ID として使用（確認不要）。`mcp__linear-server__get_issue` でタスク詳細を取得してタスク説明を補完し、即 STEP 2 へ
- **検出できなかった場合:** ユーザーに Linear タスク ID または URL を質問する。既存タスクがあれば ID を取得、なければ `mcp__linear-server__save_issue` で新規作成し、即 STEP 2 へ

```
LINEAR_ID = "XXX-123"
```

## STEP 2: タスクファイル作成

以下のパスにタスクファイルを作成して即 STEP 3 へ進む。feature は LINEAR_ID のタスク内容から短いスネークケースで命名する。

```
TASK_FILE = .claude/docs/decisions/task-{LINEAR_ID}-{feature}.md
```

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
<!-- orchestrator が startproject の返却 BRIEF から記入 -->

### Design
<!-- orchestrator が startproject の返却 DESIGN から記入 -->

### Plan
<!-- orchestrator が startproject の返却 PLAN から記入 -->

## team-implement
<!-- orchestrator が team-implement の返却 IMPLEMENTATION_NOTES から記入 -->

## team-review
<!-- orchestrator が team-review の返却 REVIEW から記入 -->

## deploy
<!-- orchestrator が deploy の返却 DEPLOY から記入 -->
```

`##` 見出しはプロセス名で固定する（kanban がこの見出しでフェーズを判定する）。

## STEP 3: startproject を実行

### tier=S

startproject は起動せず、orchestrator が関連コードを読んで計画し、TASK_FILE に直接書く。リサーチと OpenCode への設計相談はしない。

| 書き込み先 | 内容 |
|---|---|
| `## startproject` > `### Brief` | Goal / Scope / Success Criteria を数行 |
| `## startproject` > `### Design` | 方針を 1-2 行 |
| `## startproject` > `### Plan` | 実装タスクリスト |

- コードを読んで S に収まらない（ファイル数・設計判断・リスクが S を超える）と分かったら、tier を上げて報告し、下の「tier=M / L」を実行する
- タスクの解釈が複数考えられるときだけ `AskUserQuestion` で確認する（Gate 1 相当）。確認した場合の `GATE1` は `approved` / `revised`、確認しなければ `skipped`
- **[MUST]** 計画の要約を `mcp__linear-server__save_comment` で LINEAR_ID に投稿する

書き終えたら即 STEP 4 へ進む。

### tier=M / L

```
/startproject "{task description} --tier={tier} --task-file={TASK_FILE} --linear-id={LINEAR_ID}"
```

startproject は `agent: Plan` の読み取り専用コマンド。`BRIEF` / `DESIGN` / `PLAN` / `LINEAR_COMMENT` / `GATE1` を返してくる。途中の質問にはユーザーが回答し、計画完成後に返却される。

**[MUST]** 返却内容を TASK_FILE に書き込む:

| OUTPUT セクション | 書き込み先 |
|---|---|
| `BRIEF` | `## startproject` > `### Brief` |
| `DESIGN` | `## startproject` > `### Design` |
| `PLAN` | `## startproject` > `### Plan` |

**[MUST]** `LINEAR_COMMENT` の本文を `mcp__linear-server__save_comment` で LINEAR_ID に投稿する。

**Gate 1:** startproject が自己判断で発動し、ユーザーの承認（または修正）が済んでから返却してくる（詳細は startproject.md）。`GATE1`（`auto-approved` / `approved` / `revised`）の値に関わらず即 STEP 4 へ進み、値は STEP 7 の完了報告に含める。

## STEP 3F: 追加修正モード

通常モードの STEP 0〜3 の代わりに実行し、STEP 4 に合流する。追加依頼も team-implement → team-review → deploy を必ず通す（orchestrator が直接編集して push しない）。F1〜F5 を順に実行し、途中で止まるのは前提不成立のときだけ。

### F1: TASK_FILE を読む

指定された TASK_FILE から以下を読み、「状態管理」の変数を復元する。

| 読む場所 | 復元するもの |
|---|---|
| `# Task: {LINEAR_ID} — {task description}`（先頭行） | 元の task description |
| `## Meta` の `linear_id:` / `tier:` / `status:` / `branch:` / `base:` | `LINEAR_ID` / `tier` / 前提確認の材料 |
| `## deploy` の `PR/MR:` | 既存 PR / MR の URL |
| `## startproject` > `### Plan` の `#### 追加依頼 {n}` | 追加依頼の通し番号 n（既存の最大 + 1 を次の n にする） |
| `## team-implement` / `## team-review` の `### {m}回目` | 実装・レビューの回数 m（既存の最大 + 1 を次の m にする） |

n と m は独立に数える（差し戻しで m だけ増えることがある）。

**TASK_FILE が作業ツリーに無い場合**（tracked リポジトリでは STEP 6c 後、PR がマージされるまで TASK_FILE は作業ブランチにしか無い。モード判定 (a) の履歴探しから来た場合もここ）: `git log --all --format=%H -1 -- {TASK_FILE}` でコミットを見つけ、`git branch -a --contains {hash}` で作業ブランチを特定し、`/deploy "git switch {branch}"`（Ad-hoc Git モード。`switch` はガード対象外）で切り替えてから読む。`git branch -a --contains` は `remotes/origin/{branch}` の形でも返すので、`switch` には `remotes/origin/` を除いたローカル名を渡す（ローカルに無ければ `git switch` がリモート追跡ブランチから作る）。複数のブランチが返れば（起きやすいのは PR マージ後に分岐元を pull していないとき: 作業ブランチと `remotes/origin/main` の両方が返る）`## Meta` の `branch:` と一致するものを選ぶ。この時点では TASK_FILE が作業ツリーに無いので、`## Meta` は `git show {hash}:{TASK_FILE のリポジトリルート基準の相対パス}` で読む（例: `git show {hash}:.claude/docs/decisions/task-{LINEAR_ID}-….md`。`{rev}:{path}` の path に絶対パスは渡せない）。見つからなければ中止して案内する。

### F2: 前提確認

以下をすべて満たすときだけ続行する。読み取り系なので orchestrator が直接実行してよい。

| 条件 | 確認方法 |
|---|---|
| `status` が `in-review` | `## Meta` |
| `branch:` が空でない | `## Meta` |
| `## deploy` に PR / MR URL がある | `## deploy` の `PR/MR:` |
| その PR / MR が open | GitHub: `gh pr view {URL} --json state --jq .state` が `OPEN` ／ GitLab: `glab mr view {IID} --output json` の `state` が `opened`（IID は URL 末尾の番号） |

不成立なら理由別に案内して終了する（STEP 4 以降は実行しない）。

| 不成立の理由 | 案内 |
|---|---|
| `status` が `planning` / `implementing` / `reviewing` / `deploying` | 通常フローの途中で止まっている。該当 STEP から再開するかユーザーに確認する |
| `status` が `done`、または PR / MR が merged / closed | 既存 PR には追加できない。通常モードで新しいタスクとして起票するか確認し、了承なら STEP 0 から実行する |
| `branch:` が空、または `## deploy` に URL がない | deploy が済んでいない。STEP 6 から再開するかユーザーに確認する |

### F3: 規模判定

追加依頼**単体**を `$HOME/.claude/rules/adaptive-execution.md` の基準で見る。以下のいずれかに当たれば「再設計」、それ以外は「そのまま追加」とし、判定と根拠をユーザーに報告して続行する。

- 元の `tier` より上になる
- Hard Trigger に当たる
- `### Design` の「採用した方針」を変える
- 独立した機能を複数含む

**再設計の場合**（STEP 4 のエスカレーションと同形）:

1. `tier` 変数と `## Meta` の `tier:` を更新する（`status` はこの時点では変えない）
2. F4 で `#### 追加依頼 {n}` を追記する
3. 新しい tier で STEP 3 を実行し、返却で `## startproject` を上書きする（Brief / Design / Plan は追加依頼を含めて書き直させる）
4. 上書き後の `### Plan` 末尾に `#### 追加依頼 {n}` を再掲し、F5 へ進む。書き直した Plan には追加依頼が含まれるので、再掲時は F4 テンプレートの前提行を次に差し替える（そのまま再掲すると「この追加依頼だけを実装する」が新 Plan と矛盾し、再設計部分の実装が飛ばされる）:
   `- 前提: 上の Plan のうち既存 PR で実装済みの部分を除いて実装する（この追加依頼を含む再設計分が対象）`

### F4: 追加依頼を記録

`### Plan` の末尾に以下を追記する（既存の Plan は消さない。`#### 追加依頼` は kanban の見出し判定に影響しない）。

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

「状態管理」に従い `status` を `implementing` に戻し、Linear を "In Progress" にして STEP 4 を実行する。STEP 4 → 5 → 6 → 7 は通常モードと同じ（実装・レビューは `{m}回目` として追記。STEP 6 は 6a で既存 PR / MR へ追加 push し、6b で `#### 追加 push（追加依頼 {n}）` を `## deploy` の末尾に追記して `in-review` に戻し、6c でその記録を `docs(task):` として同じブランチに push する。Gate 2 の差し戻しも同じ）。

> **kanban の副作用:** `## deploy` が埋まった TASK_FILE の `status` を `implementing` に戻すため、追加修正中は kanban が deploy 列に stale（status が古い）として表示する。仕様として許容する。STEP 6b で `in-review` に戻ると解消する。また tracked リポジトリでは 6c 後、分岐元を checkout している間は TASK_FILE が作業ツリーに無く kanban に表示されない（PR マージ後に表示される）。これも仕様として許容する。

## STEP 3P: フェーズ指定モード

既存 TASK_FILE の **1 フェーズを 1 つの外部 AI で 1 回**実行し、結果を TASK_FILE に追記する。STEP 4〜6 には合流せず、P1〜P7 を順に実行して STEP 7 の報告で終わる（P7 は `--phase=deploy` だけ）。**`## Meta` の `status:` は P4 で節の書き込みを確認したあとに、実行したフェーズの値へ更新する**（P4 末尾の表。失敗時は変えない。次に何を回すかはユーザーが決める）。並列実行はしない（1 回の呼び出しで 1 フェーズ × 1 AI）。

### 引数

| 引数 | 必須 | 意味 |
|---|---|---|
| `--task-file={TASK_FILE}` | 必須 | 既存の `task-*.md`。作業ツリーに無ければ P1 の手順で履歴から作業ブランチに移って読む。作業ツリーにも履歴にも無ければ中止して案内する（新規タスクは通常モード） |
| `--phase={phase}` | 必須 | `startproject` / `team-implement` / `team-review` / `deploy` |
| `--ai={ai}[:{model}]` | `--adopt` 以外で必須 | `pi` / `cline` / `opencode` / `codex`。`:{model}` は各 CLI の `--model` にそのまま渡す（変換しない）。Claude の別モデルは対象外 |
| `--adopt=案 {k}` | 任意 | `--phase=startproject` 専用。CLI を起動せず、候補 `### 案 {k}` を `### Brief / Design / Plan` に昇格させて終わる |

### TASK_FILE に書く形（このモードの規約）

外部 CLI が書く場合も orchestrate が代筆する場合も同じ形にする（一般向け SKILL.md の「書き込み規約」と同じ内容。ここが Claude 側の定義）。

- **見出しは通常モードと同じ。** team-implement / team-review は `### {m}回目`、startproject の候補は `### 案 {k}`、deploy は `#### PR / MR`（追加 push は `#### 追加 push（追加依頼 {n}）`）。見出しに AI 名や日時を入れない
- **使った AI は見出しの直下の行**（空行を挟まない）に `利用AI: {label}（{YYYY-MM-DD HH:MM}）` と書く（label は `{ai}/{model}`、model 省略時は `{ai}`。日時は P2 で渡した実行日時）。deploy は `- 作成日時:` / `- 日時:` の行が別にあるので `利用AI: {label}` だけ
- 同じ回を別の AI でレビューすると `## team-review` に同じ `### {m}回目` が並ぶ。見出しは変えず、区別は `利用AI:` の行で付ける
- 節の中に「フェーズ指定モードで実行した」「外部 CLI で実行した」といった実行経路の説明は書かない（誰が書いたかは `利用AI:` の行だけで示す）
- **実行したフェーズの節（`## {phase}`）の外には追記しない。** 例外は team-implement の `## Meta` の `branch:` / `base:` だけ。`status:` は CLI が書かない（orchestrate が P4 で更新する）
- `--adopt` の採用の印は見出しに付けず、候補の `利用AI:` の行の直後に `採用: {YYYY-MM-DD HH:MM}` の行で書く

### P1: TASK_FILE を読み、回数と前提を決める

STEP 3F F1 と同じ場所から `LINEAR_ID` / `tier` / task description / `branch:` / `base:` を復元し、フェーズ別に次を決める。TASK_FILE が作業ツリーに無ければ F1 と同じ手順（`git log --all` でコミットを見つけ、`git branch -a --contains` の結果から `remotes/origin/` を除いたローカル名で `/deploy "git switch {branch}"`）で作業ブランチに移ってから読む。

| phase | 決めるもの | 前提（満たさなければ中止して案内） |
|---|---|---|
| `startproject` | k = `## startproject` の `### 案 {k}` の最大 + 1（初回 1） | — |
| `team-implement` | m = `## team-implement` の `### {m}回目` の最大 + 1（初回 1） | `### Brief / Design / Plan` が埋まっている（候補だけなら先に `--adopt`） |
| `team-review` | m = `## team-implement` の最新回の番号（無ければ 1） | `## team-implement` が埋まっている |
| `deploy` | — | `## team-review` の最新回が PASS、`branch:` が空でない |

ラベルは `--label={ai}/{model}`（model 省略時は `{ai}`）。ラベルは見出しには入らず、見出し直下の `利用AI:` 行になる。期待する見出し（P4 の確認に使う。**照合キーは見出し行そのもの**で、`### …` は完全一致、`#### 追加 push（` だけ前方一致。見出しに AI 名が無いので、同じ見出しが既にあっても区別せず、`## {phase}` の節の中の出現数を P3（起動前）と P4（起動後）で数えて差で判定する）:

| phase | 期待する見出し | 照合キー |
|---|---|---|
| `startproject` | `### 案 {k}` | `### 案 {k}`（完全一致） |
| `team-implement` / `team-review` | `### {m}回目`（team-review で同じ見出しが既にあってもそのまま。区別は `利用AI:` の行） | `### {m}回目`（完全一致。`## team-implement` にも同じ見出しがあるので、数えるのは `## {phase}` の節の中だけ） |
| `deploy` | `#### PR / MR`（既に PR/MR URL があれば `#### 追加 push（…）`） | `#### PR / MR`（完全一致）または `#### 追加 push（`（前方一致） |

`--adopt=案 {k}` のとき: `### 案 {k}` の `#### Brief` / `#### Design` / `#### Plan` の本文を `### Brief` / `### Design` / `### Plan` にコピーし（既存の本文は上書き。`### Plan` 末尾の `#### 追加依頼 {n}` があれば残す）、候補の `利用AI:` 行の直後（無ければ見出しの直後）に `採用: {YYYY-MM-DD HH:MM}` の行を入れて（見出しは変えない。日時は `date '+%Y-%m-%d %H:%M'`）、P2〜P5 を飛ばして P6 へ。ほかの候補に既に `採用:` があってもその行は消さない（日時が新しい方が現行）。該当の候補が無ければ中止して案内する。`## startproject` の外に書くのは `## Meta` の `status:` を `planning` にすることだけ（P4 末尾の表と同じ）。

### P2: 呼び出し表を読み、プロンプトを作る

**呼び出し表の場所を先に解決する。** 外部 CLI の起動オプション・権限・最終メッセージの取り出し・共通則は harness リポジトリの `agents/README.md`「外部 CLI のフェーズ実行」が唯一の定義で、`~/.claude` には同期されない（`sync-claude.sh` の対象外）。次の順で `HARNESS` を決め、`{HARNESS}/agents/README.md` の同節を Read してから P3 / P4 で使う:

1. 環境変数 `HARNESS` が設定されていて `$HARNESS/agents/README.md` がある → それ（`echo "${HARNESS:-}"` で確認）
2. `$HOME/src/harness/agents/README.md` がある → それ
3. どちらも無ければ中止し、`AskUserQuestion` で harness リポジトリのチェックアウトのパスを尋ねる（推測で続けない）

外部 CLI に読ませる一般向けフェーズ定義は `SKILL_PATH = $HOME/.agents/skills/{phase}/SKILL.md`。無ければ中止し、`{HARNESS}/sync-agents.sh` の実行を案内する。プロンプトは `.claude/logs/phase-{phase}-{ai}-{YYYYMMDD-HHMM}.prompt.txt` に書き（`mkdir -p .claude/logs`。`.claude/` は gitignore 済み）、CLI には `"$(cat {prompt_file})"` で渡す。**実行日時は orchestrate が `date '+%Y-%m-%d %H:%M'` で取ってプロンプトに入れる**（CLI 側で推定させず、見出しの `{日時}` を orchestrate 側で確定させる。ログファイル名の日時と揃う）。

```
Read {SKILL_PATH} and follow it exactly as your instructions for this run.

ARGUMENTS: "{task description} --task-file={TASK_FILE の絶対パス} --tier={tier} --linear-id={LINEAR_ID} --label={label}"

Current date and time: {YYYY-MM-DD HH:MM}. Use this value wherever the skill needs a timestamp; do not guess one.

Work in {リポジトリの絶対パス}. End your final message with the `### RESULT` / `### SECTION` blocks the skill specifies.
```

`--linear-id` は `NOLINEAR` のときも書く（一般向けフェーズはこの値で Linear を飛ばす）。

`--phase=team-review` では、`git branch --show-current` が `## Meta` の `branch:` と違えば中止して案内する（orchestrate は `git switch` しない。CLI に切り替えさせると P5 の比較でブランチ変更として出る）。差分は CLI が自分で `git` を実行して取るので、orchestrate はプロンプトに入れない。

### P3: 外部 CLI を起動して完了を待つ

呼び出し表は P2 で読んだ `{HARNESS}/agents/README.md` の「外部 CLI のフェーズ実行 › 呼び出し表」（起動オプションの唯一の定義。ここには書かない）。**全フェーズ同じ起動オプション**で、確認なしで編集・コマンド実行を許す（読み取り専用にしない。Gate 1 / Gate 2 でユーザー了承済み。理由は同節の「権限」）。

- startproject / team-review では、起動前にスナップショットを `.claude/logs/phase-{phase}-{ai}-{YYYYMMDD-HHMM}.before.txt` に残す（P5 で比較）: `git status --porcelain`、`git rev-parse HEAD`、`git branch --show-current`、`git for-each-ref`、`git stash list`
- 全フェーズで、P4 用に `## {phase}` の節の中の照合キー（見出し行）の出現数を**常に**数えて記録する（P4 のコマンド。同じ見出しが既に並んでいても差で判定できる）
- `--ai=codex` は呼び出し表のとおり `-o {last}` で最終メッセージを `.claude/logs/phase-{phase}-{ai}-{YYYYMMDD-HHMM}.last.md` に書かせる（サンドボックスのオプションも表に従う。ここで変えない）
- 起動は **background Bash** で `timeout -k 1m 30m {cli …} "$(cat {prompt_file})" < /dev/null > {log_file} 2>&1`（`log_file` は `.claude/logs/phase-{phase}-{ai}-{YYYYMMDD-HHMM}.log`）。`< /dev/null` を外さない（stdin が開いたままだとハングする CLI がある）。`2>/dev/null` は付けない
- **完了通知が来るまで次に進まない。** `pgrep` やログの先読みで完了を推測しない
- 失敗判定: exit code ≠ 0、または 124 / 137（timeout）、または P4 で節も `### SECTION` も無い。失敗時は log の末尾をユーザーに示して STEP 7 の報告で終わる（TASK_FILE には書かない）

### P4: TASK_FILE を確認し、未書き込みなら代筆する

**[MUST]** TASK_FILE の **`## {phase}` の節の中だけ**を対象に、P1 の照合キーと一致する見出し行を数え、P3 で記録した起動前の数より増えたかで判定する（見出しに AI 名は無いので、同じ見出しが何本並んでいても差で判定する。`### {m}回目` は `## team-implement` にも現れるので、ファイル全体を `grep -c` しない）:

````bash
# prefix=0: 見出し行と完全一致（### 案 {k} / ### {m}回目 / #### PR / MR）、prefix=1: 前方一致（#### 追加 push（）
awk -v sec='## {phase}' -v key='{照合キー}' -v prefix=0 '{sub(/[ \t]+$/,"")} /^```/{fence=!fence; next} fence{next} /^## /{f=($0==sec)} f && (prefix ? index($0,key)==1 : $0==key)' {TASK_FILE} | wc -l
````

コードブロック（```` ``` ```` で囲まれた範囲）の中の `## ` / `### ` 行は節の切り替えにも数にも入れない（節の本文にコマンド例や見出しの例が引用されていることがある）。起動前後の値の差が 1 以上なら「増えている」。

| 結果 | 動作 |
|---|---|
| 増えている | そのまま。ただし増えた見出しの直下に `利用AI: {label}…` の行が無ければ、その行を orchestrate が挿入して報告する（「TASK_FILE に書く形」）。`## Meta` の `status:` は CLI が変えていても下表の値で上書きし、`## {phase}` の外（例外: team-implement の `branch:` / `base:`）に追記があればユーザーに報告する（自動では消さない） |
| 増えていない | 最終メッセージから `### SECTION` 以下を切り出し（下記「最終メッセージの取り出し」）、`## {phase}` の末尾に追記する（代筆）。見出しは P1 の期待する見出しにし、直下に `利用AI: {label}（{日時}）` の行が無ければ足す。実行経路の説明（「代筆」「フェーズ指定モード」など）は節に書かない。team-implement は `### RESULT` の `branch:` / `base:` を `## Meta` に書く |
| 節も `### SECTION` も無い | 失敗として報告する |
| deploy が `pr: 中止（理由）`（`### SECTION` が `### 中止`） | 代筆せず、中止理由をそのまま報告する |

最終メッセージの場所（ai ごと）と `### SECTION` の切り出し方は P2 で読んだ `{HARNESS}/agents/README.md` の「外部 CLI のフェーズ実行 › 最終メッセージの取り出し」が唯一の定義（ここには書かない）。切り出した本文をそのまま追記する。

どのフェーズも CLI が TASK_FILE に直接書くのが原則（`written: yes`）。サンドボックス等で書けなかった（`written: no`）ときだけ代筆になる。

**[MUST]** 節の確認・代筆が済んだら `## Meta` の `status:` を実行したフェーズの値に更新する（通常モードの「状態管理」と同じ語彙。kanban はこの値と節の中身の遠い方で列を決める）。通常モードは STEP 開始時に更新するが、このモードは 1 フェーズ単発で失敗時に TASK_FILE を汚さない原則があるため、成功が確定した P4 の末尾で更新する。失敗（exit ≠ 0 / timeout / 節も `### SECTION` も無い）と deploy の `pr: 中止` では変えない。

| phase | 成功後の `status:` |
|---|---|
| `startproject`（`--adopt` も） | `planning` |
| `team-implement` | `implementing` |
| `team-review` | `reviewing`（FAIL でも同じ。通常モードの Gate 2 で判断待ちの状態と同じで、次に `--phase=team-implement` を回した時点で `implementing` になる） |
| `deploy` | `in-review` |

### P5: 作業ツリーと ref の確認

startproject / team-review は TASK_FILE 以外を変更しない前提（SKILL.md の指示。起動オプションでは強制しない）。P3 のスナップショットと起動後の `git status --porcelain` / `git rev-parse HEAD` / `git branch --show-current` / `git for-each-ref` / `git stash list` を比べ、TASK_FILE 以外の作業ツリーの差分、HEAD・ブランチ・ref・stash の変化があれば「{phase}（{ai}）が TASK_FILE 以外を変更しました: {差分の内容}。内容を確認し、不要なら戻してください」と報告する（自動で戻さない。扱いはユーザーが決める）。簡単な比較なので、変更済みファイルの再編集や push のように見えない変化もある。team-implement / deploy は変更が前提なので比較しない。

### P6: Linear と報告

`### RESULT` の `linear:` が `未投稿` で LINEAR_ID が実在するなら、書いた節の要約を `mcp__linear-server__save_comment` で LINEAR_ID に投稿する（`posted` なら投稿しない）。**Linear のステータスは変えない**（`## Meta` の `status:` は P4 で更新済み）。その後 P7（`--phase=deploy` のみ。それ以外は飛ばす）→ STEP 7 へ（Mode 行は `フェーズ指定（{phase}、{ai}[:{model}]、{見出し}）`。`--adopt` なら `フェーズ指定（startproject、案 {k} を採用）`）。実行経路の記録は STEP 7 の報告（ユーザー向け）だけで、TASK_FILE には残さない。

### P7: deploy の finalize

`--phase=deploy` で `### RESULT` の `pr:` が URL のときだけ（`中止（…）` なら飛ばす）、P6 の後に実行する。外部 CLI の deploy は分岐元に戻らず作業ブランチに留まる（一般向け SKILL.md は TASK_FILE をコミットしない）ので、P4 で確定した記録（`利用AI:` 行・代筆分を含む）を `/deploy` の Finalize モードで同じブランチに push してから分岐元に戻す:

```
/deploy "--finalize --task-file={TASK_FILE} --linear-id={LINEAR_ID}"
```

`FINALIZE` の返却は TASK_FILE に書かず、STEP 7 の deploy 行に添える。`- 中止:` があれば理由をそのまま報告する（作業ブランチに残った変更はそのまま）。`status:` は P4 で更新済み（deploy は `in-review`）で、P7 の `docs(task):` コミットに含まれる。

P7 を飛ばしたとき（`pr: 中止（…）`）や中止したときは、外部 CLI が留まった**作業ブランチのまま**で終わる（分岐元には戻らない）。STEP 7 で現在のブランチを示す。

## STEP 4: team-implement を実行

開始時に「状態管理」に従い TASK_FILE の `status` と Linear のステータスを更新する。**完了次第即 STEP 5 へ進む。**

起動方法は「tier 別のフェーズ構成」に従う（S は Agent・`sonnet`、M は Agent・`opus`、L は下の Skill）。

```
/team-implement "{task description} --tier={tier} --task-file={TASK_FILE} --linear-id={LINEAR_ID}"
```

team-implement はコードと git 操作のみ行い、`IMPLEMENTATION_NOTES` / `LINEAR_COMMENT` / `BRANCH` / `BASE` / `ESCALATION` を返してくる。

**[MUST]** 返却内容を TASK_FILE に書き込む:

| OUTPUT セクション | 書き込み先 |
|---|---|
| `IMPLEMENTATION_NOTES` | `## team-implement` に `### {m}回目` として追記 |
| `BRANCH` | `## Meta` の `branch:` |
| `BASE` | `## Meta` の `base:` |

`{m}` は実装・レビューの回数（`## team-implement` の既存の最大 + 1。初回は `### 1回目`）。`{n}` は追加依頼の通し番号にだけ使う（STEP 3F）。

**[MUST]** `LINEAR_COMMENT` の本文を `mcp__linear-server__save_comment` で LINEAR_ID に投稿する。

**エスカレーション:** 返却に `ESCALATION` がある場合（team-implement が tier の引き上げで中断した）:

1. ユーザーに新しい tier と理由を報告する
2. `tier` 変数と `## Meta` の `tier:` を更新する（`status` は `implementing` のまま。`planning` に戻すと kanban が「status が古い」と警告する）
3. 新しい tier で STEP 3 からやり直し、startproject の返却で `## startproject` を上書きする。作業ブランチ上の変更はそのまま引き継ぐ

**完了確認:** `ESCALATION` がなく、`## team-implement` が埋まっていることを確認してから STEP 5 へ進む。

## STEP 5: team-review を実行

起動方法は「tier 別のフェーズ構成」に従う（S は Agent・`sonnet`、M / L は下の Skill）。

```
/team-review "{task description} --tier={tier} --task-file={TASK_FILE} --linear-id={LINEAR_ID}"
```

team-review は `VERDICT` / `REVIEW` / `LINEAR_COMMENT` を返してくる。

**[MUST]** 返却内容を TASK_FILE に書き込む:

| OUTPUT セクション | 書き込み先 |
|---|---|
| `REVIEW` | `## team-review` に `### {m}回目` として追記 |
| `VERDICT` | `### {m}回目` の直下に `**VERDICT: PASS**` / `**VERDICT: FAIL**` の 1 行（kanban が Gate 2 差し戻しの判定に使う。`REVIEW` 本文にこの行が含まれていれば重ねて書かない） |

**FAIL の場合も必ず書き込む**（差し戻し履歴を残すため）。Gate 2 で STEP 4 に戻ったら、次の実装・レビューは m+1 回目として追記する（上書きしない）。

**[MUST]** `LINEAR_COMMENT` の本文を `mcp__linear-server__save_comment` で LINEAR_ID に投稿する。

**Gate 2:** `VERDICT` が `PASS` なら即 STEP 6 へ。`FAIL` ならユーザーに報告し判断を待ち、team-implement に戻るか確認する。

## STEP 6: deploy を実行

6a → 6b → 6c を順に実行し、**完了次第即 STEP 7 へ進む。** deploy 後の TASK_FILE の記録（`## deploy`・`status: in-review`）を作業ブランチ上でコミット・push してから分岐元に戻るための 3 段構造（6a の後は作業ブランチに留まっている）。

### 6a: `/deploy`（コード commit → push → PR / MR）

```
/deploy "{task description} --tier={tier} --task-file={TASK_FILE} --linear-id={LINEAR_ID}"
```

deploy はコミット・push・PR / MR 作成（既存の PR / MR があれば追加 push と本文追記）のみ行い、`DEPLOY` / `LINEAR_COMMENT` を返してくる。**分岐元には戻らず作業ブランチに留まる**（TASK_FILE 自体はコードのコミットに含めない）。

### 6b: TASK_FILE への記録と Linear（作業ブランチ上）

**[MUST]** 返却内容を TASK_FILE に書き込む:

| OUTPUT セクション | 書き込み先 |
|---|---|
| `DEPLOY` | `## deploy`。**追加修正モードでは上書きせず**、返却の `#### 追加 push（追加依頼 {n}）` を `## deploy` の末尾に追記する |

**[MUST]** 同時に「状態管理」に従い `## Meta` の `status` を `in-review` にする（6c でコミットされるので、STEP 7 ではなくここで書く）。

**[MUST]** `LINEAR_COMMENT` を投稿し、Linear のステータスを "In Review" にする（失敗したら黙って飛ばさず報告する）。

### 6c: `/deploy --finalize`（TASK_FILE を commit → push → 分岐元へ）

```
/deploy "--finalize --task-file={TASK_FILE} --linear-id={LINEAR_ID}"
```

TASK_FILE だけを `docs(task):` でコミットして同じ作業ブランチに push し、分岐元（`base:`）に戻る（TASK_FILE が gitignore のリポジトリでは commit / push せず戻るだけ）。`FINALIZE` を返してくる。**返却は TASK_FILE に書かない**（書くと再び未コミット差分になる）。STEP 7 の deploy 行に添える。`- 中止:` があれば（他ファイルがステージ済み・リモートと分岐・分岐元へ戻れない等）理由をユーザーに報告する。中止時は**作業ブランチに留まったまま**で、残った変更はそのまま（履歴は書き換えない）。

**6b と 6c の間で中断した場合**（`in-review` 済み・TASK_FILE 未コミット・作業ブランチ上）: 記録は失われない。次の追加修正モードは F2（`in-review`）を通り、その 6c で今回の記録と追加 push の記録がまとめて `docs(task):` コミットになる。先に回収したければ `/deploy "--finalize --task-file={TASK_FILE} --linear-id={LINEAR_ID}"` を単独で実行してよい（差分が無ければ何もせず分岐元に戻るだけなので再実行に安全）。

## STEP 7: 完了報告

ユーザーに日本語で最終サマリーを報告する。

```
## 完了: {task description}

- Linear: {LINEAR_ID}
- Tier: {tier}
- Task File: {TASK_FILE}
- Mode: 通常 | 追加修正（追加依頼 {n}、{m}回目） | フェーズ指定（{phase}、{ai}[:{model}]、{見出し}）

### 各フェーズのサマリー
- startproject: ...（Gate 1: {GATE1}）
- team-implement: ...
- team-review: ...
- deploy: ...
```

deploy 行には PR / MR の URL に加えて 6c の `FINALIZE` の結果（`docs(task):` コミットの hash・push 先・現在のブランチ。中止ならその理由）を添える（TASK_FILE には書かない）。**現在のブランチは必ず示す**（6c を実行しなかった・中止した・P7 を飛ばしたときは作業ブランチに留まっている。`git branch --show-current` で確認する）。`status` は 6b で `in-review` にしてあるので STEP 7 では書かない。

tier=S では startproject 行を「（S: orchestrate が計画、Gate 1: {GATE1}）」にする。追加修正モードでは startproject 行を「（追加修正モード: スキップ）」または再設計時の結果にし、deploy 行に既存 PR / MR の URL を書く。

フェーズ指定モードでは実行したフェーズの行だけを書き（書いた見出しと `利用AI:` の値・代筆の有無・`### RESULT` のフェーズ固有行: gate1 / escalation / verdict / pr。deploy は P7 の `FINALIZE` の結果と現在のブランチも添える。P7 を飛ばしたときは作業ブランチに留まっている旨を書く）、他の行は「（未実行）」にする。`status` は実行したフェーズの値（P4 の表）になっているので、次に回すフェーズと呼び出し例（`/orchestrate "--task-file=… --phase=… --ai=…"` または `--adopt=案 {k}`）を末尾に添える。

deploy 以外のフェーズ（startproject / team-implement / team-review）を 6c の後に回した場合、P1 のガードで作業ブランチに移ってから TASK_FILE に追記するので、**追記は未コミットのまま作業ブランチに残る**（P7 は `--phase=deploy` だけ）。この場合は「現在のブランチ」に加えて、回収方法として `/deploy "--finalize --task-file={TASK_FILE} --linear-id={LINEAR_ID}"` を単独で実行すれば `docs(task):` でコミット・push して分岐元に戻れる旨を報告に添える（次に deploy フェーズを回すなら、その P7 でまとめてコミットされるので急いで回収しなくてもよい）。

## 状態管理

orchestrator は以下を変数として保持し、全 command に引数で渡す。

| 変数 | 設定タイミング |
|---|---|
| `tier` | STEP 0（追加修正モードは STEP 3F F1 で `## Meta` の `tier:` から復元。F3 の再設計で更新） |
| `LINEAR_ID` | STEP 1（追加修正モードは STEP 3F F1 で `## Meta` の `linear_id:` から復元） |
| `TASK_FILE` | STEP 2（追加修正モードは引数または Linear ID から特定。フェーズ指定モードは引数の `--task-file` 必須） |

作業ブランチとその分岐元は、引数ではなく TASK_FILE の `## Meta` の `branch:` / `base:` で受け渡す（STEP 4 で記入。追加修正モードでは既存の値をそのまま使う。フェーズ指定モードの team-implement は外部 CLI が書き、未書き込みなら P4 で代筆する）。

フェーズ指定モード（STEP 3P）は Linear ステータスを**変えず**、`status` は STEP 3P P4 末尾の表で更新する（成功後に、実行したフェーズの値へ）。下表は通常・追加修正モードだけに適用する。

### TASK_FILE の `status` と Linear ステータス

各 STEP の開始時に `## Meta` の `status` を更新する（Gate 2 で STEP 4 に戻った場合も `implementing` に戻す）。例外は `in-review` で、STEP 6b（deploy 返却後、作業ブランチ上）で書き、6c の `docs(task):` コミットに含める。`done` には orchestrator はしない。PR がマージされた後に人間が変更する。

| タイミング | TASK_FILE `status` | Linear ステータス |
|---|---|---|
| STEP 2（作成時） | `planning` | — |
| STEP 3F F5（追加修正の開始 = STEP 4 開始と同じ） | `implementing` | "In Progress" |
| STEP 4 開始 | `implementing` | "In Progress" |
| STEP 5 開始 | `reviewing` | — |
| STEP 6 開始 | `deploying` | — |
| STEP 6b（deploy 返却後、作業ブランチ上） | `in-review`（PR を出してマージ待ち） | "In Review" |
| STEP 7 | —（報告のみ。書き込みなし） | — |
