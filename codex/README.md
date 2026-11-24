# Codex 設定レイヤー

Codex（`~/.codex`）に配布する harness 固有のファイル。dotfiles 側は `codex/` を知らない。

## 構成

```
codex/
├── README.md
└── prompts/
    └── orchestrate.md   # /orchestrate — ~/.agents/skills/orchestrate/SKILL.md を読む薄いラッパー
```

ここに置くのは orchestrate のプロンプト 1 本だけ。スキル本体（startproject / team-implement /
team-review / deploy / orchestrate）は `agents/skills/` にあり `sync-agents.sh` が
`~/.agents/skills/` へ、フェーズ実行スクリプトは `claude/scripts/` にあり `sync-claude.sh` が
`~/.claude/scripts/` へ配布する。

## 配布

```bash
./sync-codex.sh              # 対話モード（差分を見て a/p/h/s を選ぶ）
./sync-codex.sh -n           # 非対話。repo → HOME
./sync-codex.sh -n --to-repo # 非対話。HOME → repo
```

`~/.codex` には Codex 本体の設定（`config.toml` など）があるので、スクリプトは
**自分が持つファイルを名前で列挙**し、ディレクトリ全体は走査しない。

## 前提

`/orchestrate` はスキルとフェーズ実行スクリプトに依存する。初回はこの順で入れる。

```bash
./sync-agents.sh -n   # ~/.agents/skills/{startproject,team-implement,team-review,deploy,orchestrate}
./sync-claude.sh -n   # ~/.claude/scripts/{phase-run,ai-fallback,linear-ask}.sh
./sync-codex.sh -n    # ~/.codex/prompts/orchestrate.md
```

## 使い方

```text
/orchestrate "<task> [--tier=S|M|L] [--task-file=<path>] [--phase=<phase>] [--issue=closes:#N]"
```

Codex はプロンプト内の `$ARGUMENTS` を展開するので、引数はそのまま SKILL.md の Input に渡る。
`--phase` が無ければ通常モード（STEP 0 から）になる。

- フェーズの起動は `~/.claude/scripts/phase-run.sh` に一本化されている（既定の失敗連鎖は
  codex → cline → pi）。`--runner` / `--phase-map` で CLI・モデルを混在できる
- 質問は `### QUESTIONS` に直列化される。回答は `--answers-file` で戻す
