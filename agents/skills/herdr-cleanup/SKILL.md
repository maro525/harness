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
| 「herdr のセッション整理して」「溜まってない？」 | `~/.claude/scripts/herdr-cleanup.sh`（レポートだけ。既定は**この実行者（安定名）の分**。長命な司令塔名の pane では別チャットも混ざるので、このチャットで作った名前を `--name` で絞る） |
| 「全部まとめて整理して」「他のセッションのも」 | `herdr-cleanup.sh --all-owners`（他人のセッションも対象）
| 「終わったやつは消して」 | まず `herdr-cleanup.sh` で一覧を出す → **一覧を見せて了承を得る** → `herdr-cleanup.sh --apply --yes` |
| 「動いてないのも消していい」 | 上と同じ手順で `--include-live` を足す（了承を得てから `--apply --yes --include-live`） |
| 「worktree も見て」 | 上に `--worktrees` を足す（**この実行者の分だけ**が対象。clean は `--apply` で削除、dirty は報告のみ。他のセッションの登録済みは `--all-owners`）。記録の無い worktree は `skip（unregistered）` で、フラグでは消えない。このチャットで作ったと分かる clean なものだけ、了承後に `git worktree remove` で消す（ブランチは残る） |
| 「◯◯ だけ消して」 | `herdr-cleanup.sh --name ◯◯` で一覧 → 了承 → `--apply --yes --name ◯◯` |
| 「ロックが残ってない？」 | `herdr-cleanup.sh --only locks` |
| 「未読の報告ある？」「inbox 溜まってない？」 | `herdr-cleanup.sh --only inbox`（別の司令塔の分は `--boss NAME`。**読むだけ**） |
| 「◯◯（司令塔）の分を整理して」「pane が消えた」 | `herdr-cleanup.sh --owner ◯◯` で一覧 → 了承 → `--apply --yes --owner ◯◯` |

**閉じる前に必ず人が確認する。** `--apply` だけでは何も閉じない（TTY 無しでは exit 2）。`--yes` は「一覧を見せて了承をもらった後」にだけ付ける。

## 何を見ているか

| 区分 | 記録の場所 | 「片付ける」の意味 |
|---|---|---|
| `consult` | `~/.cache/harness/herdr-consult/*.json` | 旧 consult.sh の記録。もう作られないが、残っていれば agent の居ない／idle な tab を閉じて記録を消す |
| `agents` | `~/.cache/harness/herdr-agents/*.json` | 同上（`herdr-agent.sh close` 経由なので worktree も片付く） |
| `locks` | `~/.local/share/harness/locks/*.lock` | TTL を過ぎた実行ロックを解放する |
| `inbox` | `~/.cache/harness/inbox/<boss>/` | **何もしない（表示だけ）**。未読の報告と件数、`.watch/` のロック・`.since`・ログを並べる。片付けは `herdr-agent.sh inbox <boss> read` → `ack` → `clear` |
| `--worktrees` | `~/.herdr/worktrees/<repo>/` | 記録の無い worktree。**clean なら `git worktree remove`**（ブランチは残る）、dirty は報告のみ。**既定はこの実行者の分だけ**（`herdr-agent.sh` が作成時に `~/.cache/harness/herdr-worktrees/` へ owner を記録）。他セッションの登録済みは `--all-owners`。**登録の無い worktree は `skip（unregistered）` で、どのフラグでも消さない** |

## 実行のしかた

```bash
~/.claude/scripts/herdr-cleanup.sh                  # レポート（安全）
~/.claude/scripts/herdr-cleanup.sh --apply          # 一覧＋確認（TTY が無ければ何もせず停止）
~/.claude/scripts/herdr-cleanup.sh --apply --yes    # 了承後の実行
~/.claude/scripts/herdr-cleanup.sh --apply --yes --include-live
~/.claude/scripts/herdr-cleanup.sh --only agents --only locks
~/.claude/scripts/herdr-cleanup.sh --name codex-review-1983 --apply --yes
```

