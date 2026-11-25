#!/bin/bash
# herdr-agent.sh manager の決定テスト。偽の herdr を PATH に置き、一時ディレクトリだけで動かす。
#
# 確かめること（1 セッション 1 manager の規則）:
#   1. セッションの識別子が無ければ、勝手に決めずに exit 2
#   2. 空いているリポジトリは manager-<repo>（checkout の tab）
#   3. 同じセッションで呼び直すと再利用（tab を増やさない）
#   4. 別セッションが持っているリポジトリは worktree + manager-<repo>-<suffix>
#   5. その別セッションも、次からは同じ manager を再利用
#
# Usage: tests/herdr-agent-manager.sh   Exit: 0 = all pass

set -uo pipefail

HARNESS=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$HARNESS/claude/scripts/herdr-agent.sh"
TMP=$(mktemp -d "/tmp/$(basename "$HARNESS").XXXXXX")
trap 'rm -rf "$TMP"' EXIT
fails=0

export XDG_CACHE_HOME="$TMP/cache"
export FAKE="$TMP/fake"
# 実行環境が Herdr の中でも、セッションはテストが決める
unset HERDR_PANE_ID HERDR_AGENT_NAME HERDR_WORKSPACE_ID HARNESS_SESSION_KEY SESSION_KEY
mkdir -p "$XDG_CACHE_HOME" "$FAKE/agents" "$FAKE/wt"
: > "$FAKE/log"

# --- 偽 herdr: 状態は $FAKE 配下のファイルだけ --------------------------------
cat > "$TMP/herdr" <<'FAKE_HERDR'
#!/bin/bash
# 最小限の herdr。呼ばれた引数を $FAKE/log に残し、結果だけを返す。
set -uo pipefail
echo "$*" >> "$FAKE/log"
n=0
[[ -f "$FAKE/seq" ]] && n=$(cat "$FAKE/seq")
bump() { n=$((n + 1)); echo "$n" > "$FAKE/seq"; }

case "${1:-}" in
  workspace)
    case "${2:-}" in
      list) echo '{"result":{"workspaces":[]}}' ;;
      create) bump; printf '{"result":{"workspace":{"workspace_id":"w%d"},"tab":{"tab_id":"t%d"},"root_pane":{"pane_id":"w%d:p1"}}}\n' "$n" "$n" "$n" ;;
      close) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  tab)
    case "${2:-}" in
      create) bump; printf '{"result":{"tab":{"tab_id":"t%d"},"root_pane":{"pane_id":"w1:p%d"}}}\n' "$n" "$n" ;;
      *) exit 0 ;;
    esac
    ;;
  worktree)
    label=""; cwd=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --label) label=$2; shift 2 ;;
        --cwd) cwd=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    bump
    mkdir -p "$FAKE/wt/$label"
    printf '{"result":{"workspace":{"workspace_id":"w%d","identity_cwd":"%s"},"tab":{"tab_id":"t%d"},"root_pane":{"pane_id":"w%d:p1"}}}\n' \
      "$n" "${FAKE}/wt/${label}" "$n" "$n"
    ;;
  agent)
    case "${2:-}" in
      get)
        [[ -f "$FAKE/agents/${3:-}" ]] && printf '{"result":{"agent":{"name":"%s","agent_status":"idle"}}}\n' "$3"
        [[ -f "$FAKE/agents/${3:-}" ]] || exit 1
        ;;
      start) : > "$FAKE/agents/${3:-}"; exit 0 ;;
      read) echo ready ;;
      *) exit 0 ;;
    esac
    ;;
  pane)
    # cwd を空で返すと、スクリプトは pane run も sleep もしない。
    [[ "${2:-}" == "get" ]] && echo '{"result":{"pane":{"cwd":""}}}'
    exit 0
    ;;
  *) exit 0 ;;
esac
FAKE_HERDR
chmod +x "$TMP/herdr"
export PATH="$TMP:$PATH"

