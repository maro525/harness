---
name: herdr-cleanup
description: Tidy the Herdr sessions, task locks and worktrees the harness recorded. Reports first (default) and closes only what is really gone, unless you ask for live sessions too — so "clean up my herdr sessions" is a safe, repeatable command instead of an improvised reap. Use it after a task, when the sidebar fills up, or when a lock from a crashed run is in the way.
metadata:
  kind: housekeeping
  writes: "nothing in the repo (closes Herdr tabs and drops stale records under ~/.cache/harness)"
---

# herdr-cleanup

harness が起動したセッションは `~/.cache/harness/` に記録を残す。TUI が落ちた・tab を手で閉じた・マシンを再起動した、といった場合に**記録だけが残る**ので、記録と Herdr の実体を突き合わせて片付けるのがこのスキル。

**既定はレポートのみ。** `--apply` を付けたときだけ閉じる／解放する。生きているセッションは `--include-live` を明示しない限り触らない（`reap` のような「全部閉じる」はしない）。

## ラフな指示から実行まで

| ユーザーの言い方 | 実行 |
|---|---|
| 「herdr のセッション整理して」「溜まってない？」 | `~/.claude/scripts/herdr-cleanup.sh`（レポートだけ。結果を見せて、何を消すか伝える） |
| 「終わったやつは消して」「片付けて」 | `~/.claude/scripts/herdr-cleanup.sh --apply` |
| 「動いてないのも消していい」 | `herdr-cleanup.sh --apply --include-live` |
| 「worktree も見て」 | 上に `--worktrees` を足す（**一覧のみ**。削除はしない） |
| 「◯◯ だけ消して」 | `herdr-cleanup.sh --apply --name ◯◯` |
| 「ロックが残ってない？」 | `herdr-cleanup.sh --only locks` |

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
~/.claude/scripts/herdr-cleanup.sh --apply          # 消す（live は残す）
~/.claude/scripts/herdr-cleanup.sh --apply --include-live
~/.claude/scripts/herdr-cleanup.sh --only consult --only locks
~/.claude/scripts/herdr-cleanup.sh --name consult-review --apply
```

- 出力は `live`（残す） / `close`（消す予定） / `closed` / `released` の 4 種
- `--only consult|agents|locks` は複数指定できる
- 記録はあるが Herdr に実体が無いものは、`close`（Herdr が知っていれば）→ だめなら記録だけ削除

## やらないこと

- **`herdr-agent.sh reap` を無条件に使わない**（記録済みの全部を閉じる。他の作業を巻き込む）
- 生きているセッションを勝手に閉じない（`--include-live` はユーザーが明示したときだけ）
- worktree を勝手に消さない（`--worktrees` は一覧のみ）
- 記録の無いセッション（ユーザーが手で開いた pane）は対象外

## 終わったあと

- まだ残っているものは `--status`（consult）/ `herdr-agent.sh list` で確認できる
- タスク単位で閉じたいだけなら、このスキルではなく `claude-consult.sh --close` / `herdr-agent.sh close NAME`
