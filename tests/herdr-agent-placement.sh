#!/bin/bash
# herdr-agent.sh の配置（manager と worker）のテスト。偽の herdr を PATH に置き、
# 一時ディレクトリだけで動かす。
#
# manager の規則:
#   1. セッションの識別子が無ければ exit 2（勝手に決めない）
#   2. 常に ~/src（$HARNESS_MANAGER_ROOT）で起動し、worktree を作らない
#   3. 名前が埋まっていれば suffix 付き。場所は同じ root
#   4. 同じセッションは同じ manager を再利用する
#   5. --label で名前の対象を選べる（リポジトリの外からでも効く。切り詰めはしない）
#   6. root 以外（リポジトリ直下）に居る古い記録は引き継がない
#
# worker の規則:
#   7. そのリポジトリで作業中の worker がいなければ checkout の tab
#   8. working / blocked の worker がいれば worktree（feature/<name>）
#   9. idle / done の tab と manager は数えない
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

expect_not() { # name pattern text
  local name=$1 pattern=$2 text=$3
  if grep -Eq -- "$pattern" <<<"$text"; then
    echo "FAIL $name (found /$pattern/)"
    sed 's/^/     | /' <<<"$text"
    fails=$((fails + 1))
  else
    echo "ok   $name"
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

# 6. --label: リポジトリと関係なく名前を決める
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p4 -- manager --plan --label nanco-ads)
expect "an explicit label names the manager" 'PLAN name=manager-nanco-ads topology=tab' "$out"
expect "the label does not move the manager out of the root" "repo=$HARNESS_MANAGER_ROOT" "$out"
out=$(cd "$TMP" && run HERDR_PANE_ID=w1:p4 -- manager --plan --label Nanco_Hp)
expect "a label is normalized like a repository name" 'PLAN name=manager-nanco-hp' "$out"
out=$(cd "$TMP" && run HERDR_PANE_ID=w1:p4 -- manager --label nanco-ads)
expect "the label works outside a repository" 'MANAGER=manager-nanco-ads' "$out"
expect "the PM mirrors the label" 'PM=pm-nanco-ads' "$out"
expect "the labelled manager is at the root" "REPO=$HARNESS_MANAGER_ROOT" "$out"
out=$(cd "$TMP" && run HERDR_PANE_ID=w1:p4 -- manager --label nanco-ads)
expect "the labelled manager is reused" 'STATE=reused' "$out"
out=$(cd "$TMP" && run HERDR_PANE_ID=w1:p5 -- manager --plan --label nanco-ads)
expect "a taken label still gets a suffix" 'PLAN name=manager-nanco-ads-[0-9a-f]{4}' "$out"
out=$(cd "$TMP" && run HERDR_PANE_ID=w1:p6 -- manager --plan --label aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa); code=$?
((code == 2)) && echo "ok   an over-long label exits 2" || { echo "FAIL exit $code"; fails=$((fails + 1)); }
expect "an over-long label is refused, not shortened" "invalid name 'manager-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'" "$out"
out=$(cd "$TMP" && run HERDR_PANE_ID=w1:p7 -- manager nanco-ads --plan); code=$?
((code == 2)) && echo "ok   a positional name exits 2" || { echo "FAIL exit $code"; fails=$((fails + 1)); }
expect "the positional-name hint points at --label" 'pass --label' "$out"

# 7. root の外（リポジトリ直下）に居る古い記録は引き継がない
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

# 8. worker: 空いている checkout は tab
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 -- worker child-a --kind claude --plan)
expect "worker takes the free checkout" "PLAN name=child-a topology=tab repo=$REPO" "$out"

# 9. working の worker が居れば worktree（branch は feature/<name>）
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

# 10. idle / done の tab と manager は数えない
echo done > "$FAKE/agents/child-busy"
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 -- worker child-c --kind claude --plan)
expect "a done worker does not block the checkout" "PLAN name=child-c topology=tab repo=$REPO" "$out"
echo working > "$FAKE/agents/manager-repo-a"
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 -- worker child-d --kind claude --plan)
expect "a working manager does not block the checkout" "PLAN name=child-d topology=tab repo=$REPO" "$out"

# 11. リポジトリの外では worker を作らない
out=$(cd "$TMP" && run HERDR_PANE_ID=w1:p1 -- worker child-e --kind claude --plan); code=$?
((code == 2)) && echo "ok   worker outside a repo exits 2" || { echo "FAIL exit $code"; fails=$((fails + 1)); }
expect "worker says why" 'not a git checkout' "$out"

# 12. 記録: manager は root、worker はリポジトリ
state="$XDG_CACHE_HOME/harness/herdr-agents/manager-repo-a.json"
expect "manager session recorded" '"session": "pane:w1:p1"' "$(cat "$state")"
expect "manager repo is the root" "\"repo\": \"$HARNESS_MANAGER_ROOT\"" "$(cat "$state")"

