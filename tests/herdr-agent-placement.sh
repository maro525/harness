#!/bin/bash
# herdr-agent.sh の配置（manager と worker）のテスト。偽の herdr を PATH に置き、
# 一時ディレクトリだけで動かす。
#
# manager の規則:
#   1. セッションの識別子が無ければ exit 2（勝手に決めない）
#   2. 常に ~/src（$HARNESS_MANAGER_ROOT）で起動し、worktree を作らない
#   3. 名前が埋まっていれば suffix 付き。場所は同じ root
#   4. 同じセッションは同じ manager を再利用する
#   5. root 以外（リポジトリ直下）に居る古い記録は引き継がない
#
# worker の規則:
#   6. そのリポジトリで作業中の worker がいなければ checkout の tab
#   7. working / blocked の worker がいれば worktree（feature/<name>）
#   8. idle / done の tab と manager は数えない
#
# Usage: tests/herdr-agent-placement.sh   Exit: 0 = all pass

set -uo pipefail

HARNESS=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$HARNESS/claude/scripts/herdr-agent.sh"
TMP=$(mktemp -d "/tmp/$(basename "$HARNESS").XXXXXX")
trap 'rm -rf "$TMP"' EXIT
fails=0

export XDG_CACHE_HOME="$TMP/cache"
export FAKE="$TMP/fake"
export HARNESS_MANAGER_ROOT="$TMP/src-root"
# 実行環境が Herdr の中でも、セッションはテストが決める
unset HERDR_PANE_ID HERDR_AGENT_NAME HERDR_WORKSPACE_ID HARNESS_SESSION_KEY SESSION_KEY
mkdir -p "$XDG_CACHE_HOME" "$FAKE/agents" "$FAKE/wt" "$HARNESS_MANAGER_ROOT"
: > "$FAKE/log"

# --- 偽 herdr: 状態は $FAKE 配下のファイルだけ --------------------------------
cat > "$TMP/herdr" <<'FAKE_HERDR'
#!/bin/bash
# 最小限の herdr。呼ばれた引数を $FAKE/log に残し、結果だけを返す。
# agents/<name> の中身は agent_status（idle / working / blocked / done）。
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
    label=""; 
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --label) label=$2; shift 2 ;;
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
        if [[ -f "$FAKE/agents/${3:-}" ]]; then
          printf '{"result":{"agent":{"name":"%s","agent_status":"%s"}}}\n' "$3" "$(cat "$FAKE/agents/$3")"
        else
          exit 1
        fi
        ;;
      start) : > "$FAKE/agents/${3:-}"; echo idle > "$FAKE/agents/${3:-}"; exit 0 ;;
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

run() { # <env...> -- args...
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

# 1. 識別子が無い: 何も作らず exit 2
out=$(run HARNESS_SESSION_PROC=0 -- manager --plan); code=$?
((code == 2)) && echo "ok   manager exits 2 without a session" || { echo "FAIL exit $code"; fails=$((fails + 1)); }
expect "manager refuses to guess a session" 'no session identity' "$out"

# 2. 2a. --session を明示すれば pane が無くても決まる（場所は manager root）
out=$(cd "$REPO" && run HARNESS_SESSION_PROC=0 -- manager --plan --session chat-7f3a)
expect "explicit session works without a pane" "PLAN name=manager-repo-a topology=tab repo=$HARNESS_MANAGER_ROOT" "$out"

# 2b. --explain は何も作らず、何を見たかだけ出す
tabs_before=$(grep -c 'tab create\|worktree create' "$FAKE/log")
out=$(run HARNESS_SESSION_PROC=0 -- manager --explain); code=$?
((code == 0)) && echo "ok   explain exits 0" || { echo "FAIL exit $code"; fails=$((fails + 1)); }
expect "explain: no identity found" 'SESSION=（なし）' "$out"
expect "explain: says the lookup was off" 'SOURCE=off' "$out"
tabs_after=$(grep -c 'tab create\|worktree create' "$FAKE/log")
((tabs_after == tabs_before)) && echo "ok   explain created nothing" || { echo "FAIL explain created something"; fails=$((fails + 1)); }

# 3. 作成: リポジトリの中から呼んでも manager は root に居る（worktree は作らない）
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 -- manager)
expect "manager is created at the root" "REPO=$HARNESS_MANAGER_ROOT" "$out"
expect "manager uses a tab" 'TOPOLOGY=tab' "$out"
expect "manager is named after the repo" 'MANAGER=manager-repo-a' "$out"
expect "manager reports started" 'STATE=started' "$out"
grep -q 'worktree create' "$FAKE/log" && { echo "FAIL manager created a worktree"; fails=$((fails + 1)); } || echo "ok   manager created no worktree"

