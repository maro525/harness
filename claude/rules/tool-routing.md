# Tool Routing Rules

**どの操作をどのツール・エージェントに委譲するかを定める。**
外部リサーチは firecrawl MCP + OpenCode の二系統、設計相談は OpenCode に振り分ける。使うかどうか自体は tier で決まる（`$HOME/.claude/rules/adaptive-execution.md` の「External Research」「OpenCode Design Consultation」）。本ファイルは「使う」となった場合の委譲先を定める。

**単発の作業はサブエージェント（Agent ツール）に振らず、メインセッションで直接実行する。** リサーチ・OpenCode・Linear・docker/uv/ruff・スクリプト作成などすべて対象。サブエージェントを使うのは `/orchestrate` 系（startproject / team-implement / team-review / deploy）と、それらの command が自分で定めている場合だけ。

## Skill Routing hook への応答

`agent-router.py`（UserPromptSubmit hook）が `[Skill Routing]` / `[Agent Routing]` を additionalContext に出す。ソフトな推奨として扱う。

- **従う**: プロンプトの意図と一致し、ユーザーの明示指示と矛盾しないとき。従う旨を一言伝えて起動する（`[Skill Routing]` は Skill ツール、`[Agent Routing]` は提案された firecrawl / OpenCode をメインで直接実行）
- **従わなくてよい**: ユーザーが別のことを明示している／提案スキルに対してタスクが小さすぎる（XS など）／進行中ワークフロー内の追加質問
- 提案がずれていると思ったら、理由を伝えてユーザーに確認する

## Routing Table

| Operation | Delegate To | Method |
|-----------|-------------|--------|
| External research | **firecrawl MCP + OpenCode** | 二系統を並列実行し Claude が統合（下記） |
| 記事 (URL 1 本) | **WebFetch** | 読めないページは firecrawl（`firecrawl_scrape`） |
| PDF (URL) / 複数ページ | **firecrawl MCP** | `firecrawl_parse` / `firecrawl_scrape` |
| 音声・動画 | **未対応** | 委託先なし。ユーザーに扱い方を確認する |
| Library research | **firecrawl MCP + OpenCode** | `firecrawl_search` で一次情報 + OpenCode で実装知見 |
| Design decisions | **OpenCode（モデルはフォールバック連鎖）** | バックグラウンド Bash で直接（`~/.claude/scripts/ai-fallback.sh {prompt_file}`、下記「OpenCode リサーチの実行」） |
| git（書き込み系） | **`/deploy` skill** | Ad-hoc Git モード。読み取り系は Claude が直接 |
| `/orchestrate` で作った PR への追加変更 | **`/orchestrate` 追加修正モード** | `/orchestrate "{追加の依頼} --task-file={TASK_FILE}"`。直接編集して Ad-hoc push しない（下記「Git Operations」） |
| docker/ruff/uv | **Direct** | Bash で直接実行（長いものは `run_in_background: true`） |
| Linear MCP | **Direct** | Linear MCP ツールを直接呼ぶ |
| GitHub 操作 | **`gh` CLI** | GitHub MCP は不安定なため使わない |

## External Research via firecrawl MCP + OpenCode

二系統を **並列実行**し、Claude が突き合わせて統合する。

| 系統 | ツール | 得意分野 |
|------|-------|---------|
| **一次情報** | firecrawl MCP | 公式ドキュメント・リリースノートの実文面。出典 URL が取れるが解釈はしない |
| **実装知見** | OpenCode CLI | 設計上の勘所・落とし穴・比較。解釈は出せるが出典を持たない |

食い違ったら **firecrawl の一次情報を優先**し、相違点と採用した方を成果物に記録する（`/startproject` では OUTPUT の `DESIGN`）。

### OpenCode リサーチの実行

**これが唯一動く呼び出し形。他のファイルはこの節を参照する。**

```bash
~/.claude/scripts/ai-fallback.sh {prompt_file}
```

`ai-fallback.sh` は次の連鎖を上から順に試し、**最初に答えを返したモデルを採用する**。各モデルは 1 回だけ呼ぶ（同じモデルの再試行はしない）。

| 順 | モデル | 提供元 | 位置づけ |
|---|---|---|---|
| 1 | `github-copilot/gpt-6-astra` | OpenCode（GitHub Copilot） | 既定 |
| 2 | `opencode-go/deepseek-v4-pro` | OpenCode Go（`https://opencode.ai/zen/go/v1`） | 1 が 429 / 残高切れのとき |
| 3 | `ollama-cloud/deepseek-v4.1-flash` | Ollama Cloud（`https://ollama.com/v1`） | 1・2 が 429 / 残高切れのとき |