# 13. 試行のログ（起動しなかった理由も残る）
log="$XDG_CACHE_HOME/harness/manager.log"
expect "log: the failure is recorded" 'no-session' "$(cat "$log")"
expect "log: a started manager is recorded" 'started.*manager-repo-a$' "$(cat "$log")"
expect "log: reuse is recorded" 'reused' "$(cat "$log")"

# 14. 子 manager: --parent で親を指定し、ラベルが名前になる（場所は同じ root）
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 -- manager --plan --parent manager-repo-a --label api)
expect "a child manager is planned under its parent" \
  "PLAN name=manager-api topology=tab .*parent=manager-repo-a depth=1" "$out"
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 -- manager --parent manager-repo-a --label api)
expect "the child manager starts" 'MANAGER=manager-api' "$out"
expect "the child names its parent" 'PARENT=manager-repo-a' "$out"
expect "the child is level 1" 'DEPTH=1' "$out"
expect "the child is at the root too" "REPO=$HARNESS_MANAGER_ROOT" "$out"
expect_not "a child has no PM of its own" '^PM=' "$out"
state="$XDG_CACHE_HOME/harness/herdr-agents/manager-api.json"
expect "the child records its parent" '"parent": "manager-repo-a"' "$(cat "$state")"
expect "the child records its boss" '"boss": "manager-repo-a"' "$(cat "$state")"
expect "the child records its depth" '"depth": "1"' "$(cat "$state")"

# 15. 1 体の manager は複数の子 manager を持てる
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 -- manager --parent manager-repo-a --label web)
expect "a manager holds several children" 'MANAGER=manager-web' "$out"
expect "the second child is level 1 as well" 'DEPTH=1' "$out"
expect "the second child names the same parent" 'PARENT=manager-repo-a' "$out"

# 16. 同じ (親, ラベル) は同じ子（聞き直しても増えない）
tabs=$(grep -c 'tab create' "$FAKE/log")
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 -- manager --parent manager-repo-a --label api)
expect "the same parent and label is the same child" 'STATE=reused' "$out"
(( $(grep -c 'tab create' "$FAKE/log") == tabs )) && echo "ok   no extra tab for the known child" ||
  { echo "FAIL another tab for a known child"; fails=$((fails + 1)); }

# 16b. 別のラベルの子を名前の形で取り違えない（billing-2026 と billing）
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 -- manager --parent manager-repo-a --label billing-2026)
expect "a longer label starts its own child" 'MANAGER=manager-billing-2026' "$out"
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 -- manager --parent manager-repo-a --label billing)
expect "a label that is another's prefix is its own child" 'MANAGER=manager-billing' "$out"
expect "the prefix label is started fresh" 'STATE=started' "$out"

# 17. 子 manager の下にさらに子（既定 3 段まで）
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 -- manager --parent manager-api --label ui)
expect "a child manager can hold children" 'MANAGER=manager-ui' "$out"
expect "the grandchild names its parent" 'PARENT=manager-api' "$out"
expect "the grandchild is level 2" 'DEPTH=2' "$out"
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 HARNESS_MANAGER_MAX_DEPTH=2 -- manager --parent manager-api --label deep); code=$?
((code == 2)) && echo "ok   the depth limit exits 2" || { echo "FAIL exit $code"; fails=$((fails + 1)); }
expect "the depth limit says why" 'depth limit' "$out"

# 18. 子 manager には --label が要る（名前の元が無い）
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 -- manager --parent manager-repo-a); code=$?
((code == 2)) && echo "ok   a child without a label exits 2" || { echo "FAIL exit $code"; fails=$((fails + 1)); }
expect "the child without a label is told what to add" 'needs --label' "$out"

# 19. 親は manager だけ（PM が子 manager を直に作らない）
out=$(cd "$TMP" && run HERDR_PANE_ID=w1:p4 -- manager --plan --parent pm-nanco-ads); code=$?
((code == 2)) && echo "ok   a non-manager parent exits 2" || { echo "FAIL exit $code"; fails=$((fails + 1)); }
expect "a non-manager parent is refused" 'must be a manager name' "$out"

# 20. 同じラベルが他所で埋まっていれば、子には suffix が付く
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 -- manager --plan --parent manager-repo-a --label nanco-ads)
expect "a taken label suffixes the child" 'PLAN name=manager-nanco-ads-[0-9a-f]{4} .*parent=manager-repo-a depth=1' "$out"

