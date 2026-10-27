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
│   └── scripts/
│       ├── linear-ask.sh   # OpenCode 版 orchestrate の質問の中継用（Linear API キーが要る）
│       ├── ai-fallback.sh  # リサーチ・設計相談のモデル連鎖（429 で次の候補へ）
│       └── phase-run.sh    # フェーズを任意の CLI / モデルで実行するディスパッチャ
├── docs/phase-contract.md   # 4 フェーズが満たす契約（引数・書き込み・RESULT/QUESTIONS・status）
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
./sync-agents.sh      # ~/.agents/skills の 4 フェーズ + orchestrate（+ Cline 用 symlink）
./sync-*.sh -n        # 非対話。repo → HOME の自動コピー（初回配布にも使える）
./sync-*.sh -n --to-repo  # 非対話。HOME → repo の自動コピー
```

`-n` のコピーの向きはスクリプトごとの既定で決まる。harness の 3 スクリプトは repo → HOME（`lib/sync-common.sh` を source した直後に `SYNC_COMMON_DEFAULT_DIRECTION=repo-to-home`）、lib 自体の既定は dotfiles と同じ HOME → repo。`--to-home` / `--to-repo` でその回の向きを指定できる（`-n` と一緒に使う。対話モードには効かない）。コピー元に無いファイルは何もしない。

`~/.claude` と `~/.config/opencode` は dotfiles と共有しているので、各スクリプトは**自分が持つファイルを名前で列挙**し、ディレクトリ全体は走査しない。dotfiles 側の `sync-claude.sh` / `sync-opencode.sh` は同じ名前を除外している。ファイルを足したり消したりしたら両方のリストを揃える。

hook の登録（`settings.json` の `hooks.UserPromptSubmit`）と `Skill(orchestrate)` などの許可は `~/.claude/settings.json` にあり、dotfiles 側で管理する。

`agents/README.md` は HOME に配布しない。orchestrate のフェーズ指定モードは `$HARNESS`（未設定なら `~/src/harness`）から直接読む。別の場所に clone したら `HARNESS` を設定する。

kanban は `uv tool install --editable ~/src/harness/kanban`（詳細は `kanban/README.md`）。

## 外部 AI のフォールバック

リサーチ・設計相談・セカンドオピニオンのモデルは quota（429）で止まらず、次の候補に落ちる。呼び出しは `~/.claude/scripts/ai-fallback.sh`（`sync-claude.sh` が実行ビット付きで配布）に一本化し、連鎖は `claude/rules/tool-routing.md`「OpenCode リサーチの実行」が唯一の定義。

| 順 | モデル | 提供元 |
|---|---|---|
| 1 | `codex`（記録は `codex/{config.toml の model}`） | Codex CLI（`codex exec -s read-only`） |
| 2 | `github-copilot/gpt-6-astra` | OpenCode（GitHub Copilot） |
| 3 | `opencode-go/deepseek-v4-pro` | OpenCode Go（`https://opencode.ai/zen/go/v1`） |
| 4 | `ollama-cloud/deepseek-v4.1-flash` | Ollama Cloud（`https://ollama.com/v1`） |

```bash
~/.claude/scripts/ai-fallback.sh {prompt_file}                 # 1 → 2 → 3 → 4 の順に試す
AI_CHAIN="opencode-go/deepseek-v4-pro" ~/.claude/scripts/ai-fallback.sh {prompt_file}
AI_CHAIN="codex:gpt-6-sol github-copilot/gpt-6-astra" ~/.claude/scripts/ai-fallback.sh {prompt_file}
```

- 切替条件: 429 / `insufficient_quota` / rate limit / 401・403（認証）/ タイムアウト（exit 124・137）/ 空出力（429 はログ、`ERROR` は stderr）。同一モデルの再試行はしない
- Codex（`codex` / `codex:{model}`）はエンジン切替なしの単発候補で、失敗したら次のモデルへ進む。未インストールなら skip して OpenCode 連鎖だけで動く
- quota 以外の理由でエンジンが落ちたら（OpenCode 系の候補のみ）、次のエンジンで同じモデルから再開する（`opencode2`（v2）→ `opencode`（v1）→ `pi` の順。DB 破損などエンジン側の不具合で全滅しないため）
- v1 と v2 は同じ config / data / DB を共有するが、CLI フラグが違う（v2 は `--auto`・`--standalone`・`--log-level error`・`-m provider/model#variant`）。この環境の v1 は `session_message.seq` で全滅するので **v2 が本線**
- 成功時は stderr に `AI_MODEL`（と `AI_SKIPPED`）を出し、成果物の `利用AI:` 行に記録する
- OpenCode が無い環境では同じスクリプトが `pi -p --no-session --model` に切り替える（`opencode-go/*` は `oc-sdk-go/*` に読み替え）
- OpenCode から 3 番目を使うための provider 登録は `opencode/README.md`「フォールバック先の登録」（`opencode.jsonc` は dotfiles の持ち物）
- フェーズ指定モード（`--ai=opencode`）は CLI 直呼びなので連鎖は効かない。429 なら `--ai=pi:{model}` に切り替える。v2 が入っている環境では `--ai=opencode2` を使う（v1 はこの環境で `session_message.seq` により全滅）

