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

## PR / MR と issue の紐づけ

deploy は PR / MR を作る・追記するときに、Linear issue と GitHub / GitLab issue を機械的に紐づける（定義は `claude/commands/deploy.md`「紐づけの規則」。OpenCode 版・`agents/skills/deploy` も同じ）。

| 対象 | 紐づけ方 |
|---|---|
| Linear | タイトル末尾の ` ({LINEAR_ID})`、本文末尾 `## 関連` の `Part of {LINEAR_ID}`、ブランチ名 `feature/{linear_id を小文字}-{短い名前}`（team-implement が付ける）。連携で PR が添付されていなければ `save_issue` の `links` で代わりに添付する（新規作成時のみ。Claude 版は orchestrate STEP 6b、OpenCode 版は deploy agent） |
| GitHub / GitLab issue | `/orchestrate "… --issue=closes:#12,#34"` で渡す。`## Meta` に `- issue: closes #12, refs #34` が残り、本文の `## 関連` に `Closes #12` / `Related to #34` が入る。接頭辞なしは `refs`（参照だけ）。閉じるのは `closes:` を明示したときだけ。`#N` の自動検出はしない |

```text
--issue={ref}[,{ref}...]    {ref} = [closes:|refs:]{#N | owner/repo#N | URL}
```

- 追加修正モードで `--issue` を渡すと、Meta に追記され、既存 PR / MR の本文に無い行だけが `### 関連（追加依頼 {n}）` として足される。旧形式（「関連 Linear タスク: {ID}」だけ）の PR には `Part of {LINEAR_ID}` が補われる（タイトルは変えない）
- 禁則: Linear ID は大文字、参照は 1 行に 1 つ、コードフェンスの中に書かない、行頭を `/` にしない（GitLab の quick action になる）
- deploy の返却（`## deploy`）に `紐づけ:` 行が入る。base がデフォルトブランチでない（`Closes` が自動で閉じない）・ブランチ名に ID が無い・`links` で代わりに添付した、は申し送りに書かれる

### Linear 連携の前提と状態遷移（仕様メモ）

- 現在、Linear の GitHub 連携は有効にしていない（NSKETCH-1983 Gate 1）。issue から PR に辿る経路は `links` による添付で、マージしても Linear の状態は自動では変わらない
- Linear の magic word: closing（`Closes` / `Fixes` / `Resolves` / `Completes` / `Implements` 系）はマージ時に team の「On PR merge」の状態へ移す。non-closing（`Part of` / `Ref` / `Refs` など。GitLab では `Refs` が無く `Updates` がある）は状態を変えない。本文はあとから編集しても紐づく
- `Part of` を使うのは、GitHub / GitLab の両方で non-closing として読まれ、マージで自動 Done にしないため（Gate 1 Q1）
- 連携を有効にする場合は、PR を開いたとき・マージしたときの状態遷移（team の Settings > Workflow の Git automations）を先に決める。タイトル・ブランチ名の ID だけで紐づいた PR がマージ時に closing として扱われるかは未確認なので、有効化したら確かめ、自動 Done にしたくなければ「On PR merge」の自動化を外す。連携が自動で添付した PR が `get_issue` の `attachments` に載るか（`links` との二重添付）も確かめる
- GitHub の `Closes #N` は base がデフォルトブランチの PR でだけ効く。GitLab はデフォルトブランチへマージされたときに閉じ、`Related to #N` は関連 issue になる

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
