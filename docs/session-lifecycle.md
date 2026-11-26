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
| `external-review` | 独立レビュー・設計相談が発生したとき | 回答を採用 / 却下したら即 `close`（同じ論点で続けて聞くなら残す） |
| `review` | team-review に入るとき | PASS して deploy に進む直前、または FAIL 対応が終わったとき |
| `implement` | team-implement に入るとき | PR 作成（deploy 完了）後 |
| pi / codex（`herdr-agent.sh`） | そのタスクを任せるとき | コミット・PR が終わったとき |
| manager の子（`herdr-agent.sh delegate`） | manager が最初の仕事を渡すとき（`ensure` → `delegate`） | 報告を `ack` した後、その子に続きを渡さないと決めたとき |
| 子 manager（`herdr-agent.sh manager --parent`） | 親 manager が自分の範囲を分けたとき（子 manager からさらに子へも同じ） | 子 manager の報告を `ack` して、その範囲が終わったとき（親が `close` する） |

`external-review` のセッションは既定で残す（同じ論点に文脈を保って続けて聞けるように）。
使い捨てでよいなら回答を受けたら `close` する。

## manager は 1 セッションに 1 つ、manager は子を複数持てる（常に `~/src`）

PM（Cursor などの会話）は manager を `herdr-agent.sh manager` で用意する。名前も居場所も自分で組み立てない（決めるのはスクリプト）。manager は**リポジトリをまたいで指示する役**なので、どのリポジトリにも入らず、常に `~/src`（`$HARNESS_MANAGER_ROOT`）で動く。**manager は worktree を作らない。**

同じ規則が子 manager にも当てはまる。1 体の manager は範囲を分けて子 manager を**複数**起こせる（1 チャット 1 manager は PM 直下の話）。

| 状態 | 返るもの |
|---|---|
| 名前が空いている | `manager-<label>`（`~/src` の tab） |
| 別のセッションが同じ名前を持っている | `manager-<label>-<suffix>`（同じ `~/src` の別 tab） |
| 同じセッションの manager がいる | それを再利用（`STATE=reused`） |
| `~/src` の外に居る古い記録 | 引き継がない（新しい manager が `~/src` に立つ。古いものは `close` する） |

- `<label>` は既定で呼び出し元のリポジトリ名。**`--label <name>` を渡せば、どのディレクトリからでもその名前で立つ**（リポジトリが手元に無い、このチャットの主題が今居るリポジトリと違う、1 つのチャットで複数のリポジトリをまたぐ、といったとき）。`--label` が変えるのは名前だけ
- セッションの識別は 3 段。`--session` / `$HARNESS_SESSION_KEY` → Herdr の pane（`$HERDR_PANE_ID`。rename しても id は変わらない）→ 呼び出し元のエージェントプロセス（`proc:<pid>:<starttime>`）。Cursor は Herdr の pane を持たないが、チャットごとに `cursor-agent` のプロセスが 1 つあるのでここで分かれる
- 3 つとも取れなければ exit 2（勝手に共有しない）。共有された親プロセス配下で動く場合は `HARNESS_SESSION_PROC=0` でプロセス探索を止め、`--session <token>` を渡す
- うまく決まらないときは `herdr-agent.sh manager --explain` で、決まったセッション（`SESSION=` / `SOURCE=`）と見た先祖（`ANCESTORS=`）だけを出せる（何も作らない）
- 試行は 1 回 1 行、`~/.cache/harness/manager.log` に残る（`<時刻> <結果> <session> <repo> <名前>`）。`no-session` が並んでいるなら、その呼び出し元はセッションを決められていない
- プロセスの探索は**祖先のコマンド名**で見る（`cursor-agent` / `agent` / `claude` / `codex` / `pi` / `opencode`）。パスでは見ない（cursor 同梱の node が `.../cursor-agent/` の下にある）
- `--plan` は決まる名前と居場所だけを出す（何も作らない）
- 片付けは PM の終わりに `close <manager>`、まとめて閉じるなら `reap`

### 子 manager（`--parent`）

```bash
M=$(~/.claude/scripts/herdr-agent.sh manager)                       # PM 直下（depth 0）
~/.claude/scripts/herdr-agent.sh manager --parent "$M" --label api  # 子（depth 1）
~/.claude/scripts/herdr-agent.sh manager --parent "$M" --label web  # もう 1 体（1 体で複数持てる）
```

