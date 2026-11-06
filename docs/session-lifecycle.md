# セッションのライフサイクル（明示運用）

Herdr 上のエージェント・セッションは、**閉じるまで残る**（TTL のような自動失効は入れていない）。
そのかわり「いつ開いて、いつ閉じるか」をここで決めておく。

原則は **1 タスク = 1 セッション**。

- 開くのは、その作業で本当に必要になった瞬間だけ（先回りして開かない）
- 閉じるのは、**そのセッションから受け取るものを全部受け取った直後**
- タスクやブランチが変わったら `--new` で作り直す（文脈の混線を防ぐ）

## role 別

| role | 開くタイミング | 閉じるタイミング |
|---|---|---|
| `consult` | 設計相談が発生したとき | **回答を採用 / 却下したら即**（既定では残るので、`--close` を習慣にする） |
| `review` | team-review に入るとき | PASS して deploy に進む直前、または FAIL 対応が終わったとき |
| `implement` | team-implement に入るとき | PR 作成（deploy 完了）後 |
| pi / codex（`herdr-agent.sh`） | そのタスクを任せるとき | コミット・PR が終わったとき |

`consult` だけは既定で残す（同じ相談者に文脈を保ってほしい場面があるため）。
使い捨てでよいと分かっているときは `--close` を付けて 1 回で閉じる。

## どこに開くか（topology）

Herdr の構造は workspace → tab → pane。セッションをどこに作るかは `herdr-agent.sh ensure` の `--topology` で選ぶ（`claude-consult.sh` は常に `tab`）。

| topology | 何ができる | 向いている場面 |
|---|---|---|
| `tab`（既定） | 呼び出し元の workspace に新しい tab | 同じリポジトリの作業を並行する。今の workspace を汚さない |
| `workspace` | そのリポジトリ専用の workspace（tab と pane 付き） | **別のリポジトリ**を任せるとき。workspace ごとにサイドバーで分離される（git は触らない） |
| `worktree` | git worktree を作り、その workspace と tab で起動（パスは `~/.herdr/worktrees/{repo}/{branch}`） | 同じリポジトリでタスクを隔離したいとき。ブランチも切られる（`--branch` / `--base`） |

- `tab` は**呼び出し元の workspace id を必要とする**（`HERDR_WORKSPACE_ID`）。無い・古い場合は `workspace create` に自動フォールバックする
- `workspace` / `worktree` で作った workspace は**このツールが所有**するので、`close` で workspace ごと閉じる
- `worktree` のセッションは `close` で **worktree も削除**する（`herdr worktree remove`。`--force` は使わないので、未コミットの変更があれば workspace だけ閉じて警告する）。**ブランチは残る**（成果物なので意図的）
- 手で作った workspace / tab / worktree は絶対に閉じない（所有フラグで判定）

## タスク境界のルール

1. **開始時**: 前のタスクのセッションが残っていたら閉じる（または `--new` で作り直す）

   ```bash
   ~/.claude/scripts/claude-consult.sh --status            # 残っているセッションを確認
   ~/.claude/scripts/claude-consult.sh --close --roles implement,review
   ~/.claude/scripts/herdr-agent.sh reap                    # pi / codex 側もまとめて
   ```

2. **終了時**（完了報告を書く前）: そのタスクで開いたものを閉じる

   ```bash
   ~/.claude/scripts/claude-consult.sh --close --role implement
   ~/.claude/scripts/herdr-agent.sh close <name>
   ```

3. **迷ったとき**: `--status` / `herdr-agent.sh list` を見て、`idle` のまま用のないものを閉じる

## 安全策

- `--close` / `reap` は **自分が作った tab のときだけ** tab を閉じる（状態ファイルの `tab_owned`）。
  自分で作っていない tab を借りているセッションは pane だけ閉じ、呼び出し元の tab は残す
- ユーザーが手で開いた pane / tab は対象外（記録があるものしか触らない）
- herdr の `[session] resume_agents_on_restore` が有効だと、**サーバ再起動時にエージェントが復元**される。
  閉じたものが復活するのが困るなら設定で切る（常用セッションも復元されなくなる点に注意）

## コマンド対応表

| やりたいこと | コマンド |
|---|---|
| 記録済みセッションの一覧 | `claude-consult.sh --status` / `herdr-agent.sh list` |
| 1 つ閉じる | `claude-consult.sh --close --role ROLE` / `herdr-agent.sh close NAME` |
| 複数ロールを閉じる | `claude-consult.sh --close --roles implement,review` |
| 全部閉じる | `claude-consult.sh --close` / `herdr-agent.sh reap` |
| 種類で絞って閉じる | `herdr-agent.sh reap --kind pi` |
| 作り直す（文脈リセット） | `claude-consult.sh --new --role ROLE` / `herdr-agent.sh restart NAME` |
| ターミナルの末尾を見る | `claude-consult.sh --show ROLE` / `herdr-agent.sh read NAME` |
