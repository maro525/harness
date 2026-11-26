# Tool Routing Rules

**どの操作をどのツール・エージェントに委譲するかを定める。**
外部リサーチは **gemini が先**。インターネットの一次情報が要るときだけ firecrawl / WebFetch（pi は web fetch）を使う。設計相談とセカンドオピニオンは external-review（Herdr に別ファミリのセッションを 1 つ立てる）で 1 つ名指しして聞く（連鎖は使わない）。使うかどうか自体は tier で決まる（`$HOME/.claude/rules/adaptive-execution.md` の「External Research」「OpenCode Design Consultation」）。本ファイルは「使う」となった場合の委譲先を定める。

**単発の作業はサブエージェント（Agent ツール）に振らず、メインセッションで直接実行する。** リサーチ・OpenCode・Linear・docker/uv/ruff・スクリプト作成などすべて対象。サブエージェントを使うのは `/orchestrate` 系（startproject / team-implement / team-review / deploy）と、それらの command が自分で定めている場合だけ。

## Skill Routing hook への応答

`agent-router.py`（UserPromptSubmit hook）が `[Skill Routing]` / `[Agent Routing]` を additionalContext に出す。ソフトな推奨として扱う。

- **従う**: プロンプトの意図と一致し、ユーザーの明示指示と矛盾しないとき。従う旨を一言伝えて起動する（`[Skill Routing]` は Skill ツール、`[Agent Routing]` は提案された firecrawl / OpenCode をメインで直接実行）
- **従わなくてよい**: ユーザーが別のことを明示している／提案スキルに対してタスクが小さすぎる（XS など）／進行中ワークフロー内の追加質問
- 提案がずれていると思ったら、理由を伝えてユーザーに確認する

## Routing Table

| Operation | Delegate To | Method |
|-----------|-------------|--------|
| External research | **gemini（先）+ 必要時のみ firecrawl** | gemini に質問し、出典が要るときだけ一次情報を取る（下記） |
| 記事 (URL 1 本) | **WebFetch** | 読めないページは firecrawl（`firecrawl_scrape`） |
| PDF (URL) / 複数ページ | **firecrawl MCP** | `firecrawl_parse` / `firecrawl_scrape` |
| 音声・動画 | **未対応** | 委託先なし。ユーザーに扱い方を確認する |
| Library research | **gemini（先）+ 必要時のみ firecrawl** | `external-ask.sh --to pi` で実装知見。一次情報が要るときだけ `firecrawl_search` |
| Design decisions | **external-review（別ファミリを 1 つ指定）** | `~/.agents/skills/external-review/SKILL.md`（下記「external-review」） |
| git（書き込み系） | **`/deploy` skill** | Ad-hoc Git モード。読み取り系は Claude が直接 |
| `/orchestrate` で作った PR への追加変更 | **`/orchestrate` 追加修正モード** | `/orchestrate "{追加の依頼} --task-file={TASK_FILE}"`。直接編集して Ad-hoc push しない（下記「Git Operations」） |
| docker/ruff/uv | **Direct** | Bash で直接実行（長いものは `run_in_background: true`） |
| Linear MCP | **Direct** | Linear MCP ツールを直接呼ぶ |
| GitHub 操作 | **`gh` CLI** | GitHub MCP は不安定なため使わない |

## 外部エージェントは Herdr の中でだけ動かす

**セッションを立てて何かをさせるのは、必ず Herdr 経由。**

| 目的 | 使う | 使わない |
|---|---|---|
| 別エージェントに相談 | `external-review`（Herdr の別ファミリ 1 セッション）／草案は `external-ask.sh --to pi` | `tmux new-session` で `claude`/`codex` を起動 |
| PM の manager を用意する（1 セッション 1 つ、名前と居場所は任せる） | `herdr-agent.sh manager` | `ensure manager-<repo>` を自分で組み立てる（同じリポジトリの別セッションと共有してしまう） |
| 子に仕事を配る | `herdr-agent.sh ensure` ＋ `delegate` | `tmux` / `screen` / `nohup` / `claude --bg` |
| 実作業の子を対象リポジトリで起こす | `herdr-agent.sh worker <name> --kind K --repo <repo>`（空いていれば checkout、作業中なら worktree） | `ensure --topology tab` を自分で選ぶ（2 体が同じ checkout を触る） |
| 並列に回す（manager のみ。PM は manager に `ask` する） | `orchestrate-parallel.sh`（worktree 分け） | ターミナルを手で並べる |
| フェーズ実行 | `phase-run.sh`（tab を作らない設計） | 手で `claude -p` を並べる |

