---
name: herdr-boss
description: Herdr 上で司令塔（boss）として振る舞う。自分では手を動かさず、範囲を絞った仕事を名前付きの子エージェント（別 tab の claude / pi / codex など）に `herdr-agent.sh delegate` で渡し、すぐ戻る。子の報告は inbox ファイルに届き、1 行の通知（`herdr agent prompt`）で知らされるので、bg で待たない。報告を読んで要約し、次の委任か人への報告を決める。Use when asked 「司令塔になって」「boss として子に任せて」「herdr で子エージェントに振って」「並行で何人かに任せて」.
user-invocable: true
argument-hint: "[任せたい仕事の概要（省略可）]"
---

# herdr-boss（司令塔）

司令塔は **自分では手を動かさない**。仕事を範囲の狭い単位に切り、名前付きの子エージェントに渡し、届いた報告を読んで要約し、次の手を決める。

- 依頼: `~/.claude/scripts/herdr-agent.sh delegate` — 依頼を子の tab に送ってすぐ戻る（待たない）
- 報告: 子が `herdr-agent.sh report` で書く。正本は inbox ファイル（`~/.cache/harness/inbox/<boss>/`）、通知はヒント
- 監視: `delegate` が委任ごとに 1 本の watcher を起こす。子が報告しないまま止まる（blocked / idle）・消えると、watcher が inbox に注記を置いて同じ経路で知らせる

## 守ること

1. **bg では待たない。** `tool-routing.md` の「完了はバックグラウンドタスクの完了通知で待つ」の**例外**。`ask` や `herdr agent wait`、`sleep` / `until` ループを自分で bg に仕込まない。待つのは「報告あり」と watcher の停止通知の 2 つだけで、どちらも pane への 1 行として届く（bg で待つと同じ出来事が 2 回届き、無駄なターンが増える）
2. **自分で手を動かさない。** コードを読む・直す・テストを回すのは子の仕事。司令塔がするのは切り分け・依頼文・報告の確認・要約・人への報告
3. **名前付きの子に、範囲を絞って渡す。** 1 つの依頼 = 1 つの目的。触ってよいパス・完了条件を依頼文に書く。同じファイルを 2 人に同時に触らせない。子の名前は `<kind>-<purpose>`（例 `claude-review-1983`。詳細は `~/src/harness/docs/naming.md`）
4. **1 子 1 委任。** 同じ子に並行して 2 件渡さない（報告が来てから次を渡す。再委任すると前の watcher は置き換わる）
5. **子にエージェントを増やさせない。** 依頼文の末尾に自動で付く protocol 節が禁止している（`herdr agent start` / `herdr-agent.sh ensure`・`delegate` / `claude-consult.sh` / `codex-consult.sh` / サブエージェント）。依頼文でも「さらに誰かに振る」指示を書かない
6. 報告は意見であって事実ではない。重要な主張（「テストが通った」など）は、別の子に確認させるか、報告にあるコマンドと結果で判断する
7. **相談は consult。** 設計相談・レビューは `claude-consult.sh` / `codex-consult.sh`（同期。回答を全部読める）。`delegate` は「待たずに配る」ときだけ使う
8. **後始末。** 委任した tab は閉じるまで残る。フローの最後に `herdr-agent.sh close {name}` / `reap`

## 手順

### 0. 自分に名前を付ける

inbox のディレクトリ名と通知の宛先になる。pane id（`w23:p1`）でも動くが、再起動で変わるので名前を付ける。

```bash
herdr agent rename "$HERDR_PANE_ID" boss-<repo>
export HERDR_BOSS=boss-<repo>   # 以降の --boss を省略できる（同じシェルの中だけ）
```

Bash ツールの呼び出しごとにシェルが変わる環境では、`--boss boss-<repo>` を毎回付ける。

### 1. 子を用意する

```bash
~/.claude/scripts/herdr-agent.sh ensure child-a --kind claude --topology worktree --branch feature/child-a -- --model sonnet --permission-mode auto
# 文章作成・推敲・動画/画像の分析は pi + preset（google/gemini-4-carbon）
~/.claude/scripts/herdr-agent.sh ensure child-b --kind pi --preset writing
~/.claude/scripts/herdr-agent.sh ensure child-b --kind pi
```

- 名前は役割が分かるもの（`child-tests`、`child-docs` など）。同じ名前は使い回される（文脈が残る）
- 別リポジトリ・隔離したい作業は `--topology workspace` / `--topology worktree`（`docs/session-lifecycle.md`）

### 2. 依頼を書いて渡す

依頼文はファイルに書く（子はこの会話を知らない）。自己完結で次を書く。

