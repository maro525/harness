#!/usr/bin/env bash
# draft.sh — 対外文書の下書きを gemini に 1 回だけ投げる薄いラッパー。
#
#   draft.sh --kind=pr|comment|commit|section|reply [--material FILE] [--out FILE]
#   cat notes.md | draft.sh --kind=commit
#
# 目的: `consult.sh --to pi -m google/gemini-4-carbon - <<'EOF' ... EOF` を毎回
# 手で書かせない（heredoc・モデル名・空出力の検査をここに閉じる）。
#
#   stdout : 下書きの本文（そのまま貼れる）
#   stderr : ANSWER_FILE=<path> / 文面: pi/google/gemini-4-carbon
#   exit   : 0 = 書けた / 1 = 失敗（空出力・quota・timeout）/ 2 = 使い方
#
# 失敗しても ai-fallback.sh へ勝手に落ちない（下書きを別モデルが書いたことを
# 記録できなくなる）。呼び出し側が代替を使い、`利用AI:` に codex/… と書く。

set -uo pipefail

PROG=$(basename "$0")
CONSULT="${CONSULT_SH:-$HOME/.claude/scripts/consult.sh}"
MODEL_DEFAULT="google/gemini-4-carbon"

die() {
  echo "$PROG: $*" >&2
  exit 2
}

usage() {
  cat <<'EOF'
usage: draft.sh --kind=KIND [--material FILE] [--out FILE] [--model MODEL]

  --kind       pr | comment | commit | section | reply（必須）
  --material   材料。省略すると標準入力から読む（空なら exit 2）
  --out        下書きの置き場所（既定: $TMPDIR/draft-KIND-<日時>.md）
  --model      既定 google/gemini-4-carbon

  stdout に本文、stderr に ANSWER_FILE と「文面: pi/<model>」を出す。
EOF
}

kind="" material="" out="" model="$MODEL_DEFAULT"
for arg in "$@"; do
  case "$arg" in
    --kind=*) kind=${arg#*=} ;;
    --material=*) material=${arg#*=} ;;
    --out=*) out=${arg#*=} ;;
    --model=*) model=${arg#*=} ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $arg（--help を見る）" ;;
  esac
done

[[ -n "$kind" ]] || die "--kind is required（pr|comment|commit|section|reply）"
[[ -x "$CONSULT" ]] || die "consult.sh not found: $CONSULT"
command -v pi >/dev/null 2>&1 || die "pi is not installed（gemini は pi 経由で走る）"

case "$kind" in
  pr) what="PR / MR の本文。見出しは ## を使い、「何をしたか / 確かめたこと / 影響・注意」の順に書く" ;;
  comment) what="Linear のコメント（または issue の description）。要点を 3〜6 行で、根拠と次の手を書く" ;;
  commit) what="コミットメッセージ。1 行目は 50 文字以内の命令形（prefix は材料の慣習に合わせる）、必要なら空行を挟んで本文" ;;
  section) what="TASK_FILE に書き込む Markdown の節。見出しは材料の構成に合わせる" ;;
  reply) what="レビューコメントへの返信。丁寧だが簡潔に、変更点と根拠を書く" ;;
  *) die "unknown --kind: $kind（pr|comment|commit|section|reply）" ;;
esac

src=""
if [[ -n "$material" ]]; then
  [[ -f "$material" ]] || die "material not found: $material"
  src="$material"
elif [[ -t 0 ]]; then
  die "材料が無い（--material FILE か標準入力で渡す）"
fi

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/draft.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$tmpdir"' EXIT

if [[ -n "$src" ]]; then
  cat "$src" > "$tmpdir/material.md"
else
  cat > "$tmpdir/material.md"
fi
[[ -s "$tmpdir/material.md" ]] || die "材料が空"

{
  printf '%s\n' "あなたは日本語の技術文書を書く編集者です。以下の材料だけを根拠に、$what を書いてください。"
  printf '\n%s\n' "守ること:"
  printf '%s\n' "- 出力は本文だけ。前置き・後書き・「以下が下書きです」・全体を囲うコードフェンスは書かない"
  printf '%s\n' "- 材料に無い事実・数値・固有名詞を作らない。書けないことは書かずに落とす"
  printf '%s\n' "- 冗長な前置き（「この変更は」など）を避け、読む人が判断できる情報だけを残す"
  printf '%s\n' "- 材料が英語なら英語、そうでなければ日本語"
  printf '\n%s\n\n' "--- 材料 ---"
  cat "$tmpdir/material.md"
} > "$tmpdir/prompt.md"

[[ -n "$out" ]] || out="${TMPDIR:-/tmp}/draft-${kind}-$(date +%Y%m%d-%H%M%S).md"
mkdir -p "$(dirname "$out")" 2>/dev/null

err="$tmpdir/consult.err"
if ! "$CONSULT" --to pi -m "$model" - < "$tmpdir/prompt.md" > "$out" 2> "$err"; then
  echo "$PROG: gemini が書けなかった（下書きは作っていない）。材料かネットワークを確かめる" >&2
  sed 's/^/  /' "$err" >&2
  echo "$PROG: 代替を使うなら ai-fallback.sh。そのときは 利用AI: に codex/… と書く" >&2
  exit 1
fi

if [[ ! -s "$out" ]]; then
  echo "$PROG: 空の下書きが返った（$out）" >&2
  exit 1
fi

echo "ANSWER_FILE=$out" >&2
echo "文面: pi/$model" >&2
cat "$out"
