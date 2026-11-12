---
name: claude-consult
description: Ask a Claude session for a design consultation, a review, or an implementation hand-off through a persistent Claude Code session in its own Herdr tab (created on demand, reused afterwards). Outside Herdr it stops and asks for a Herdr pane instead of silently switching behaviour; one-shot `claude -p` is available only with an explicit `-b print`. Supports role-split sessions (consult / review / implement) and parallel fan-out, so several roles can be orchestrated side by side.
metadata:
  kind: consult
  writes: "none in the repo (questions and answers live in a temp dir)"
---

# claude-consult

Cursor / pi / Cline / OpenCode などから、**別の Claude セッション**に設計相談・レビュー・実装の引き継ぎをさせるスキル。

実装は `~/.claude/scripts/consult.sh`（`claude-consult.sh` は `--to claude` を固定した薄いラッパー）。**Codex を相談先にするときは [codex-consult](../codex-consult/SKILL.md)** を使う — ロール・Herdr の扱い・`--status` / `--close` は共通で、違いは権限（codex は read-only）と回答の受け取り方（codex はマーカーのみ）だけ。

Herdr が動いていれば、**専用の tab に常駐する Claude Code セッションに `herdr agent prompt` で質問を打ち込む**。tab は無ければ作られ（呼び出し元の pane の中ならその workspace、Herdr の外からなら新しい workspace）、次回以降は使い回されるので、追加質問は同じ会話の続きになる（呼び出し元の pane は分割しない）。

**`claude -p` へは自動フォールバックしない。** Herdr サーバに繋がらないときはエラーで止まる（「herdr を起動するか `-b print` を付けろ」と案内が出る）。単発の `claude -p` を使いたいときだけ `-b print` を明示する — ツール制限・会話の継続・tab の有無が変わるため、黙って切り替わらないようにしている。

**`HERDR_ENV` は不要。** pane の中でも素のターミナルでも同じように動く（スクリプトは pane id しか使わない）。pane の外から使うと `HERDR_WORKSPACE_ID` が無いので、tab を付ける workspace が無ければ新しく作る。

配布先は `~/.agents/skills/claude-consult/`。pi・opencode・codex・Cursor（2.4+）はこの場所を直接読むので追加設定はいらない。Cline だけは `~/.cline/skills/` への symlink が要る（`./sync-agents.sh` が作る）。Cursor の headless（`cursor-agent -p`）はスキルを読まないという報告があるので、その場合はプロンプトで `Read ~/.agents/skills/claude-consult/SKILL.md and follow it` と絶対パスを渡す。

Claude Code 自身からは使わない（自分自身を呼ぶ形になる）。

## 使う / 使わない

- **使う**: 設計相談・レビュー・実装の引き継ぎ。**同期**——回答が返るまで待ち、stdout と `<base>.answer.md` で受け取って自分で検証できる
- **使わない**:
  - 並行で走らせて報告で判断したい → [herdr-boss](../herdr-boss/SKILL.md) の `delegate`（非同期。子の画面は見えない）
  - 4 フェーズの実行 → `phase-run.sh`（orchestrate 経由）
  - 外部リサーチ → `ai-fallback.sh`
- **`herdr-agent.sh ensure` / `delegate` を直接使わない**（consult の tab/pane 管理はこのスクリプトが持つ。混ざると `consult*` と任意名のセッションが二重に残る）

## 前提

- `~/.claude/scripts/claude-consult.sh`（`./sync-claude.sh` で配布）、`claude` と `jq`
- Herdr バックエンドは `herdr` が PATH にあり、**Herdr サーバが動いている**ことが条件（`HERDR_ENV` は不要）。サーバが無ければエラーで止まる（`-b print` で単発実行を明示できる）
- **相談したいリポジトリのルートで実行する。** tab は実行時の cwd で起動する

## ロール（tab の分け方）

