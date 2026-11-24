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
| boss の子（`herdr-agent.sh delegate`） | 司令塔が最初の仕事を渡すとき（`ensure` → `delegate`） | 報告を `ack` した後、その子に続きを渡さないと決めたとき |

`consult` だけは既定で残す（同じ相談者に文脈を保ってほしい場面があるため）。
使い捨てでよいと分かっているときは `--close` を付けて 1 回で閉じる。

## どこに開くか（topology）

Herdr の構造は workspace → tab → pane。セッションをどこに作るかは `herdr-agent.sh ensure` の `--topology` で選ぶ（`claude-consult.sh` / `codex-consult.sh` は常に `tab`）。

**エージェントを動かすセッションは必ず Herdr の中で立てる。** `tmux` / `screen` / `nohup` / `claude --bg` などの Herdr 外の手段は使わない — 記録が残らず、`--status` / `close` / `herdr-cleanup.sh` の対象外になる。Herdr が使えないときは止まって確認し、一回きりの文章作成だけ `consult.sh --to pi` を使う。

相談先は 2 つで、実装は同じ `consult.sh`（`--to claude|codex`）。以下の `claude-consult.sh` は、Codex を相談先にするとき `codex-consult.sh` に読み替えればそのまま使える。Herdr の agent 名は claude が `consult` / `consult-<role>`、codex が `consult-codex` / `consult-codex-<role>` なので、両方を並べて残せる（引数なしの `--close` は両方閉じる）。

| topology | 何ができる | 向いている場面 |
|---|---|---|
| `tab`（既定） | 呼び出し元の workspace に新しい tab | 同じリポジトリの作業を並行する。今の workspace を汚さない |
| `workspace` | そのリポジトリ専用の workspace（tab と pane 付き） | **別のリポジトリ**を任せるとき。workspace ごとにサイドバーで分離される（git は触らない） |
| `worktree` | git worktree を作り、その workspace と tab で起動（パスは `~/.herdr/worktrees/{repo}/{branch}`） | 同じリポジトリでタスクを隔離したいとき。ブランチも切られる（`--branch` / `--base`） |

- `tab` は**呼び出し元の workspace id を必要とする**（`HERDR_WORKSPACE_ID`）。無い・古い場合は `workspace create` に自動フォールバックする
- `workspace` / `worktree` で作った workspace は**このツールが所有**するので、`close` で workspace ごと閉じる
- `worktree` のセッションは `close` で **worktree も削除**する（`herdr worktree remove`。`--force` は使わないので、未コミットの変更があれば workspace だけ閉じて警告する）。**ブランチは残る**（成果物なので意図的）
- 手で作った workspace / tab / worktree は絶対に閉じない（所有フラグで判定）
- **手で `git worktree add` するときも置き場所は同じ**（`$HOME/.herdr/worktrees/{repo}/{branch}`）。`../<repo>-<task>` のような相対パスで切ると、`herdr-cleanup.sh` の対象外になって残骸が溜まる（`checks/worktrees.sh` が警告する）

## inbox と watcher のライフサイクル（司令塔パターン）

司令塔（`herdr-boss` skill）は子の完了を待たない。子 → 司令塔の報告は **inbox ファイル（正本）+ 通知（ヒント）** の 2 段で届く。

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

- 通知は `herdr agent prompt <boss>` の 1 行（`報告あり（child-a）: <path>`）。boss が agent でない・blocked のときは `herdr notification show`、Herdr に繋がらないときは stderr の warning だけ。**どの場合も inbox には残る**ので、司令塔は節目に `inbox <boss>` を見る
- `clear` は**未読を消さない**。読まずに捨てたいときは `read` してから `ack`（または `ack <file>`）し、`clear`
- 同じ子への再委任は、送信が成功した時点で前の watcher を止めて置き換える。送信に失敗した（子が blocked など、exit 1）ときは前の watcher と委任時刻をそのまま残す
- 通知の 1 行と inbox のヘッダからは改行・制御文字を除く（子の名前や boss 名に混ざっても司令塔の入力欄に複数行が入らない）

タスク終了時（司令塔）:

```bash
~/.claude/scripts/herdr-agent.sh inbox boss-<repo>          # 未読が残っていないか
~/.claude/scripts/herdr-agent.sh close child-a              # 子を閉じる（reap でまとめても可）
~/.claude/scripts/herdr-agent.sh inbox boss-<repo> clear    # 既読と watcher の残骸を消す
```

