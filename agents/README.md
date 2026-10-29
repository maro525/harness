# Agent-general phase skills

`/orchestrate` の 4 フェーズ（startproject / team-implement / team-review / deploy）を、**Claude 以外の CLI エージェント**（pi / cline / opencode / codex）でも回せるようにした [Agent Skills](https://agentskills.io/specification) 形式の定義。Claude 版（`../claude/commands/*.md`）は OUTPUT を返して orchestrate が TASK_FILE に書くが、こちらは**各フェーズが TASK_FILE の自分の節を自分で書く**。

`orchestrate/` が orchestrator 本体（pi / cline / codex でも単独でタスクを回せる）。フェーズの起動は `~/.claude/scripts/phase-run.sh` に任せ、CLI / モデルの差はそこで吸収する。

主な使い道は `/orchestrate` の**フェーズ指定モード**（`../claude/commands/orchestrate.md` STEP 3P）: 既存 TASK_FILE の 1 フェーズを別 AI で 1 回実行し、別案（`### 案 {k}`）や別視点のレビュー（`### {m}回目`）として追記する。見出しは Claude 版の通常モードと同じで、使った AI は見出しの直下の `利用AI:` 行で示す。

## Layout

```
agents/
├── README.md
└── skills/
    ├── startproject/SKILL.md    # 計画: Brief / Design / Plan（--label ありなら ### 案 {k} + 利用AI 行）
    ├── team-implement/SKILL.md  # 実装: feature ブランチ + TDD、### {m}回目 + 利用AI 行、Meta の branch/base
    ├── team-review/SKILL.md     # レビュー: 観点別（Quality/Logic → Security → Simplify）、判定 PASS/FAIL
    ├── claude-consult/SKILL.md  # フェーズではない。Claude 以外のエージェントから読み取り専用の Claude に設計相談（~/.claude/scripts/claude-consult.sh、--resume で往復）
    └── deploy/SKILL.md          # commit → push → PR/MR（gh / glab）、#### PR / MR + 利用AI 行 + 紐づけ行。作業ブランチに留まる（TASK_FILE のコミットと分岐元への復帰は呼び出し元）
```

配布先は `~/.agents/skills/{name}/`（`./sync-agents.sh`）。Cline だけは `~/.cline/skills/{name}` → `~/.agents/skills/{name}` の symlink で読ませる。

## 共通規約

フェーズの SKILL.md（claude-consult を除く）はすべて同じ規約で書かれている。

| 項目 | 規約 |
|---|---|
| frontmatter | `name`（ディレクトリ名と同一）/ `description` / `metadata.phase` / `metadata.writes` のみ。CLI 固有のキーは使わない |
| 引数 | `"{task description} --task-file={TASK_FILE} [--tier=S\|M\|L] [--linear-id={ID}] [--label={実行者名}]"`。`--tier` / `--linear-id` は省略時 `## Meta` から読む |
| 書く場所 | 自分の `##` 節だけで、その外には何も追記しない。`## Meta` の `status:` は書かない（team-implement だけ `branch:` / `base:` を書く）。`##` 見出しは増やさない（kanban が `##` で列判定） |
| 見出し | Claude 版の通常モードと同じ。startproject: `--label` あり → `### 案 {k}` + `#### Brief/Design/Plan`、なし → `### Brief/Design/Plan` を上書き。team-implement / team-review: `### {m}回目`。deploy: `#### PR / MR`（追加は `#### 追加 push（…）`）。見出しに実行者名や日時を入れない |
| 利用AI 行 | `--label` があれば見出しのすぐ下（空行なし）に `利用AI: {label}（{YYYY-MM-DD HH:MM}）`（deploy は日時の行が別にあるので `利用AI: {label}`）。無ければ書かない。同じ見出しが並んでも（同じ回を別の AI がレビュー）区別はこの行で付ける。節の中に実行経路の説明（「外部 CLI で実行」など）は書かない |
| 対話 | 質問できない環境では推定して続行し、`前提（推定）` として節に残す。Gate 1 は候補モード・非対話では待たず `gate1: 要確認` |
| 外部ツール | サブエージェント・Web 検索・Linear 連携は「あれば使う、無ければ自分で行い、その旨を書く」。Linear のステータスは変えない |
| 最終メッセージ | `### RESULT`（phase / task_file / written / section / linear / フェーズ固有行）+ `### SECTION`（書いた節の丸写し）。サンドボックスで書けなかったとき orchestrate がこれを代筆する |

Claude 固有要素（`context: fork`、`agent:`、`allowed-tools`、`model:`、AskUserQuestion、Agent ツール、hook、`$HOME/.claude/rules`）には依存しない。tier の意味・セキュリティ観点・git 保護ブランチなど必要な共通ルールは各 SKILL.md に内包してある。

## 各 CLI がスキルを探す場所

| CLI | 探索場所（一次情報） |
|---|---|
| pi | `~/.agents/skills/`、`.agents/skills/`（cwd から祖先、リポジトリルートまで）。**同名は最初に見つかった方が勝ち**（`~/.pi/agent/skills` が先） — [docs/skills.md](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/skills.md) |
| cline | プロジェクト `.cline/skills/`、`.clinerules/skills/`、`.claude/skills/`。グローバル `~/.cline/skills/` — [Skills](https://docs.cline.bot/customization/skills) |
| opencode | `.opencode/skills`、`~/.config/opencode/skills`、`.claude/skills`、`~/.claude/skills`、`.agents/skills`、`~/.agents/skills` — [Agent Skills](https://opencode.ai/docs/skills/) |
| codex | `$CWD/.agents/skills`、`$CWD/../.agents/skills`、`$REPO_ROOT/.agents/skills`、`$HOME/.agents/skills`、`/etc/codex/skills` — [Build skills](https://developers.openai.com/codex/skills) |

orchestrate のフェーズ指定モードは探索に頼らず、プロンプトで `Read {abs path}/SKILL.md and follow it` と絶対パスを渡す（CLI ごとの探索差を吸収するため）。各 CLI の起動オプションは下の「外部 CLI のフェーズ実行」。

## 外部 CLI のフェーズ実行

`/orchestrate` のフェーズ指定モード（`../claude/commands/orchestrate.md` STEP 3P）が、既存 TASK_FILE の 1 フェーズを外部 CLI に実行させるときの呼び出し表。対象 CLI は **pi / cline / opencode / codex**（Claude の別モデルは対象外。`context: fork` の command は frontmatter の `model` が優先され `--model` で変えられない）。読ませる定義は `~/.agents/skills/{phase}/SKILL.md`（この `skills/` の配布先。配布は `../sync-agents.sh`）。

**CLI の起動オプション・権限・最終メッセージの取り出し・共通則は、この節が唯一の定義。** 実行は `claude/scripts/phase-run.sh`（`sync-claude.sh` が `~/.claude/scripts/phase-run.sh` に配布）に一本化しており、下の表はスクリプトが組み立てるコマンドと同じ。`../claude/rules/tool-routing.md` には書かない（毎回読み込まれるファイルだが、この内容を使うのはフェーズ指定モードだけ）。手で 1 フェーズを回すときも同じ表のコマンドに `"$(cat {prompt_file})"` を渡し、`--label={ai}/{model}` を付ける（TASK_FILE の書き方が orchestrate 経由と同じになる。「共通規約」の見出し・利用AI 行）。deploy を手で回したときは CLI が作業ブランチに留まり TASK_FILE を未コミットで残すので、自分で TASK_FILE だけを `docs(task):` でコミットして同じブランチに push し、分岐元に戻る（orchestrate 経由では STEP 3P P7 が `/deploy "--finalize --task-file=…"` で行う）。**TASK_FILE を gitignore していないリポジトリでは、このコミットが PR / MR に載る**（設計の検討内容・Linear ID などの社内向けメモが公開範囲に入る）。公開したくなければ `.claude/`（または `.claude/docs/decisions/`）を `.gitignore` に入れておく（gitignore なら finalize は commit / push せず分岐元に戻るだけ）。

### orchestrate からの参照

この README は `~/.claude` に同期されない（`sync-claude.sh` の対象は `claude/` 配下だけ）ので、orchestrate.md STEP 3P は harness リポジトリのチェックアウトを次の順で探し、`{HARNESS}/agents/README.md` のこの節を読む（P2 で解決し、P3 / P4 で使う）:

1. 環境変数 `HARNESS` が設定されていて `$HARNESS/agents/README.md` がある → それ
2. `$HOME/src/harness/agents/README.md` がある → それ
3. どちらも無ければ中止し、ユーザーに harness リポジトリのパスを尋ねる（推測で続けない。`sync-agents.sh` の案内と同じ扱い）

リポジトリを `~/src/harness` 以外に置いたら `HARNESS` を設定する。この README を `~/.claude` や `~/.agents` にコピーして配布することはしない（コピーは古くなるし、この節を使うのは orchestrate だけ）。

### 呼び出し表

**全フェーズ同じ起動オプションで動かす（読み取り専用にしない）。** startproject / team-review も team-implement / deploy と同じく、確認なしで編集・コマンド実行を許す指定で起動する（Gate 1 / Gate 2 でユーザー了承済み。理由は下の「権限」）。`{prompt}` は orchestrate が作ったプロンプトファイルの中身（`"$(cat {prompt_file})"`）、`{repo}` は対象リポジトリの絶対パス、`{last}` は `{log_file}` と同じ場所の `.last.md`。

| ai | 起動（全フェーズ共通） | モデル指定（`--ai={ai}:{model}`） |
|---|---|---|
| `pi` | `pi -p --no-session "{prompt}"` | `--model {model}`（`provider/id` 形式可） |
| `cline` | `cline --json --auto-approve true -t 1800 "{prompt}"` | `-m {model}`（provider は cline の設定値。変えるなら `-P {provider}` を併記） |
| `opencode` | `opencode run --agent build --dangerously-skip-permissions "{prompt}"` | `-m {provider/model}` |
| `opencode2` | `opencode2 run --standalone --agent build --auto "{prompt}"` | `-m {provider/model}#{variant}` |
| `claude` | `claude -p --model {model} --permission-mode acceptEdits "--allowedTools={tools}" "{prompt}"` | `--model {model}` |
| `codex` | `codex exec -s workspace-write -c 'sandbox_workspace_write.writable_roots=["{repo}/.git"]' -o {last} "{prompt}"`。deploy は push のため `-c 'sandbox_workspace_write.network_access=true'` を加える | `-m {model}` |

- モデル名は**変換せずそのまま**渡す（各 CLI で通る名前をユーザーが指定する）
- **claude の `--allowedTools` は `=` 形式で渡す**（`--allowedTools=Read,Write,...`）。空白区切りだと後ろのプロンプトがツール名として吞み込まれ、`Input must be provided either through stdin or as a prompt argument` で落ちる
- **claude は `--permission-mode acceptEdits` を付ける**（付けないと非対話では書き込みが拒否される）。`--dangerously-skip-permissions` は使わない
- **codex に `-s danger-full-access` は使わない。** `workspace-write` は writable root 配下の `.git` を読み取り専用にするため、`git checkout -b` / `git commit` が失敗する。`.git` を `writable_roots` に足せば足り、deploy の push は `network_access=true` で通る（キー名は codex の config reference `sandbox_workspace_write.writable_roots` / `.network_access`）。codex を更新したら `codex exec --help` と config reference でキー名が生きているか確認する
- codex の最終メッセージは `-o {last}`（`--output-last-message`）でファイルに取る。stdout は `--json` を付けなくてもイベントログが混ざるので、そこから拾わない
- `which -a codex` で複数見つかる環境（WSL で Windows 側の `npm` の codex が先に来る等）では、PATH の先頭がどちらかを `codex --version` で確認してから使う
- cline の `--json` は 1 行 1 JSON のストリーム（`text` はエスケープ済み）。最終メッセージは `"type":"run_result"` 行の `text`（下記「最終メッセージの取り出し」）
- どのフェーズも CLI が TASK_FILE に直接書く（`written: yes`）。サンドボックス等で書けなかったとき（`written: no`）だけ orchestrate が `### SECTION` から代筆する（STEP 3P P4）。startproject / team-review では起動前後で作業ツリー・HEAD・ref・stash を比べ、TASK_FILE 以外に変化があれば報告する（P5）
- codex 0.80.0 は ChatGPT アカウントで使えるモデルが無く全モデル失敗する（2026-09-28 実測）。`npm i -g @openai/codex@latest` で更新してから使う（下の「実機の状態」）
- opencode は quota 切れ（429）だと無出力に見える。ログ（`~/.local/share/opencode/log/`）の 429 を先に確認する。Claude 版のリサーチ・設計相談は `~/.claude/scripts/ai-fallback.sh` のモデル連鎖に任せる（`../claude/rules/tool-routing.md`「OpenCode リサーチの実行」）。**フェーズ指定モード（`--ai=opencode`）は CLI 直呼びなので連鎖は効かず、429 なら `--ai=pi:{model}` で回す**
- **v1 と v2 でフラグが違う**: v2（`opencode2`）は `--auto`（v1 は `--dangerously-skip-permissions`）、`--log-level` は小文字、モデルは `provider/model#variant`。この環境の v1 は `run` が `session_message.seq` で全滅するので、入っていれば **v2 を使う**（`--ai=opencode2`）
- **pi の許可リストにワークフローのスクリプトを入れる**: pi は `~/.pi/agent/extensions/permissions/` の `ALLOW_PATTERNS` に無いコマンドを TTY 無しで拒否する。`"~/.claude/scripts/**"`（および `/home/dev/.claude/scripts/**`）と `git switch` を入れておかないと、`phase-run.sh` の起動やブランチ復帰で止まる（未登録の場合の回避策は `for _ in 1; do <script> ...; done`、というより追加する）

### 権限

**全フェーズ同じ権限で動く。読み取り専用にしない**（Gate 2 のユーザー判断、2026-09-29）。理由: 読み取りフェーズだけ絞っても、各 CLI の「読み取り専用」は実態と一致しなかった（pi の `bash` は `~/.pi/agent/extensions/permissions/` の許可リストで `git push` / `python3` まで通り、opencode の許可リストにはサブエージェント起動などの抜け道が残った）うえ、絞ると `date` / `git` / テストが使えず orchestrate 側の代筆・差分渡し・検知の手順が肥大した。

- startproject / team-review が TASK_FILE 以外を変更しないのは **SKILL.md の指示**によるもので、起動オプションでは強制しない。orchestrate は起動前後の簡単な比較で TASK_FILE 以外の変化を報告する（orchestrate.md STEP 3P P5）
- リポジトリ内の文章に仕込まれた指示に従う危険はどのフェーズにもある。信頼できないリポジトリでは使わない

### 最終メッセージの取り出し（STEP 3P P4）

| ai | 最終メッセージ |
|---|---|
| `pi` / `opencode` | `{log_file}` の末尾（プレーンテキスト） |
| `codex` | `{last}`（`-o` で書かせたファイル） |
| `cline` | `grep '"type":"run_result"' {log_file} \| tail -n 1 \| jq -r .text`（`jq` が無ければ `python3 -c 'import sys,json; print(json.loads(sys.stdin.readline())["text"])'`） |

取り出したテキストから `### SECTION` 以下を切り出す: `awk '/^### SECTION/{f=1;next} f'`（`### RESULT` は追記しない）。

### 共通則

| 要素 | 理由 |
|---|---|
| `< /dev/null` **必須** | stdin が開いたパイプだと pi / opencode / codex はハングする（codex はプロンプト未指定時に stdin を読む） |
| `timeout -k 1m 30m` | 実装フェーズは 10 分を超える。Bash の既定 10 分では kill されて出力ゼロになる |
| **バックグラウンド実行必須** | 同上。完了通知で待ち、`pgrep` やログ先読みで完了を推測しない |
| `2>/dev/null` を**付けない** | エラーが stderr に出て exit 0 で終わる CLI がある。`> {log} 2>&1` で両方を残す |
| cwd は対象リポジトリ | 各 CLI は cwd からリポジトリの指示ファイル・スキルを探す。非 git ディレクトリではハングする CLI がある（opencode） |
| ログは `.claude/logs/phase-{phase}-{ai}-{日時}.log` | プロンプトも同じ場所に `.prompt.txt`、codex の最終メッセージは `.last.md` で残す（`.claude/` は gitignore 済み） |

```bash
timeout -k 1m 30m {上表のコマンド} "$(cat {prompt_file})" < /dev/null > {log_file} 2>&1
```

失敗判定は orchestrate 側（exit ≠ 0 / 124・137 / 節も `### SECTION` も無い）。再試行・モデル差し替えは自動では行わず、ユーザーに報告する。

### 実機の状態（2026-10-27）

| CLI | 状態 |
|---|---|
| pi | `pi -p --no-session` で orchestrate（`agents/skills/orchestrate`）からのフェーズ逐次実行を通しで確認（捨てリポジトリで plan → 実装 → レビュー。review は `claude:haiku` に委譲、deploy はリモート無しで中止）。`--tools` 制限なしの起動（上の呼び出し表）は未検証。pi の bash で何が通るかは `~/.pi/agent/extensions/permissions/` の許可リストで決まる |
| cline | `cline --json -t 150` で動作確認済み。`--auto-approve true` での起動は未検証 |
| opencode | 429 quota_exceeded（retry-after 約 2.4 日）。復旧後に追試 |
| codex | 0.80.0 は ChatGPT アカウントで使えるモデルが無く全モデル失敗。**`npm i -g @openai/codex@latest` で更新してから使う** |

## 配布とセットアップ

```bash
./sync-agents.sh          # 対話モード。初回は各スキルで (p) を選び repo → ~/.agents/skills にコピー
./sync-agents.sh -n       # 非対話。repo → ~/.agents/skills の自動コピー（初回配布にも使える）
./sync-agents.sh -n --to-repo  # 非対話。~/.agents/skills → repo の自動コピー
```

`sync-agents.sh` は `~/.agents/skills` のうち **この 4 スキルだけ**を扱う（残りは `npx skills` 管理。`.skill-lock.json` に触らない）。同期後に:

1. **Cline 用 symlink**: `~/.cline/skills/{name}` → `~/.agents/skills/{name}` を作る。既に何かあればスキップして警告（実体ディレクトリなら手で消してから再実行）。`sync-cline.sh` は symlink の先を辿らないので `cline/skills/` に重複は入らない
2. **pi の旧コピー**: `~/.pi/agent/skills/{startproject,team-implement,team-review,deploy,orchestrate}` に旧仕様（Decision Log 前提）のコピーが残っていると、pi はそちらを先に見つけて `~/.agents/skills` 側を無視する。スクリプトは警告だけ出す。中身が旧コピーであることを確認してから手で削除する:

   ```bash
   for s in startproject team-implement team-review deploy orchestrate; do
     diff -q ~/.pi/agent/skills/$s/SKILL.md ~/.agents/skills/$s/SKILL.md 2>&1 | head -1
   done
   rm -r ~/.pi/agent/skills/{startproject,team-implement,team-review,deploy,orchestrate}
   ```

   `orchestrate` も汎用版（`agents/skills/orchestrate/`）があり、`~/.agents/skills/orchestrate` に配布される。旧コピーは削除するだけでよい。

3. `~/.claude/skills` には置かない（Claude の `/startproject` などと名前が二重になる）

## Claude 版との対応

| 項目 | Claude 版（`claude/commands/*.md`） | 一般向け（`agents/skills/*/SKILL.md`） |
|---|---|---|
| TASK_FILE の書き手 | orchestrate（command は OUTPUT を返す） | 各フェーズ自身（`written: no` のときだけ orchestrate が代筆） |
| orchestrator | `claude/commands/orchestrate.md`（`/orchestrate`） | `agents/skills/orchestrate/SKILL.md`（pi / cline / codex でも回せる。フェーズは `~/.claude/scripts/phase-run.sh` 経由） |
| Linear | orchestrate が投稿・ステータス変更 | 連携ツールがあればコメントのみ。ステータスは変えない |
| `status:` | orchestrate が各 STEP で更新 | 書かない（フェーズ指定モードでは orchestrate が STEP 3P P4 で、実行したフェーズの値に更新する） |
| 回数・候補 | `### {m}回目` | 同じ `### {m}回目`（startproject は `### 案 {k}`）。実行者は見出し直下の `利用AI: {label}（{日時}）` 行 |
| 承認（Gate 1） | AskUserQuestion で待つ | 質問できれば待つ。候補モード・非対話では `gate1: 要確認` |
| 並列レビュアー（team-review） | Claude / OpenCode / Security / Simplify を並列 | 同一モデルで観点を順に（Quality/Logic → Security → Simplify）。セカンドオピニオンは任意 |
| 外部リサーチ・設計相談 | firecrawl + `opencode run` | 使えるツールがあれば。無ければ「不可: {理由}」 |
| deploy の Ad-hoc Git モード | あり | なし（Deploy Workflow のみ） |
| 分岐元への復帰 / TASK_FILE のコミット | deploy は作業ブランチに留まり、`/deploy --finalize`（STEP 6c / 3P P7）が TASK_FILE だけを `docs(task):` でコミット・push して分岐元へ戻る | 作業ブランチに留まり TASK_FILE は未コミット。コミット・push・復帰は呼び出し元（orchestrate 経由なら P7、手動なら自分） |
| PR / MR と issue の紐づけ | deploy がタイトルの `({LINEAR_ID})`・本文の `## 関連`（`Part of {LINEAR_ID}`・Meta の `issue:` の行）を書き、`紐づけ:` を返す。Linear への `links` 添付は orchestrate STEP 6b | 同じ規則で書き、RESULT に `linked:` を返す。`links` 添付はしない（フェーズ指定モードでは orchestrate が STEP 3P P6 で行う）。team-implement のブランチ名も同じ `feature/{linear_id を小文字}-{短い名前}`。`--issue` は orchestrate が Meta に書く（P1） |
| 共通ルールの参照 | `$HOME/.claude/rules/*.md` | 各 SKILL.md に内包 |

一般向け定義から Claude 版を生成することはしない（構造が違う）。Claude 版を変えたら、この表を見て対応する SKILL.md を手で追随させる。

## フェーズ指定モードの流れ（orchestrate STEP 3P）

```
/orchestrate "--task-file=.claude/docs/decisions/task-X-feature.md --phase=startproject --ai=pi:google/gemini-2.5-pro"
   → ## startproject に ### 案 2 を追記（直下に 利用AI: pi/google/gemini-2.5-pro（2026-09-28 10:00））
/orchestrate "--task-file=… --phase=startproject --adopt=案 2"
   → 案 2 の #### Brief/Design/Plan を ### Brief/Design/Plan に昇格（利用AI 行の直後に 採用: {日時} を追加。見出しは変えない）
/orchestrate "--task-file=… --phase=team-review --ai=codex"
   → ## team-review に ### 1回目 を追記（直下に 利用AI: codex（…）。status は reviewing になる）
/orchestrate "--task-file=… --phase=deploy --ai=pi"
   → ## deploy に #### PR / MR を追記（直下に 利用AI: pi）。CLI は作業ブランチに留まり、P7 の /deploy --finalize が TASK_FILE を docs(task): で同じブランチに push して分岐元へ戻る（P4 で status は in-review になり、その記録も docs(task): に含まれる）
```

TASK_FILE に書かれる形（`### 案 {k}` の例。`### {m}回目` も同じ）:

```markdown
### 案 2
利用AI: pi/google/gemini-2.5-pro（2026-09-28 10:00）
採用: 2026-09-28 11:30

#### Brief
…
```

どのフェーズも同じ権限で起動し（上の「権限」）、CLI が TASK_FILE に直接書く。実行日時は orchestrate がプロンプトで渡す（CLI 側で推定させない）。orchestrate は `## {phase}` 節内の期待見出し（`### 案 {k}` / `### {m}回目` の完全一致。見出しに AI 名が無いので、同じ見出しが並んでいても起動前後の出現数の差で判定する）が起動前より増えていなければ、最終メッセージの `### SECTION` から代筆する。増えていても直下に `利用AI:` 行が無ければ orchestrate が足す。節の確認が済んだら orchestrate が `## Meta` の `status:` を実行したフェーズの値（startproject / `--adopt` → `planning`、team-implement → `implementing`、team-review → `reviewing`、deploy → `in-review`）に更新する（CLI は書かない。失敗時は変えない）。startproject / team-review では起動前後で作業ツリー・HEAD・ref・stash を比べ、TASK_FILE 以外に変化があれば報告する。

## 検証

```bash
# 一般向け定義に Claude 固有語・フェーズ指定モードへの言及が無いこと・name がディレクトリ名と一致すること
# （orchestrate/SKILL.md は CLI 名を意図的に書くので対象外）
grep -nE 'context: fork|agent:|allowed-tools|model:|AskUserQuestion|Agent ツール|hook|TodoWrite|mcp__|\.claude/rules|AGENTS\.md|CLAUDE\.md|subagent|opencode run|firecrawl|Claude|OpenCode|orchestrate|フェーズ指定' \
  agents/skills/{startproject,team-implement,team-review,deploy}/SKILL.md
for d in agents/skills/*/; do n=$(basename "$d"); grep -q "^name: $n$" "$d/SKILL.md" || echo "name mismatch: $n"; done

# 見出しに実行者名・日時が残っていないこと（利用AI 行に移した）
grep -nE '### (案 \{k\}|\{m\}回目)（|実行者:' agents/skills/*/SKILL.md

# kanban が ### 案 / ### {m}回目 / 利用AI 行で列判定を変えないこと
cd kanban && uv run pytest
```