| role | できること | 既定モデル | 既定の agent 名 |
|---|---|---|---|
| `consult`（既定） | Read / Grep / Glob ＋ 回答ファイルの書き込み | opus | `consult` |
| `review` | 同上（レビュー用の tab を分けたいとき） | opus | `consult-review` |
| `implement` | フルツール（編集可） | opus | `consult-implement` |

- どのロールも `--permission-mode auto` で起動する。相談用の tab は誰も見ていないので、承認ダイアログで止まらないようにしている（変えたいときは `CONSULT_PERMISSION_MODE`。例 `plan` / `acceptEdits` / `bypassPermissions`）。`consult` / `review` の**組み込み**ツールは `Read,Grep,Glob` と回答ファイルへの `Write` だけに絞ってある
- セッション名は `consult` / `consult-<role>`（codex は `consult-codex` / `consult-codex-<role>`。`~/src/harness/docs/naming.md` の規則。`--name` で上書きするときも同じ形にする）
- **MCP は使える**（`~/.claude/settings.json` に設定したサーバー。Linear / firecrawl / GitHub など）。「Linear の issue を見て判断して」のような相談ができる。ただし**Linear への書き込み（コメント・ステータス・description）は orchestrator の仕事**で、consult は書かない（フェーズ契約）

- ロールごとに tab と会話が独立する。実装は `implement`、確認は `review` に投げる、という分担ができる
- `--name` で agent 名を変えられる（同じロールを複数持ちたいとき）
- モデルは `-m` / `CONSULT_MODEL` / `CONSULT_IMPLEMENT_MODEL`、追加フラグは `CONSULT_<ROLE>_ARGS`（例 `--effort high`）。旧 `CLAUDE_CONSULT_*` も読む
- フラグやモデルを変えたときは `--new` で tab を作り直す（起動済みセッションには反映されない）

## ラフな指示から実行まで（呼び出し側のエージェント向け）

**ユーザーにフラグやファイル名を打たせない。聞き返さない。** 次の対応表で自分で決めて、そのまま実行する。

| ユーザーの言い方 | role | 実行 |
|---|---|---|
| 「相談して」「聞いてみて」「意見ほしい」 | `consult` | `claude-consult.sh --text "{そのままの言葉}"` |
| 「レビューして」「見てほしい」「まずいとこある？」 | `review` | `claude-consult.sh --role review --text "{そのまま＋対象の diff}"` |
| 「実装して」「直して」「やっておいて」 | `implement` | `claude-consult.sh --role implement --text "{そのまま}"` |
| 「codex にも聞いて」 | `consult` | `codex-consult.sh --text "{同じ質問}"` |
| 「consult と review 両方の立場で」 | `--roles consult,review` | 1 コマンドで並列。出力はロールごとの節 |
| 「両方に聞いて」「比べて」（モデル違い） | `consult` | claude と codex を**同時に**起動 → 両方待って差分を表に |
| 「並行で別々の仕事を進めて」「裏で走らせて」 | herdr-boss | `delegate`（非同期・子の画面は見えない。報告で判断） |
| 「終わって」「もういい」 | — | `--close --role {使ったロール}` / `close` / `reap` |

並列の 3 種類は別物（混ぜない）:

| 種類 | 何が並ぶ | 待ち方 |
|---|---|---|
| `--roles consult,review` | 同じリポジトリの 2 ロール | 1 コマンド内で待つ |
| claude + codex | 別モデル 2 本 | 2 コマンドを同時起動 → 両方待つ |
| `delegate` × 子の数 | 別 tab / worktree | 待たない（inbox の報告） |

- **既定値**（何も指定しなくてよい）: role=`consult`、`--context` はインラインのとき自動で付く、タイムアウト 20 分、バックエンドは Herdr
- 足りない前提は**自分で調べて補う**（リポジトリを見る、`--context` で付く repo/branch/直近コミットを使う）
- 呼び出しは**フォアグラウンド**。回答が返るまで待ち、返ってきた本文をそのまま読んで要約する
- `--close` は**採用/却下を決めた後**に自分で実行する（ユーザーに言われなくても）

