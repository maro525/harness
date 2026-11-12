---
name: orchestrate
description: Orchestrator for the task-file workflow — classifies the task, creates the TASK_FILE (kept outside the repository, under ~/.local/share/harness/tasks/<repo>/), then runs startproject → team-implement → team-review → deploy through ~/.claude/scripts/phase-run.sh, writes ## Meta / status itself, handles Gate 1 / Gate 2 and the FAIL loop, and finishes with the deploy three-stage (code PR → record → return to base). Use when asked to run a task end to end, or to run one phase of an existing task file (--phase).
metadata:
  phase: orchestrate
  writes: "## Meta, #### 追加依頼"
---

# orchestrate

Claude 版（`claude/commands/orchestrate.md`）の **pi / cline / codex 版**。TASK_FILE を書くのは orchestrator（このスキル）だけで、各フェーズは別プロセス（`phase-run.sh`）で走る。契約は `docs/phase-contract.md`。

**止まらずに STEP 0 → 7 まで進む。** 止まるのは Gate 1 / Gate 2 / XS の提案だけ。

## Input

```
$ARGUMENTS: "{task description} [--tier=S|M|L] [--task-file={TASK_FILE}] [--linear-id={LINEAR_ID}] [--issue={REFS}] [--phase={phase}] [--runner={SPEC}] [--phase-map={MAP}] [--adopt=案 {k}]"
```

| 引数 | 説明 |
|---|---|
| `--tier` | 省略時は自分で判定（STEP 0） |
| `--task-file` | 追加修正モード / フェーズ指定モードでは必須 |
| `--linear-id` | 省略時は引数から検出。無ければ `NOLINEAR` |
| `--issue` | `closes:#12,refs:#34` 形式。`## Meta` の `issue:` に書く |
| `--phase` | フェーズ指定モード（STEP 3P） |
| `--runner` / `--phase-map` | フェーズを走らせる CLI / モデル（`phase-run.sh` に渡す） |
| `--adopt` | フェーズ指定モードで `### 案 {k}` を昇格させる |

## 実行原則

- **TASK_FILE に書くのは自分だけ**: `## Meta`（`tier:` / `status:` / `branch:` / `base:` / `issue:`）と `#### 追加依頼 {n}` は orchestrator が書く。各フェーズは自分の節（`## startproject` など）を自分で書く。フェーズに `status:` を書かせない
- **フェーズの起動は `~/.claude/scripts/phase-run.sh` に一本化**する（CLI / モデルの差はスクリプトが吸収する）。1 フェーズ 1 プロセスで、完了を待ってから次へ進む
- **質問は `### QUESTIONS` プロトコル**（`docs/phase-contract.md`）。フェーズの出力に `### QUESTIONS` があれば、ユーザーに聞けるなら聞き、答えをファイルに書いて `--answers-file=` を付けて同じフェーズを再実行する。聞けないなら質問をそのまま最終メッセージに転記して終了する（推測で答えを作らない）
- **Linear の状態の書き手は自分（orchestrator）**: ステータス変更と description 更新は自分だけが行う（フェーズには書かせない）。コメントは、フェーズの系統が自分で投稿する場合（汎用 / OpenCode のフェーズ）はそれを尊重し、投稿しない系統（Claude の command）なら自分が `save_comment` で投稿する — **同じ結果を二重投稿しない**。`LINEAR_ID` が `NOLINEAR`、または MCP が無ければ「Linear: unavailable」と記録して続行し、止まらない。失敗も黙って飛ばさず報告する
- **失敗しても止まらない**: フェーズが失敗（exit ≠ 0 / 空出力 / タイムアウト）したら 1 度だけ別 runner で再試行し（`phase-run.sh` の fallback が自動で行う）、それでも駄目なら報告して停止する。TASK_FILE には失敗を書かない
- 報告は日本語。モデル名・runner 名・URL・ブランチ名はそのまま書く

## ラフな指示から実行まで（呼び出し側のエージェント向け）

**ユーザーに `--tier` / `--phase` / TASK_FILE のパスを打たせない。聞き返さない**（Linear ID だけは、既存 issue に紐づける必要があるときに確認してよい）。

