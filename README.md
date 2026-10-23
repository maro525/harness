# harness

`/orchestrate` を中心にした AI コーディングエージェント用のワークフロー定義。tier（XS / S / M / L）でタスクを分類し、startproject → team-implement → team-review → deploy の 4 フェーズを回す。各フェーズの記録は対象リポジトリの `.claude/docs/decisions/task-*.md`（TASK_FILE）に残る。

もとは [maro525/_dotfiles](https://github.com/maro525/_dotfiles) の一部で、履歴ごと切り出した。シェル・ターミナル・各 CLI の一般設定は引き続き dotfiles 側にある。

## 構成

```
harness/
├── claude/                  # Claude Code 版 (~/.claude)
│   ├── commands/            # orchestrate / startproject / team-implement / team-review / deploy
│   ├── rules/               # adaptive-execution.md (tier 分類) / tool-routing.md (委譲先)
│   ├── hooks/agent-router.py  # UserPromptSubmit hook。意図を検出して /orchestrate へ誘導
│   └── scripts/linear-ask.sh  # OpenCode 版 orchestrate の質問の中継用（Linear API キーが要る）
├── opencode/                # OpenCode 版 (~/.config/opencode)
│   ├── README.md            # OpenCode 版と Claude 版の違い
│   ├── commands/
│   └── agents/
├── agents/                  # Claude 以外の CLI (pi / cline / opencode / codex) 向け Agent Skills (~/.agents/skills)
│   ├── README.md            # 外部 CLI のフェーズ実行（orchestrate STEP 3P が直接読む）
│   └── skills/
├── checks/crossrefs.sh      # dotfiles との相互参照チェック（下記「dotfiles との契約」）
├── kanban/                  # TASK_FILE を読む読み取り専用の kanban ボード (taskboard)
├── lib/sync-common.sh
├── sync-claude.sh
├── sync-opencode.sh
└── sync-agents.sh
```

## 配布

dotfiles と同じく HOME ⇄ リポジトリの双方向同期（対話モードで差分を見て a/p/h/s を選ぶ）。

```bash
./sync-claude.sh      # ~/.claude の harness ファイルだけ
./sync-opencode.sh    # ~/.config/opencode の harness ファイルだけ
./sync-agents.sh      # ~/.agents/skills の 4 フェーズ（+ Cline 用 symlink）
./sync-*.sh -n        # 非対話。HOME → repo の自動コピー
```

`~/.claude` と `~/.config/opencode` は dotfiles と共有しているので、各スクリプトは**自分が持つファイルを名前で列挙**し、ディレクトリ全体は走査しない。dotfiles 側の `sync-claude.sh` / `sync-opencode.sh` は同じ名前を除外している。ファイルを足したり消したりしたら両方のリストを揃える。

hook の登録（`settings.json` の `hooks.UserPromptSubmit`）と `Skill(orchestrate)` などの許可は `~/.claude/settings.json` にあり、dotfiles 側で管理する。

`agents/README.md` は HOME に配布しない。orchestrate のフェーズ指定モードは `$HARNESS`（未設定なら `~/src/harness`）から直接読む。別の場所に clone したら `HARNESS` を設定する。

kanban は `uv tool install --editable ~/src/harness/kanban`（詳細は `kanban/README.md`）。

## dotfiles との契約

`~/.claude` と `~/.config/opencode` は [maro525/_dotfiles](https://github.com/maro525/_dotfiles) と共有している。ファイルの所有者は名前で分けているが、**中身の参照関係**は名前でしか結ばれていないため、以下を契約として `checks/crossrefs.sh` で機械検査する（CI は無いので `sync-opencode.sh` の末尾から呼ぶ。失敗しても同期は成功扱い）。

1. `opencode/{commands,agents}/*.md` が `` `AGENTS.md` の「X」 `` の形で参照する節 X は、dotfiles の `opencode/AGENTS.md` に `## X` として実在すること（現在: `GIT RULES` / `ADAPTIVE EXECUTION` / `OpenCode 仕様メモ`）
2. dotfiles の `opencode/AGENTS.md` が `` `agents/x.md` `` / `` `commands/x.md` `` の形で参照するファイルは、`opencode/` 配下に実在すること
3. dotfiles の `opencode/AGENTS.md` が本リポジトリの `claude/rules/*.md` を要約している節には `正:` の注記があること（正はこちら側。dotfiles は OpenCode 向けの要約）

```bash
./checks/crossrefs.sh              # dotfiles を $DOTFILES / ~/src/_dotfiles / ../_dotfiles から探す
./checks/crossrefs.sh ~/src/_dotfiles
```

## Linear への質問の中継

orchestrate 中の質問（startproject のヒアリング・Gate 1、Gate 2 など）を Linear の issue コメントに投稿し、スレッド返信かターミナル入力の先着で回答を受ける。Linear ID が `NOLINEAR` なら従来どおりターミナルで聞く。

- **Claude Code 版**（`claude/commands/orchestrate.md`「質問の中継（Linear）」）: **API キー不要。** Linear MCP の `save_comment` で目印 `[claude-q:{MARK}]` 付きで投稿し、background Bash の `sleep` タイマーの完了通知で起きて `list_comments` でスレッド返信を確かめる（無ければタイマーを再起動、最大 4 時間 + 再アーム 1 回）。待機状態は `.claude/logs/ask-*.md` に残るので、会話が圧縮されても再開できる
- **OpenCode 版**（`opencode/commands/orchestrate.md`）: `~/.claude/scripts/linear-ask.sh`（`sync-claude.sh` が実行ビット付きで配布）で投稿・待機する。Linear の個人 API キー（Settings > Security & access > Personal API keys）が要る

OpenCode 版のキーの置き方:

```bash
mkdir -p ~/.config/harness
( umask 077; read -rsp 'Linear API key: ' k; echo; printf 'LINEAR_API_KEY=%s\n' "$k" > ~/.config/harness/linear.env )
chmod 600 ~/.config/harness/linear.env   # 既存ファイルを上書きした場合も 600 に
~/.claude/scripts/linear-ask.sh --check   # ok なら有効
```

- 環境変数 `LINEAR_API_KEY` があればそちらを優先する。ファイルは `source` せず、所有者が自分でない・group / other に権限があるファイルは拒否する
- `~/.claude/settings.json` には置かない（dotfiles で公開管理しているため）
- キーが無い・無効なら OpenCode 版はターミナル（`question` tool）で聞く
- exit code: 0 回答 / 2 タイムアウト / 3 キー不備 / 4 API 失敗 / 64 引数誤り / 130・143 シグナル。`--help` で使い方
