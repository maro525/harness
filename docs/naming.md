# 名前のルール（セッション / ブランチ / workspace）

Herdr のセッション名は **agent 名・tab 名・（worktree のときは）workspace 名** にそのまま使われる。あとから `herdr-agent.sh list` や `close` で探すときの手がかりになるので、次の規則で統一する。

## 1. 基本形

```
<種類>-<対象>[-<補足>]
```

- 文字は **英小文字・数字・ハイフン**（`[a-z0-9-]`）。大文字は使わない（ID は小文字化する）
- 空白と `/` は**禁止**（`herdr-agent.sh` が拒否する）
- 長さは **32 文字以内**（超えると警告）
- 単語は `-` でつなぐ。先頭・末尾に `-` を置かない

## 2. 種類ごとの形式

| 対象 | 形式 | 例 |
|---|---|---|
| consult（旧 consult.sh のセッション。新規には作られない） | `consult` / `consult-<role>` / `consult-codex[-<role>]` | `consult-review`, `consult-codex` |
| external-review（別ファミリの独立レビュー。Herdr の 1 セッション） | `<kind>-review-<id>` | `codex-review-nsketch-1983`, `pi-review-1983` |
| 並列 orchestrate | `orchestrate-<linear-id 小文字>[-<feature>]` | `orchestrate-nsketch-1983` |
| issue 無しの orchestrate | `orchestrate-noissue-<feature>` | `orchestrate-noissue-quick-fix` |
| delegate の子 | `<claude\|codex\|pi>-<purpose>` | `claude-review-1983`, `codex-research-cache` |
| manager（PM の技術の脳。常に `~/src` で動く） | `manager-<label>[-<suffix>]`（`<label>` は既定で呼び出し元のリポジトリ名、`--label` で指定） | `manager-nanco-next`, `manager-nanco-next-9305` |
| 子 manager（manager が `--parent` で起こす。複数可） | `manager-<label>[-<suffix>]`（`<label>` は `--label` で必ず指定。親の名前は入らない） | `manager-api`, `manager-web-4f2a` |
| PM（pm-mode） | `pm-<repo>[-<suffix>]` | `pm-nanco-next`, `pm-nanco-next-9305`（manager の suffix を引き継ぐ） |
| 実作業の子（`herdr-agent.sh worker`） | `<kind>-<purpose>`（manager が付ける。worktree に入っても名前は同じ） | `claude-review-1983`, `pi-seo-doc` |
| 相談・配布以外の一時セッション | `<kind>-<purpose>-<短い id>` | `pi-repro-4f2a` |

external-review のセッション名には CLI 名（`codex`、`pi`、`claude`）を入れる。同じ issue を複数のファミリに読ませたとき、sidebar で並べて見分けられる。

### 32 文字の扱い

Herdr の上限は 32 文字。`orchestrate-<id>-<feature>` が超えるときは **feature を先に落とす**（`orchestrate-nsketch-1983`）。それでも超えるなら末尾の単語単位で切る。

`manager-<label>-<suffix>` は `-` と 4 桁の suffix が入るので、リポジトリ名から作るときは label 部分を 19 文字で切る（`herdr-agent.sh manager` がやる。切った名前は自分で組み立てない）。**`--label` で渡したものは切らない** — そのまま名前になるので、`-<suffix>` の余地を残して 19 文字以内にする（name 自体が 32 文字を超えるラベルはエラーになる）。子 manager のラベルも同じ扱い（切らない）。

## 3. ブランチ

| 用途 | 形式 | 例 |
|---|---|---|
| orchestrate（並列含む） | `feature/<linear-id 小文字>-<slug>` | `feature/nsketch-1983-ci-cache` |
| issue 無し | `feature/<slug>` | `feature/quick-fix` |
| delegate / worktree を手で切るとき | `<type>/<slug>`（`type` は `feature` / `fix` / `chore` / `docs`） | `fix/flutter-model-path-filter` |
| `ensure --topology worktree` で `--branch` を省いたとき（`worker` も同じ） | **`feature/<セッション名>`**（スクリプトの既定） | `feature/claude-help-page-access` |

