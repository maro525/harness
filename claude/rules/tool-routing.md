# Tool Routing Rules

**どの操作をどのツール・エージェントに委譲するかを定める。**
外部リサーチは **自分（firecrawl MCP）+ gemini** の二系統、設計相談は ai-fallback（フォールバック連鎖）に振り分ける。使うかどうか自体は tier で決まる（`$HOME/.claude/rules/adaptive-execution.md` の「External Research」「OpenCode Design Consultation」）。本ファイルは「使う」となった場合の委譲先を定める。

**単発の作業はサブエージェント（Agent ツール）に振らず、メインセッションで直接実行する。** リサーチ・OpenCode・Linear・docker/uv/ruff・スクリプト作成などすべて対象。サブエージェントを使うのは `/orchestrate` 系（startproject / team-implement / team-review / deploy）と、それらの command が自分で定めている場合だけ。

## Skill Routing hook への応答

`agent-router.py`（UserPromptSubmit hook）が `[Skill Routing]` / `[Agent Routing]` を additionalContext に出す。ソフトな推奨として扱う。

- **従う**: プロンプトの意図と一致し、ユーザーの明示指示と矛盾しないとき。従う旨を一言伝えて起動する（`[Skill Routing]` は Skill ツール、`[Agent Routing]` は提案された firecrawl / OpenCode をメインで直接実行）
- **従わなくてよい**: ユーザーが別のことを明示している／提案スキルに対してタスクが小さすぎる（XS など）／進行中ワークフロー内の追加質問
- 提案がずれていると思ったら、理由を伝えてユーザーに確認する

## Routing Table

| Operation | Delegate To | Method |
|-----------|-------------|--------|
| External research | **firecrawl MCP（自分）+ gemini** | 二系統を並列実行し Claude が統合（下記） |
| 記事 (URL 1 本) | **WebFetch** | 読めないページは firecrawl（`firecrawl_scrape`） |
| PDF (URL) / 複数ページ | **firecrawl MCP** | `firecrawl_parse` / `firecrawl_scrape` |
| 音声・動画 | **未対応** | 委託先なし。ユーザーに扱い方を確認する |
| Library research | **firecrawl MCP（自分）+ gemini** | `firecrawl_search` で一次情報 + `consult.sh --to pi` で実装知見 |
| Design decisions | **OpenCode（モデルはフォールバック連鎖）** | バックグラウンド Bash で直接（`~/.claude/scripts/ai-fallback.sh {prompt_file}`、下記「OpenCode リサーチの実行」） |
| git（書き込み系） | **`/deploy` skill** | Ad-hoc Git モード。読み取り系は Claude が直接 |
| `/orchestrate` で作った PR への追加変更 | **`/orchestrate` 追加修正モード** | `/orchestrate "{追加の依頼} --task-file={TASK_FILE}"`。直接編集して Ad-hoc push しない（下記「Git Operations」） |
| docker/ruff/uv | **Direct** | Bash で直接実行（長いものは `run_in_background: true`） |
| Linear MCP | **Direct** | Linear MCP ツールを直接呼ぶ |
| GitHub 操作 | **`gh` CLI** | GitHub MCP は不安定なため使わない |

## 外部エージェントは Herdr の中でだけ動かす

**セッションを立てて何かをさせるのは、必ず Herdr 経由。**

| 目的 | 使う | 使わない |
|---|---|---|
| 別エージェントに相談 | `claude-consult.sh` / `codex-consult.sh`／草案は `consult.sh --to pi` | `tmux new-session` で `claude`/`codex` を起動 |
| 子に仕事を配る | `herdr-agent.sh ensure` ＋ `delegate` | `tmux` / `screen` / `nohup` / `claude --bg` |
| 並列に回す | `orchestrate-parallel.sh`（worktree 分け） | ターミナルを手で並べる |
| フェーズ実行 | `phase-run.sh`（tab を作らない設計） | 手で `claude -p` を並べる |

理由: 名前・状態・報告（inbox）・後始末（`close` / `reap` / `herdr-cleanup.sh`）が **Herdr の記録に一本化**されているため。tmux 等で立てると記録が残らず、片付けの対象外になる。

- Herdr が使えないときは**止まって確認する**（黙って tmux に落ちない）。一回きりの文章作成なら `consult.sh --to pi`（`pi -p`）
- `tmux` を Claude の状態表示（hooks）以外の目的で使わない

## External Research: 自分 + gemini

リサーチは **2 人でやる**: 自分（Cursor / Claude）が一次情報を取り、**gemini** が解釈する。突き合わせて統合する。

| 系統 | 担当 | 得意分野 |
|------|-------|---------|
| **一次情報** | **自分**（firecrawl MCP / `curl`） | 公式ドキュメント・リリースノートの実文面。出典 URL が取れるが解釈はしない |
| **実装知見** | **gemini**（`consult --to pi`） | 設計上の勘所・落とし穴・比較。解釈は出せるが出典を持たない |

食い違ったら **一次情報を優先**し、相違点と採用した方を成果物に記録する（`/startproject` では OUTPUT の `DESIGN`）。