- 候補の上書き: `AI_CHAIN="opencode-go/deepseek-v4-pro ollama-cloud/deepseek-v4.1-flash" ~/.claude/scripts/ai-fallback.sh {prompt_file}`
- 切替条件（スクリプトが判定）: HTTP 429 / `insufficient_quota` / rate limit → 次の候補。401 / 403（認証エラー）→ 次の候補。`exit 124` / `137`（タイムアウト）→ 次の候補。**空出力**のときは 429 をログ（`~/.local/share/opencode/log/`）、`ERROR` を stderr（`--print-logs --log-level ERROR`）で見て、どちらも無ければ「空出力」として次の候補
- **quota 以外の理由で落ちたときはエンジンを切り替える。** OpenCode 側の不具合（DB 破損・インストール不全）は次のモデルでも同じ壁に当たるので、その場合だけ `pi -p --no-session --model` に切り替えて連鎖を続ける（stderr に `switching to pi` を出す）。quota のときは切り替えない
- **記録は必須。** 成果物（`DESIGN` / `## team-review` / PR 本文など）に `利用AI: {AI_MODEL}` を書き、落とした候補があれば `（{model} は {理由} で skip）` を添える。スクリプトは stderr に `AI_ENGINE` / `AI_MODEL` / `AI_SKIPPED` を出す
- 全候補が失敗したときだけ OpenCode なしで続け、成果物に「OpenCode 不可: {理由}」と書く
- エンジンも連鎖する: `opencode2`（v2）→ `opencode`（v1）→ `pi` の順で、入っているものを使う。1 つのエンジンでモデル連鎖を回し、**quota 以外**の理由（DB 破損・認証エラー・タイムアウトなど）で落ちたら次のエンジンで同じモデルから再開する。`pi` に回ったときは `opencode-go/*` を `oc-sdk-go/*` に読み替える
- v1 と v2 の差分（`--auto`・`--standalone`・`--log-level` の大小文字・`-m provider/model#variant`）は下の「ラッパーが内部で使うコマンド」の表を参照
- 3 番目の候補を OpenCode から使うには provider 登録が要る（`../opencode/README.md`「フォールバック先の登録」）。未登録なら 3 番目は pi 側に切り替わる
- 長文プロンプトはファイルに落として渡す（スクリプトはファイルパスか `-`（stdin）を受ける）
- ツール呼び出しで止まらせたくなければ、プロンプト冒頭に `DO NOT USE ANY TOOLS`

#### ラッパーが内部で使うコマンド

手で叩いて切り分けるときの形。要素を外すと壊れる。**v2（`opencode2`）が本線、v1（`opencode`）は代替、どちらも無ければ `pi`**。

```bash
# v2
timeout -k 1m 20m opencode2 run --standalone --agent plan --print-logs --log-level error -m {model} "{research question}" < /dev/null
# v1
timeout -k 1m 20m opencode run --agent plan --print-logs --log-level ERROR -m {model} "{research question}" < /dev/null
```

| 要素 | 外すと壊れる理由 |
|------|-----------------|
| `--agent plan` **必須** | 既定の `build` は非対話実行だとパーミッション確認で**無言ハング**する（v1 で確認。v2 は `--auto` でも回避できるが、リサーチ用途では使わない）。stderr にも何も出ない |
| `--standalone`（v2） **必須** | v2 の `run` は既定で背景サービスに繋ぐ。`--standalone` で回ごとに専用サーバを立てる（前回の状態を引きずらない）。**サーバログが stderr に出るのも `--standalone` のときだけ**なので、429 の検知に必要 |
| `--log-level` の値は CLI ごとに違う | v2 は小文字（`error`）、v1 は大文字（`ERROR`）。間違えると理由が取れない |
| `< /dev/null` **必須** | stdin が**開いたパイプ**だと永久にハングする。`run_in_background: true` がまさにその状態（フォアグラウンドには自動で付くがバックグラウンドには付かない）。**バックグラウンド実行と必ずセット** |
| `2>/dev/null` を**付けない** | エラーを stderr に出しつつ **exit code 0** で終わる。潰すと「成功したのに出力が空」に見える |
| モデルは連鎖の 1 番目から | `openai/gpt-5.6-sol` は残高切れ（`insufficient_quota`）で**必ず失敗した**（課金が復活したら `AI_CHAIN` の先頭に戻す）。モデルを手で選ばず `ai-fallback.sh` に任せる |
| **バックグラウンド実行必須** | 込み入った質問は 10 分超。Bash ツールの既定 10 分で kill されると出力ゼロになり、ハングと見分けがつかない |
| `timeout -k 1m 20m` **必須** | 失敗後にプロセスが終わらないことがある（429 の後に MCP の認証待ちで止まり、完了通知が来ないまま待ち続けた）。`-k 1m` は SIGTERM で終わらないとき 1 分後に SIGKILL する。exit code 124（SIGTERM）/ 137（SIGKILL）はラッパーが次の候補へ回す |
| cwd は **git リポジトリ** | 非 git ディレクトリ（`/tmp` 等）だと起動時の `service=vcs` 初期化で無言ハングする |

