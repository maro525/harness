#!/bin/bash
# Cross-repo reference check — harness -> dotfiles (one direction only).
#
# 前提（参照方向）:
#   harness は外部ワークフローとして後から足せるレイヤーで、dotfiles の存在を
#   知ってよい。逆に dotfiles は harness を知らない（dotfiles 単体で完結する）。
#   そのため相互参照の検査はすべてこのリポジトリ側に置き、dotfiles の
#   sync スクリプトからは呼ばない。
#
#   検査対象は ~/.claude / ~/.config/opencode を共有している都合で harness が
#   dotfiles 所有のファイルに依存している箇所だけ。dotfiles が見つからなければ
#   「検査対象なし」として成功扱いで終了する（dotfiles は必須ではない）。
#
# 検査する契約:
#   1. 節の実在 — `opencode/{commands,agents}/*.md` が `` `AGENTS.md` の「X」 ``
#      の形で参照する節 X は、dotfiles の `opencode/AGENTS.md` に `## X` として実在する
#   2. 下位項目の実在 — `` `AGENTS.md` の「X」の「Y」 `` の形で参照する項目 Y は、
#      dotfiles の X 節の中に実在する（バッククォート / 強調は無視して比較）
#   3. 共有ルールの必須項目 — X 節に harness が前提にしている語（下の REQUIRED）がある
#   4. 参照ファイルの実在 — dotfiles の `opencode/AGENTS.md` が `` `agents/x.md` `` /
#      `` `commands/x.md` `` の形で参照するファイルは、`opencode/` 配下に実在する
#
# Usage: checks/crossrefs.sh [dotfiles-path]
#   未指定なら $DOTFILES、$HOME/src/_dotfiles、<harness>/../_dotfiles の順に探す。
# Exit: 0 = ok（dotfiles 無しで skip した場合も 0） / 1 = 不整合

set -euo pipefail

HARNESS=$(cd "$(dirname "$0")/.." && pwd)

# X 節に必ず存在してほしい語（harness 側の手順が前提にしている共有ルール）
REQUIRED=(
  "ADAPTIVE EXECUTION:エスカレーション"
  "GIT RULES:保護ブランチ"
)

DOTFILES=${1:-${DOTFILES:-}}
if [[ -z "$DOTFILES" ]]; then
  for candidate in "$HOME/src/_dotfiles" "$HARNESS/../_dotfiles"; do
    if [[ -f "$candidate/opencode/AGENTS.md" ]]; then
      DOTFILES="$candidate"
      break
    fi
  done
fi

if [[ -z "$DOTFILES" || ! -f "$DOTFILES/opencode/AGENTS.md" ]]; then
  echo "crossrefs: skip（dotfiles が見つからない。引数か DOTFILES で指定すると検査する）"
  exit 0
fi

AGENTS="$DOTFILES/opencode/AGENTS.md"

fail=0
ng() {
  echo "NG: $*" >&2
  fail=1
}

# バッククォートと強調を落として比較用の文字列にする。
strip_marks() {
  tr -d '`*' <<< "$1"
}

# 節 X の本文（次の `## ` まで）を返す。
section_body() {
  awk -v h="## $1" '$0 == h { f = 1; next } f && /^## / { f = 0 } f' "$AGENTS"
}

# --- 1. 節の実在 -------------------------------------------------------------
refs=$(grep -rhoE 'AGENTS\.md` の「[^」]+」' "$HARNESS/opencode" || true)
if [[ -z "$refs" ]]; then
  ng "harness/opencode に \`AGENTS.md\` の「...」参照が見つからない（参照形式が変わった？）"
else
  while IFS= read -r section; do
    [[ -z "$section" ]] && continue
    grep -qxF "## $section" "$AGENTS" ||
      ng "節「## $section」が $AGENTS に無い（harness/opencode が参照している）"
  done < <(printf '%s\n' "$refs" | sed -E 's/.*「(.+)」$/\1/' | sort -u)
fi

# --- 2. 下位項目の実在 -------------------------------------------------------
nested=$(grep -rhoE 'AGENTS\.md` の「[^」]+」の「[^」]+」' "$HARNESS/opencode" || true)
if [[ -n "$nested" ]]; then
  while IFS=$'\t' read -r section item; do
    [[ -z "$section" || -z "$item" ]] && continue
    body=$(strip_marks "$(section_body "$section")")
    printf '%s\n' "$body" | grep -qF "$(strip_marks "$item")" ||
      ng "節「## $section」の中に項目「$item」が無い（harness/opencode が参照している）"
  done < <(printf '%s\n' "$nested" | while IFS= read -r line; do
    outer=$(sed -E 's/.*AGENTS\.md` の「([^」]+)」.*/\1/' <<< "$line")
    inner=$(sed -E 's/.*AGENTS\.md` の「[^」]+」の「([^」]+)」.*/\1/' <<< "$line")
    printf '%s\t%s\n' "$outer" "$inner"
  done | sort -u)
fi

# --- 3. 共有ルールの必須項目 -------------------------------------------------
for entry in "${REQUIRED[@]}"; do
  section=${entry%%:*}
  word=${entry#*:}
  if ! grep -qxF "## $section" "$AGENTS"; then
    ng "節「## $section」が $AGENTS に無い（harness が共有ルールとして前提にしている）"
    continue
  fi
  section_body "$section" | grep -qF "$(strip_marks "$word")" ||
    ng "節「## $section」に「$word」が無い（harness の手順が前提にしている）"
done

# --- 4. 参照ファイルの実在 ---------------------------------------------------
paths=$(grep -oE '`(agents|commands)/[A-Za-z0-9._-]+\.md`' "$AGENTS" || true)
if [[ -z "$paths" ]]; then
  ng "$AGENTS に \`agents/*.md\` / \`commands/*.md\` の参照が見つからない（参照形式が変わった？）"
else
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    [[ -f "$HARNESS/opencode/$path" ]] ||
      ng "$path が harness/opencode に無い（$AGENTS が参照している）"
  done < <(printf '%s\n' "$paths" | tr -d '`' | sort -u)
fi

if [[ $fail -eq 0 ]]; then
  echo "crossrefs: ok (harness -> $DOTFILES)"
  exit 0
fi

echo "crossrefs: 不整合あり。dotfiles 側 (opencode/AGENTS.md) か harness 側の参照を直す。" >&2
exit 1