- 先頭の `Scope:` 行に、解決した安定名（`agent:<name>` / `pane:<id>`）・pane id・inbox を見る boss が出る
- 記録の行は `live`（残す） / `close`（消す予定） / `closed` / `released` の 4 種で、行末に `boss:<name>`（無ければ `boss:-`）
- inbox の行は `unread <file>`・`N unread`・`watch <file>`（ロックは `watcher alive` / `watcher gone`）。`--apply` でも触らない
- `--only consult|agents|locks|inbox` は複数指定できる
- `--boss NAME` で見る inbox を選ぶ（既定は `$HERDR_BOSS` → `--owner` の名前 → 自分の安定名）
- 記録はあるが Herdr に実体が無いものは、`close`（Herdr が知っていれば）→ だめなら記録だけ削除
- **pane 名で拾った記録（行末 `via:pane-name`）は `--apply` でも閉じない。** 生きていればレポートだけ（`--include-live` でも閉じない）、実体が無ければ記録ファイルだけ消して tab / pane は残す。閉じるのは `--owner pane:ID` を明示して owner 一致で拾ったときだけ
- `via:pane-name(owner:pane:w1:p2)` の括弧内が記録の owner。一覧をユーザーに見せて了承を得てから `--owner pane:w1:p2` に渡せば、owner 一致として閉じられる

## 対象の範囲（既定はこの実行者の分。チャット単位ではない）

セッションの記録には **start 時の実行者**が `owner` として書き込まれる。値は pane が消えても追える**安定名**（`$HERDR_AGENT_NAME` → Herdr が知っているその pane の agent 名 → 取れなければ `pane:<id>`）で、生の pane id は `owner_pane` に残る。`delegate` された子の記録には司令塔の名前が `boss` として追記される。`herdr-cleanup.sh` は**既定でこの実行者（安定名）の分だけ**を対象にする。範囲は次のどれか:

1. `owner` が自分の安定名と一致する
2. `owner` が `pane:P` の古い記録で、pane `P` の今の agent 名が自分の名前
3. `boss` が自分の名前（司令塔の pane が消えても boss 名で追える）

- `owner` が空の古い記録、他の pane/agent が作った記録は**触らない**
- 全体を見るなら `--all-owners`、特定の実行者だけなら `--owner agent:NAME` / `--owner pane:ID` / `--owner NAME`（= `agent:NAME`）
- **この範囲はチャットではなく実行者の安定名で決まる。** pane に `boss-storage` のような長命な名前が付いていると、同じ名前で走った別のチャットの tab も同じ範囲に入る。混ざったら、このチャットで作った名前だけを `--name` で絞り、その一覧を人に見せる。レポート全体に `--include-live` を付けない
- 記録の無い worktree は owner が無いので、このツールは消さない。このチャットで作ったと分かる clean なものだけ、了承後に `git worktree remove` する（ブランチは残す）。そのために `--all-owners` を使わない
- 実行ロックも同じで、lease には acquire した pane が `owner` として入る。**この実行者が立ち上げた子の pane / agent が取った lease も同じ範囲として扱う**（`orchestrate` を子セッションで回しても、そのロックが漏れない）
- worktree も同じ: `herdr-agent.sh` が作成時に `~/.cache/harness/herdr-worktrees/` へ owner を記録し、cleanup はその owner で絞る

## やらないこと

- **了承なしに `--apply --yes` を付けない**（`--yes` は一覧を見せてユーザーが OK した後だけ）
- **レポート全体に `--include-live` を付けない**（長命な司令塔名の pane では他のチャットを巻き込む。`--name` で絞った 1 件ずつ）
- **`--all-owners` を、記録の無い worktree を消すためだけに使わない**（他のチャットを巻き込む。手で消す）
- **自分が立ち上げていないセッションを消さない**（`--all-owners` / `--owner` を付けない限り対象外。付けろと言われたときも一覧を見せる）
- **`herdr-agent.sh reap` を無条件に使わない**（記録済みの全部を閉じる。他の作業を巻き込む）
- 生きているセッションを勝手に閉じない（`--include-live` はユーザーが明示したときだけ）
- worktree を勝手に消さない（`--worktrees` ＋ `--apply --yes` のときだけ。**dirty な worktree は絶対に消さない**。ブランチはどちらにせよ残る）
- worktree も **pane 名一致（`via:pane-name(owner:pane:…)`）では消さない**（`skip` 行で理由が出る）。消すのは了承を得て `--owner pane:ID` を明示したときだけ
- 記録の無いセッション（ユーザーが手で開いた pane）は対象外

## 終わったあと

- まだ残っているものは `--status` / `herdr-agent.sh list` で確認できる
- タスク単位で閉じたいだけなら、このスキルではなく `herdr-agent.sh close NAME`