- **完了はバックグラウンドタスクの完了通知で待つ。** `pgrep` / `tail --pid` で自前監視しない（`pgrep -f` は監視コマンド自身にマッチし、タイムアウトまで待ち続ける）
- 空出力を quota と決めつけず、ログ（`~/.local/share/opencode/log/`）で確認する。v1 は 1 セッション 1 ファイル、v2 は `opencode.log` 1 本に追記するので、**実行前後の差分だけを見る**（ラッパーはファイルサイズを控えてから `tail -c` で差分を検索する）。v1 の正常系は `service=session` → `POST /session` → `service=snapshot` → `resolveTools` → `service=llm … stream` と進む。**`service=vcs … initialized` で止まっていれば stdin 詰まり**（`< /dev/null` 忘れ）で、非 git cwd と同じ見た目になる。`session_message.seq` の SQLite エラーは **v1 固有**（v2 は同じ DB で動く）で、モデルを替えても直らない（ラッパーは `--print-logs --log-level error` を付けて stderr に理由を出させ、その行を `skip: … (error)` の下に添える）
- 疎通確認: `opencode2 run --agent plan -m <model> "Reply with exactly: PONG"`（v2。v1 は `opencode run …`）。利用可能モデルは `opencode2 models` で確認できる
- エンジンは `opencode2` → `opencode` → `pi` の順で存在するものを使う（ラッパーが決める）。手で叩くときは入っている方を使う
- どこでも Bash ツールで直接実行する（`run_in_background: true`）。サブエージェントは挟まない。長い出力はファイルに落とし、必要な部分だけ読む
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

### How to Route

サブエージェントは使わず、メインセッションで二系統を同時に進める。

1. **系統 2（実装知見）を先に起動**: `~/.claude/scripts/ai-fallback.sh {prompt_file}` を Bash の `run_in_background: true` で起動し、出力を `.claude/docs/research/{topic}-opencode.md` に落とす（10 分超かかることがある。stderr の `AI_MODEL` を `利用AI:` として記録する）
2. **系統 1（一次情報）をその間に実行**: `firecrawl_search` → 公式ドキュメント／リリースノートを `firecrawl_scrape`。主張ごとに出典 URL を控える
3. ai-fallback.sh の完了通知を待ち、出力ファイルを読んで firecrawl の結果と突き合わせて統合する（食い違いは firecrawl 優先）

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

- 判定基準: 対象ブランチが TASK_FILE（`.claude/docs/decisions/task-*.md`）の `## Meta` `branch:` に一致し、その `## deploy` に PR / MR URL がある
- 禁止: orchestrator やメインセッションがファイルを直接編集して `/deploy`（Ad-hoc Git モード）で commit / push すること。レビューを通らない変更が PR に載る（実例: `task-NOLINEAR-claude_config_simplify` の 2回目は後追いレビューで major が見つかり取り消しになった）
- 呼び出し形: `/orchestrate "{追加の依頼} --task-file={TASK_FILE}"`（または `/orchestrate "{LINEAR_ID} {追加の依頼}"`）
- `/deploy` の Ad-hoc Git モードは対象ブランチを検出したら実行せず、追加修正モードを案内して確認する（deploy.md「/orchestrate 由来の PR ブランチへのガード」）
- 例外（追加修正モードを通さなくてよい）: コードを変えない操作 — PR / MR の本文・タイトル修正、ラベル・レビュアー設定、読み取り系 git、マージ済み PR のブランチ削除。ユーザーが承知のうえで Ad-hoc 実行を明示した場合も実行するが、レビューを通っていない旨を報告する

### 保護ブランチ

- **`release` / `staging` / `main`（master 含む）への直接コミット・push は、ユーザーの明示的な許可がない限り禁止。** 反映は必ず PR / MR 経由
- 保護ブランチ上で書き込み操作が必要になったら、feature ブランチを作成してから実行する（tier=XS も同様）

### ホスティング CLI

`origin` のリモート URL で判定し、GitLab（セルフホスト含む）は `glab`、GitHub は `gh` を使う。GitHub MCP は不安定なため使わない。

## Linear MCP Operations

スキルの内外を問わず、Linear MCP ツールをメインセッションで直接呼ぶ。issue 作成前は重複を検索する。

## Operational Commands

依存管理（`uv`）・Lint/Format（`ruff`）・Docker・環境セットアップ・ファイル整理・シェルスクリプト作成・changelog 生成は、メインセッションで直接実行する。長い出力のコマンドは `tail` / `grep` で絞るか、`run_in_background: true` で実行してログファイルから必要な部分だけ読む。
