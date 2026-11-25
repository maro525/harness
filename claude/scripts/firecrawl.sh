#!/bin/bash
# firecrawl.sh — URL を 1 本ずつ、無料枠の間隔を守って取る。
#
# なぜ要るか: firecrawl の無料枠は 15 req/min。連続で scrape すると 429 で落ち、
# 本文の "retry after 30s" だけ待たないと成功しない。2026-11-25 は 1 日で 90 回の
# scrape が 429 で失敗した（同じセッションが待たずに撃ち続けた）。
#
# このスクリプトは、API キー（$FIRECRAWL_API_KEY）で REST を直接叩く。MCP の
# ツールではなくこちらを使えば、間隔・429 の待ち・キャッシュが効く。
#
# Usage:
#   firecrawl.sh scrape <url> [--json] [--refresh] [--min-interval S] [--max-tries N]
#   firecrawl.sh batch  <url-file> --out DIR [--refresh] ...
#
# Options:
#   --json           API の JSON をそのまま出す（既定は markdown だけ）
#   --refresh        キャッシュを無視して取り直す
#   --min-interval S 呼び出しの最小間隔（既定 4 秒 = 15 req/min）
#   --max-tries N    429 のときの試行回数（既定 3）
#   --timeout S      curl の上限（既定 120 秒）
#
# stdout: markdown（--json なら JSON）。batch は書いたファイルの一覧
# stderr: CACHE=hit|miss / TRY=n / STATUS=200|429|... / WAIT=ns / NG=...
# exit:   0 = ok, 1 = 一部失敗（batch）, 2 = usage, 3 = 429 で諦めた,
#         4 = API エラー, 5 = API キーが無い, 6 = 中身が空

set -uo pipefail

API=${FIRECRAWL_API_URL:-https://api.firecrawl.dev/v2/scrape}
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/harness/firecrawl"
MIN_INTERVAL=${FIRECRAWL_MIN_INTERVAL:-4}
MAX_TRIES=${FIRECRAWL_MAX_TRIES:-3}
TIMEOUT=${FIRECRAWL_TIMEOUT:-120}
CACHE_TTL=${FIRECRAWL_CACHE_TTL:-21600} # 6h

die() {
  printf 'firecrawl: %s\n' "$1" >&2
  exit "${2:-4}"
}

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

command -v jq >/dev/null 2>&1 || die "jq is not installed" 4
command -v curl >/dev/null 2>&1 || die "curl is not installed" 4

CMD=${1:-}
[[ -n "$CMD" ]] || { usage >&2; exit 2; }
shift

AS_JSON=0
REFRESH=0
OUT=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) AS_JSON=1; shift ;;
    --refresh) REFRESH=1; shift ;;
    --min-interval) MIN_INTERVAL=$2; shift 2 ;;
    --max-tries) MAX_TRIES=$2; shift 2 ;;
    --timeout) TIMEOUT=$2; shift 2 ;;
    --out) OUT=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    --*) die "unknown option: $1" 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

[[ -n "${FIRECRAWL_API_KEY:-}" ]] || die "FIRECRAWL_API_KEY is not set" 5
mkdir -p "$CACHE_DIR" || die "cannot create $CACHE_DIR" 4

cache_file() {
  local ext=md
  ((AS_JSON)) && ext=json
  printf '%s/%s.%s' "$CACHE_DIR" "$(printf '%s' "$1" | sha1sum | cut -c1-20)" "$ext"
}

