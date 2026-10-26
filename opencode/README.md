# OpenCode Config (Port of Claude Code Workflow)

Claude Code 版の `orchestrate + 4 subcommands` フローを OpenCode CLI 用に移植したもの。

## Layout

```
opencode/
├── AGENTS.md            # OpenCode 用グローバル指示（pi は pi/AGENTS.md と独立）
├── opencode.jsonc       # 主設定（model / permission / MCP）
├── agents/              # 各フェーズの subagent 定義（実体）
│   ├── startproject.md
│   ├── team-implement.md
│   ├── team-review.md
│   └── deploy.md
└── commands/            # スラッシュコマンド（薄いラッパー）
    ├── orchestrate.md   # メインオーケストレーター（@agent で駆動）
    ├── startproject.md  # → agents/startproject.md
    ├── team-implement.md
    ├── team-review.md
    └── deploy.md
```

## Deployment

### Global（全プロジェクト共通）

```bash
mkdir -p ~/.config/opencode/{agents,commands}
cp AGENTS.md           ~/.config/opencode/
cp opencode.jsonc      ~/.config/opencode/
cp agents/*.md         ~/.config/opencode/agents/
cp commands/*.md       ~/.config/opencode/commands/
```

### Per-project

リポジトリ直下に `.opencode/` として配置:

```bash
mkdir -p .opencode/{agents,commands}
cp -r opencode/agents/*.md    .opencode/agents/
cp -r opencode/commands/*.md  .opencode/commands/
```

## Portability Notes

Claude Code 版と完全に一致しない点:

| 機能 | Claude Code | OpenCode 版 |
|------|-------------|-------------|
| スキル連鎖 | `Skill` tool で別 skill 呼出 | `skill` tool はあるが、フェーズの連鎖は引き続き `@agent-name` mention / `task` |
| `context: fork` / `allowed-tools` | ネイティブ | `mode: subagent` + `subtask: true` / `permission` で近似 |
| UserPromptSubmit hook (`agent-router.py`) と「Skill Routing hook への応答」 | あり | **なし**（自動スキル提案は不可） |
| `AskUserQuestion` / `TodoWrite` ツール | あり | `question` / `todowrite`（`question` が subagent 内からユーザーに届くかは実機未検証） |
| `WebFetch`（記事 URL 1 本） | あり | `webfetch` tool。読めなければ `firecrawl_scrape` |
| `Agent` tool（サブエージェント起動） | あり。バックグラウンド起動と**完了通知**で待つ | `task` tool / `@agent` mention。**同期**なので完了通知・`timeout` は不要 |
| Linear MCP | `mcp__linear-server__*` | 同 MCP をそのまま利用可能 |
| TASK_FILE / Linear の書き手 | 各 command は OUTPUT を返し、orchestrator が書く | 各フェーズ agent が自分の節と Linear コメントを書く。`status` / `tier` / `#### 追加依頼 {n}` は orchestrator |
| ブラウザ確認 | ツール指定なし | ツール指定なし |
| `/simplify` など design skills | あり | 未移植（必要なら個別移植） |
| OpenCode セカンドオピニオン（team-review）・設計相談（startproject） | `~/.claude/scripts/ai-fallback.sh` で別モデル（連鎖は `~/.claude/rules/tool-routing.md`「OpenCode リサーチの実行」。全候補失敗時は「OpenCode 不可」） | `task` subagent（別コンテキスト）で代替。不可時は「Second Opinion 不可」/「設計相談不可」。`opencode run` の gotcha・完了通知・timeout・モデル連鎖は該当なし |
| 追加修正モード（既存 PR への追加変更） | `/orchestrate` STEP 3F、`/deploy` の Ad-hoc ガード | 同じ構成で移植済み（`commands/orchestrate.md` / `agents/deploy.md` / `AGENTS.md` GIT RULES） |
| PR / MR と issue の紐づけ（`--issue`・`## 関連`・タイトルの ID・ブランチ名） | `/orchestrate` が Meta に `issue:` を書き、`/deploy` が本文に書く。Linear への `links` 添付は orchestrate STEP 6b | 同じ規則（`commands/orchestrate.md` の「`--issue`」・`agents/deploy.md`「紐づけの規則」）。`links` 添付は deploy agent の 4-1b |
| 共通ルール（tier 基準・Git ルール） | `~/.claude/rules/*.md` | `AGENTS.md` に集約 |
| 質問の中継（Linear） | API キー不要。Linear MCP の `save_comment` で目印付きで投稿し、background Bash の `sleep` タイマーの完了通知で起きて `list_comments` でスレッド返信を確かめる。Linear 返信とターミナル入力の先着（`TaskStop` でタイマーを止める） | `~/.claude/scripts/linear-ask.sh`（`sync-claude.sh` で配布。Linear API キーが要る）で `--post-only` 投稿→URL 提示のあと、**フォアグラウンド**で `--timeout 540` ずつ再アームして待つ。ターミナル先着なし。実機未検証 |

## モデルのフォールバック（Claude 版）

Claude 版のリサーチ・設計相談は `~/.claude/scripts/ai-fallback.sh`（`sync-claude.sh` が配布）で次の連鎖を順に試す。詳細は `../claude/rules/tool-routing.md`「OpenCode リサーチの実行」。

