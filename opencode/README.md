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
| OpenCode セカンドオピニオン（team-review）・設計相談（startproject） | `opencode run` で別モデル（`timeout -k 1m 20m`、不可時は「OpenCode 不可」） | `task` subagent（別コンテキスト）で代替。不可時は「Second Opinion 不可」/「設計相談不可」。`opencode run` の gotcha・完了通知・timeout は該当なし |
| 追加修正モード（既存 PR への追加変更） | `/orchestrate` STEP 3F、`/deploy` の Ad-hoc ガード | 同じ構成で移植済み（`commands/orchestrate.md` / `agents/deploy.md` / `AGENTS.md` GIT RULES） |
| 共通ルール（tier 基準・Git ルール） | `~/.claude/rules/*.md` | `AGENTS.md` に集約 |

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
/startproject 新機能を追加したい
/team-review レビューして

# 追加修正モード（既存 PR / MR への追加変更）
/orchestrate レビュー指摘の型エラーを直す --task-file=.claude/docs/decisions/task-PROJ-573-coupon.md
/orchestrate PROJ-573 クーポンの有効期限チェックも追加する
```

## 参考

- 元 Claude Code 版: `../claude/commands/`
- OpenCode 公式: https://opencode.ai/docs/