### リサーチの呼び出し形

```bash
~/.claude/scripts/consult.sh --to pi -m google/gemini-4-carbon - <<'EOF'
{リサーチ質問}
---
## こちらの一次情報（firecrawl / curl で取ったもの）
- {出典 URL と要点}
EOF
```

- **自分は `firecrawl` MCP（または `curl`）で一次情報を取る。** gemini には「何を調べたいか」と「こちらが取った材料」を渡す
- gemini 側は既定で**ツールを持たない**（`pi -p --no-session --no-tools`。呼び出し元の AGENTS.md / skills / MCP も読ませない。実測 232s → 66s）。不足の裏取りをさせたいときだけ `CONSULT_PI_TOOLS=1` を付ける
- 並列にしたいときは **材料を待たずに質問だけ先に投げる**（gemini は同期なので、材料を渡すなら自分が取ってから）
- 記録は `利用AI:` に両方書く（例: `利用AI: claude/opus + pi/google/gemini-4-carbon`）

### OpenCode リサーチの実行（ai-fallback・設計相談と代替用）

ふだんのリサーチは上の gemini 経由。ここから下は **gemini が 429 / 認証エラー / 無出力のときの代替**と、**設計相談（startproject）・セカンドオピニオン（team-review）** のためのもの（各ドキュメントからの「OpenCode リサーチの実行」参照はこの節を指す）。

```bash
~/.claude/scripts/ai-fallback.sh {prompt_file}
```

`ai-fallback.sh` は次の連鎖を上から順に試し、**最初に答えを返したモデルを採用する**。各モデルは 1 回だけ呼ぶ（同じモデルの再試行はしない）。

| 順 | モデル | 提供元 | 位置づけ |
|---|---|---|---|
| 1 | `codex`（`AI_MODEL` は `codex/{config.toml の model}`） | Codex CLI（`codex exec`、読み取り専用） | 既定 |
| 2 | `ollama-cloud/deepseek-v4.1-flash` | Ollama Cloud（`https://ollama.com/v1`） | 1 が quota / 認証 / タイムアウト / 空出力 / 未インストールのとき |

- 候補の上書き: `AI_CHAIN="ollama-cloud/deepseek-v4.1-flash" ~/.claude/scripts/ai-fallback.sh {prompt_file}`。Codex は `codex`（`-m` なし。モデルは `${CODEX_HOME:-~/.codex}/config.toml` の `model` で、読めなければ `codex/default` と記録）か `codex:{model}`（`-m {model}` を付ける）と書く（例: `AI_CHAIN="codex:gpt-6-sol ollama-cloud/deepseek-v4.1-flash"`）
- **Codex はエンジン切替なしの単発候補。** 失敗したら（quota / 認証 / タイムアウト / 空出力 / exit ≠ 0）そのまま次のモデルへ進む。`codex` が入っていなければ `skip: codex/{model} on codex (not installed)` を出して OpenCode 連鎖だけで動く。逆に OpenCode 系エンジンが無く `codex` だけでも動く（`provider/model` 候補は `(no engine)` で skip）
- Codex の判定は **exit 0 かつ最終メッセージ（`-o`）が非空なら成功**で、出力は grep しない（プロンプトに「quota」等が含まれても誤判定しない）。失敗したときだけ stderr と出力を quota（`429` / `rate limit` / `usage limit` など）→ 認証（`401` / `403` / `unauthorized`）の順に見て理由を付ける
- 切替条件（スクリプトが判定）: HTTP 429 / `insufficient_quota` / rate limit → 次の候補。401 / 403（認証エラー）→ 次の候補。`exit 124` / `137`（タイムアウト）→ 次の候補。**空出力**のときは 429 をログ（`~/.local/share/opencode/log/`）、`ERROR` を stderr（`--print-logs --log-level ERROR`）で見て、どちらも無ければ「空出力」として次の候補
- **quota 以外の理由で落ちたときはエンジンを切り替える。** OpenCode 側の不具合（DB 破損・インストール不全）は次のモデルでも同じ壁に当たるので、その場合だけ `pi -p --no-session --model` に切り替えて連鎖を続ける（stderr に `switching to pi` を出す）。quota のときは切り替えない
- **記録は必須。** 成果物（`DESIGN` / `## team-review` / PR 本文など）に `利用AI: {AI_MODEL}` を書き、落とした候補があれば `（{model} は {理由} で skip）` を添える（例: `利用AI: ollama-cloud/deepseek-v4.1-flash（codex/gpt-6-sol は quota で skip）`）。スクリプトは stderr に `AI_ENGINE` / `AI_MODEL` / `AI_SKIPPED` を出す
- 全候補が失敗したときだけ OpenCode なしで続け、成果物に「OpenCode 不可: {理由}」と書く
- エンジンも連鎖する（`provider/model` 候補のみ。Codex は対象外）: `opencode2`（v2）→ `opencode`（v1）→ `pi` の順で、入っているものを使う。1 つのエンジンでモデル連鎖を回し、**quota 以外**の理由（DB 破損・認証エラー・タイムアウトなど）で落ちたら次のエンジンで同じモデルから再開する
- v1 と v2 の差分（`--auto`・`--standalone`・`--log-level` の大小文字・`-m provider/model#variant`）は `~/src/harness/docs/tool-commands.md` の表を参照
- ollama-cloud（`ollama-cloud/deepseek-v4.1-flash`）を OpenCode から使うには provider 登録が要る（`../opencode/README.md`「フォールバック先の登録」）。未登録なら pi 側に切り替わる
- 長文プロンプトはファイルに落として渡す（スクリプトはファイルパスか `-`（stdin）を受ける）
- ツール呼び出しで止まらせたくなければ、プロンプト冒頭に `DO NOT USE ANY TOOLS`

