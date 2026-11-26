---
name: external-review
description: Get an independent review from a different model family through Herdr, without consult.sh. Use it for a team-review second opinion, a design objection, or any "what does a different model think" check. Names the model, records REVIEWER and AI_MODEL, and leaves the repository untouched.
metadata:
  kind: review
  writes: "none in the repository (prompt and answer live in $TMPDIR)"
---

# external-review（別ファミリの独立レビュー）

実装者とは別のモデルに、diff と設計を読ませて独立した判定をもらう。Herdr のセッションを 1 つ立てるだけで、consult.sh は使わない。相談（設計・方針の壁打ち）はこのスキルの仕事ではない。それは manager に `ask` で聞く。

## 前提

- `~/.claude/scripts/herdr-agent.sh`（`./sync-claude.sh` で配布）、`herdr`、`jq`
- レビュー対象のリポジトリと、base になる ref（`origin/main` など）
- 実装者の `利用AI:`（`{cli}/{model}` の形）。TASK_FILE の `## team-implement` から読む

## いつ使うか

- team-review が PASS を出すのに必要な「実装者と別ファミリの独立レビュー」
- 設計や方針に反対意見が欲しいとき
- 実装者の `利用AI:` にモデル部分が無い（`claude/best` など）ときの唯一の独立判定

## 手順

1. 実装者と同じファミリを選ばない。`claude/*` の実装には codex か pi、`codex/*` の実装には claude か pi。**CLI 名の違いだけでは独立とみなさない**（`claude/opus` と `claude/sonnet` は別ファミリではない）。モデル ID も自分で名指しする
2. 名前を決める。`<kind>-review-<id>`（例 `codex-review-nsketch-1983`）。Herdr の 32 文字制限に収める（`docs/naming.md`）
3. セッションを立てる。レビューは読み取り専用で立てる

```bash
# codex
~/.claude/scripts/herdr-agent.sh ensure codex-review-1983 --kind codex \
  --repo ~/src/nanco-next -- -s read-only -a never -m gpt-6-sol
# claude
~/.claude/scripts/herdr-agent.sh ensure claude-review-1983 --kind claude \
  --repo ~/src/nanco-next -- --permission-mode auto --model opus
# pi（gemini 系に読みたいとき）
~/.claude/scripts/herdr-agent.sh ensure pi-review-1983 --kind pi \
  --repo ~/src/nanco-next -- -m ollama-cloud/kimi-k3.1-pro
```

`ensure` の stderr の `MODEL=` がこのセッションのモデル名になる。`AI_MODEL=<kind>/<model>` として控える。

4. 依頼をファイルに書く。次を必ず入れる。

- 対象（`git -C <repo> diff --stat <base>...HEAD` と、読むべきファイルの絶対パス）
- 設計の要約（TASK_FILE の `## startproject` の Design を貼る）
- 判定してほしい観点（正しさ、抜けている分岐、既存の前提を壊していないか、テストの十分さ）
- 出力の形（先頭に `VERDICT: PASS | FAIL | BLOCKED`、次に理由、そのあと指摘を箇条書き）
- **リポジトリを編集しないこと**（読むだけ）

5. 渡して待つ。回答はファイルに落とさせる。

```bash
~/.claude/scripts/herdr-agent.sh ask codex-review-1983 /tmp/review-1983.md \
  --answer-file /tmp/review-1983.answer.md --timeout 20m
```

`ask` はセッションが落ち着くまで待ち、stdout に回答を返す（`--answer-file` があればその中身）。タイムアウトは `--timeout` で延ばす。

6. リポジトリが汚れていないことを確かめる。レビューの前後で `git -C <repo> status --porcelain` を比べる。変わっていたらレビューは失敗として扱い、その変更を捨てる。読み取り専用で立てていれば起きないが、claude は `--permission-mode auto` なので必ず確認する。

7. 記録する。team-review の結果に次の 3 行を残す。

```
REVIEWER: {kind}/{model}
INDEPENDENT: yes（実装者 {利用AI} と別ファミリ）
利用AI: {kind}/{model}
```

8. 片付ける。使い終わったら `~/.claude/scripts/herdr-agent.sh close codex-review-1983`。同じ論点で続けて聞くなら残す（文脈が続く）。

## 失敗したとき

- `ensure` が失敗した（未認証、CLI が無い）→ `セカンドオピニオン不可: {理由}`
- `ask` がタイムアウト、または空の回答 → `セカンドオピニオン不可: {理由}`
- 失敗したときに**別のモデルへ切り替えない**。切り替えると「独立レビューが取れた」と嘘になる。team-review は BLOCKED にする

## 判定の読み方

- `VERDICT: FAIL` は指摘を 1 つずつ実装者に返す。もっともらしくても、根拠の無い指摘は採らない
- レビュアーの意見は事実ではない。主張（「テストが通る」など）は、報告にあるコマンドと結果で確かめる
- レビュアー自身に追加のエージェントを立てさせない。依頼文に「他のエージェントを起動しない」と書く

## 使わないもの

- `consult.sh` / `claude-consult.sh` / `codex-consult.sh`（廃止済み。このスキルが置き換え）
- `delegate`（子にレビューを頼むと、その子が報告を返す形になり、独立した判定の記録が残らない。同期で答えを読むのは `ask` の仕事）
- 実装者と同じファミリのモデル