理由: 名前・状態・報告（inbox）・後始末（`close` / `reap` / `herdr-cleanup.sh`）が **Herdr の記録に一本化**されているため。tmux 等で立てると記録が残らず、片付けの対象外になる。

- Herdr が使えないときは**止まって確認する**（黙って tmux に落ちない）。一回きりの文章作成なら `external-ask.sh --to pi`（中で `pi -p` を呼ぶ）
- `tmux` を Claude の状態表示（hooks）以外の目的で使わない

## External Research: gemini が先、一次情報は必要時だけ

リサーチは **gemini に聞くところから始める**。gemini は実装知見（設計上の勘所・落とし穴・比較）を返す。**インターネットの一次情報が要るときだけ**、自分で出典を取る。

| 系統 | 担当 | 使う条件 |
|------|-------|---------|
| **実装知見** | **gemini**（`external-ask.sh --to pi`） | まずこれ。最初に聞く |
| **一次情報** | **自分**（firecrawl MCP / `WebFetch` / `curl`。pi は web fetch） | 出典 URL が要る / 最新版・リリースノート・公式仕様を確認する / gemini の答えを裏取りする |

食い違ったら **一次情報を優先**し、相違点と採用した方を成果物に記録する（`/startproject` では OUTPUT の `DESIGN`）。

### リサーチの呼び出し形

まず gemini に聞く（材料がまだ無くてもよい）:

```bash
~/.claude/scripts/external-ask.sh --to pi -m google/gemini-3-flash-preview - <<'EOF'
{リサーチ質問}
EOF
```

インターネット情報が要るときだけ、一次情報を足す:

- **Claude Code / Cursor**: `firecrawl` MCP（`firecrawl_search` / `firecrawl_scrape`）。無ければ `WebFetch` か `curl`
- **pi**: `web_fetch` / `web_search` ツール
- 取った材料は、添えて gemini にもう一度聞いてよい（gemini は同期）
- gemini 側は既定で**ツールを持たない**（`pi -p --no-session --no-tools`。呼び出し元の AGENTS.md / skills / MCP も読ませない。実測 232s → 66s）。不足の裏取りをさせたいときだけ `CONSULT_PI_TOOLS=1` を付ける
- **gemini が 429 / 認証エラー / 無出力で落ちても、別のモデルに切り替えない。** 理由を書いて自分の知識で進む（`外部リサーチ不可: {理由}`）
- 記録は `利用AI:` に使った方を書く（例: `利用AI: pi/google/gemini-3-flash-preview`。一次情報も取ったなら `+ claude/opus (firecrawl)`）

### external-review（独立レビュー・設計相談）

設計相談（startproject）とセカンドオピニオン（team-review）は、`~/.agents/skills/external-review/SKILL.md` の手順で **別ファミリのモデルを 1 つ名指しして 1 回聞く**。モデルの連鎖は使わない。セッションは Herdr に 1 つ立て（読み取り専用）、`ask --answer-file` で同期に受ける。

```bash
# セッション（codex の例。実装者と別ファミリを選ぶ）
~/.claude/scripts/herdr-agent.sh ensure codex-review-{purpose} --kind codex \
  --repo "$PWD" -- -s read-only -a never -m gpt-6-sol

# 設計相談・セカンドオピニオン
~/.claude/scripts/herdr-agent.sh ask codex-review-{purpose} /tmp/question.md \
  --answer-file /tmp/question.answer.md --timeout 20m
```

