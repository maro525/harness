# harness

`/orchestrate` を中心にした AI コーディングエージェント用のワークフロー定義。tier（XS / S / M / L）でタスクを分類し、startproject → team-implement → team-review → deploy の 4 フェーズを回す。各フェーズの記録は対象リポジトリの `.claude/docs/decisions/task-*.md`（TASK_FILE）に残る。

もとは [maro525/_dotfiles](https://github.com/maro525/_dotfiles) の一部で、履歴ごと切り出した。シェル・ターミナル・各 CLI の一般設定は引き続き dotfiles 側にある。

## 構成

```
harness/
├── claude/                  # Claude Code 版 (~/.claude)
│   ├── commands/            # orchestrate / startproject / team-implement / team-review / deploy
│   ├── rules/               # adaptive-execution.md (tier 分類) / tool-routing.md (委譲先)
│   └── hooks/agent-router.py  # UserPromptSubmit hook。意図を検出して /orchestrate へ誘導
├── opencode/                # OpenCode 版 (~/.config/opencode)
│   ├── README.md            # OpenCode 版と Claude 版の違い
│   ├── commands/
│   └── agents/
├── agents/                  # Claude 以外の CLI (pi / cline / opencode / codex) 向け Agent Skills (~/.agents/skills)
│   ├── README.md            # 外部 CLI のフェーズ実行（orchestrate STEP 3P が直接読む）
│   └── skills/
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
