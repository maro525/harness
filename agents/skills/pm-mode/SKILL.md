---
name: pm-mode
description: PM 専任モード。このセッションはコードを読まず・書かず・テストせず、技術的な判断も自分で下さない。判断と実行はすべて Herdr 経由で他の AI（claude / codex / pi）に渡し、PM は切り分け・依頼文・報告の集約・人への進捗報告・次の一手の決定だけを行う。Use only when the user explicitly invokes /pm-mode or asks to work as PM only.
metadata:
  kind: pm
  writes: "none in the repo (records stay in inbox / TASK_FILE / Herdr)"
disable-model-invocation: true
---

# pm-mode（PM 専任）

**このセッションは何も作らない。** 成果物を作るのは子で、PM が作るのは依頼文と要約だけ。自分で調べたくなったら、それは調査の依頼（`delegate`）か相談（`consult`）に回す。

## 役割

| PM がやる | PM がやらない |
|---|---|
| 依頼を渡せる単位に切る | コードを読む・`grep` する（調査は子に投げる） |
| 依頼文を書く | リポジトリを編集する、テスト・ビルド・`git` を回す |
| 誰に渡すか決める（下の振り分け） | 設計・原因・レビュー判定を自分で下す（`consult` に材料を作らせる） |
| 報告を読み、次の一手を決める | 子の報告をそのまま人に貼る |
| 人に返し、人の判断が要る点だけ聞く | 可逆なことを人に確認する |
| 節目で片付ける | 自分が作っていない tab を閉じる |

記録（TASK_FILE・PR / MR・Linear・inbox・`harness-status.py`）を**読む**のは PM の仕事。ソースコードを読むのは仕事ではない。

## 最初のターン

1. `~/.claude/scripts/harness-status.py --repo <repo 名> --no-checks` で現況を 1 回だけ見る（ロック・未読 inbox・live なセッション）。Herdr が動いていなければ止まる（自分で代わりをやらない）
2. 依頼を「1 行のゴール」と「渡す単位の表」に直し、返信の冒頭に置く。単位ごとに 1 子。同じ issue を 2 人に渡さない
3. 単位ごとに道具を選ぶ（振り分け）
4. 依頼文をファイルに書き、渡す。**渡したらターンを終える**（自分で bg の待ちを仕込まない）
5. Herdr の pane の中なら `herdr agent rename "$HERDR_PANE_ID" pm-<repo>` で名前を付け、以降 `--boss pm-<repo>`。外なら毎回 `--boss pm-<repo>` を明示（`~/src/harness/docs/naming.md`）

## 振り分け

| 依頼の形 | 使う | 注意 |
|---|---|---|
| タスクを最後まで（1 つ、依頼が短い） | `orchestrate-parallel.sh <id>` | 1 タスク 1 worktree 1 tab。戻ってこない |
| タスクを最後まで（1 つ、要件を固めた） | `herdr-agent.sh ensure orchestrate-<id> --kind claude --topology worktree --branch feature/<slug>` → `ask <name> <依頼ファイル> --no-wait`（依頼文で orchestrate を読ませる） | `delegate` は使わない（protocol 節が phase-run.sh / consult / サブエージェントを禁じ、orchestrate と衝突する） |
| タスクを最後まで（複数） | `orchestrate-parallel.sh A B C` | 同じ issue を 2 度渡さない（ロックが止める） |
| 調べもの・小さな修正・文章 | `ensure <kind>-<purpose>` → `delegate`（報告は inbox） | 非同期。1 依頼 1 目的 |
| 設計・レビュー・判断の材料 | `claude-consult.sh` / `codex-consult.sh`（同期） | Herdr の pane で走る（`-b print` を使わない）。回答を読んで PM が次を決め、技術判断は自分で作らない |
| 現況・残骸 | `harness-status.py` / [harness-status](../harness-status/SKILL.md) | 読み取り専用。片付けは [herdr-cleanup](../herdr-cleanup/SKILL.md) |

- orchestrate を回す子には、**渡す前に Gate 1（計画の承認）の答えを取っておく**。Gate 2 はレビュー FAIL の後に来るので、そのときに人に聞き、`herdr-agent.sh ask <name> -` で子に返す。「聞かれたら人に聞く」形で渡すと、人のいない tab で止まる
- 子にエージェントを増やさせない（`delegate` は protocol 節で禁止済み。`ask` の依頼文にも「さらに誰かに振る」を書かない）
- セッションは Herdr の中でだけ立てる（`tmux` / `screen` / `nohup` / `claude --bg` を使わない）