#### コマンドと壊れやすい要素

手で叩くときのコマンド形・`--agent plan` / `--standalone` / `< /dev/null` などの理由・ログと疎通確認の読み方は `~/src/harness/docs/tool-commands.md` に移した（このファイルには置かない）。

- OpenCode はコードを読まずに答えることがある。結論は採用してよいが**根拠は必ず自分で検証する**

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

### 調べものの記録の置き場所

**調べた結果はリポジトリの外、`~/.local/share/harness/tasks/{repo}/research/` に置く。** TASK_FILE（`{repo}/task-*.md`）と同じバケットなので、作業ツリーを切り替えても 1 か所にまとまり、git にも載らない。

- `{repo}` は `~/.claude/scripts/task-file.sh dir` が出す（`basename $(git rev-parse --git-common-dir)` の `.git` を除いたもの。worktree でも同じバケット）。バケットまではスクリプトが作るが `research/` は作らないので、書く前に `mkdir -p` する
- ファイル名は由来が分かる形にする: `{topic}-opencode.md`（実装知見）/ `{topic}-sources.md`（一次情報）
- 記録は TASK_FILE と同居するので、後から `/team-review` や `/deploy` が同じバケットを探せば見つかる
- **`.claude/docs/research/` は旧配置。** 2026-11-10 に git から外した（それまでの分は git の履歴で読める）。フォルダは古い道具が `>` で書き込んでも落ちないように `.gitkeep` で残してあるだけで、新規には書かない

### How to Route

サブエージェントは使わず、メインセッションで二系統を同時に進める。

1. **系統 2（実装知見）を先に起動**: `~/.claude/scripts/consult.sh --to pi -m google/gemini-4-carbon -` を Bash の `run_in_background: true` で起動し、出力を `~/.local/share/harness/tasks/{repo}/research/{topic}-gemini.md` に落とす（`{repo}` の求め方は「調べものの記録の置き場所」。stderr の `AI_MODEL` を `利用AI:` として記録する）
2. **系統 1（一次情報）をその間に実行**: `firecrawl_search` → 公式ドキュメント／リリースノートを `firecrawl_scrape`。主張ごとに出典 URL を控える
3. gemini の完了通知を待ち、出力ファイルを読んで firecrawl の結果と突き合わせて統合する（食い違いは firecrawl 優先）

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
| フェーズ（`phase-run.sh`） | `~/.claude/scripts/task-file.sh ai show --task-file={TASK_FILE}` の 1 行（`startproject=claude/opus / team-implement=auto/pi/google/gemini-4-carbon`）。`phase-run.sh` が成功のたびに `{TASK_FILE}.ai.log` へ書く（stderr の `LABEL=` を拾い損ねてもここから取れる） |
| consult / draft（gemini・claude・codex） | stderr の `AI_MODEL=`（`draft.sh` は `文面: pi/<model>`） |
| Herdr の子（`herdr-agent.sh`） | `delegate` / `ensure` の stderr `MODEL=` と、子の報告にある `利用AI:` |

- 報告の形: `利用AI: startproject=claude/opus / team-implement=auto/pi/google/gemini-4-carbon / team-review=auto/codex/gpt-6-sol`
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
- 依頼したら記録に「文面: pi/google/gemini-4-carbon」を添える（`利用AI:` / `### RESULT` / PR 本文）
- **往復は 1〜4 分**（実測 66〜232 秒）。1 行の要約・ラベル・定型文は自分で書く（往復のほうが高い）
- 失敗したら `draft.sh` は exit 1 で止まる。代わりに `ai-fallback.sh` を使い、`利用AI:` に codex/… と書く（黙って別モデルに書かせない）
- 使わなかったときは理由を 1 行残す（例: 「件名だけなので自分で書いた」）

## Linear MCP Operations

スキルの内外を問わず、Linear MCP ツールをメインセッションで直接呼ぶ。issue 作成前は重複を検索する。文面の下書きは上の「対外文書の下書き」に従う。

## Operational Commands

依存管理（`uv`）・Lint/Format（`ruff`）・Docker・環境セットアップ・ファイル整理・シェルスクリプト作成・changelog 生成は、メインセッションで直接実行する。長い出力のコマンドは `tail` / `grep` で絞るか、`run_in_background: true` で実行してログファイルから必要な部分だけ読む。