## 手順

### 1. 相談を書く

**思いつきの 1〜2 行でよい。ファイルも、立派な依頼文も要らない。** 不足する前提（リポジトリ・ブランチ・直近のコミット・変更ファイル数）は `--context` が自動で付ける。呼び出し側のエージェントは、**ユーザーに書き直させずに**、そのままの言葉で投げてよい。

```bash
# 最短（引数で渡す。ファイルを作らない）
~/.claude/scripts/claude-consult.sh --context --text "CI をもっとはやくしたい。方法を考えたい"

# 複数行をそのまま（ヒアドキュメント）
~/.claude/scripts/claude-consult.sh --context - <<'EOF'
CI をもっとはやくしたいんだよね。方法を考えたい
EOF

# 長い相談・`--append` で使い回す相談だけファイルにする
~/.claude/scripts/claude-consult.sh /tmp/q.md
```

- `--text` / 標準入力のときの出力は `$TMPDIR/harness-consult/out/` なので、リポジトリの cwd は汚れない
- `--context` を付けると「repo / branch / cwd / changed files / 直近 5 コミット」が質問の前に付く。1 行の相談でも見当違いの回答になりにくい
- **Claude はこの会話を知らない。** だから最低限、次のどれかは入れる（足りなければ自分で調べる前提でよい）:
  - 何をしたいか（目的・つらさ）
  - 対象（ファイルパスやブランチ。`--context` が入れる分を除く）
  - 回答の形（結論を先に / 候補を 3 つ / リスクも / 短く）
- 秘密情報（API キー・個人情報）は書かない

### 2. 実行する

```bash
~/.claude/scripts/claude-consult.sh {prompt_file}                    # consult（読み取り専用）
~/.claude/scripts/claude-consult.sh --context --text "{一言}"       # 一番短い形
~/.claude/scripts/claude-consult.sh - < {prompt_file}               # 標準入力から
~/.claude/scripts/claude-consult.sh --role review {prompt_file}       # review 用 tab
~/.claude/scripts/claude-consult.sh --role implement {prompt_file}    # 実装用 tab（書き込み可）
~/.claude/scripts/claude-consult.sh --roles review,consult {prompt_file}  # 並列に別ロールへ
~/.claude/scripts/claude-consult.sh -t 30m -m sonnet {prompt_file}    # タイムアウト / モデル
```

- **このコマンドは回答が返るまで戻らない（同期）**。バックグラウンドに回さず、フォアグラウンドで待って stdout をそのまま読めばよい（追加の「待つ」手順は無い）。タイムアウト既定 20 分（`-t` / `CONSULT_TIMEOUT`）
- どうしてもバックグラウンドにするなら、**完了通知の後に stderr の `ANSWER_FILE={path}` を読む**（回答本文はそこにも書かれている）
- stdout が回答本文。`{prompt_file の拡張子を除いた名前}.answer.md` に同じ内容、`.json` にターミナルの生テキストと送信結果が残る（`--roles` は `.{role}.answer.md` / `.{role}.json`。標準入力のときは `$TMPDIR/harness-consult/out/{target}-consult-{timestamp}.answer.md`）
- stderr の `ANSWER_FILE=…` / `AI_MODEL=claude/{model}` / `AGENT={agent名}` / `PANE={pane id}` を控える（tab 名は agent 名になる）
- 回答は tab に常駐するセッションが `$TMPDIR/harness-consult/{agent}/` に書いた Markdown をそのまま使う（TUI の描画を経由しないのでコードフェンスが保たれる）
- `--debug` でターミナルの生テキストを `{base}.pane.txt` に保存

### 3. 続ける

同じロールに投げ直せば、その tab の会話の続きになる（`--resume` は不要）。

```bash
~/.claude/scripts/claude-consult.sh --role implement {followup_file}
~/.claude/scripts/claude-consult.sh --append {前の回答} --role review {review_file}   # 前段の回答を添える
```