| 決めごと | 振る舞い |
|---|---|
| 名前 | `manager-<label>`。`--label` は必須で、親の名前は入らない（名前の階層を作らず、サイドバーを浅く保つ）。埋まっていれば `(親, ラベル)` のハッシュで `-<suffix>` が付く |
| 居場所 | 親と同じ `~/src` の別 tab。worktree は作らない |
| 報告先 | 記録に `parent` / `boss` が入り、子の報告はその子 manager の inbox に届く。子 manager がまとめて親に 1 回返す |
| 同じ（親, ラベル） | 同じ子を再利用（`STATE=reused`）。聞き直しても tab は増えない |
| 深さ | `depth` = 親 + 1。`HARNESS_MANAGER_MAX_DEPTH`（既定 3 段）を超える `--parent` は exit 2。それ以上は worker に振る |
| 親になれるのは manager だけ | `--parent` は `manager-*` の記録が生きていることを確かめる（PM が子 manager を直に作らない） |
| 親は自分自身 | 自分の子を分けるときは `--parent <自分の名前>` を渡す。これが通常の呼び方で、スクリプトは通す。断るのは、子の名前が親と同じになるラベルだけ |
| 自分自身の起動 | manager の pane から `--parent` 無しの `manager` は exit 2（自分の記録が返るだけで子が増えない）。メッセージどおり `--parent <自分の名前>` を付ける |
| 片付け | 親を `herdr-cleanup.sh --owner <親>` で見ると、子 manager と worker が `via:boss` で並ぶ |

## 実作業はリポジトリの中で（`worker`）

manager は子を `herdr-agent.sh worker <name> --kind claude --repo ~/src/<repo>` で起こす。**置く場所だけスクリプトが決める。**

| その checkout の状態 | 置き場所 |
|---|---|
| 作業中の子（`working` / `blocked` の tab）がいない | そのリポジトリの checkout（tab） |
| 作業中の子がいる | `feature/<name>` の worktree（`OCCUPIED=` に出る） |

- 同じ checkout を 2 体が同時に触らない。並行させたいときは両方 worktree になる
- `done` / `idle` の tab と manager・consult は「作業中」に数えない（finished の tab が並んでいるだけで worktree が増えないように）
- `--plan` でどちらになるか先に見られる
- 場所を自分で決めたいときは `ensure --topology tab|workspace|worktree` をそのまま使う（隔離・別リポジトリ・文章作成など）

## どこに開くか（topology）

Herdr の構造は workspace → tab → pane。セッションをどこに作るかは `herdr-agent.sh ensure` の `--topology` で選ぶ（external-review のセッションも `tab`）。

**エージェントを動かすセッションは必ず Herdr の中で立てる。** `tmux` / `screen` / `nohup` / `claude --bg` などの Herdr 外の手段は使わない — 記録が残らず、`--status` / `close` / `herdr-cleanup.sh` の対象外になる。Herdr が使えないときは止まって確認し、一回きりの調べもの・下書きだけ `external-ask.sh`（セッションを作らない）を使う。

相談とレビューのセッションは 1 種類になった。`external-review` の手順で `herdr-agent.sh ensure` に別ファミリのモデルを 1 つ名指しし、`ask --answer-file` で同期に受ける。名前は `<kind>-review-<id>` なので、codex と pi を並べて残せる。

| topology | 何ができる | 向いている場面 |
|---|---|---|
| `tab`（既定） | 呼び出し元（または `--workspace` で名指しした）workspace に新しい tab | 同じリポジトリの作業を並行する。今の workspace を汚さない |
| `workspace` | そのリポジトリ専用の workspace（tab と pane 付き） | **別のリポジトリ**を任せるとき。workspace ごとにサイドバーで分離される（git は触らない） |
| `worktree` | git worktree を作り、その workspace と tab で起動（パスは `~/.herdr/worktrees/{repo}/{branch}`） | 同じリポジトリでタスクを隔離したいとき。ブランチも切られる（`--branch` / `--base`） |