| ユーザーの言い方 | モード | 自分で決めること |
|---|---|---|
| 「これ実装して」「PR まで」「最後までやって」 | 通常（STEP 0〜7） | tier 判定、feature 名、branch / base |
| 「この 1 フェーズだけ」「レビューだけ回して」 | フェーズ指定（STEP 3P） | どの phase か。`--task-file` は `task-file.sh find` で探す |
| 「さっきの PR に追加で」 | 追加修正（STEP 3F） | 既存 TASK_FILE を `find` で特定 |
| 「issue は無いけど頼む」 | 通常（NOLINEAR） | Linear は触らない。ロックは feature 名で取る |
| 「終わって」「もういい」 | — | `lock release`、残った tab を `close` / `reap` |

- runner は自分の CLI 名（Cursor なら `--runner=cursor`）。ロックと `## Meta` の `runner:` に入る
- **同じ issue を並列で回さない**（実行ロックが止める）。別 issue なら並列可
- 報告は日本語。Linear を触ったか（投稿 / ステータス / description）を最後に 1 行で添える
- 途中で相談が必要になったら `claude-consult.sh --text "..."`（前の回答を引き継ぐときだけ `--append {answer.md}`）

## モード判定

| モード | 条件 | 開始 |
|---|---|---|
| フェーズ指定 | `--phase=` がある（`--task-file` 必須） | STEP 3P |
| 追加修正 | `--phase` が無く、`--task-file` が既存、または Linear ID の `task-*.md` が存在する | STEP 3F |
| 通常 | それ以外 | STEP 0 |

## 状態管理（TASK_FILE と Linear）

### 実行ロック（1 タスク 1 ランナー）

TASK_FILE はブランチ単位で別ファイルになるため、それだけでは「Claude と Cursor が同じ issue を別ブランチで同時にやる」のを防げない。**issue（`repo` + `LINEAR_ID`）単位のリース**を `task-file.sh lock` で取り、取れなければ始めない。

| いつ | コマンド |
|---|---|
| STEP 2（TASK_FILE を作る前） | `task-file.sh lock acquire --linear-id={LINEAR_ID} --feature={feature} --runner={runner}` |
| 各 STEP の先頭（少なくとも 30 分に 1 回） | `task-file.sh lock refresh --linear-id={LINEAR_ID} --runner={runner}` |
| STEP 7 の報告後、または中止・失敗で抜けるとき | `task-file.sh lock release --linear-id={LINEAR_ID} --runner={runner}` |
| 状況確認 | `task-file.sh lock show --linear-id={LINEAR_ID}` |

- リースは `~/.local/share/harness/locks/{repo}-{LINEAR_ID}.lock`。`LINEAR_ID` が無いときは feature 名、それも無ければリポジトリ単位。既存の TASK_FILE を引き継ぐときは `--task-file={TASK_FILE}` を付けるとリースに記録される
- 既定の寿命は 45 分（`--ttl=45m`）。**持ち主が決めた寿命**で判定するので、refresh を怠ると別のランナーに奪われる
- `acquire` が exit 1 のときは**開始しない**。保持者（runner / started / cwd / task_file）と経過時間を報告して止まる。生きているリースを奪うのは `--takeover` を明示したときだけ
- 追加修正・フェーズ指定モードでも同じ（TASK_FILE を触る前に acquire、終了時に release）。ロックはリポジトリ外なので commit しない

`## Meta` の `status:` と `updated:` を更新するタイミングと、Linear に反映する内容。`LINEAR_ID` が `NOLINEAR` なら Linear 側は何もしない。Claude 版（`claude/commands/orchestrate.md`「状態管理」）と同じ表で、**ステータスを変えるのは orchestrator だけ**。

| タイミング | TASK_FILE `status` | Linear ステータス | description 更新 |
|---|---|---|---|
| STEP 2（作成時） | `planning` | — | ✓ |
| STEP 3 完了後（計画を書いた直後） | `planning` のまま | — | ✓ |
| STEP 3F F4 / STEP 4 開始 | `implementing` | "In Progress" | ✓ |
| STEP 5 開始 | `reviewing` | — | ✓ |
| STEP 6 開始 | `deploying` | — | ✓ |
| STEP 6b（deploy 返却後） | `in-review` | "In Review" | ✓（PR / MR の URL を含める） |
| STEP 7 | —（報告のみ） | — | — |