**エンジン**: `opencode2`（v2）→ `opencode`（v1）→ `pi` の順で、入っているものを使う（1 つのエンジンで連鎖を回し、quota 以外の理由で落ちたら次のエンジンで同じモデルから再開する）。

| エンジン | 実体 | この環境での状態 |
|---|---|---|
| v2 | `opencode2` 2.1.4 | **本線**。`run --standalone --agent plan` で動く（実測 `PONG`） |
| v1 | `opencode` 1.14.48 | `run` が全モデルで `NOT NULL constraint failed: session_message.seq` |
| pi | `pi -p --no-session` | 最後の砦。`opencode-go/*` は `oc-sdk-go/*` に読み替え |

| 順 | モデル | OpenCode からそのまま使えるか |
|---|---|---|
| 1 | `github-copilot/gpt-6-astra` | 使える。ただし Copilot の**月間 quota 切れ**で `quota` 判定になる（実測） |
| 2 | `opencode-go/deepseek-v4-pro` | モデルは `opencode2 models` に出るが、この環境では **401（invalid credential）** |
| 3 | `ollama-cloud/deepseek-v4.1-flash` | **provider 登録が必要**（下記）。未登録ならスクリプトが `pi -p --model` に切り替える |

### v1 と v2 の CLI 差分

| 項目 | v1（`opencode`） | v2（`opencode2`） |
|---|---|---|
| 承認 | `--dangerously-skip-permissions` | `--auto` |
| モデル | `-m provider/model` | `-m provider/model#variant` |
| サーバ | 暗黙にローカル起動 | 背景サービスが既定。`--standalone` で専用サーバ、`--server <url>` で接続 |
| ログ | `--log-level ERROR`（大文字） | `--log-level error`（小文字、`all`/`none` など） |
| ログ出力 | `~/.local/share/opencode/log/` に 1 セッション 1 ファイル | 同ディレクトリの `opencode.log` 1 本に追記 |
| サブコマンド | 限定的 | `models` / `auth`(list, login, export, import, switch) / `service` / `session` / `serve` / `debug`(agents, config, paths, heap-dump) / `plugin` / `mcp` |
| 設定キー | `permission: "allow"` / `mcp` 直下 | `permissions[]` / `mcp.servers` に正規化（v1 形式も読める） |

config / data / DB / log のパスは v1 と v2 で共通（`opencode2 debug paths` で確認）。

### フォールバック先の登録

`~/.config/opencode/opencode.jsonc`（このファイルは dotfiles の持ち物なので、ここのリポジトリには置かない）:

```jsonc
{
  "provider": {
    "ollama-cloud": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama Cloud",
      "options": {
        "baseURL": "https://ollama.com/v1",
        "apiKey": "{env:OLLAMA_API_KEY}"
      },
      "models": {
        "deepseek-v4.1-flash": { "name": "deepseek-v4.1-flash" }
      }
    }
  }
}
```

- キーは `~/.bashrc.local` で `export OLLAMA_API_KEY=...`（OpenCode の設定ファイルに直書きしない）
- 疎通: `opencode run --agent plan -m ollama-cloud/deepseek-v4.1-flash "Reply with exactly: PONG" < /dev/null`
- 未登録のままスクリプトを回すと、3 番目は `pi -p --no-session --model ollama-cloud/deepseek-v4.1-flash` で実行される（pi 側は登録済み）

## Limitations

1. **自動ルーティングなし**: Claude Code の `agent-router.py` 相当が OpenCode にないため、ユーザーは明示的に `/orchestrate` を呼ぶ必要がある。
2. **スキル間呼出しの制約**: OpenCode のコマンドは他のコマンドを直接呼べない。orchestrate はサブエージェント `@` mention で連鎖させる設計。
3. **`context: fork` の完全一致不可**: `subtask: true` で近似するが、親子間のトークン共有挙動は若干異なる。
4. **Claude 固有で対応物がなく移植していないもの**:
   - 「完了通知で待つ」ルール、`pgrep` 禁止、`timeout -k 1m 20m` と exit 124 / 137、`opencode run` の gotcha 表（OpenCode 内では `task` が同期のため該当なし）
   - `agent: Plan` で CLAUDE.md が読まれない注意（OpenCode は `AGENTS.md` が全 agent に読み込まれる）
   - `model: opus[1m]` / `best` / `haiku` の指定（agent frontmatter で固定済み）
   - `context: fork` と `allowed-tools`（`subtask: true` と `permission` で近似済み）
5. **`question` の到達性は未検証**: subagent 内から `question` tool でユーザーに質問が届くかは実機で確認していない。届かない場合は通常の対話（返却で質問して再起動）で代替する。

## Testing

```bash
# OpenCode を起動
opencode

# TUI 内で試す
/orchestrate PROJ-573 をやりたいです
/orchestrate PROJ-573 をやりたいです --issue=closes:#12,#34
/startproject 新機能を追加したい
/team-review レビューして

# 追加修正モード（既存 PR / MR への追加変更）
/orchestrate レビュー指摘の型エラーを直す --task-file=.claude/docs/decisions/task-PROJ-573-coupon.md
/orchestrate PROJ-573 クーポンの有効期限チェックも追加する
```

## 参考

- 元 Claude Code 版: `../claude/commands/`
- OpenCode 公式: https://opencode.ai/docs/
