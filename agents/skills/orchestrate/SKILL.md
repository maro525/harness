---
name: orchestrate
description: Orchestrator for the task-file workflow — classifies the task, creates the TASK_FILE, then runs startproject → team-implement → team-review → deploy through ~/.claude/scripts/phase-run.sh, writes ## Meta / status itself, handles Gate 1 / Gate 2 and the FAIL loop, and finishes with the deploy three-stage (code PR → record → finalize). Use when asked to run a task end to end, or to run one phase of an existing task file (--phase).
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
- **Linear は任意**: MCP が使えれば `save_comment` で各フェーズの結果を投稿する。使えなければ「Linear: unavailable」と記録して続行し、止まらない
- **失敗しても止まらない**: フェーズが失敗（exit ≠ 0 / 空出力 / タイムアウト）したら 1 度だけ別 runner で再試行し（`phase-run.sh` の fallback が自動で行う）、それでも駄目なら報告して停止する。TASK_FILE には失敗を書かない
- 報告は日本語。モデル名・runner 名・URL・ブランチ名はそのまま書く

## モード判定

| モード | 条件 | 開始 |
|---|---|---|
| フェーズ指定 | `--phase=` がある（`--task-file` 必須） | STEP 3P |
| 追加修正 | `--phase` が無く、`--task-file` が既存、または Linear ID の `task-*.md` が存在する | STEP 3F |
| 通常 | それ以外 | STEP 0 |

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

```
TASK_FILE = .claude/docs/decisions/task-{LINEAR_ID}-{feature}.md
```

`{feature}` は内容から短いスネークケース。`NOLINEAR` のときは `task-NOLINEAR-{feature}.md`。

```markdown
# Task: {LINEAR_ID} — {task description}

## Meta
- linear_id: {LINEAR_ID}
- tier: {tier}
- created: {YYYY-MM-DD HH:MM}
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
- `## Meta` の `status:` を **`in-review`** にする（6c でコミットされるので、ここで書く）
- MCP があれば `save_comment` で結果を投稿する（無ければスキップ）

### 6c: finalize（TASK_FILE だけをコミットして分岐元へ）

```bash
git add -A -- {TASK_FILE}
git commit -m "docs(task): {task description} の記録を追加"
git push origin HEAD
git switch {base}
```

- TASK_FILE が gitignore なら commit / push せず `git switch {base}` だけ行う
- 他ファイルがステージ済み・リモートと分岐・分岐元へ戻れないときは中止し、**作業ブランチに留まったまま**理由を報告する（履歴は書き換えない）
- `deploy` フェーズの `--finalize` を使う実装（Claude / OpenCode）もあるが、pi 版はここで自分で行う

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

## STEP 3F: 追加修正モード

1. `--task-file`（または Linear ID から特定した `task-*.md`）を読み、`## Meta` の `tier:` / `linear_id:` / `branch:` / `base:` を復元する
2. `## Meta` の `status:` が `in-review` なら、`git switch {branch}` してから作業する（TASK_FILE が作業ツリーに無ければ `git log --all` から復元する）
3. `### Plan` の末尾に `#### 追加依頼 {n}` を書く（`{n}` は既存の最大 + 1）
4. `status:` を `implementing` にして STEP 4 から実行する（STEP 3 はスキップ。設計をやり直す必要があるときだけ STEP 3）
5. deploy は 6a → 6b → 6c（`## deploy` は上書きせず追記）

## STEP 3P: フェーズ指定モード

1. `--task-file` が必須。`## Meta` から `tier:` / `linear_id:` を復元する
2. `phase-run.sh --phase={phase} --task-file={TASK_FILE} {--runner=...} [--answers-file=...]` を実行する
3. `written: no` なら `### SECTION` を該当節に書き、`利用AI: {label}` を書いた見出しの直下に入れる
4. `status:` を実行したフェーズの値に更新する（startproject → `planning` / team-implement → `implementing` / team-review → `reviewing` / deploy → `in-review`）
5. `--adopt=案 {k}` が指定されていれば、`### 案 {k}` の `#### Brief` / `#### Design` / `#### Plan` を `### Brief` / `### Design` / `### Plan` に昇格し、`利用AI:` の直後に `採用: {YYYY-MM-DD HH:MM}` を足す
6. STEP 7 の報告をフェーズ指定モード用に書く（他のフェーズは「（未実行）」、次に回すフェーズと `phase-run.sh` の呼び出し例を添える）

## 失敗時の扱い

| 事象 | 扱い |
|---|---|
| フェーズが失敗 | `phase-run.sh` の fallback（claude → opencode2 → pi → auto）で自動再試行。全滅したら報告して停止（TASK_FILE へ失敗を書かない） |
| モデルが 429 / 認証エラー | `--runner=auto` なら `ai-fallback.sh` がモデル・エンジンを切り替える |
| `### QUESTIONS` が返った | 回答を得て `--answers-file=` で再実行。得られないなら質問を転記して停止 |
| TASK_FILE が書けなかった | `### SECTION` から代筆し、報告に「代筆」と書く |
| 同一フェーズで 5 回差し戻し | 報告して停止（無限ループを避ける） |
