---
name: claude-consult
description: Ask a Claude session for a design consultation, a review, or an implementation hand-off through a persistent Claude Code session in its own Herdr tab (created on demand, reused afterwards). Outside Herdr it stops and asks for a Herdr pane instead of silently switching behaviour; one-shot `claude -p` is available only with an explicit `-b print`. Supports role-split sessions (consult / review / implement) and parallel fan-out, so several roles can be orchestrated side by side.
metadata:
  kind: consult
  writes: "none in the repo (questions and answers live in a temp dir)"
---

# claude-consult

Cursor / pi / Cline / OpenCode などから、**別の Claude セッション**に設計相談・レビュー・実装の引き継ぎをさせるスキル。

Herdr の中（`HERDR_ENV=1`）では、**専用の tab に常駐する Claude Code セッションに `herdr agent prompt` で質問を打ち込む**。tab は無ければ呼び出し元の workspace に作られ、次回以降は使い回されるので、追加質問は同じ会話の続きになる（呼び出し元の pane は分割しない）。

**Herdr の外では自動フォールバックしない。** `HERDR_ENV` が無いとエラーで止まる（「Herdr の pane で起動するか `-b print` を付けろ」と案内が出る）。単発の `claude -p` を使いたいときだけ `-b print` を明示する — ツール制限・会話の継続・tab の有無が変わるため、黙って切り替わらないようにしている。

配布先は `~/.agents/skills/claude-consult/`。pi・opencode・codex・Cursor（2.4+）はこの場所を直接読むので追加設定はいらない。Cline だけは `~/.cline/skills/` への symlink が要る（`./sync-agents.sh` が作る）。Cursor の headless（`cursor-agent -p`）はスキルを読まないという報告があるので、その場合はプロンプトで `Read ~/.agents/skills/claude-consult/SKILL.md and follow it` と絶対パスを渡す。

Claude Code 自身からは使わない（自分自身を呼ぶ形になる）。

## 前提

- `~/.claude/scripts/claude-consult.sh`（`./sync-claude.sh` で配布）、`claude` と `jq`
- Herdr バックエンドは追加で `HERDR_ENV=1` と `herdr` が PATH に必要。無い場合はエラーで止まる（`-b print` で単発実行を明示できる）
- **相談したいリポジトリのルートで実行する。** tab は実行時の cwd で起動する

## ロール（tab の分け方）

| role | できること | 既定モデル | 既定の agent 名 |
|---|---|---|---|
| `consult`（既定） | Read / Grep / Glob ＋ 回答ファイルの書き込み | opus | `hc-consult` |
| `review` | 同上（レビュー用の tab を分けたいとき） | opus | `hc-review` |
| `implement` | フルツール（編集は `acceptEdits` で事前承認） | opus | `hc-implement` |

- ロールごとに tab と会話が独立する。実装は `implement`、確認は `review` に投げる、という分担ができる
- `--name` で agent 名を変えられる（同じロールを複数持ちたいとき）
- モデルは `-m` / `CLAUDE_CONSULT_MODEL` / `CLAUDE_CONSULT_IMPLEMENT_MODEL`、追加フラグは `CLAUDE_CONSULT_<ROLE>_ARGS`（例 `--effort high`）
- フラグやモデルを変えたときは `--new` で tab を作り直す（起動済みセッションには反映されない）

## 手順

### 1. 相談を書く

作業ディレクトリの外（`/tmp` など）か、コミットされない場所にプロンプトファイルを作る。**Claude はこの会話を知らない**ので、次を自己完結で書く。

- 目的と背景（何を作る・直すのか）
- 現状と制約（関係するファイルパスを具体的に。Claude が Read で読める）
- 聞きたいこと（案の比較、落とし穴、設計の妥当性など。1 回に 1 テーマ）
- 回答の形式の希望（結論を先に、理由、代替案、など）

秘密情報（API キー・個人情報）は書かない。

### 2. 実行する

```bash
~/.claude/scripts/claude-consult.sh {prompt_file}                    # consult（読み取り専用）
~/.claude/scripts/claude-consult.sh --role review {prompt_file}       # review 用 tab
~/.claude/scripts/claude-consult.sh --role implement {prompt_file}    # 実装用 tab（書き込み可）
~/.claude/scripts/claude-consult.sh --roles review,consult {prompt_file}  # 並列に別ロールへ
~/.claude/scripts/claude-consult.sh -t 30m -m sonnet {prompt_file}    # タイムアウト / モデル
```

- 長くかかる（数分〜）ので、使えるならバックグラウンドで実行して完了を待つ。タイムアウト既定 20 分（`-t` / `CLAUDE_CONSULT_TIMEOUT`）
- stdout が回答本文。`{prompt_file の拡張子を除いた名前}.answer.md` に同じ内容、`.json` にターミナルの生テキストと送信結果が残る（`--roles` は `.{role}.answer.md` / `.{role}.json`）
- stderr の `AI_MODEL=claude/{model}` / `AGENT={agent名}` / `PANE={pane id}` を控える（tab 名は agent 名になる）
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

1. ロールの agent 名（`hc-*`）で `herdr agent get` を引き、いなければ**呼び出し元の workspace に新しい tab を作り**（`herdr tab create --workspace $HERDR_WORKSPACE_ID --cwd $PWD --no-focus`、tab 名は agent 名にする）、その root pane で `herdr agent start --kind claude` する
2. 質問は**ファイル**に書き、ターミナルには 1 行のポインタ（「このファイルの指示に従え」）だけを打つ。長い貼り付けは TUI の再描画中に落ちることがあるため
3. セッションは回答を `$TMPDIR/harness-consult/{agent}/{base}.answer.md` に書き、ターミナルには `<<<ANSWER>>>` で挟んだ 1 行を返す。スクリプトはファイルを優先し、無ければマーカーから本文を拾う
4. 新しい tab の TUI は最初の Enter を落とすことがあるので、`idle` のままマーカーが現れない場合は入力をクリアして再送信する（最大 3 回）
5. 状態は `~/.cache/harness/herdr-consult/{agent}.json` に残す（pane と tab）。cwd が変わったセッションは作り直す（`--reuse-cwd` で回避）

## やらないこと

- この呼び出しでリポジトリのファイルは変更されない（`implement` ロールは例外で、tab の中の Claude が編集する）
- プロンプトファイルを `claude -p` に直接渡さない（読み取り専用の制限が外れる）。必ずスクリプトを経由する
- 自分が作っていない Herdr の tab / pane を閉じない（`--close` は記録済みの tab だけを閉じる）