- `tab` は既定で**呼び出し元の workspace id を使う**（`HERDR_WORKSPACE_ID`）。無い・古い場合は `workspace create` に自動フォールバックする
- `tab` は `--workspace <id|label>` も受ける。manager がタスク用に workspace を 1 つ作り、その id を子の `ensure` すべてに渡せば、子の tab はその workspace に相乗りする（1 タスク 1 workspace）。id でもラベルでもよく、`herdr workspace list` の結果から一意に決まるときだけ解決する（見つからない・複数一致なら何も作らずに exit 2）
- `--workspace` で相乗りした workspace は**このツールの所有ではない**ので、`close` は tab だけを閉じ、workspace は残る（片付けは `herdr workspace close <id>`）。`--workspace` は `tab` 専用で、`workspace` / `worktree` に付けると exit 2
- `workspace` / `worktree` で作った workspace は**このツールが所有**するので、`close` で workspace ごと閉じる
- `worktree` のセッションは `close` で **worktree も削除**する（`herdr worktree remove`。`--force` は使わないので、未コミットの変更があれば workspace だけ閉じて警告する）。**ブランチは残る**（成果物なので意図的）
- 手で作った workspace / tab / worktree は絶対に閉じない（所有フラグで判定）
- **手で `git worktree add` するときも置き場所は同じ**（`$HOME/.herdr/worktrees/{repo}/{branch}`）。`../<repo>-<task>` のような相対パスで切ると、`herdr-cleanup.sh` の対象外になって残骸が溜まる（`checks/worktrees.sh` が警告する）

## inbox と watcher のライフサイクル（manager パターン）

manager は子の完了を待たない。子 → manager の報告は **inbox ファイル（正本）+ 通知（ヒント）** の 2 段で届く。

```
~/.cache/harness/inbox/<boss>/          # mode 700。<boss> は [A-Za-z0-9._-] 以外を _ に（w23:p1 → w23_p1）
├── child-a-20261109-141106.md           # report（子が書く。不変・上書きしない）
├── child-a-20261109-142310.question.md  # 子の質問（--kind question）
├── child-b-20261109-143002.stalled.md   # watcher の注記（.blocked / .stalled / .gone / .expired）
├── done/                                # ack 済み
├── .last-read                           # 直前の read が表示したファイルの一覧（ack が使う）
└── .watch/                              # watcher のロック（<child>.lock/）・委任時刻（<child>.since）・ログ（<child>.log）
```

| もの | できる | 消える |
|---|---|---|
| 報告 / 質問 | 子が `report <boss> <file\|-> --from <child>` を実行したとき（tmp に書いてから `ln`（使えなければ `mv -n`）で置く。既存の名前は上書きせず `-2`, `-3` … を付ける。先頭に `from / to / at / kind`） | `inbox <boss> read` → `inbox <boss> ack` で `done/` へ（`read` が表示した分だけ。1 件なら `ack <file>`）→ `inbox <boss> clear` で削除 |
| watcher の注記 | 子が報告しないまま blocked（1 回）/ idle・done が猶予（`HERDR_WATCH_GRACE`、既定 90s）続いた / 3 回続けて見つからない / 寿命が切れた（`.expired`） | 報告と同じ（`read` → `ack` → `clear`） |
| watcher（プロセス） | `delegate` が子への送信に成功したあと、委任ごとに 1 本、`setsid` で切り離して起こす（`--no-watch` で起こさない） | 報告を見つけた / stalled・gone を通知した / 寿命（`--watch-timeout`、既定 2h）が尽きた（`.expired` を通知）/ 同じ子への再委任が成功した。終了時に自分のロックを消す |
| 依頼ファイル | `delegate` が委任ごとに `$TMPDIR/harness-agent/<child>-<ts>-<乱数>/request.md` を作る（ディレクトリ 700・ファイル 600。`ask` は従来どおり `<name>.request.md` を上書き） | 自動では消さない（`$TMPDIR` の掃除に任せる） |
| `.watch/` のロック・ログ | watcher の起動時 | watcher の終了時（ロック）。プロセスが死んで残ったものとログは `clear` が消す |

- 通知は `herdr agent prompt <boss>` の 1 行（`報告あり（child-a）: <path>`）。boss が agent でない・blocked のときは `herdr notification show`、Herdr に繋がらないときは stderr の warning だけ。**どの場合も inbox には残る**ので、manager は節目に `inbox <boss>` を見る
- `clear` は**未読を消さない**。読まずに捨てたいときは `read` してから `ack`（または `ack <file>`）し、`clear`
- 同じ子への再委任は、送信が成功した時点で前の watcher を止めて置き換える。送信に失敗した（子が blocked など、exit 1）ときは前の watcher と委任時刻をそのまま残す
- 通知の 1 行と inbox のヘッダからは改行・制御文字を除く（子の名前や boss 名に混ざってもmanager の入力欄に複数行が入らない）

