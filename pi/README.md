# pi 設定レイヤー

pi（`~/.pi/agent`）に配布する harness 固有のファイル。dotfiles 側は `pi/` を知らない。

## 構成

```
pi/
├── README.md
└── prompts/
    └── orchestrate.md   # /orchestrate — ~/.agents/skills/orchestrate/SKILL.md を読む薄いラッパー
```

pi のスキル本体（startproject / team-implement / team-review / deploy / orchestrate）は
`agents/skills/` にあり、`sync-agents.sh` が `~/.agents/skills/` へ配布する。ここに置くのは
pi だけが読むプロンプトテンプレートで、`/orchestrate` を Claude / OpenCode と同じ名前で使えるようにする。

## 配布

```bash
./sync-pi.sh              # 対話モード（差分を見て a/p/h/s を選ぶ）
./sync-pi.sh -n           # 非対話。repo → HOME
./sync-pi.sh -n --to-repo # 非対話。HOME → repo
```

`~/.pi/agent` には pi 本体の設定（`AGENTS.md` / `settings.json` / `extensions/`）があるので、
スクリプトは **自分が持つファイルを名前で列挙**し、ディレクトリ全体は走査しない。

## 前提

`/orchestrate` はスキルとフェーズ実行スクリプトに依存する。初回はこの順で入れる。

```bash
./sync-agents.sh -n   # ~/.agents/skills/{startproject,team-implement,team-review,deploy,orchestrate}
./sync-claude.sh -n   # ~/.claude/scripts/{phase-run,ai-fallback,linear-ask}.sh
./sync-pi.sh -n       # ~/.pi/agent/prompts/orchestrate.md
```

pi は TTY が無いと未許可の bash を拒否するので、`~/.pi/agent/extensions/permissions/index.ts` の
`ALLOW_PATTERNS` に次を足しておく（`sync-pi.sh` が不足を警告する）。

```ts
"~/.claude/scripts/**",
"/home/<user>/.claude/scripts/**",   // $HOME を展開して呼ぶ場合
"git switch **",
```

反映には pi の再起動か `/reload` が要る。

## 使い方

```text
/orchestrate "<task> [--tier=S|M|L] [--task-file=<path>] [--phase=<phase>] [--issue=closes:#N]"
```

`/skill:orchestrate` でも同じ `SKILL.md` に入れる。引数は SKILL.md の Input と同じで、`--phase` が
無ければ通常モード（STEP 0 から）になる。

- フェーズの起動は `~/.claude/scripts/phase-run.sh` に一本化されている（`--runner` / `--phase-map` で
  CLI・モデルを混在できる）。既定の失敗連鎖は claude → opencode2 → pi → auto
- 質問は `### QUESTIONS` に直列化される（pi に質問ツールが無いため）。回答は `--answers-file` で戻す
- レビューは順次（Claude 版の並列レビュアーは未移植）、Linear は MCP があるときだけ