- ターゲットは **そのフェーズを実行している CLI（`--label`）と別のファミリ**から選ぶ。`--label` が分からなければ `codex`
- CLI の答えは鵜吞みにしない。コードを読まずに答えることがあるので、根拠は自分で確かめてから採用する
- 1 回で終わり。失敗（未認証 / quota / timeout / 空出力）したら**別モデルに切り替えない**。`設計相談不可: {理由}` / `セカンドオピニオン不可: {理由}` を書いて、そのフェーズを飛ばすか自分の判断で進む
- `利用AI:` には `ensure` の stderr `MODEL=` を `<kind>/<model>` の形で書く（`ask` の前に控える）
- manager が居る対話の文脈では、設計相談は manager に `ask` で聞いてもよい（同じリポジトリを読んでいる）
- Herdr が無い環境では `external-ask.sh` を使う（一発だけで、セッションを作らない）

### Scope

ライブラリ・フレームワークの最新仕様と公式ドキュメント／リリースノート・変更履歴・非推奨情報／既知の不具合・脆弱性・回避策／実装事例・ベンチマーク・比較記事

### Tools（firecrawl 系統）

| Tool | 用途 |
|------|------|
| `firecrawl_search` | Web 検索（本文抽出込み）。まずこれを使う |
| `firecrawl_scrape` | URL が判明しているページを Markdown で取得 |
| `firecrawl_map` | サイト内の URL 一覧を取得（ドキュメントサイトの探索） |
| `firecrawl_extract` | 複数ページから構造化データを抽出 |
| `firecrawl_parse` | PDF など URL 上のドキュメントをパース |

### 連続で scrape しない（無料枠は 15 req/min）

firecrawl の無料枠は **15 req/min**。待たずに撃つと 429 で落ち、本文の `retry after 37s` の間は何をしても通らない。2026-11-25 は 1 日で 90 回の scrape が 429 で失敗し、その日の失敗の半分以上を占めた（待たずに連続実行しただけ）。

- 続けて取るときは **4 秒あける**（15 req/min を超えない）。sitemap や静的な HTML なら `curl` で足りる
- 429 が返ったら **本文かヘッダにある待ち時間だけ待ってから** 1 回だけ再試行する。待たずに撃ち直さない
- 3 本以上・まとめて取るときは MCP ではなく `~/.claude/scripts/firecrawl.sh` を使う。間隔・429 の待ち・キャッシュ（6h）をスクリプトが守る

```bash
~/.claude/scripts/firecrawl.sh scrape "https://docs.example.com/api"    # markdown を stdout へ
~/.claude/scripts/firecrawl.sh scrape "https://docs.example.com/api" --json
~/.claude/scripts/firecrawl.sh batch /tmp/urls.txt --out /tmp/sources   # 1 本ずつ、間隔をあけて
```

- 2 回続けて 429 なら、その URL は追わない。`curl` / gemini（`external-ask.sh --to pi`）/ 自分の知識で進み、`外部リサーチ不可: {理由}` を残す
- API キーは `$FIRECRAWL_API_KEY`（MCP と同じもの）。`/v1/scrape` は非推奨（2026-12-10 で停止）なので、REST を直に叩くときは `/v2/scrape` を使う

### 調べものの記録の置き場所

**調べた結果はリポジトリの外、`~/.local/share/harness/tasks/{repo}/research/` に置く。** TASK_FILE（`{repo}/task-*.md`）と同じバケットなので、作業ツリーを切り替えても 1 か所にまとまり、git にも載らない。

- `{repo}` は `~/.claude/scripts/task-file.sh dir` が出す（`basename $(git rev-parse --git-common-dir)` の `.git` を除いたもの。worktree でも同じバケット）。バケットまではスクリプトが作るが `research/` は作らないので、書く前に `mkdir -p` する
- ファイル名は由来が分かる形にする: `{topic}-gemini.md`（実装知見）/ `{topic}-sources.md`（一次情報）
- 記録は TASK_FILE と同居するので、後から `/team-review` や `/deploy` が同じバケットを探せば見つかる
- **`.claude/docs/research/` は旧配置。** 2026-11-10 に git から外した（それまでの分は git の履歴で読める）。フォルダは古い道具が `>` で書き込んでも落ちないように `.gitkeep` で残してあるだけで、新規には書かない