タスク終了時（manager）:

```bash
~/.claude/scripts/herdr-agent.sh inbox manager-<repo>          # 未読が残っていないか
~/.claude/scripts/herdr-agent.sh close child-a              # 子を閉じる（reap でまとめても可）
~/.claude/scripts/herdr-agent.sh inbox manager-<repo> clear    # 既読と watcher の残骸を消す
```

## 記録の帰属（owner と boss）

`herdr-cleanup.sh` は「誰が立ち上げた記録か」で片付ける範囲を決める。pane id は pane を閉じたり作り直したりすると引けなくなるので、記録には**後から名前で追える値**を残す。

用語は 3 つに分ける。**session** は Herdr の agent セッション（pane / tab で動くもの）、**owner** はその起動元の安定名、**chat** は人が向き合っている会話。cleanup の既定範囲は owner で決まり、chat では決まらない。

| フィールド | 書くもの | 書く場所 |
|---|---|---|
| `owner` | 起動元の**安定名** `agent:<name>`。名前が取れないときだけ `pane:<id>` | `herdr-agent.sh ensure`（状態ファイル・worktree レジストリ。external-review のセッションもここ） |
| `owner_pane` | `owner` を解決したときの生の pane id（照合・調査用） | 同上 |
| `boss` | 子が報告するmanager の名前 | `herdr-agent.sh delegate`（子の状態ファイルと worktree レジストリに追記） |

`boss` は**結果の受け取り手**を指す。同期で受ける `ask` / `external-review` は boss を書かない（回答はその場の stdout に返る）。

- 安定名の解決順: `$HERDR_AGENT_NAME` → `herdr agent get "$HERDR_PANE_ID"` の agent 名 → `pane:$HERDR_PANE_ID`。Herdr に繋がらないときは pane id に落ちる（`report` / `inbox` / cleanup のレポートは Herdr 無しでも動く）
- フィールドは追加だけ。`boss` の無い記録や、`owner` が `pane:<id>` の古い記録もそのまま読める

`herdr-cleanup.sh --owner` は `agent:NAME` / `pane:ID` / 素の `NAME`（= `agent:NAME`）を受け、次のどれかに当たる記録を自分の分とみなす（省略時はこの実行者（owner）の安定名）。

1. 記録の `owner` が一致する
2. 記録の `owner` が `pane:P` で、pane `P` の今の agent 名が `NAME`（名前が無かった頃の記録を拾う）
3. 記録の `boss` が `NAME`

manager の pane が消えた後に残りを追うときは、別の pane から `--owner boss-a` で引く（3 で拾える）。

2 で拾った記録は、pane id が使い回されると他人のものに当たりうるので、**閉じない**。行末に `via:pane-name` が付き、生きている記録はレポートだけ（`--include-live` でも閉じない）、実体の無い記録は記録ファイルだけ消して tab / pane には触らない。閉じたいときは `--owner pane:ID` を明示して 1 で拾わせる。3 で拾った記録には `via:boss` が付く。

行末の `via:pane-name(owner:pane:w1:p2)` は「記録の owner が `pane:w1:p2` で、その pane の今の名前で拾った」という意味。中身を確かめてから `--owner pane:w1:p2` に渡せば、owner 一致として閉じられる。

```bash
~/.claude/scripts/herdr-cleanup.sh --owner boss-a              # boss-a の記録（pane が消えていても boss で追える）
~/.claude/scripts/herdr-cleanup.sh --only inbox --boss boss-a  # boss-a の未読と .watch/ の残骸（読むだけ）
```

レポートの先頭行は `Scope: agent:boss-a (this owner; pane w1:p2, boss boss-a — …)` の形で、解決した安定名・pane id・inbox を見る boss を出す。各記録の行末には `boss:<name>`（無ければ `boss:-`）が付く。

`inbox (<boss>)` の節は未読ファイル名と件数、`.watch/` のロック・`.since`・ログを並べるだけで、**ack も削除もしない**。片付けは従来どおり `herdr-agent.sh inbox <boss> read` → `ack` → `clear`。boss は `--boss`、`$HERDR_BOSS`、`--owner` の名前（省略時は自分の安定名）の順で決まる。

## タスク境界のルール