## フェーズの混在（phase mixing）

4 フェーズは `agents/skills/{phase}/SKILL.md` が共通の契約（`docs/phase-contract.md`）を満たし、起動は `~/.claude/scripts/phase-run.sh` が吸収する。だから**フェーズごとに別の CLI / 別のモデル**で回せる。

```bash
# 1 フェーズだけ別 CLI で
~/.claude/scripts/phase-run.sh --phase=team-review --task-file=.claude/docs/decisions/task-X.md \
  --runner=pi:ollama-cloud/deepseek-v4.1-flash

# タスク全体の割り当てを決める（--phase-map）
~/.claude/scripts/phase-run.sh --phase=team-implement --task-file=.claude/docs/decisions/task-X.md \
  --phase-map="startproject=claude:opus,team-implement=pi:ollama-cloud/deepseek-v4.1-flash,team-review=opencode2:opencode-go/deepseek-v4-pro,deploy=claude:haiku"

# モデル / エンジン連鎖に任せる（429 で次の候補へ）
~/.claude/scripts/phase-run.sh --phase=startproject --task-file=… --runner=auto
```

- runner: `claude` / `opencode2` / `opencode` / `pi` / `codex` / `cline` / `auto`（`ai-fallback.sh`）。既定の失敗連鎖は claude → opencode2 → pi → auto
- `--dry-run` で起動コマンドだけ確認できる（トークンを使わない）
- 実際に走った runner / モデルは stderr の `PHASE=` / `RUNNER=` / `MODEL=` / `LABEL=` で返り、`利用AI:` 行には `--label` でそのまま入る
- 契約（引数・書き込み規約・`### RESULT` / `### SECTION`・`### QUESTIONS`・`status:` の専権）は `docs/phase-contract.md`
- 機械検査: `./checks/phases.sh`（3 系統の定義の揃い / `--task-file`・`--label` / フェーズが `status:` を書いていない / orchestrator の 3F・3P / `phase-run.sh` の runner / 配布対象）

### pi 単独で回す

`agents/skills/orchestrate/SKILL.md` が orchestrator（`./sync-agents.sh` で `~/.agents/skills/orchestrate` に配布）。pi からは次の形で起動する。

```
Read ~/.agents/skills/orchestrate/SKILL.md and follow it.

$ARGUMENTS: "{task description} --tier=M"
```

- フェーズは内部で `~/.claude/scripts/phase-run.sh` を呼ぶので、混在（`--phase-map`）も同じ口で指定できる
- 質問は `### QUESTIONS` に直列化し、`--answers-file` で戻す（pi に質問ツールが無いため）
- 制約: レビューは順次（Claude 版の並列レビュアーは未移植）、Linear は MCP があるときだけ

## dotfiles との契約

`~/.claude` と `~/.config/opencode` は [maro525/_dotfiles](https://github.com/maro525/_dotfiles) と共有している。**参照方向は harness → dotfiles の一方向**で、dotfiles は本リポジトリの存在を知らない（dotfiles 単体で完結し、harness は後から任意で足せるレイヤー）。したがって相互参照の検査はすべてこのリポジトリ側に置き、dotfiles の sync スクリプトからは呼ばない。dotfiles が見つからない場合、`checks/crossrefs.sh` は検査せずに成功終了する。

`lib/sync-common.sh` は dotfiles の `lib/sync-common.sh` と同一内容（ヘッダコメント 1 行を除く）を保つ。片方を変えたらもう片方にも同じ変更を入れる。

`checks/crossrefs.sh` が検査する内容（CI は無いので `sync-opencode.sh` の末尾から呼ぶ。失敗しても同期は成功扱い）:

1. `opencode/{commands,agents}/*.md` が `` `AGENTS.md` の「X」 `` の形で参照する節 X は、dotfiles の `opencode/AGENTS.md` に `## X` として実在すること（現在: `GIT RULES` / `ADAPTIVE EXECUTION` / `OpenCode 仕様メモ`）
2. `` `AGENTS.md` の「X」の「Y」 `` の形で参照する下位項目 Y は、dotfiles の X 節の中に実在すること（バッククォート・強調は無視して比較）
3. X 節に、本リポジトリの手順が前提にしている語（`ADAPTIVE EXECUTION` → エスカレーション、`GIT RULES` → 保護ブランチ）があること
4. dotfiles の `opencode/AGENTS.md` が `` `agents/x.md` `` / `` `commands/x.md` `` の形で参照するファイルは、`opencode/` 配下に実在すること

```bash
./checks/crossrefs.sh              # dotfiles を $DOTFILES / ~/src/_dotfiles / ../_dotfiles から探す
./checks/crossrefs.sh ~/src/_dotfiles
```

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