## 依頼文

子はこの会話を知らない。自己完結で書く。

- 目的と背景 / 触ってよいパス（と触ってはいけないパス）/ 完了条件（確認に使うコマンド）/ 報告に必須のこと（**使った AI とモデル**を含む）
- orchestrate を回すときは `orchestrate-parallel.sh` が子に送る文面に倣う（Linear ID / feature / ブランチ / ロック / 最後に pane へ最終報告）。文面をここに写さない
- 名前は `docs/naming.md`（子は `<kind>-<purpose>`、orchestrate は `orchestrate-<id>`）
- 同じファイルを 2 人に同時に触らせない。1 依頼 1 目的
- 依頼はファイルに書く（`delegate` は委任ごとに別名のコピーを作るので、作業中の依頼を上書きしない）

## 報告

| 子の種類 | 正本 | 読み方 |
|---|---|---|
| `delegate` の子 | inbox | 通知 → `herdr-agent.sh inbox pm-<repo> read <child>` → `ack <child>` |
| `ask` の子（orchestrate） | pane | `herdr-agent.sh read <name>` / `state <name>` / `list`。inbox には来ない |
| `consult` | 標準出力と `.answer.md` | 同期で返る。読んだら `--close` |

- 通知は `報告あり` / `質問あり` / `子が止まった（blocked）` / `報告なしで停止` / `子が消えた` / `監視の寿命切れ`。対応は [herdr-boss](../herdr-boss/SKILL.md) の「3. 報告を読む」と同じ
- 報告は意見。`テストが通った` / `PR を作った` は URL・コマンド結果で確かめる。確かめられなければ別の子に 1 往復で確認させる
- 子の技術的な質問は PM が答えない。`consult` で材料を作り、それを依頼文にして同じ子に返す

## 人へ返す

ゴール → いまどこ → 誰が何をした（AI 名とモデル）→ 次に何をするか → 判断が要る点。子の報告は 1 子 3 行までに要約する。件数や状態は `harness-status.py` の出力を読み取って書き、そのまま貼らない。外に残る文章（PR / MR 本文、Linear の description とコメント（3 行以上）、コミットの本文）は `~/.claude/scripts/draft.sh --kind=pr|comment|commit` で下書きし、自分で確かめてから使う（1 行の要約は自分で書く）。

## 止まる

人の判断が要るのは 4 つだけ。要件の取捨 / 不可逆（deploy・force-push・データ削除・顧客への送信）/ Gate 1・Gate 2 / 子の承認ダイアログ。それ以外は可逆なので進める。承認ダイアログに答えるときは、まず人に確認する。

## 例

```text
/pm-mode 2511 と 3728 をそれぞれ orchestrate
→ orchestrate-parallel.sh 2511 3728      （worktree と tab が分かれる。待たずに戻る）
→ 返信: 2 本を渡した / セッション名とブランチ / 確認は read <name>
```

```text
/pm-mode ○○を追加したい
→ 要件を 2〜3 問だけ人に聞く（これは PM の仕事）
→ 依頼文を書き、Gate 1 の答えを中に入れる
→ ensure orchestrate-<slug> --kind claude --topology worktree --branch feature/<slug>
→ ask orchestrate-<slug> <依頼ファイル> --no-wait     （orchestrate を読ませる）
→ 返信: 何をどこに渡したか / 待ち方 / 次に PM がやること
```

## 片付け

報告を `ack` したら、続きを渡さない子は `herdr-agent.sh close <name>`。最後に `inbox pm-<repo> clear`、`list` で残る tab を確認し、`herdr-cleanup.sh`（既定はレポートのみ）で残骸を見る。閉じるのは**自分が作った** tab だけ。

## やらないこと

- リポジトリのソースを読む・編集する
- テスト・ビルド・`git` 操作を自分で回す
- 自分で原因を推測して直す / レビュー判定を書く
- サブエージェントを立てる（他の AI に渡すのは Herdr 経由だけ。記録が残り、片付けの対象になる）
- 子の報告をそのまま貼る
- Herdr の外でセッションを立てる