セッション名・ブランチ名・workspace 名は [`naming.md`](naming.md) の規則に従う（`<種類>-<対象>[-<補足>]`、英小文字とハイフン）。以下のコマンドはその名前で対象を選ぶので、命名が揃っていないと**閉じ間違い・閉じ忘れ**が起きる。

1. **開始時**: 前のタスクのセッションが残っていたら閉じる（または `--new` で作り直す）

   ```bash
   ~/.claude/scripts/herdr-agent.sh list                      # 残っているセッションを確認
   ~/.claude/scripts/herdr-agent.sh reap                      # まとめて閉じる
   ```

2. **終了時**（完了報告を書く前）: そのタスクで開いたものを閉じる

   ```bash
   ~/.claude/scripts/herdr-agent.sh close <name>
   ```

3. **迷ったとき**: `--status` / `herdr-agent.sh list` を見て、`idle` のまま用のないものを閉じる

4. **同じタスクを 2 セッションでやらない**: TASK_FILE はブランチ単位で別ファイルになるので、記録だけでは重複を防げない。orchestrate は STEP 2 で **リース**を取り、取れなければ開始しない。

   ```bash
   ~/.claude/scripts/task-file.sh lock acquire --linear-id={LINEAR_ID} --feature={feature} --runner={claude|cursor|pi}
   ~/.claude/scripts/task-file.sh lock refresh --linear-id={LINEAR_ID} --runner={runner}   # 各 STEP で
   ~/.claude/scripts/task-file.sh lock release --linear-id={LINEAR_ID} --runner={runner}   # 終了時 / 中止時
   ~/.claude/scripts/task-file.sh lock show    --linear-id={LINEAR_ID}                    # 保持者の確認
   ```

   - リースは `~/.local/share/harness/locks/{repo}-{LINEAR_ID}.lock`（45 分で失効。**更新を怠ると別のランナーに奪われる**）
   - `acquire` が exit 1 なら、表示された保持者（runner / started / cwd / task_file）と経過時間をユーザーに報告して止まる。奪うのは `--takeover` を明示したときだけ
   - TASK_FILE を引き継ぐとき（追加修正・フェーズ指定）は `--task-file={TASK_FILE}` を付ける

## 安全策

- `--close` / `reap` は **自分が作った tab のときだけ** tab を閉じる（状態ファイルの `tab_owned`）。
  自分で作っていない tab を借りているセッションは pane だけ閉じ、呼び出し元の tab は残す
- ユーザーが手で開いた pane / tab は対象外（記録があるものしか触らない）
- herdr の `[session] resume_agents_on_restore` が有効だと、**サーバ再起動時にエージェントが復元**される。
  閉じたものが復活するのが困るなら設定で切る（常用セッションも復元されなくなる点に注意）

## コマンド対応表

| やりたいこと | コマンド |
|---|---|
| 相談して答えを受け取りたい（同期） | `external-review`（別ファミリ）/ manager に `ask` |
| 並行で走らせて報告で判断（非同期） | `herdr-agent.sh delegate` ＋ `close` / `reap` |
| 記録済みセッションの一覧 | `herdr-agent.sh list` |
| 1 つ閉じる | `herdr-agent.sh close NAME` |
| 全部閉じる | `herdr-agent.sh reap` |
| 記録を突き合わせて整理（推奨） | `herdr-cleanup.sh`（既定はレポート）/ `--apply`（確認）/ `--apply --yes`（了承後）/ `--apply --yes --include-live` |
| pane が消えた manager の記録を追う | `herdr-cleanup.sh --owner BOSS`（`boss` 一致でも拾う） |
| 未読の報告が溜まっていないか（読むだけ） | `herdr-cleanup.sh --only inbox [--boss BOSS]` |
| 種類で絞って閉じる | `herdr-agent.sh reap --kind pi` |
| 作り直す（文脈リセット） | `herdr-agent.sh restart NAME` |
| ターミナルの末尾を見る | `herdr-agent.sh read NAME` |
| 子に仕事を渡して戻る（manager） | `herdr-agent.sh delegate CHILD REQUEST --boss BOSS` |
| 子から報告する | `herdr-agent.sh report BOSS FILE --from CHILD`（`--kind question`） |
| inbox を見る / 読む / 既読にする / 掃除 | `herdr-agent.sh inbox [BOSS] [list\|read\|ack\|clear] [CHILD\|FILE]`（BOSS を省くと `--boss` / `HERDR_BOSS` / pane の名前） |
