#!/bin/bash
# Cross-repo reference check — maro525/harness <-> maro525/_dotfiles.
#
# この 2 つのリポジトリは ~/.claude と ~/.config/opencode を共有しているが、
# ファイルの所有者が違うため「どちらがどちらを参照しているか」は名前でしか
# 結ばれていない。節名やファイル名を変えると相手側が静かに壊れるので、
# ここで機械的に検査する（CI は無いので sync-*.sh から呼ぶ）。
#
# 契約:
#   1. harness/opencode/{commands,agents}/*.md が `AGENTS.md` の「X」の形で
#      参照する節 X は、dotfiles の opencode/AGENTS.md に `## X` として実在する
#   2. dotfiles の opencode/AGENTS.md が `agents/x.md` / `commands/x.md` の形で
#      参照するファイルは、harness/opencode/ 配下に実在する
#   3. dotfiles の opencode/AGENTS.md が harness の claude/rules/*.md を要約して
#      いる節には `正:` の注記がある（正は harness 側。dotfiles は要約）
#
# Usage: checks/crossrefs.sh [dotfiles-path]
#   未指定なら $DOTFILES、$HOME/src/_dotfiles、<harness>/../_dotfiles の順に探す。
#   dotfiles 側の sync-opencode.sh からは引数で dotfiles のパスを渡す。
#
# Exit: 0 = ok / 1 = 不整合 / 2 = dotfiles が見つからない

set -euo pipefail

HARNESS=$(cd "$(dirname "$0")/.." && pwd)

DOTFILES=${1:-${DOTFILES:-}}
if [[ -z "$DOTFILES" ]]; then
  for candidate in "$HOME/src/_dotfiles" "$HARNESS/../_dotfiles"; do
    if [[ -f "$candidate/opencode/AGENTS.md" ]]; then
      DOTFILES="$candidate"
      break
    fi
  done
fi

AGENTS="${DOTFILES:-}/opencode/AGENTS.md"
if [[ -z "$DOTFILES" || ! -f "$AGENTS" ]]; then
  echo "crossrefs: dotfiles の opencode/AGENTS.md が見つからない（引数か DOTFILES で指定する）" >&2
  exit 2
fi

fail=0
ng() {
  echo "NG: $*" >&2
  fail=1
}

# --- 1. harness -> dotfiles: 節名の解決 -------------------------------------
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

# --- 2. dotfiles -> harness: ファイル名の解決 -------------------------------
paths=$(grep -oE '`(agents|commands)/[A-Za-z0-9._-]+\.md`' "$AGENTS" || true)
if [[ -z "$paths" ]]; then
  ng "$AGENTS に \`agents/*.md\` / \`commands/*.md\` 参照が見つからない（参照形式が変わった？）"
else
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    [[ -f "$HARNESS/opencode/$path" ]] ||
      ng "$path が harness/opencode に無い（$AGENTS が参照している）"
  done < <(printf '%s\n' "$paths" | tr -d '`' | sort -u)
fi

# --- 3. 要約節に「正:」の注記があるか ---------------------------------------
for entry in \
  "ADAPTIVE EXECUTION:claude/rules/adaptive-execution.md" \
  "GIT RULES:claude/rules/tool-routing.md"; do
  section=${entry%%:*}
  source_file=${entry#*:}

  if ! grep -qxF "## $section" "$AGENTS"; then
    ng "節「## $section」が $AGENTS に無い（要約の対象として期待されている）"
    continue
  fi

  body=$(awk -v h="## $section" '$0 == h { f = 1; next } f && /^## / { f = 0 } f' "$AGENTS")
  if ! printf '%s\n' "$body" | grep -q '正:'; then
    ng "節「## $section」に「正: $source_file」の注記が無い（二重管理の向きが不明）"
  fi
done

if [[ $fail -eq 0 ]]; then
  echo "crossrefs: ok (harness <-> $DOTFILES)"
  exit 0
fi

echo "crossrefs: 不整合あり。dotfiles 側 (opencode/AGENTS.md) と harness 側の参照を突き合わせて直す。" >&2
exit 1
