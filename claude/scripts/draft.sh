#!/usr/bin/env bash
# draft.sh — 対外文書の下書きを gemini に 1 回だけ投げる薄いラッパー。
#
#   draft.sh --kind=pr|comment|commit|section|reply [--material FILE] [--out FILE]
#   （どのオプションも `--opt VALUE` と `--opt=VALUE` の両方を受ける）
#   cat notes.md | draft.sh --kind=commit
#
# 目的: `external-ask.sh --to pi -m google/gemini-3-flash-preview - <<'EOF' ... EOF` を毎回
# 手で書かせない（heredoc・モデル名・空出力の検査をここに閉じる）。
#
#   stdout : 下書きの本文（そのまま貼れる）
#   stderr : ANSWER_FILE=<path> / 文面: pi/google/gemini-3-flash-preview
#   exit   : 0 = 書けた / 1 = 失敗（空出力・quota・timeout）/ 2 = 使い方
#
# 失敗しても別のモデルへ落ちない（下書きを別モデルが書いたことを記録できなく
# なる）。下書きフェーズは飛ばし、呼び出し元が自分で書く。

set -uo pipefail

PROG=$(basename "$0")
CONSULT="${EXTERNAL_ASK:-$HOME/.claude/scripts/external-ask.sh}"
MODEL_DEFAULT="google/gemini-3-flash-preview"

die() {
  echo "$PROG: $*" >&2
  exit 2
}

usage() {
  cat <<'EOF'
usage: draft.sh --kind KIND [--material FILE] [--out FILE] [--model MODEL]

  --kind KIND      pr | comment | commit | section | reply（必須）
  --material FILE  材料。省略すると標準入力から読む（空なら exit 2）
  --out FILE       下書きの置き場所（既定: $TMPDIR/draft-KIND-<日時>.md）
  --model MODEL    既定 google/gemini-3-flash-preview

  どのオプションも `--opt VALUE` と `--opt=VALUE` の両方を受ける。

  stdout に本文、stderr に ANSWER_FILE と「文面: pi/<model>」を出す。
EOF
}

# need_value <option> <args left>: a value-taking option at the end is a usage error.
need_value() {
  (( $2 >= 2 )) && return 0
  die "$1 needs a value"
}

kind="" material="" out="" model="$MODEL_DEFAULT"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kind=*) kind=${1#*=}; shift ;;
    --material=*) material=${1#*=}; shift ;;
    --out=*) out=${1#*=}; shift ;;
    --model=*) model=${1#*=}; shift ;;
    --kind) need_value "$1" $#; kind=$2; shift 2 ;;
    --material) need_value "$1" $#; material=$2; shift 2 ;;
    --out) need_value "$1" $#; out=$2; shift 2 ;;
    --model) need_value "$1" $#; model=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown argument: $1（--help を見る）" ;;
  esac
done

[[ -n "$kind" ]] || die "--kind is required（pr|comment|commit|section|reply）"
[[ -x "$CONSULT" ]] || die "external-ask.sh not found: $CONSULT"
command -v pi >/dev/null 2>&1 || die "pi is not installed（gemini は pi 経由で走る）"

case "$kind" in
  pr) what="PR / MR の本文（見出しは ## を使い、「何をしたか / 確かめたこと / 影響・注意」の順）" ;;
  comment) what="Linear のコメント（または issue の description、要点 3〜6 行、根拠と次の手）" ;;
  commit) what="コミットメッセージ（1 行目は 50 文字以内の命令形、prefix は材料の慣習に合わせる。必要なら空行を挟んで本文）" ;;
  section) what="TASK_FILE に書き込む Markdown の節（見出しは材料の構成に合わせる）" ;;
  reply) what="レビューコメントへの返信（丁寧だが簡潔に、変更点と根拠）" ;;
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
  printf '%s\n' "あなたは技術文書を書く編集者です。以下の材料だけを根拠に、$whatを書いてください。"
  printf '\n%s\n' "守ること:"
  printf '%s\n' "- 出力は本文だけ。前置き・後書き・「以下が下書きです」・全体を囲うコードフェンスは書かない"
  printf '%s\n' "- 材料に無い事実・数値・固有名詞を作らない。書けないことは書かずに落とす"
  printf '%s\n' "- 冗長な前置き（「この変更は」など）を避け、読む人が判断できる情報だけを残す"
  printf '%s\n' "- 1 文 1 アイデア。読み返さないと分からない文は分ける"
  printf '%s\n' "- 能動態で書き、行為者を名指しする（不明なら省く）"
  printf '%s\n' "- 同じものは同じ名前で呼ぶ。言い換えない"
  printf '%s\n' "- 仕組みか数字で示す。中身のない前置き・締め・「重要です」を削る"
  printf '%s\n' "- 平易な語を使う（「活用する」→「使う」）。比喩・格言・擬人化を避ける"
  printf '%s\n' "- 矢印・略語は言葉にする"
  printf '%s\n' "- ダッシュ（—, –, -）を区切りに使わない。コロンはリスト・例の前だけ"
  printf '%s\n' "- 太字は必要な語だけ。**ラベル:** で同じ行を言い換えない。絵文字は使わない"
  printf '%s\n' "- 賞賛・同意の前置きや「お役に立てれば」を書かない。ヘッジは 1 つまで"
  printf '%s\n' "- 材料が英語なら英語、そうでなければ日本語"
  printf '\n%s\n\n' "--- 材料 ---"
  cat "$tmpdir/material.md"
} > "$tmpdir/prompt.md"

[[ -n "$out" ]] || out="${TMPDIR:-/tmp}/draft-${kind}-$(date +%Y%m%d-%H%M%S).md"
mkdir -p "$(dirname "$out")" 2>/dev/null

err="$tmpdir/external-ask.err"
if ! "$CONSULT" --to pi -m "$model" - < "$tmpdir/prompt.md" > "$out" 2> "$err"; then
  echo "$PROG: gemini が書けなかった（下書きは作っていない）。材料かネットワークを確かめる" >&2
  sed 's/^/  /' "$err" >&2
  echo "$PROG: 下書きフェーズは飛ばす。呼び出し元が自分で書き、利用AI: に自分のモデルを書く" >&2
  exit 1
fi

if [[ ! -s "$out" ]]; then
  echo "$PROG: 空の下書きが返った（$out）" >&2
  exit 1
fi

echo "ANSWER_FILE=$out" >&2
echo "文面: pi/$model" >&2
cat "$out"