### How to Route

サブエージェントは使わず、メインセッションで進める。

1. **まず gemini に聞く**: `~/.claude/scripts/external-ask.sh --to pi -m google/gemini-3-flash-preview -` を Bash で実行し、出力を `~/.local/share/harness/tasks/{repo}/research/{topic}-gemini.md` に落とす（`{repo}` の求め方は「調べものの記録の置き場所」。stderr の `AI_MODEL` を `利用AI:` として記録する）
2. **インターネットの一次情報が要るときだけ**: `firecrawl_search` → 公式ドキュメント／リリースノートを `firecrawl_scrape`（pi は web fetch）。主張ごとに出典 URL を控え、`{topic}-sources.md` に置く
3. 両方あるときは突き合わせて統合する（食い違いは一次情報を優先）。gemini が落ちたら一次情報だけで進み、理由を残す

### Triggers

| User Input | Action |
|------------|--------|
| 「調べて」「リサーチして」「最新バージョンは」「使い方を調べて」 | firecrawl + OpenCode を並列実行 |
| 「公式ドキュメントを見て」「仕様を確認して」 | firecrawl 主体（OpenCode は任意） |
| 「既知の不具合はある?」「脆弱性を確認して」 | firecrawl + OpenCode を並列実行 |

バージョン番号など「現在の事実」は firecrawl の結果を正とする。

### Exceptions (Claude handles directly)

- URL が 1 本だけ分かっていて要約するだけ（WebFetch で足りる）

## Git Operations

**書き込み系は `/deploy`（Ad-hoc Git モード）経由、読み取り系は Claude が直接実行してよい。**

| 分類 | コマンド | 実行者 |
|------|---------|--------|
| **書き込み** | `add`, `commit`, `push`, `pull`, `merge`, `rebase`, `cherry-pick`, `tag`（作成）, `stash`（push/pop/apply）, `reset`, `revert`, `branch`（作成）, `checkout`, `switch` | `/deploy` |
| **読み取り** | `status`, `log`, `diff`, `show`, `blame`, `branch`（一覧）, `fetch`, `stash list/show`, `rev-parse`, `config --get` | Claude が直接 |

`/team-implement` `/team-review` `/deploy` の fork 内では、書き込み系も直接実行する。

### /orchestrate で作った PR への追加変更

**`/orchestrate` が PR / MR を出したブランチへのコードの追加変更は、必ず `/orchestrate` の追加修正モード（orchestrate.md「STEP 3F: 追加修正モード」）で行い、team-implement → team-review → deploy を通す。**

- 判定基準: 対象ブランチが TASK_FILE（`~/.local/share/harness/tasks/{repo}/task-*.md`。`~/.claude/scripts/task-file.sh find` で探す）の `## Meta` `branch:` に一致し、その `## deploy` に PR / MR URL がある
- 禁止: orchestrator やメインセッションがファイルを直接編集して `/deploy`（Ad-hoc Git モード）で commit / push すること。レビューを通らない変更が PR に載る（実例: `task-NOLINEAR-claude_config_simplify` の 2回目は後追いレビューで major が見つかり取り消しになった）
- 呼び出し形: `/orchestrate "{追加の依頼} --task-file={TASK_FILE}"`（または `/orchestrate "{LINEAR_ID} {追加の依頼}"`）
- `/deploy` の Ad-hoc Git モードは対象ブランチを検出したら実行せず、追加修正モードを案内して確認する（deploy.md「/orchestrate 由来の PR ブランチへのガード」）
- 例外（追加修正モードを通さなくてよい）: コードを変えない操作 — PR / MR の本文・タイトル修正、ラベル・レビュアー設定、読み取り系 git、マージ済み PR のブランチ削除。ユーザーが承知のうえで Ad-hoc 実行を明示した場合も実行するが、レビューを通っていない旨を報告する

