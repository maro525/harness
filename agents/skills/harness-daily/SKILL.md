---
name: harness-daily
description: 1 日の振り返り。その日のセッション（親 / 子）、司令塔が実行したコマンド、子が実行したコマンド、失敗、役割の逸脱（親が子の仕事をした箇所）、委譲比率、片付いていない残骸を突き合わせ、次の日の改善を 3 つ以内で提案する。Use when the user asks for a retrospective, a daily or weekly review, "昨日どうだった", "振り返りして", or "retro".
metadata:
  kind: review
  writes: "none in the repo (reads the transcripts; writes nothing)"
---

# harness-daily

「今日の振り返り」「昨日どうだった」「この 1 週間どうだった」で使う。数字は `~/.claude/scripts/harness-daily.py` が出す。**そのまま貼らず、意味を読んで解釈する。**

## 手順

```bash
~/.claude/scripts/harness-daily.py                    # 今日（JST）
~/.claude/scripts/harness-daily.py --date 2026-11-18
~/.claude/scripts/harness-daily.py --days 7           # 直近 7 日
~/.claude/scripts/harness-daily.py --repo nanco-next  # リポジトリで絞る
```

1. まず**全体**（`--days 1`）を出し、対象が多すぎる（セッション 30 件超・逸脱 100 件超）なら `--repo` で絞って出し直す
2. 数字を読む（下の「読み方」）
3. **改善を 3 つ以内**に絞って提示する（実行可能な粒度で。例「テストは子に渡す」「`/tmp` の依頼文は親のままでよい」）

## 読み方

| セクション | 何を見るか |
|---|---|
| **セッション** | 親（cwd がリポジトリ）と子（cwd が `/.herdr/worktrees/`）。子が 0 なら委譲していない |
| **失敗したコマンド** | exit ≠ 0 / `error`。同じ失敗の繰り返しは手順か環境の問題。MCP の失敗は exit 無しの `error` で出る |
| **役割の逸脱** | 親が「リポジトリの編集・テスト/ビルド/lint・git 書き込み・PR 作成」をした件数。**`/tmp` の依頼文・PR 本文は逸脱ではない**（PM の仕事）。1 セッションに集中していたら、そのセッションの進め方の問題 |
| **指示フローの効率** | 委譲比率（子 / 全体）は 50% 以上が目安。`ensure`/`delegate`/`consult` が 0 なら全部自分でやっている。繰り返し（`git status` ×12 など）は手順の無駄 |
| **文章（下書き）** | `draft.sh`（gemini）で下書きした件数と、対外文書（Linear / PR / MR / コミット）を書いた操作の比。下書きが 0 のまま対外文書が多いなら、規則（`tool-routing.md`「対外文書の下書き」）が使われていない |
| **残骸** | セッション記録 / worktree / ロック（＋管理外 worktree とロック履歴）。0 でなければ `herdr-cleanup.sh` を案内する（**`--apply` はユーザーの了承後だけ**）。管理外（`~/.herdr/worktrees` の外）は cleanup が拾わないので、場所を直す話として別に書く。ロック履歴（`*.lock.guard`）は flock 用の 0 バイトで状態ではないので、残骸として数えず「タスク数」として読む |

## 出す形

```
■ サマリ（数字は 3〜4 個。全部並べない）
■ よかった点（子に渡せていた、失敗が少ない、等）
■ 直すところ（逸脱・失敗・繰り返しから 1〜2 個。原因も一言）
■ 次の日にやること（3 つ以内。実行可能な形で）
```

- **数字を捏造しない**（スクリプトに出ていない件数を書かない）
- 逸脱は**文脈で判断する**: 依頼文の作成、PR 本文、読み取り（`git status` / `gh pr view`）、`/tmp` への書き出しは親の仕事
- 子の失敗を責めない。**依頼文の不足**（完了条件・触ってよいパスが曖昧）を疑う
- 1 日で傾向が出ないときは `--days 7` で見る。単発の失敗を傾向として扱わない

## やらないこと

- 残骸を勝手に消さない（`herdr-cleanup.sh` は既定がレポート、`--apply` は了承後）
- スクリプトや transcript を書き換えない
- 「もっと委譲しましょう」だけで終わらせない（**どの作業を・どの子に・どう渡すか**まで書く）