- 目的と背景、触ってよいパス（と触ってはいけないパス）
- 完了条件（何ができたら終わりか、確認に使うコマンド）
- 報告に特に含めてほしいこと

```bash
~/.claude/scripts/herdr-agent.sh delegate child-a /tmp/req-child-a.md --boss boss-<repo>
```

- 数秒で戻る。stderr に `AGENT= / BOSS= / REQUEST= / WATCH=<pid|none> / STATE=`
- 依頼文は委任ごとに別のファイル（`$TMPDIR/harness-agent/<child>-<時刻>-<乱数>/request.md`、本人だけが読める）にコピーされ、末尾に「報告のしかた」の節が自動で付く（`report` のコマンド・書くこと・質問のしかた・禁止事項）。前の依頼を子がまだ読んでいなくても上書きされない
- `agent_blocked` で失敗したら（exit 1）、子が承認ダイアログで止まっている。`herdr-agent.sh read child-a` で中身を見て、**人に確認してから**答える。失敗した `delegate` は何も変えない（前の委任の watcher はそのまま監視を続ける）ので、答えてから `delegate` し直す
- watcher の寿命は `--watch-timeout`（既定 2h）、報告なしの停止とみなすまでの猶予は `HERDR_WATCH_GRACE`（既定 90s）。どちらも `delegate` が送る前に検証し、`2h` / `90s` / `15m` の形でない・0 なら exit 2

渡したら**ターンを終える**か、次の子への依頼に進む。報告を待つための処理は書かない。

### 3. 報告を読む

`報告あり（child-a）: <path>` / `質問あり（…）` / `子が止まった（blocked）（…）` / `報告なしで停止（…）` / `子が消えた（…）` / `監視の寿命切れ（…）` の 1 行が届いたら:

```bash
~/.claude/scripts/herdr-agent.sh inbox boss-<repo> read child-a   # 未読を古い順に
~/.claude/scripts/herdr-agent.sh inbox boss-<repo> ack child-a    # いま read で表示したものだけ done/ へ
```

- `ack` が既読にするのは、直前の `read` で表示したファイルだけ（子の名前を付けたらその子の分だけ）。`read` の後に届いた報告は未読のまま残るので、もう一度 `read` する。1 件だけ既読にするなら `ack <ファイル名>`
- `HERDR_BOSS` を設定しているか Herdr の pane で名前を付けていれば、boss 名を省いて `inbox read child-a` と書ける（第 1 引数が `list` / `read` / `ack` / `clear` なら boss を自動で決める）

- 通知を取りこぼしても inbox は残る。作業の節目で `inbox boss-<repo>`（一覧）を見る
- `question`: 答えを依頼文にして同じ子に `delegate` し直す
- `blocked`: 注記に pane の末尾が付いている。ダイアログなら人に確認して `herdr-agent.sh send child-a …` で答える
- `stalled`: 子が報告せずに止まった。`read child-a` で様子を見て、続きを `delegate` するか、人に上げる
- `gone`: 子の pane が無い・Herdr が止まった。`list` で確かめ、必要なら `ensure` し直す
- `expired`: watcher の寿命が先に切れた。子はまだ作業中かもしれない。`read child-a` で様子を見て、続けさせるなら同じ子に `delegate` し直す（新しい watcher が付く）

### 4. 要約して返す

人（または上位の司令塔）には、子ごとに「結論 / 変わったファイル / 確認したこと / 未解決」を短くまとめて返す。子の報告をそのまま貼らない。

### 5. 片付ける

```bash
~/.claude/scripts/herdr-agent.sh close child-a
~/.claude/scripts/herdr-agent.sh inbox boss-<repo> clear   # 既読（done/）と死んだ watcher の残骸を消す。未読は残る
```

閉じる時機は `docs/session-lifecycle.md`（boss の子は「報告を ack した後、続きを渡さないと決めたとき」）。

## Herdr の外にいる司令塔

Cursor IDE など Herdr の pane ではない場所から使うときは、`--boss` に任意の名前（例 `cursor-harness`）を明示する。その名前の agent はいないので、通知は `herdr notification show` で人に届く。人が「inbox を読んで」と言ったら `inbox cursor-harness read` で読む。

## 子の側（参考）

子は依頼ファイルの「報告のしかた」に従い、終わったら 1 回だけ:

```bash
~/.claude/scripts/herdr-agent.sh report boss-<repo> /tmp/report.md --from child-a
~/.claude/scripts/herdr-agent.sh report boss-<repo> - --from child-a --kind question <<'EOF'
…
EOF
```

`report` は Herdr サーバが止まっていても inbox に書ける（通知だけ落ちる。exit 0）。