# 4. 同じセッションは再利用
tabs=$(grep -c 'tab create' "$FAKE/log")
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 -- manager)
expect "same session reuses" 'STATE=reused' "$out"
(( $(grep -c 'tab create' "$FAKE/log") == tabs )) && echo "ok   no extra tab for the same session" ||
  { echo "FAIL another tab"; fails=$((fails + 1)); }

# 5. 別セッション: 名前だけ分かれ、場所は同じ root（worktree は作らない）
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p2 -- manager --plan)
expect "second session gets a suffixed name" 'PLAN name=manager-repo-a-[0-9a-f]{4} topology=tab' "$out"
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p2 -- manager)
expect "second manager starts" 'STATE=started' "$out"
expect "second manager is at the root too" "REPO=$HARNESS_MANAGER_ROOT" "$out"
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p2 -- manager)
expect "second session reuses its own" 'STATE=reused' "$out"
grep -q 'worktree create' "$FAKE/log" && { echo "FAIL a manager created a worktree"; fails=$((fails + 1)); } || echo "ok   still no worktree"

# 6. root の外（リポジトリ直下）に居る古い記録は引き継がない
mkdir -p "$XDG_CACHE_HOME/harness/herdr-agents"
old="$XDG_CACHE_HOME/harness/herdr-agents/manager-repo-b.json"
printf '{"agent":"manager-repo-b","pane":"w9:p9","tab":"t9","kind":"claude","topology":"tab","repo":"%s"}\n' \
  "$TMP/repo-b" > "$old"
echo idle > "$FAKE/agents/manager-repo-b"
mkdir -p "$TMP/repo-b" && git -C "$TMP/repo-b" init -q &&
  git -C "$TMP/repo-b" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
out=$(cd "$TMP/repo-b" && run HERDR_PANE_ID=w1:p3 -- manager)
expect "an old checkout manager is not adopted" 'STATE=started' "$out"
expect "the new one is at the root" "REPO=$HARNESS_MANAGER_ROOT" "$out"
expect "the new one has a suffix" 'MANAGER=manager-repo-b-[0-9a-f]{4}' "$out"

# 7. worker: 空いている checkout は tab
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 -- worker child-a --kind claude --plan)
expect "worker takes the free checkout" "PLAN name=child-a topology=tab repo=$REPO" "$out"

# 8. working の worker が居れば worktree（branch は feature/<name>）
echo working > "$FAKE/agents/child-busy"
printf '{"agent":"child-busy","pane":"w1:p9","tab":"t9","kind":"claude","topology":"tab","repo":"%s"}\n' \
  "$REPO" > "$XDG_CACHE_HOME/harness/herdr-agents/child-busy.json"
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 -- worker child-b --kind claude --plan)
expect "worker goes to a worktree when one is working" "PLAN name=child-b topology=worktree repo=$REPO branch=feature/child-b" "$out"
expect "the busy worker is named" 'occupied=child-busy' "$out"

out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 -- worker child-b --kind claude)
expect "worker starts" "AGENT=child-b" "$out"
expect "worker reports the worktree" 'TOPOLOGY=worktree' "$out"
grep -Eq -- 'worktree create .*--branch feature/child-b' "$FAKE/log" && echo "ok   worktree created for the worker" ||
  { echo "FAIL no worktree for the worker"; fails=$((fails + 1)); }

# 9. idle / done の tab と manager は数えない
echo done > "$FAKE/agents/child-busy"
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 -- worker child-c --kind claude --plan)
expect "a done worker does not block the checkout" "PLAN name=child-c topology=tab repo=$REPO" "$out"
echo working > "$FAKE/agents/manager-repo-a"
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 -- worker child-d --kind claude --plan)
expect "a working manager does not block the checkout" "PLAN name=child-d topology=tab repo=$REPO" "$out"

# 10. リポジトリの外では worker を作らない
out=$(cd "$TMP" && run HERDR_PANE_ID=w1:p1 -- worker child-e --kind claude --plan); code=$?
((code == 2)) && echo "ok   worker outside a repo exits 2" || { echo "FAIL exit $code"; fails=$((fails + 1)); }
expect "worker says why" 'not a git checkout' "$out"

# 11. 記録: manager は root、worker はリポジトリ
state="$XDG_CACHE_HOME/harness/herdr-agents/manager-repo-a.json"
expect "manager session recorded" '"session": "pane:w1:p1"' "$(cat "$state")"
expect "manager repo is the root" "\"repo\": \"$HARNESS_MANAGER_ROOT\"" "$(cat "$state")"

# 12. 試行のログ（起動しなかった理由も残る）
log="$XDG_CACHE_HOME/harness/manager.log"
expect "log: the failure is recorded" 'no-session' "$(cat "$log")"
expect "log: a started manager is recorded" 'started.*manager-repo-a$' "$(cat "$log")"
expect "log: reuse is recorded" 'reused' "$(cat "$log")"

echo ""
if ((fails == 0)); then
  echo "all pass"
  exit 0
fi
echo "$fails failed"
exit 1