## 記録の帰属（owner と boss）

`herdr-cleanup.sh` は「誰が立ち上げた記録か」で片付ける範囲を決める。pane id は pane を閉じたり作り直したりすると引けなくなるので、記録には**後から名前で追える値**を残す。

用語は 3 つに分ける。**session** は Herdr の agent セッション（pane / tab で動くもの）、**owner** はその起動元の安定名、**chat** は人が向き合っている会話。cleanup の既定範囲は owner で決まり、chat では決まらない。

| フィールド | 書くもの | 書く場所 |
|---|---|---|
| `owner` | 起動元の**安定名** `agent:<name>`。名前が取れないときだけ `pane:<id>` | `herdr-agent.sh ensure`（状態ファイル・worktree レジストリ）/ `consult.sh`（状態ファイル） |
| `owner_pane` | `owner` を解決したときの生の pane id（照合・調査用） | 同上 |
| `boss` | 子が報告する司令塔の名前 | `herdr-agent.sh delegate`（子の状態ファイルと worktree レジストリに追記）/ `consult.sh`（`$HERDR_BOSS`、無ければ起動元の安定名。どちらも無ければ書かない） |

`boss` はどちらの記録でも**結果の受け取り手**を指す。`herdr-agent.sh` では delegate した司令塔（報告の宛先）、`consult.sh` では回答を受け取る起動元で、意味は同じ「報告先」。

- 安定名の解決順: `$HERDR_AGENT_NAME` → `herdr agent get "$HERDR_PANE_ID"` の agent 名 → `pane:$HERDR_PANE_ID`。Herdr に繋がらないときは pane id に落ちる（`report` / `inbox` / cleanup のレポートは Herdr 無しでも動く）
- フィールドは追加だけ。`boss` の無い記録や、`owner` が `pane:<id>` の古い記録もそのまま読める

`herdr-cleanup.sh --owner` は `agent:NAME` / `pane:ID` / 素の `NAME`（= `agent:NAME`）を受け、次のどれかに当たる記録を自分の分とみなす（省略時はこの実行者（owner）の安定名）。

1. 記録の `owner` が一致する
2. 記録の `owner` が `pane:P` で、pane `P` の今の agent 名が `NAME`（名前が無かった頃の記録を拾う）
3. 記録の `boss` が `NAME`

司令塔の pane が消えた後に残りを追うときは、別の pane から `--owner boss-a` で引く（3 で拾える）。

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
| 相談して答えを受け取りたい（同期） | `claude-consult.sh` / `codex-consult.sh --role {role}` |
| 並行で走らせて報告で判断（非同期） | `herdr-agent.sh delegate` ＋ `close` / `reap` |
| 記録済みセッションの一覧 | `claude-consult.sh --status` / `herdr-agent.sh list` |
| 1 つ閉じる | `claude-consult.sh --close --role ROLE` / `herdr-agent.sh close NAME` |
| 複数ロールを閉じる | `claude-consult.sh --close --roles implement,review` |
| 全部閉じる | `claude-consult.sh --close` / `herdr-agent.sh reap` |
| 記録を突き合わせて整理（推奨） | `herdr-cleanup.sh`（既定はレポート）/ `--apply`（確認）/ `--apply --yes`（了承後）/ `--apply --yes --include-live` |
| pane が消えた司令塔の記録を追う | `herdr-cleanup.sh --owner BOSS`（`boss` 一致でも拾う） |
| 未読の報告が溜まっていないか（読むだけ） | `herdr-cleanup.sh --only inbox [--boss BOSS]` |
| 種類で絞って閉じる | `herdr-agent.sh reap --kind pi` |
| 作り直す（文脈リセット） | `claude-consult.sh --new --role ROLE` / `herdr-agent.sh restart NAME` |
| ターミナルの末尾を見る | `claude-consult.sh --show ROLE` / `herdr-agent.sh read NAME` |
| 子に仕事を渡して戻る（司令塔） | `herdr-agent.sh delegate CHILD REQUEST --boss BOSS` |
| 子から報告する | `herdr-agent.sh report BOSS FILE --from CHILD`（`--kind question`） |
| inbox を見る / 読む / 既読にする / 掃除 | `herdr-agent.sh inbox [BOSS] [list\|read\|ack\|clear] [CHILD\|FILE]`（BOSS を省くと `--boss` / `HERDR_BOSS` / pane の名前） |