### 保護ブランチ

- **`release` / `staging` / `main`（master 含む）への直接コミット・push は、ユーザーの明示的な許可がない限り禁止。** 反映は必ず PR / MR 経由
- 保護ブランチ上で書き込み操作が必要になったら、feature ブランチを作成してから実行する（tier=XS も同様）

### ホスティング CLI

`origin` のリモート URL で判定し、GitLab（セルフホスト含む）は `glab`、GitHub は `gh` を使う。GitHub MCP は不安定なため使わない。

## 移譲したら「誰がやったか」を書く

子・外部モデルに仕事を渡したら、**報告・PR 本文・TASK_FILE の `利用AI:` に使った AI を書く**（推測で書かない。次の 3 つから取る）。

| 何に移譲したか | どこから取るか |
|---|---|
| フェーズ（`phase-run.sh`） | `~/.claude/scripts/task-file.sh ai show --task-file={TASK_FILE}` の 1 行（`startproject=claude/opus / team-implement=pi/ollama-cloud/kimi-k3`）。`phase-run.sh` が成功のたびに `{TASK_FILE}.ai.log` へ書く（stderr の `LABEL=` を拾い損ねてもここから取れる） |
| consult / draft（gemini・claude・codex） | stderr の `AI_MODEL=`（`draft.sh` は `文面: pi/<model>`） |
| Herdr の子（`herdr-agent.sh`） | `delegate` / `ensure` の stderr `MODEL=` と、子の報告にある `利用AI:` |

- 報告の形: `利用AI: startproject=claude/opus / team-implement=pi/ollama-cloud/kimi-k3 / team-review=codex/gpt-6-sol`
- 取れなかったときは `利用AI: （不明）` と書く（空欄や推測で埋めない）
- 人が読むのは「どのタスクを、どのモデルが、いくらでやったか」なので、**子の名前（タブ名）だけでは足りない**

## 対外文書の下書き（`draft.sh`）

**外に残る文章は、下書きを `draft.sh`（gemini）に任せる。** 対象:

- Linear: issue の本文・description、コメント（3 行以上になるもの）
- Notion / GitHub / GitLab: PR・MR の本文、レビュー返信
- コミットメッセージ（**本文**が 3 行以上になるとき。件名だけなら自分で書く）
- TASK_FILE の `## deploy` などの節

```bash
~/.claude/scripts/draft.sh --kind=pr --material /tmp/notes.md > /tmp/draft.md
~/.claude/scripts/draft.sh --kind=comment < /tmp/notes.md   # stdout に本文
```

- kind は `pr` / `comment` / `commit` / `section` / `reply`。stdout が本文、stderr に `ANSWER_FILE=` と `文面: pi/<model>`
- **作成・投稿は自分（メインセッション）が行う。** 下書きモデルには MCP もツールも渡さない（`draft.sh` が固定する）
- 帰ってきた文面を**確かめてから**使う（事実・数値・固有名詞は自分で照合する）
- 依頼したら記録に「文面: pi/google/gemini-3-flash-preview」を添える（`利用AI:` / `### RESULT` / PR 本文）
- **往復は 1〜4 分**（実測 66〜232 秒）。1 行の要約・ラベル・定型文は自分で書く（往復のほうが高い）
- 失敗したら `draft.sh` は exit 1 で止まる。下書きフェーズを飛ばして自分で書く
- 使わなかったときは理由を 1 行残す（例: 「件名だけなので自分で書いた」）

## Linear MCP Operations

スキルの内外を問わず、Linear MCP ツールをメインセッションで直接呼ぶ。issue 作成前は重複を検索する。文面の下書きは上の「対外文書の下書き」に従う。

## Operational Commands

依存管理（`uv`）・Lint/Format（`ruff`）・Docker・環境セットアップ・ファイル整理・シェルスクリプト作成・changelog 生成は、メインセッションで直接実行する。長い出力のコマンドは `tail` / `grep` で絞るか、`run_in_background: true` で実行してログファイルから必要な部分だけ読む。