- **Linear ID はブランチ名に小文字で入れる**（deploy が紐づけを確認する）
- ブランチ名は `orchestrate-parallel.sh` が `feature/` ＋ ID ＋ slug で自動生成する。変えたいときは `--prefix`
- worktree のパスは Herdr が `~/.herdr/worktrees/<repo>/<branch の / を - にしたもの>` に作る（名前は決め打ちできない）
- **`herdr/` と `cursor/` の接頭辞は使わない。** `herdr/` は Herdr 自身の worktree 既定（`worktree/<ランダム>`）と混同しやすく、`cursor/` は実行者ごとに増えてしまう。スクリプトは `--branch` にこの 2 つが来たら警告する
- **既存の `herdr/*` は移行しない（決定）。** `nanco-next` の `herdr/help-*-3140`（32 本、うち 29 本は push 済み）はそのまま残し、**新規だけ `feature/*`** にする。worktree がチェックアウト中だと `git branch -m` できず、push 済みブランチの改名は MR の参照も張り替える必要があるため

## 4. その他の記録物

| 対象 | 形式 | 例 |
|---|---|---|
| TASK_FILE | `task-<LINEAR_ID\|NOLINEAR>-<feature>.md` | `task-NSKETCH-1983-ci-cache.md` |
| 実行ロック | `<repo>-<LINEAR_ID>.lock` / `<repo>-task-<feature>.lock` / `<repo>-repo.lock` | `nanco-next-NSKETCH-1983.lock` |
| inbox | `~/.cache/harness/inbox/<boss>/` | `~/.cache/harness/inbox/manager-nanco-next/` |
| 回答ファイル（相談） | `external-review` は `ask --answer-file` に渡したパス / `external-ask.sh` は `$TMPDIR/external-ask-<target>-<timestamp>.md` | — |

TASK_FILE とロックは **ID を大文字のまま**使う（ブランチだけ小文字）。既存の `task-file.sh` / `lock` の挙動に合わせている。

状態ファイル（`~/.cache/harness/herdr-agents/<name>.json`）には `session`（起こしたセッション。`pane:<pane id>` か `proc:<pid>:<starttime>`）と `manager_repo`（その manager が担当するリポジトリの直下。manager は常に `~/src`）が入る。`herdr-agent.sh manager` はこの 2 つで「同じセッションの manager か、別セッションの manager か」を判定する。session の無い古い記録は、最初に呼んだセッションが引き継ぐ（タグを付ける。ただし `~/src` の外に居る古い manager は引き継がない）。

子 manager の記録はさらに 3 つを持つ。`parent`（起こした manager の名前）、`boss`（報告先。`parent` と同じで `delegate` / watcher / `herdr-cleanup.sh` が読む）、`depth`（0 = PM 直下、1 = その子。`HARNESS_MANAGER_MAX_DEPTH`、既定 3 段まで）。**`parent` の無い manager 記録が PM 直下**で、セッションによる再利用の対象になる。

## 5. 誰が守るか

| 場面 | 守る仕組み |
|---|---|
| `herdr-agent.sh ensure` / `restart` / `delegate` | 名前を検証する。空白・`/` はエラー、小文字でない・32 文字超は警告 |
| `herdr-agent.sh manager` | manager の名前を自分で決める（常に `~/src` の tab。名前が埋まっていれば `-<suffix>`）。`--label` で指定できるのは対象だけ（居場所・topology・suffix はスクリプトが決める）。`--parent <manager>` は子 manager を作る（`--label` 必須、深さは `HARNESS_MANAGER_MAX_DEPTH` まで） |
| `herdr-agent.sh worker` | 実作業の子の居場所を決める（checkout が空いていれば tab、作業中の子が居れば worktree） |
| `herdr-agent.sh ensure`（external-review） | セッション名は呼び出し側が決める（`<kind>-review-<id>`）。`ask --answer-file` で同期に受ける |
| `orchestrate-parallel.sh` | `orchestrate-<id>[-<feature>]` と `feature/<id>-<feature>` を自動生成 |
| 手で `ensure` するとき | この文書の表に従う |

## 6. なぜ決めるか

- `herdr-agent.sh list` / `close` / `reap` は名前で対象を選ぶ。命名が揺れると**消し間違い・閉じ忘れ**が起きる
- worktree の workspace 名と tab 名がセッション名と揃うと、Herdr のサイドバーで「どのタスクの作業か」が一目で分かる
- ブランチに小文字の ID を入れておくと、deploy の紐づけ確認（`branch:` と `Meta` の `linear_id:`）が機械的に通る
