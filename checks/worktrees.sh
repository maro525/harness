#!/bin/bash
# worktree check — 子の作業ツリーを 1 箇所に保つ。
#
# 背景: エージェントが `git worktree add ../nanco-next-audit` のように相対パスで
# 切ると、`~/.herdr/worktrees/` の外に作業ツリーが増える。すると
#   - herdr-cleanup.sh が残骸として拾えない（registry は herdr が作った分だけ）
#   - harness-daily.py の親/子の判定がパス依存だと誤る（今は git の印で判定する）
# ので、手順書に相対パスの書き方が現れたら NG にする。
#
#   1. agents/skills, claude/commands, claude/rules, docs の `git worktree add` が
#      $HOME / ~ / 絶対パス以外を指していたら NG
#   2. ~/.herdr/worktrees の外にある linked worktree を一覧する（警告のみ）
#
# Usage: checks/worktrees.sh
# Exit: 0 = ok（管理外があっても 0） / 1 = 手順書に相対パスがある

set -uo pipefail

HARNESS=$(cd "$(dirname "$0")/.." && pwd)
fail=0

texts=(
  "$HARNESS/agents/skills"
  "$HARNESS/claude/commands"
  "$HARNESS/claude/rules"
  "$HARNESS/docs"
)

hits=$(grep -rn 'git worktree add' "${texts[@]}" 2>/dev/null || true)
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  arg=${line#*git worktree add}
  case "$arg" in
    *'$HOME'* | *'~/'* | *'/.herdr/worktrees'* | *'/home/'* ) ;;
    *)
      echo "NG: worktree を相対パスで作る手順がある（~/.herdr/worktrees/{repo}/{branch} に固定する）" >&2
      echo "    $line" >&2
      fail=1
      ;;
  esac
done <<< "$hits"

root="$HOME/.herdr/worktrees"
found=0
list=""
for gitfile in "$HOME"/src/*/.git "$HOME"/src/*/*/.git "$HOME"/test/*/.git; do
  [[ -f "$gitfile" ]] || continue
  wt=${gitfile%/.git}
  case "$wt" in
    "$root"/*) continue ;;
  esac
  found=$((found + 1))
  list+="$wt"$'\t'"$(sed -n 's/^gitdir: //p' "$gitfile")"$'\n'
done
if [[ $found -gt 0 ]]; then
  # 新しい順に 10 本だけ出す（古いものはまとめて数える）
  while IFS=$'\t' read -r wt gitdir; do
    echo "警告: 管理外 worktree ${wt/#$HOME/~}（$gitdir）"
  done < <(printf '%s' "$list" | while IFS=$'\t' read -r wt gitdir; do
    [[ -n "$wt" ]] && printf '%s\t%s\t%s\n' "$(stat -c %Y "$wt" 2>/dev/null || echo 0)" "$wt" "$gitdir"
  done | sort -rn | head -10 | cut -f2-)
  echo "警告: 管理外 worktree が ${found} 本ある。herdr-cleanup.sh の対象外なので、片付けるか ~/.herdr/worktrees の下へ移す。"
else
  echo "worktrees: ok（~/.herdr/worktrees の外に worktree は無い）"
fi

if [[ $fail -eq 0 ]]; then
  echo "worktrees: ok（手順書の worktree パスは固定されている）"
  exit 0
fi
exit 1
