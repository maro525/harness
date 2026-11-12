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
| consult（claude） | `hc-<role>` / 追加は `hc-<role>-<topic>` | `hc-consult`, `hc-review`, `hc-consult-ci` |
| consult（codex） | `hx-<role>` / `hx-<role>-<topic>` | `hx-consult`, `hx-review` |
| 並列 orchestrate | `orch-<linear-id 小文字>[-<feature>]` | `orch-nsketch-1983-ci-cache` |
| issue 無しの orchestrate | `orch-noissue-<feature>` | `orch-noissue-quick-fix` |
| delegate の子 | `<claude\|codex\|pi>-<purpose>` | `claude-review-1983`, `codex-research-cache` |
| boss | `boss-<repo>` | `boss-nanco-next` |
| 相談・配布以外の一時セッション | `<kind>-<purpose>-<短い id>` | `pi-repro-4f2a` |

`<role>` は `consult` / `review` / `implement` のいずれか（`consult.sh` のロール名と一致させる）。

## 3. ブランチ

| 用途 | 形式 | 例 |
|---|---|---|
| orchestrate（並列含む） | `feature/<linear-id 小文字>-<slug>` | `feature/nsketch-1983-ci-cache` |
| issue 無し | `feature/<slug>` | `feature/quick-fix` |
| delegate / worktree を手で切るとき | `<type>/<slug>`（`type` は `feature` / `fix` / `chore` / `docs`） | `fix/flutter-model-path-filter` |

- **Linear ID はブランチ名に小文字で入れる**（deploy が紐づけを確認する）
- ブランチ名は `orchestrate-parallel.sh` が `feature/` ＋ ID ＋ slug で自動生成する。変えたいときは `--prefix`
- worktree のパスは Herdr が `~/.herdr/worktrees/<repo>/<branch の / を - にしたもの>` に作る（名前は決め打ちできない）

## 4. その他の記録物

| 対象 | 形式 | 例 |
|---|---|---|
| TASK_FILE | `task-<LINEAR_ID\|NOLINEAR>-<feature>.md` | `task-NSKETCH-1983-ci-cache.md` |
| 実行ロック | `<repo>-<LINEAR_ID>.lock` / `<repo>-task-<feature>.lock` / `<repo>-repo.lock` | `nanco-next-NSKETCH-1983.lock` |
| inbox | `~/.cache/harness/inbox/<boss>/` | `~/.cache/harness/inbox/boss-nanco-next/` |
| 回答ファイル（相談） | `<prompt 名>.answer.md` / インラインは `$TMPDIR/harness-consult/out/<target>-consult-<timestamp>.answer.md` | — |

TASK_FILE とロックは **ID を大文字のまま**使う（ブランチだけ小文字）。既存の `task-file.sh` / `lock` の挙動に合わせている。

## 5. 誰が守るか

| 場面 | 守る仕組み |
|---|---|
| `herdr-agent.sh ensure` / `restart` / `delegate` | 名前を検証する。空白・`/` はエラー、小文字でない・32 文字超は警告 |
| `consult.sh` | `hc-<role>` / `hx-<role>` を自動で作る（`--name` で上書き可） |
| `orchestrate-parallel.sh` | `orch-<id>-<feature>` と `feature/<id>-<feature>` を自動生成 |
| 手で `ensure` するとき | この文書の表に従う |

## 6. なぜ決めるか

- `herdr-agent.sh list` / `close` / `reap` は名前で対象を選ぶ。命名が揺れると**消し間違い・閉じ忘れ**が起きる
- worktree の workspace 名と tab 名がセッション名と揃うと、Herdr のサイドバーで「どのタスクの作業か」が一目で分かる
- ブランチに小文字の ID を入れておくと、deploy の紐づけ確認（`branch:` と `Meta` の `linear_id:`）が機械的に通る
