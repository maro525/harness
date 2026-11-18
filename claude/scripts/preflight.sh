#!/usr/bin/env bash
# preflight — セッションの冒頭に 1 回だけ回す環境確認。
#
#   preflight.sh [repo]        # 既定は $PWD
#
# 目的: 「command -v tsc が無い」「node_modules が無い」「.env が無い」を
# 子が毎回 `command -v` / `ls node_modules/.bin` / `ls .env*` で確かめ直すのを
# やめる。足りない物を 1 画面に並べるだけで、exit は常に 0（呼び出し側を止めない）。
#
# 使い方（team-implement / team-review の依頼文に 1 行足す）:
#   ~/.claude/scripts/preflight.sh "$PWD"   # 結果を報告の `#### 前提（推定）` に残す

set -uo pipefail

repo=${1:-$PWD}
cd "$repo" 2>/dev/null || {
  echo "MISS repo      $repo（ディレクトリが無い）"
  exit 0
}

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'no git')
printf '# preflight %s (%s)\n' "$repo" "$branch"

# worktree か clone か（片方だけを掃除する事故を防ぐ）
if [[ -f .git ]]; then
  printf 'note worktree  %s\n' "$(sed -n 's/^gitdir: //p' .git)"
elif [[ -d .git ]]; then
  printf 'note clone     %s\n' "$(cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .git)" && pwd)"
fi

for c in node pnpm npm npx tsc vitest jest eslint prettier jq gh glab; do
  if command -v "$c" >/dev/null 2>&1; then
    printf 'ok   %-8s %s\n' "$c" "$(command -v "$c")"
  elif [[ -x "node_modules/.bin/$c" ]]; then
    printf 'ok   %-8s node_modules/.bin/%s\n' "$c" "$c"
  else
    printf 'MISS %-8s\n' "$c"
  fi
done

if [[ -d node_modules ]]; then
  echo 'ok   node_modules'
else
  echo 'MISS node_modules → pnpm install --frozen-lockfile'
fi

envs=$(ls -1d .env* 2>/dev/null || true)
if [[ -n "$envs" ]]; then
  printf 'ok   env        %s\n' "$(tr '\n' ' ' <<< "$envs")"
else
  echo 'note env        なし（DATABASE_URL などが要るコマンドは env を前置する）'
fi

dirty=$(git status --short 2>/dev/null | head -5)
if [[ -n "$dirty" ]]; then
  printf 'note dirty\n%s\n' "$dirty"
else
  echo 'ok   worktree clean'
fi
