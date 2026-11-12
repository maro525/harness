---
name: herdr-cleanup
description: Tidy the Herdr sessions, task locks and worktrees the harness recorded. Reports first (default) and closes only what is really gone, unless you ask for live sessions too — so "clean up my herdr sessions" is a safe, repeatable command instead of an improvised reap. Use it after a task, when the sidebar fills up, or when a lock from a crashed run is in the way.
metadata:
  kind: housekeeping
  writes: "nothing in the repo (closes Herdr tabs and drops stale records under ~/.cache/harness)"
---

# herdr-cleanup

harness が起動したセッションは `~/.cache/harness/` に記録を残す。TUI が落ちた・tab を手で閉じた・マシンを再起動した、といった場合に**記録だけが残る**ので、記録と Herdr の実体を突き合わせて片付けるのがこのスキル。

**既定はレポートのみ。** `--apply` を付けても、**一覧を見せて了承を得るまで何も閉じない**（ターミナルがあれば `[y/N]` を聞き、無ければ何もせず exit 2 で止まる → `--apply --yes` は了承後だけ）。生きているセッションは `--include-live` を明示しない限り触らない（`reap` のような「全部閉じる」はしない）。

## ラフな指示から実行まで

| ユーザーの言い方 | 実行 |
|---|---|
| 「herdr のセッション整理して」「溜まってない？」 | `~/.claude/scripts/herdr-cleanup.sh`（レポートだけ。結果を見せて、何を消すか伝える） |
| 「終わったやつは消して」 | まず `herdr-cleanup.sh` で一覧を出す → **一覧を見せて了承を得る** → `herdr-cleanup.sh --apply --yes` |
| 「動いてないのも消していい」 | 上と同じ手順で `--include-live` を足す（了承を得てから `--apply --yes --include-live`） |
| 「worktree も見て」 | 上に `--worktrees` を足す（**一覧のみ**。削除はしない） |
| 「◯◯ だけ消して」 | `herdr-cleanup.sh --name ◯◯` で一覧 → 了承 → `--apply --yes --name ◯◯` |
| 「ロックが残ってない？」 | `herdr-cleanup.sh --only locks` |

**閉じる前に必ず人が確認する。** `--apply` だけでは何も閉じない（TTY 無しでは exit 2）。`--yes` は「一覧を見せて了承をもらった後」にだけ付ける。

## 何を見ているか

| 区分 | 記録の場所 | 「片付ける」の意味 |
|---|---|---|
| `consult` | `~/.cache/harness/herdr-consult/*.json` | agent がもう居ない／idle な相談セッションの tab を閉じて記録を消す |
| `agents` | `~/.cache/harness/herdr-agents/*.json` | 同上（`herdr-agent.sh close` 経由なので worktree も片付く） |
| `locks` | `~/.local/share/harness/locks/*.lock` | TTL を過ぎた実行ロックを解放する |
| `--worktrees` | Herdr の worktree 一覧 | **一覧表示のみ**（削除コマンドを案内する） |

## 実行のしかた

```bash
~/.claude/scripts/herdr-cleanup.sh                  # レポート（安全）
~/.claude/scripts/herdr-cleanup.sh --apply          # 一覧＋確認（TTY が無ければ何もせず停止）
~/.claude/scripts/herdr-cleanup.sh --apply --yes    # 了承後の実行
~/.claude/scripts/herdr-cleanup.sh --apply --yes --include-live
~/.claude/scripts/herdr-cleanup.sh --only consult --only locks
~/.claude/scripts/herdr-cleanup.sh --name consult-review --apply --yes
```

- 出力は `live`（残す） / `close`（消す予定） / `closed` / `released` の 4 種
- `--only consult|agents|locks` は複数指定できる
- 記録はあるが Herdr に実体が無いものは、`close`（Herdr が知っていれば）→ だめなら記録だけ削除

## やらないこと

- **了承なしに `--apply --yes` を付けない**（`--yes` は一覧を見せてユーザーが OK した後だけ）
- **`herdr-agent.sh reap` を無条件に使わない**（記録済みの全部を閉じる。他の作業を巻き込む）
- 生きているセッションを勝手に閉じない（`--include-live` はユーザーが明示したときだけ）
- worktree を勝手に消さない（`--worktrees` は一覧のみ）
- 記録の無いセッション（ユーザーが手で開いた pane）は対象外

## 終わったあと

- まだ残っているものは `--status`（consult）/ `herdr-agent.sh list` で確認できる
- タスク単位で閉じたいだけなら、このスキルではなく `claude-consult.sh --close` / `herdr-agent.sh close NAME`
