---
name: codex-consult
description: Ask a Codex CLI session for a design consultation, a review, or an implementation hand-off through a persistent session in its own Herdr tab (created on demand, reused afterwards). Same flow as claude-consult — one shared implementation (`consult.sh --to codex`) — but read-only sandboxes and no answer file, so answers come back between terminal markers. Use it to get a second opinion from a different model than Claude. Outside Herdr it stops and asks for a Herdr pane instead of silently switching behaviour; one-shot `codex exec` is available only with an explicit `-b print`.
metadata:
  kind: consult
  writes: "none in the repo (questions and answers live in a temp dir)"
---

# codex-consult

Cursor / pi / Cline / OpenCode などから、**別の Codex セッション**に設計相談・レビュー・実装の引き継ぎをさせるスキル。

実装は [claude-consult](../claude-consult/SKILL.md) と同じ `consult.sh` で、`--to codex` が固定された薄いラッパー `codex-consult.sh` を呼ぶ。Herdr の扱い（tab の作り方・再利用・再送信・`--status` / `--close`）は完全に共通なので、**詳細は claude-consult の SKILL.md を読む**。ここには codex 固有の差分だけを書く。

## 使う / 使わない

境界は claude-consult と同じ: **待って答えを受け取る（同期）＝ consult、待たずに配る（非同期）＝ delegate**。

- **使う**: 設計相談・レビュー・実装の引き継ぎ（claude とは別モデルの意見がほしいとき）
- **使わない**:
  - 並行で走らせて報告で判断したい → [herdr-boss](../herdr-boss/SKILL.md) の `delegate`
  - 4 フェーズの実行 → `phase-run.sh`
  - 外部リサーチ → `ai-fallback.sh`（codex も候補に入っている）
- **`herdr-agent.sh ensure` / `delegate` を直接使わない**（`hx-*` の tab/pane 管理はこのスクリプトが持つ）

## claude-consult との違い

| | claude-consult | codex-consult |
|---|---|---|
| バイナリ | `claude` | `codex` |
| `consult` / `review` の権限 | 読み取り ＋ 回答ファイルの書き込み | `-s read-only`（回答ファイルを書けない） |
| `implement` の権限 | `acceptEdits` | `-s workspace-write -a never` |
| 回答の受け取り | 回答ファイル優先、マーカーはフォールバック | **常に `<<<ANSWER>>>` マーカーから抽出** |
| 既定モデル | `opus` | `~/.codex/config.toml` の `model`（`-m` で上書き） |
| agent 名 | `hc-<role>` | `hx-<role>`（claude と同居できる） |
| `-b print` | `claude -p`（`-r` で再開可） | `codex exec -s read-only`（`-r` 不可） |

読み取り専用なので、**コードフェンスの多い回答はターミナル描画の影響を受けうる**。整形が崩れたら `--show consult` で pane をそのまま読む。

## 前提

- `~/.claude/scripts/codex-consult.sh`（`./sync-claude.sh` で配布）と `~/.claude/scripts/consult.sh`、`codex` と `jq`
- Herdr バックエンドは `herdr` が PATH にあり、**Herdr サーバが動いている**こと。サーバが無ければエラーで止まる（`-b print` で単発実行を明示できる）
- **codex TUI の初回起動ダイアログは人が答える**（更新通知 /「このフォルダを信頼するか」）。信頼はセキュリティ判断なので自動で押さない。`error: could not start codex ... (startup dialog?)` が出たら pane で 1 回答え、同じコマンドを再実行する（tab は `--close --role consult` で閉じられる）。追加の codex フラグは `CONSULT_CONSULT_ARGS` などで渡す
- **相談したいリポジトリのルートで実行する。** tab は実行時の cwd で起動する

## 手順

### 1. 相談を書く

プロンプトは自己完結で書く（codex はこの会話を知らない）。目的と背景 / 現状と制約（ファイルパスを具体的に）/ 聞きたいこと（1 回 1 テーマ）/ 回答の形式。秘密情報は書かない。

### 2. 実行する

```bash
~/.claude/scripts/codex-consult.sh {prompt_file}                      # consult（read-only）
~/.claude/scripts/codex-consult.sh --role review {prompt_file}         # review 用 tab
~/.claude/scripts/codex-consult.sh --role implement {prompt_file}      # 実装用 tab（workspace-write）
~/.claude/scripts/codex-consult.sh --roles review,consult {prompt_file} # 並列に別ロールへ
~/.claude/scripts/codex-consult.sh -t 30m -m gpt-5-codex {prompt_file}  # タイムアウト / モデル
~/.claude/scripts/codex-consult.sh -b print {prompt_file}              # Herdr 無しの単発 codex exec
```

- stdout が回答本文、`{base}.answer.md` と `.json`（生ログ）が残る。stderr の `AI_MODEL=codex/{model}` / `AGENT=hx-{role}` / `PANE={pane id}` を控える
- 長くかかる（数分〜）。既定タイムアウト 20 分（`-t` / `CONSULT_TIMEOUT`）

### 3. 続ける / 閉じる

```bash
~/.claude/scripts/codex-consult.sh --append {前の回答} --role review {review_file}
~/.claude/scripts/codex-consult.sh --close --role consult      # 採用 / 却下したら即
~/.claude/scripts/codex-consult.sh --status                    # hx-* も含めて一覧
~/.claude/scripts/codex-consult.sh --show consult              # pane の末尾
```

セッションは閉じるまで残る（`docs/session-lifecycle.md` のルールは claude と同じ。1 タスク = 1 セッション）。`--new` で作り直す。

### 4. claude と並べて独立意見を取る

同じプロンプトを両方に投げると、モデルの違う 2 案を比較できる。

```bash
~/.claude/scripts/claude-consult.sh {prompt_file}
~/.claude/scripts/codex-consult.sh  {prompt_file}
```

- 回答は意見であって決定ではない。**根拠は自分で検証してから**採用する
- ユーザーに伝えるときは `利用AI: codex/{model}` を添える（claude 側は `利用AI: claude/{model}`）

## やらないこと

- この呼び出しでリポジトリのファイルは変更されない（`implement` ロールは例外で、tab の中の codex が編集する）
- `~/.claude/scripts/consult.sh` を直接 `--to` 無しで叩かない（既定は claude になる）
- 自分が作っていない Herdr の tab / pane を閉じない