# One slot at a time across every process and session of this user: the limit is
# per API key, so pacing has to be global, not per caller.
take_slot() {
  local last now wait
  exec 9>"$CACHE_DIR/.lock" || return 0
  flock 9 2>/dev/null || true
  last=$(cat "$CACHE_DIR/.slot" 2>/dev/null || echo 0)
  now=$(date +%s)
  wait=$((last + MIN_INTERVAL - now))
  if ((wait > 0)); then
    echo "WAIT=${wait}s" >&2
    sleep "$wait"
  fi
  date +%s >"$CACHE_DIR/.slot"
  exec 9>&-
}

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/firecrawl.XXXXXX") || die "cannot create a temp dir" 4
cleanup() { [[ -z "$TMP_DIR" ]] || rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# post <url> — writes the body and headers to files, prints the HTTP status.
post() {
  local url=$1 payload
  payload=$(jq -cn --arg u "$url" '{url:$u, formats:["markdown"], onlyMainContent:true}')
  curl -sS --max-time "$TIMEOUT" -D "$TMP_DIR/hdr" -o "$TMP_DIR/body" -w '%{http_code}' \
    -X POST "$API" \
    -H "Authorization: Bearer $FIRECRAWL_API_KEY" \
    -H 'Content-Type: application/json' \
    -d "$payload" 2>"$TMP_DIR/err" || echo 000
}

# Seconds to wait from `Retry-After:` or from "retry after 37s" in the body.
retry_after() {
  local secs
  secs=$(sed -n 's/^[Rr]etry-[Aa]fter: *\([0-9]\+\).*/\1/p' "$TMP_DIR/hdr" 2>/dev/null | head -n 1)
  [[ -n "$secs" ]] || secs=$(sed -n 's/.*retry after \([0-9]\+\)s.*/\1/p' "$TMP_DIR/body" 2>/dev/null | head -n 1)
  [[ "$secs" =~ ^[0-9]+$ ]] || secs=10
  # The reset can be further away than a single window; never sleep the day away.
  ((secs > 60)) && secs=60
  printf '%s' "$secs"
}

# fetch <url> — markdown (or the raw JSON) of one page, honouring the rate limit.
fetch() {
  local url=$1 try=1 code wait reason
  while ((try <= MAX_TRIES)); do
    take_slot
    code=$(post "$url")
    echo "TRY=$try STATUS=$code" >&2
    case "$code" in
      200)
        if [[ $(jq -r '.success // false' "$TMP_DIR/body" 2>/dev/null) != "true" ]]; then
          reason=$(jq -r '.error // "unknown error"' "$TMP_DIR/body" 2>/dev/null)
          die "API returned 200 but success=false: $reason" 4
        fi
        if ((AS_JSON)); then cat "$TMP_DIR/body"; else jq -r '.data.markdown // empty' "$TMP_DIR/body"; fi
        return 0
        ;;
      429)
        wait=$(retry_after)
        echo "NG=429 (rate limit) — waiting ${wait}s before try $((try + 1))" >&2
        sleep "$wait"
        ;;
      401 | 403)
        reason=$(jq -r '.error // empty' "$TMP_DIR/body" 2>/dev/null || true)
        die "auth failed (HTTP $code)${reason:+: $reason} — check FIRECRAWL_API_KEY" 4
        ;;
      402)
        reason=$(jq -r '.error // empty' "$TMP_DIR/body" 2>/dev/null || true)
        die "payment required (HTTP 402)${reason:+: $reason} — the free plan ran out or the URL is not allowed" 4
        ;;
      000)
        reason=$(tr -d '\n' <"$TMP_DIR/err" 2>/dev/null | head -c 120)
        echo "NG=curl failed: ${reason:-timeout}" >&2
        ;;
      *)
        reason=$(jq -r '.error // empty' "$TMP_DIR/body" 2>/dev/null || true)
        echo "NG=HTTP $code${reason:+: $reason}" >&2
        ;;
    esac
    try=$((try + 1))
  done
  return 3
}

cmd_scrape() {
  local url=${1:-} file body age
  [[ -n "$url" ]] || die "scrape needs a URL" 2
  file=$(cache_file "$url")
  if ((REFRESH == 0)) && [[ -f "$file" ]]; then
    age=$(($(date +%s) - $(stat -c %Y "$file" 2>/dev/null || echo 0)))
    if ((age <= CACHE_TTL)); then
      echo "CACHE=hit (${age}s old)" >&2
      cat "$file"
      return 0
    fi
  fi
  echo "CACHE=miss" >&2
  body=$(fetch "$url") || exit $?
  [[ -n "$body" ]] || die "empty body for $url" 6
  printf '%s\n' "$body" >"$file"
  printf '%s\n' "$body"
}

cmd_batch() {
  local list=${1:-} line url n=0 ok=0 ng=0 slug path
  [[ -n "$list" && -f "$list" ]] || die "batch needs a file of URLs (one per line)" 2
  [[ -n "$OUT" ]] || die "batch needs --out DIR" 2
  mkdir -p "$OUT" || die "cannot create $OUT" 4
  while IFS= read -r line; do
    # # で始まる行はコメント。URL は前後の空白だけ落とす（# 以降は URL の一部）。
    [[ "$line" == \#* ]] && continue
    url=$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [[ -n "$url" ]] || continue
    n=$((n + 1))
    slug=$(printf '%s' "$url" | sed -e 's#^https\?://##' -e 's#[^A-Za-z0-9._-]#-#g' | cut -c1-80)
    path="$OUT/$(printf '%03d' "$n")-$slug.md"
    if (cmd_scrape "$url" >"$path") 2>"$path.err" && [[ -s "$path" ]]; then
      ok=$((ok + 1))
      rm -f "$path.err"
      echo "OK  $url -> $path" >&2
    else
      ng=$((ng + 1))
      why=$(tail -n 1 "$path.err" 2>/dev/null || true)
      rm -f "$path" "$path.err"
      echo "NG  $url${why:+ ($why)}" >&2
    fi
  done <"$list"
  echo "DONE ok=$ok ng=$ng" >&2
  ((ng == 0)) || return 1
}

case "$CMD" in
  scrape) cmd_scrape "${ARGS[0]:-}" ;;
  batch) cmd_batch "${ARGS[0]:-}" ;;
  *) usage >&2; exit 2 ;;
esac