# --- リポジトリの fixture ----------------------------------------------------
REPO="$TMP/repo-a"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init

run() { # <env...> -- args...  （env は PREFIX= 形式で先に渡す）
  local env=()
  while [[ "${1:-}" != "--" ]]; do env+=("$1"); shift; done
  shift
  env "${env[@]}" "$SCRIPT" "$@" 2>&1
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

# 1. 識別子が無い: 何も作らず exit 2（プロセスの探索も切って、祖先に pi などがいても揺れないようにする）
out=$(run ENV_NOOP=1 HARNESS_SESSION_PROC=0 -- manager --repo "$REPO"); code=$?
(( code == 2 )) && echo "ok   exit 2 without a session" || { echo "FAIL exit $code"; fails=$((fails + 1)); }
expect "refuses to guess a session" 'no session identity' "$out"
if grep -q 'tab create' "$FAKE/log"; then
  echo "FAIL created a tab without a session"; fails=$((fails + 1))
else
  echo "ok   nothing was created without a session"
fi

# 2. 空いているリポジトリ: manager-<repo> を checkout に（--plan は作らない）

# 2a. --session で明示すれば pane が無くても決まる
out=$(run HARNESS_SESSION_PROC=0 -- manager --repo "$REPO" --plan --session chat-7f3a)
expect "an explicit session works without a pane" 'PLAN name=manager-repo-a topology=tab' "$out"
expect "the explicit session is used" 'session=chat-7f3a' "$out"

# 2b. --explain は何も作らず、何を見たかだけ出す（起動しないときの切り分け）
tabs_before_explain=$(grep -c 'tab create' "$FAKE/log")
out=$(run HARNESS_SESSION_PROC=0 -- manager --explain); code=$?
(( code == 0 )) && echo "ok   explain exits 0" || { echo "FAIL exit $code"; fails=$((fails + 1)); }
expect "explain: no identity found" 'SESSION=（なし）' "$out"
expect "explain: says the lookup was off" 'SOURCE=off' "$out"
out=$(run HARNESS_SESSION_PROC=0 -- manager --explain --session chat-7f3a)
expect "explain: shows the explicit session" 'SESSION=chat-7f3a' "$out"
expect "explain: names the source" 'SOURCE=explicit' "$out"
tabs_after_explain=$(grep -c 'tab create' "$FAKE/log")
(( tabs_after_explain == tabs_before_explain )) && echo "ok   explain created nothing" ||
  { echo "FAIL explain created a tab"; fails=$((fails + 1)); }
out=$(run HERDR_PANE_ID=w1:p1 -- manager --repo "$REPO" --plan)
expect "plan: first session takes the checkout" 'PLAN name=manager-repo-a topology=tab' "$out"

out=$(run HERDR_PANE_ID=w1:p1 -- manager --repo "$REPO")
code=$?
(( code == 0 )) && echo "ok   create exit 0" || { echo "FAIL exit $code"; fails=$((fails + 1)); }
expect "created manager-repo-a" 'MANAGER=manager-repo-a' "$out"
expect "started, not reused" 'STATE=started' "$out"
expect "PM name mirrors it" 'PM=pm-repo-a' "$out"
expect "stdout is the name" '^manager-repo-a$' "$out"
first_tabs=$(grep -c 'tab create' "$FAKE/log")
(( first_tabs == 1 )) && echo "ok   one tab created" || { echo "FAIL tab create x$first_tabs"; fails=$((fails + 1)); }

# 3. 同じセッションで呼び直す: 再利用（tab を増やさない）
out=$(run HERDR_PANE_ID=w1:p1 -- manager --repo "$REPO")
expect "same session reuses" 'STATE=reused' "$out"
expect "same manager name" 'MANAGER=manager-repo-a' "$out"
now_tabs=$(grep -c 'tab create' "$FAKE/log")
(( now_tabs == first_tabs )) && echo "ok   no extra tab for the same session" ||
  { echo "FAIL tab create x$now_tabs"; fails=$((fails + 1)); }

# 4. 別セッション: checkout が埋まっているので worktree に自分の manager
out=$(run HERDR_PANE_ID=w1:p2 -- manager --repo "$REPO" --plan)
expect "plan: second session gets a worktree" 'topology=worktree' "$out"
expect "plan: worktree name carries a suffix" 'PLAN name=manager-repo-a-[0-9a-f]{4} ' "$out"

out=$(run HERDR_PANE_ID=w1:p2 -- manager --repo "$REPO")
expect "second session starts its own manager" 'STATE=started' "$out"
expect "own manager, not the first one" 'MANAGER=manager-repo-a-[0-9a-f]{4}$' "$out"
expect "it runs on a worktree" 'TOPOLOGY=worktree' "$out"
expect "the worktree is the repo it manages" "REPO=$TMP/fake/wt/manager-repo-a-[0-9a-f]{4}$" "$out"
grep -q 'worktree create' "$FAKE/log" && echo "ok   a worktree was created" ||
  { echo "FAIL no worktree create"; fails=$((fails + 1)); }
grep -Eq -- '--branch pm/repo-a-[0-9a-f]{4}' "$FAKE/log" && echo "ok   branch pm/<repo>-<suffix>" ||
  { echo "FAIL branch name"; fails=$((fails + 1)); }

# 5. 2 つ目のセッションも、次からは同じ manager を再利用
out=$(run HERDR_PANE_ID=w1:p2 -- manager --repo "$REPO")
expect "second session reuses its own" 'STATE=reused' "$out"
expect "same suffixed name" 'MANAGER=manager-repo-a-[0-9a-f]{4}$' "$out"
wts=$(grep -c 'worktree create' "$FAKE/log")
(( wts == 1 )) && echo "ok   no second worktree" || { echo "FAIL worktree create x$wts"; fails=$((fails + 1)); }

# 6. 旧レコード（session 無し）は最初の呼び出し元が引き継ぐ（既存 manager を捨てない）
REPO_B="$TMP/repo-b"
mkdir -p "$REPO_B"
git -C "$REPO_B" init -q
git -C "$REPO_B" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
: > "$FAKE/agents/manager-repo-b"
printf '{"agent":"manager-repo-b","pane":"w9:p9","tab":"t9","kind":"claude","topology":"tab","repo":"%s"}\n' \
  "$REPO_B" > "$XDG_CACHE_HOME/harness/herdr-agents/manager-repo-b.json"
tabs_before=$(grep -c 'tab create' "$FAKE/log")
out=$(run HERDR_PANE_ID=w1:p3 -- manager --repo "$REPO_B")
expect "adopts an old record instead of starting another" 'STATE=reused' "$out"
expect "adopted name" 'MANAGER=manager-repo-b$' "$out"
tabs_after=$(grep -c 'tab create' "$FAKE/log")
(( tabs_after == tabs_before )) && echo "ok   adoption created nothing" ||
  { echo "FAIL adoption created a tab"; fails=$((fails + 1)); }
expect "adoption tags the session" '"session": "pane:w1:p3"' \
  "$(cat "$XDG_CACHE_HOME/harness/herdr-agents/manager-repo-b.json")"

# 7. 1 つ目のセッションは影響を受けていない
out=$(run HERDR_PANE_ID=w1:p1 -- manager --repo "$REPO")
expect "first session still holds the checkout" 'MANAGER=manager-repo-a$' "$out"

# 8. 状態ファイルに、次の呼び出しが頼る 2 つのフィールドが入っている
state="$XDG_CACHE_HOME/harness/herdr-agents/manager-repo-a.json"
expect "session recorded" '"session": "pane:w1:p1"' "$(cat "$state")"
expect "manager_repo recorded" "\"manager_repo\": \"$REPO\"" "$(cat "$state")"

echo ""
if ((fails == 0)); then
  echo "all pass"
  exit 0
fi
echo "$fails failed"
exit 1