# 20b. top-level の suffix 経路でも子 manager は引き継がない
clash="manager-clash-$(printf 'pane:w1:p1' | sha1sum | cut -c1-4)"
echo idle > "$FAKE/agents/$clash"
printf '{"agent":"%s","pane":"w1:p9","tab":"t9","kind":"claude","topology":"tab","repo":"%s","parent":"manager-repo-a","boss":"manager-repo-a","depth":"1","session":"pane:w1:p1"}\n' \
  "$clash" "$HARNESS_MANAGER_ROOT" > "$XDG_CACHE_HOME/harness/herdr-agents/$clash.json"
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 -- manager --label clash)
expect "a top-level manager does not adopt a child" 'STATE=started' "$out"
expect "the new top-level manager has no parent" '^PARENT=-$' "$out"

# 21. manager 自身は --parent 無しで manager を起こさない（自分が返るのを防ぐ）
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 HERDR_AGENT_NAME=manager-repo-a -- manager --plan); code=$?
((code == 2)) && echo "ok   a manager cannot start a top-level manager" || { echo "FAIL exit $code"; fails=$((fails + 1)); }
expect "the manager is told to pass --parent" 'pass --parent manager-repo-a --label' "$out"

# 21b. 通常の呼び方: manager は自分を親にして子を分ける
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 HERDR_AGENT_NAME=manager-repo-a -- manager --parent manager-repo-a --label split)
expect "a manager starts a child under itself" 'MANAGER=manager-split' "$out"
expect "the child names the caller as its parent" 'PARENT=manager-repo-a' "$out"
expect "the child is level 1" 'DEPTH=1' "$out"
me="$XDG_CACHE_HOME/harness/herdr-agents/manager-repo-a.json"
expect_not "the caller keeps no parent" '"parent"' "$(cat "$me")"
expect "the caller stays at depth 0" '"depth": "0"' "$(cat "$me")"
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 HERDR_AGENT_NAME=manager-repo-a -- manager --parent manager-repo-a --label split)
expect "the child under itself is reused" 'STATE=reused' "$out"

# 21c. 子の名前が親と同じになるラベルだけは断る
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 HERDR_AGENT_NAME=manager-repo-a -- manager --parent manager-repo-a --label repo-a --plan); code=$?
((code == 2)) && echo "ok   a child named after its parent exits 2" || { echo "FAIL exit $code"; fails=$((fails + 1)); }
expect "the same-name refusal names the fix" 'cannot be named after its parent' "$out"

# 21d. suffix 付きの名前でも親と同じ名前は exit 2（hash が親名に落ちる場合）
# sha1("manager-x-64cb:x") の先頭 4 文字は 64cb なので、fallback 名が親そのものになる。
for n in manager-x manager-x-64cb; do
  echo idle > "$FAKE/agents/$n"
  printf '{"agent":"%s","pane":"w1:p9","tab":"t9","kind":"claude","topology":"tab","repo":"%s","depth":"0"}\n' \
    "$n" "$HARNESS_MANAGER_ROOT" > "$XDG_CACHE_HOME/harness/herdr-agents/$n.json"
done
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 -- manager --parent manager-x-64cb --label x --plan); code=$?
((code == 2)) && echo "ok   a suffixed name equal to the parent exits 2" || { echo "FAIL exit $code"; fails=$((fails + 1)); }
expect "the suffixed same-name refusal names the fix" 'cannot be named after its parent' "$out"

# 22. delegate の protocol 節: 子 manager は子を持てる、worker は持てない
printf 'child request\n' >"$TMP/req.md"
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 -- delegate manager-api "$TMP/req.md" --boss manager-repo-a --no-watch)
request=$(sed -n 's/^REQUEST=//p' <<<"$out")
[[ -f "$request" ]] && echo "ok   delegate wrote the request" || { echo "FAIL no request file"; fails=$((fails + 1)); }
expect "a child manager may start its own children" 'manager --parent manager-api --label' "$(cat "$request")"
expect "a child manager is told to report once" 'report manager-repo-a' "$(cat "$request")"
expect_not "the manager section expands its names" '[$]child|[$]boss|[$]self' "$(cat "$request")"
expect_not "a child manager is not told to stop starting agents" '他のエージェントを起動しない' "$(cat "$request")"
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 -- delegate manager-api "$TMP/req.md" --boss manager-web --no-watch); code=$?
((code == 2)) && echo "ok   a child manager refuses another boss" || { echo "FAIL exit $code"; fails=$((fails + 1)); }
expect "the child manager names its real boss" 'delegate with --boss manager-repo-a' "$out"
out=$(cd "$REPO" && run HERDR_PANE_ID=w1:p1 -- delegate child-b "$TMP/req.md" --boss manager-repo-a --no-watch)
request=$(sed -n 's/^REQUEST=//p' <<<"$out")
expect "a worker keeps the no-agents rule" '他のエージェントを起動しない' "$(cat "$request")"

echo ""
if ((fails == 0)); then
  echo "all pass"
  exit 0
fi
echo "$fails failed"
exit 1