実装 → レビューのように順番に回すときは、`implement` の回答を `--append` で `review` に渡す。

```bash
~/.claude/scripts/claude-consult.sh --role implement /tmp/impl-req.md
~/.claude/scripts/claude-consult.sh --role review --append /tmp/impl-req.answer.md /tmp/review-req.md
```

- `--roles` は**独立した意見**を並列に取るためのもの（同じ repo を同時に触らせたくないときは順番に投げる）
- `--new` でその tab を作り直す（モデルやフラグを変えたとき、会話をリセットしたいとき）
- `--close` で回答後に tab を閉じる。引数なしの `--close`（`--role` / `--roles` と組み合わせ可）は、記録済みセッションを閉じるだけで相談はしない
- `--status` で記録済みセッションの一覧、`--show {role}` でターミナルの末尾を確認

### 4. 回答を扱う

- 回答は意見であって決定ではない。**根拠（ファイルパス・コードの引用）は自分で検証してから**採用する
- ユーザーに伝えるとき、または成果物に残すときは `利用AI: claude/{model}` を添える
- 失敗したとき（exit 1）は stderr を確認する。典型的なのは「セッションが承認ダイアログで止まっている（`blocked`）」「セッションが質問を実行しなかった」。ダイアログは**ユーザーに確認してから**答える。リトライは 1 回まで

### 5. セッションを閉じる（必須）

セッションは**閉じるまで残る**（自動失効なし）。1 タスク = 1 セッション。

- `consult` は**回答を採用 / 却下したら即** `--close`（既定では残るので明示的に閉じる）
- `review` は PASS して deploy に入る直前、または FAIL 対応が終わったときに閉じる
- `implement` は PR 作成（deploy 完了）後に閉じる
- タスク・ブランチが変わるときは `--new` で作り直す
- タスク開始時に前タスクのものが残っていたら `--status` で確認して `--close`

```bash
~/.claude/scripts/claude-consult.sh --close --role consult
~/.claude/scripts/claude-consult.sh --close --roles implement,review
~/.claude/scripts/claude-consult.sh --status          # 残っているものを確認
```

ルールの全体は harness の `docs/session-lifecycle.md`（pi / codex 側の `herdr-agent.sh reap` も同じ文書）。

## Herdr バックエンドの仕組み（保守する人向け）

1. ロールの agent 名（`consult*`）で `herdr agent get` を引き、いなければ**呼び出し元の workspace に新しい tab を作り**（`herdr tab create --workspace $HERDR_WORKSPACE_ID --cwd $PWD --no-focus`、tab 名は agent 名にする）、その root pane で `herdr agent start --kind claude` する
2. 質問は**ファイル**に書き、ターミナルには 1 行のポインタ（「このファイルの指示に従え」）だけを打つ。長い貼り付けは TUI の再描画中に落ちることがあるため
3. セッションは回答を `$TMPDIR/harness-consult/{agent}/{base}.answer.md` に書き、ターミナルには `<<<ANSWER>>>` で挟んだ 1 行を返す。スクリプトはファイルを優先し、無ければマーカーから本文を拾う
4. 新しい tab の TUI は最初の Enter を落とすことがあるので、`idle` のままマーカーが現れない場合は入力をクリアして再送信する（最大 3 回）
5. 状態は `~/.cache/harness/herdr-consult/{agent}.json` に残す（pane と tab）。cwd が変わったセッションは作り直す（`--reuse-cwd` で回避）

## やらないこと

- この呼び出しでリポジトリのファイルは変更されない（`implement` ロールは例外で、tab の中の Claude が編集する）
- プロンプトファイルを `claude -p` に直接渡さない（読み取り専用の制限が外れる）。必ずスクリプトを経由する
- 自分が作っていない Herdr の tab / pane を閉じない（`--close` は記録済みの tab だけを閉じる）
