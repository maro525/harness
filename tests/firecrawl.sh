#!/bin/bash
# firecrawl.sh のテスト。偽の curl を PATH に置き、一時ディレクトリだけで動かす。
#
# 確かめること:
#   1. 200 なら markdown を出して exit 0
#   2. 2 回目はキャッシュから（curl を呼ばない）
#   3. --refresh は取り直す
#   4. 429 は本文の "retry after Ns" だけ待って再試行する
#   5. 402 は再試行せずに exit 4
#   6. キーが無ければ exit 5
#   7. 間隔（--min-interval）をあけて呼ぶ
#   8. batch は成功ぶんだけファイルを書き、失敗があれば exit 1
#
# Usage: tests/firecrawl.sh   Exit: 0 = all pass

set -uo pipefail

HARNESS=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$HARNESS/claude/scripts/firecrawl.sh"
TMP=$(mktemp -d "/tmp/$(basename "$HARNESS").XXXXXX")
trap 'rm -rf "$TMP"' EXIT
fails=0

export XDG_CACHE_HOME="$TMP/cache"
export FIRECRAWL_API_KEY=test-key
export FAKE="$TMP/fake"
mkdir -p "$XDG_CACHE_HOME" "$FAKE/bin" "$FAKE/calls"
: > "$FAKE/count"

# --- 偽 curl: URL ごとに決まった応答を返す ------------------------------------
cat > "$FAKE/bin/curl" <<'FAKE_CURL'
#!/bin/bash
# -o OUT / -D HDR / -d DATA だけ見る。
set -uo pipefail
out=/dev/null hdr=/dev/null data=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -D) hdr=$2; shift 2 ;;
    -d) data=$2; shift 2 ;;
    *) shift ;;
  esac
done
echo "$data" >>"$FAKE/calls"
n=$(cat "$FAKE/count" 2>/dev/null || echo 0)
echo $((n + 1)) >"$FAKE/count"
url=$(jq -r '.url // empty' <<<"$data" 2>/dev/null || true)

case "$url" in
  *slow.test*)
    slow=$(cat "$FAKE/slow" 2>/dev/null || echo 0)
    echo $((slow + 1)) >"$FAKE/slow"
    if ((slow == 0)); then
      printf 'HTTP/2 429 \r\nretry-after: 1\r\n\r\n' >"$hdr"
      printf '{"success":false,"error":"Rate limit exceeded. please retry after 1s"}' >"$out"
      echo 429
    else
      printf 'HTTP/2 200 \r\n\r\n' >"$hdr"
      printf '{"success":true,"data":{"markdown":"# slow ok\\n"}}\n' >"$out"
      echo 200
    fi
    ;;
  *bad.test*)
    printf 'HTTP/2 402 \r\n\r\n' >"$hdr"
    printf '{"success":false,"error":"Payment required"}' >"$out"
    echo 402
    ;;
  *)
    printf 'HTTP/2 200 \r\n\r\n' >"$hdr"
    printf '{"success":true,"data":{"markdown":"# page %s\\n"}}\n' "$url" >"$out"
    echo 200
    ;;
esac
FAKE_CURL
chmod +x "$FAKE/bin/curl"
export PATH="$FAKE/bin:$PATH"

run() { # <stderr-out-file> <args...>
  local err=$1
  shift
  "$SCRIPT" "$@" 2>"$err"
}

expect() { # name pattern text
  local name=$1 pattern=$2 text=$3
  if grep -Eq -- "$pattern" <<<"$text"; then
    echo "ok   $name"
  else
    echo "FAIL $name (/$pattern/)"
    sed 's/^/     | /' <<<"$text"
    fails=$((fails + 1))
  fi
}

calls() { cat "$FAKE/count" 2>/dev/null || echo 0; }