- **フェーズ指定モード（STEP 3P）は Linear ステータスを変えない**（既存タスクへの追記だから）。`status:` は 3P の手順で更新し、description はフェーズの結果で更新する
- `done` は自分では書かない（PR マージ後に人が変える）
- **description の規則**（Claude 版と同じ）: `get_issue` で現状を取り、行頭が `## 🤖 Orchestrate` の行から末尾だけを TASK_FILE から作り直して置換する（人の記述は一字も変えない）。`save_issue` には description だけを渡す（タイトル・ステータスは渡さない）
- コメントと description は別物: コメントは履歴、description はつねに最新の要約

## STEP 0: CLASSIFY

`claude/rules/adaptive-execution.md` の基準で tier を判定し、根拠を 1 行で報告する。

| tier | 目安 |
|---|---|
| XS | 1 ファイル・数行・判断不要。**実装を提案して終了**（STEP 1 以降に進まない） |
| S | 1〜2 ファイル、設計判断がほぼ無い |
| M | 複数ファイル、設計判断あり |
| L | 横断的・新規設計・複数フェーズにまたがる |

## STEP 1: LINEAR タスク確認

引数から `XXX-123` 形式を探す。見つかれば `LINEAR_ID` にし、MCP があれば `get_issue` で説明を補完する。見つからず、ユーザーに聞けないなら `LINEAR_ID=NOLINEAR` として進む（勝手に issue を作らない）。

## STEP 2: TASK_FILE 作成

**同じタスクを 2 つのセッションでやらないよう、先に実行ロックを取る**（「状態管理」の「実行ロック」）。取れなければ停止して報告する。

```bash
~/.claude/scripts/task-file.sh lock acquire \
  --linear-id={LINEAR_ID} --feature={feature} --runner={runner}
```

```bash
TASK_FILE=$(~/.claude/scripts/task-file.sh new \
  --linear-id={LINEAR_ID} --feature={feature} --branch={branch})
```

`{feature}` は内容から短いスネークケース。`NOLINEAR` のときは `--linear-id` を省く（`task-NOLINEAR-{feature}.md` になる）。

Linear が使えるなら、この時点で**「実行開始」コメントを 1 回だけ**投稿する（`runner: {runner}`、TASK_FILE のパス、実行モード）。**ステータスは変えない**（"In Progress" は STEP 4 / 3F F4）。

**TASK_FILE はリポジトリ内に置かない。** 出力は `~/.local/share/harness/tasks/{repo}/` 配下の絶対パス（`{repo}` = 本体リポジトリ名。worktree 共通）。旧配置（`{repo}/.claude/docs/decisions/`）のファイルは `task-file.sh find` / `resolve` で読める。

```markdown
# Task: {LINEAR_ID} — {task description}

## Meta
- linear_id: {LINEAR_ID}
- tier: {tier}
- created: {YYYY-MM-DD HH:MM}
- runner: {runner}
- updated: {YYYY-MM-DD HH:MM}
- status: planning
- branch:
- base:
- issue: {ISSUE_REFS}

## startproject
### Brief

### Design

### Plan

## team-implement

## team-review

## deploy
```

`##` 見出しはこの 6 つだけ（kanban がこの見出しで列を判定する）。空のまま作ってよい。

**tier 別の runner**（`phase-run.sh` に渡す。省略時はスクリプト既定の連鎖 claude → opencode2 → pi → auto）:

| tier | startproject | team-implement | team-review | deploy |
|---|---|---|---|---|
| S | 起動しない（自分で計画） | `--runner=auto` | `--runner=auto` | `--runner=auto` |
| M | `--runner=auto` | `--runner=auto` | `--runner=auto` | `--runner=auto` |
| L | `--runner=auto`（リサーチ併用） | `--runner=auto` | `--runner=auto` | `--runner=auto` |

`--phase-map` が渡されたら全フェーズでそれを優先する（例: `--phase-map="startproject=claude:opus,team-implement=pi:ollama-cloud/deepseek-v4.1-flash,team-review=opencode2:opencode-go/deepseek-v4-pro,deploy=claude:haiku"`）。

