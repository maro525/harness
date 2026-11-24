---
name: harness-status
description: harness の現況を端末で一望する。Herdr のサーバー・agent、セッション記録、ロック、タスクファイル、worktree、inbox の未読、checks の結果を 1 回で読み取り専用に出す。Use when the user asks "いまの状況", "harness の状態", "何が動いてる", "溜まってない？", "status", or wants an overview before tidying up.
metadata:
  kind: status
  writes: "none (read-only; never creates buckets, acks inbox or closes sessions)"
---

# harness-status

「いま harness はどうなってる？」に答える。数字は `~/.claude/scripts/harness-status.py` が出す。**そのまま貼らず、要対応を読み取って伝える。**

## 手順

```bash
~/.claude/scripts/harness-status.py                  # 全 repo の件数と要対応項目
~/.claude/scripts/harness-status.py --repo harness   # repo で絞る（inbox は boss 単位なので絞らない）
~/.claude/scripts/harness-status.py --all            # 要対応でない項目も全件出す
~/.claude/scripts/harness-status.py --no-checks      # checks を走らせない（速い）
```

## 読み方

| 区分 | 読み方 |
|---|---|
| **Herdr** | `確認不可` は接続できなかっただけで、停止とは限らない。このとき セッション記録も `確認不可` になる |
| **セッション記録** | `gone` = 記録はあるが Herdr に実体が無い。`live` は既定では個別に出ない |
| **ロック** | `expired` = lease の更新から TTL を過ぎた。`*.lock.guard`（flock 用の 0 バイト）は数えない |
| **タスクファイル** | 個別に出るのは planning / implementing / reviewing / deploying と人待ち（`waiting-gate1` / `waiting-gate2`）のもの。他は件数だけ |
| **worktree** | `orphan` = 記録の無い worktree（clean / dirty を併記）。`in-use` は既定では出ない |
| **inbox** | 未読の報告の件数（boss ごと）。既読化はしない |
| **checks** | 成功 / 失敗 / skip / 確認不可を区別する。失敗は最初の NG 行を添える |

## 片付けは別のスキル

status は**見るだけ**。`gone` / `expired` / `orphan` / 未読があっても、ここから自動で閉じたり消したりしない。人に見せて、片付けるなら `herdr-cleanup`（既定はレポート、`--apply` はユーザーの了承後）、未読は `herdr-agent.sh inbox <boss> read` を案内する。