# 1. 200 は markdown を出して exit 0
out=$(run "$TMP/e1" scrape https://ok.test/a); code=$?
((code == 0)) && echo "ok   scrape exits 0" || { echo "FAIL exit $code"; fails=$((fails + 1)); }
expect "scrape prints the markdown" '# page https://ok.test/a' "$out"
expect "scrape reports a miss" 'CACHE=miss' "$(cat "$TMP/e1")"

# 2. 2 回目はキャッシュ（curl を呼ばない）
before=$(calls)
out=$(run "$TMP/e2" scrape https://ok.test/a); code=$?
after=$(calls)
expect "second call is a cache hit" 'CACHE=hit' "$(cat "$TMP/e2")"
((after == before)) && echo "ok   cache hit made no API call" || { echo "FAIL API called again ($before -> $after)"; fails=$((fails + 1)); }

# 3. --refresh は取り直す
out=$(run "$TMP/e3" scrape https://ok.test/a --refresh --min-interval 0)
after=$(calls)
((after > before)) && echo "ok   --refresh fetches again" || { echo "FAIL no fetch on --refresh"; fails=$((fails + 1)); }

# 4. 429 は retry-after だけ待って再試行する（1 秒 + 間隔 0）
start=$(date +%s)
out=$(run "$TMP/e4" scrape https://slow.test/b --min-interval 0); code=$?
elapsed=$(($(date +%s) - start))
((code == 0)) && echo "ok   429 then success exits 0" || { echo "FAIL exit $code"; fails=$((fails + 1)); }
expect "429 is retried" 'NG=429' "$(cat "$TMP/e4")"
expect "the body of the retry is used" '# slow ok' "$out"
((elapsed >= 1)) && echo "ok   it waited (${elapsed}s)" || { echo "FAIL did not wait (${elapsed}s)"; fails=$((fails + 1)); }

# 5. 402 は再試行しない
before=$(calls)
out=$(run "$TMP/e5" scrape https://bad.test/c --min-interval 0); code=$?
after=$(calls)
((code == 4)) && echo "ok   402 exits 4" || { echo "FAIL exit $code"; fails=$((fails + 1)); }
((after - before == 1)) && echo "ok   402 is not retried" || { echo "FAIL retried 402 ($((after - before)) calls)"; fails=$((fails + 1)); }
expect "402 says why" 'payment required' "$(cat "$TMP/e5")"

# 6. キーが無ければ exit 5
out=$(FIRECRAWL_API_KEY= "$SCRIPT" scrape https://ok.test/a 2>&1); code=$?
((code == 5)) && echo "ok   no key exits 5" || { echo "FAIL exit $code"; fails=$((fails + 1)); }

# 7. 間隔をあける（2 本で 1 秒以上）
printf 'https://a.test/1\nhttps://a.test/2\n' > "$TMP/urls.txt"
start=$(date +%s)
out=$(run "$TMP/e7" batch "$TMP/urls.txt" --out "$TMP/out" --min-interval 1); code=$?
elapsed=$(($(date +%s) - start))
((code == 0)) && echo "ok   batch exits 0" || { echo "FAIL exit $code"; fails=$((fails + 1)); }
((elapsed >= 1)) && echo "ok   batch paced itself (${elapsed}s)" || { echo "FAIL batch did not pace (${elapsed}s)"; fails=$((fails + 1)); }
n=$(ls "$TMP/out" | wc -l)
((n == 2)) && echo "ok   batch wrote 2 files" || { echo "FAIL wrote $n files"; fails=$((fails + 1)); }

# 8. batch は失敗を混ぜても続け、exit 1
printf 'https://ok.test/b1\nhttps://bad.test/b2\n' > "$TMP/urls2.txt"
out=$(run "$TMP/e8" batch "$TMP/urls2.txt" --out "$TMP/out2" --min-interval 0); code=$?
((code == 1)) && echo "ok   batch with a failure exits 1" || { echo "FAIL exit $code"; fails=$((fails + 1)); }
expect "batch summarises" 'DONE ok=1 ng=1' "$(cat "$TMP/e8")"
n=$(ls "$TMP/out2" | wc -l)
((n == 1)) && echo "ok   only the good URL was written" || { echo "FAIL wrote $n files"; fails=$((fails + 1)); }

echo ""
if ((fails == 0)); then
  echo "all pass"
  exit 0
fi
echo "$fails failed"
exit 1