## STEP 3: startproject

### tier=S

フェーズを起動せず、自分でコードを読んで `### Brief` / `### Design` / `### Plan` を書く。読み終えて S に収まらないと分かったら tier を上げて報告し、下の「tier=M / L」に切り替える。

### tier=M / L

```bash
~/.claude/scripts/phase-run.sh --phase=startproject --task-file={TASK_FILE} \
  --tier={tier} --linear-id={LINEAR_ID} {RUNNER_ARGS}
```

返ってきた `### RESULT` を読む。`written: yes` なら TASK_FILE の `## startproject` は書けている。`written: no` なら `### SECTION` の中身を `## startproject` として書く。`### QUESTIONS` があれば「Gate 1」として扱い、回答を得て `--answers-file=` 付きで再実行する。

`--candidate` を付けていないので、`### Brief` / `### Design` / `### Plan` が直接書かれるはず。`### 案 {k}` しか無い場合は採用されていないので、最新の `### 案 {k}` を `### Brief` / `### Design` / `### Plan` に昇格し、`利用AI:` 行の直後に `採用: {YYYY-MM-DD HH:MM}` を入れてから STEP 4 へ進む（候補を残したまま実装に進まない）。

## STEP 4: team-implement

`## Meta` の `status:` を `implementing` に更新してから起動する。

```bash
~/.claude/scripts/phase-run.sh --phase=team-implement --task-file={TASK_FILE} \
  --tier={tier} --linear-id={LINEAR_ID} {RUNNER_ARGS}
```

- `## Meta` の `branch:` / `base:` はフェーズが書く（`written: no` なら `### SECTION` から拾って代筆）
- `### RESULT` に `escalation:` があれば、tier を上げて `## Meta` の `tier:` を更新し、STEP 3 からやり直す（作業ブランチの変更はそのまま）
- `## team-implement` に `### {m}回目` が入ったことを確認して STEP 5 へ

## STEP 5: team-review

`status:` を `reviewing` に更新してから起動する。

```bash
~/.claude/scripts/phase-run.sh --phase=team-review --task-file={TASK_FILE} \
  --tier={tier} --linear-id={LINEAR_ID} {RUNNER_ARGS}
```

- `### RESULT` の `verdict:` を読む（`PASS` / `FAIL`）
- `## team-review` の `### {m}回目` の直下に `**VERDICT: PASS**` / `**VERDICT: FAIL**` の 1 行を書く（本文に既にあれば重ねない）
- **FAIL は Gate 2**: 指摘の要約と「1. 差し戻して直す / 2. ここで止める」を提示して判断を待つ。差し戻すなら `status:` を `implementing` に戻して STEP 4 へ（`{m}` を進める）。**最大 5 回**まで。超えたら報告して停止する
- PASS なら STEP 6 へ

## STEP 6: deploy（3 段）

`status:` を `deploying` に更新してから 6a → 6b → 6c を順に実行する。

### 6a: コードの commit / push / PR

```bash
~/.claude/scripts/phase-run.sh --phase=deploy --task-file={TASK_FILE} \
  --tier={tier} --linear-id={LINEAR_ID} {RUNNER_ARGS}
```

deploy フェーズはコードだけをコミットし、**作業ブランチに留まる**（TASK_FILE はコミットしない）。

### 6b: TASK_FILE の記録と status

- `## deploy` を書く（`written: no` なら `### SECTION` から代筆。追加修正モードでは上書きせず末尾に追記）
- `## Meta` の `status:` を **`in-review`** にする（ここで書く）
- Linear が使えるなら: ステータスを "In Review" にし、「状態管理」の規則で description を更新する。`save_comment` は **deploy がまだ投稿していないときだけ**（汎用 / OpenCode の deploy は自分でコメントする）。MCP が無ければスキップして「Linear: unavailable」と報告

### 6c: 分岐元へ戻る

```bash
git status --short    # 未コミットの変更が残っていれば git switch は失敗する
git switch {base}
```

- **TASK_FILE はリポジトリ外にあるので、git の操作は何もしない**（コミット・push・stash をしない）
- 未コミットの変更（deploy が残したもの）があるなどで戻れないときは中止し、**作業ブランチに留まったまま**理由を報告する（勝手に破棄しない）
- 記録は既に TASK_FILE にあるので、戻れなくても失われない

## STEP 7: 完了報告

```
## 完了: {task description}

- Linear: {LINEAR_ID}
- Tier: {tier}
- Task File: {TASK_FILE}
- Mode: 通常 | 追加修正（{m}回目） | フェーズ指定（{phase}）
- Issue: {ISSUE_REFS | なし}
- 現在のブランチ: {branch}

### 各フェーズのサマリー
- startproject: {1 行}（Gate 1: approved / revised / skipped）
- team-implement: {1 行}（利用AI: {label}）
- team-review: {VERDICT と主要な指摘}（利用AI: {label}）
- deploy: {PR / MR の URL}（利用AI: {label}）

### 質問
- {なし | phase: 要旨 → 回答の要旨}
```

`利用AI:` の値は `phase-run.sh` が stderr に出す `LABEL=` を使う（推測で書かない）。

報告の最後に **[MUST]** 実行ロックを離す:

```bash
~/.claude/scripts/task-file.sh lock release --linear-id={LINEAR_ID} --runner={runner}
```

STEP 7 まで来ずに中止・失敗した場合も、終了前に同じ release を実行する（取れなかったロックは release しない）。

## STEP 3F: 追加修正モード

1. `--task-file`（または Linear ID から特定した `task-*.md`）を読み、`## Meta` の `tier:` / `linear_id:` / `branch:` / `base:` を復元する
2. `## Meta` の `status:` が `in-review` なら、`git switch {branch}` してから作業する（TASK_FILE はリポジトリ外にあるので、ブランチを切り替えても消えない）
3. `### Plan` の末尾に `#### 追加依頼 {n}` を書く（`{n}` は既存の最大 + 1）
4. `status:` を `implementing` にして STEP 4 から実行する（STEP 3 はスキップ。設計をやり直す必要があるときだけ STEP 3）
5. deploy は 6a → 6b → 6c（`## deploy` は上書きせず追記）

## STEP 3P: フェーズ指定モード

1. `--task-file` が必須。`## Meta` から `tier:` / `linear_id:` を復元する
2. `phase-run.sh --phase={phase} --task-file={TASK_FILE} {--runner=...} [--answers-file=...]` を実行する（startproject は `--candidate` を付けて `### 案 {k}` として追記させる）
3. `written: no` なら `### SECTION` を該当節に書き、`利用AI: {label}` を書いた見出しの直下に入れる
4. `status:` を実行したフェーズの値に更新する（startproject → `planning` / team-implement → `implementing` / team-review → `reviewing` / deploy → `in-review`）。**Linear のステータスは変えない**（フェーズ指定は既存タスクへの追記のため）
5. `--adopt=案 {k}` が指定されていれば、`### 案 {k}` の `#### Brief` / `#### Design` / `#### Plan` を `### Brief` / `### Design` / `### Plan` に昇格し、`利用AI:` の直後に `採用: {YYYY-MM-DD HH:MM}` を足す
6. Linear が使えるなら、「状態管理」の規則で description を更新する。コメントは **実行したフェーズが自分で投稿していないときだけ** `save_comment`（ステータスは変えない）
7. STEP 7 の報告をフェーズ指定モード用に書く（他のフェーズは「（未実行）」、次に回すフェーズと `phase-run.sh` の呼び出し例を添える）

## 失敗時の扱い

| 事象 | 扱い |
|---|---|
| フェーズが失敗 | `phase-run.sh` の fallback（claude → opencode2 → pi → auto）で自動再試行。全滅したら報告して停止（TASK_FILE へ失敗を書かない） |
| モデルが 429 / 認証エラー | `--runner=auto` なら `ai-fallback.sh` がモデル・エンジンを切り替える |
| `### QUESTIONS` が返った | 回答を得て `--answers-file=` で再実行。得られないなら質問を転記して停止 |
| TASK_FILE が書けなかった | `### SECTION` から代筆し、報告に「代筆」と書く |
| 同一フェーズで 5 回差し戻し | 報告して停止（無限ループを避ける） |
