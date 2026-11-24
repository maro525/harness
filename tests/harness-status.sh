#!/bin/bash
# harness-status.py の fixture テスト。実環境の記録には触れず、一時ディレクトリだけを読ませる。
# Usage: tests/harness-status.sh   Exit: 0 = all pass

set -uo pipefail

HARNESS=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$HARNESS/claude/scripts/harness-status.py"
TMP=$(mktemp -d "/tmp/$(basename "$HARNESS").XXXXXX")
trap 'rm -rf "$TMP"' EXIT
fails=0

export XDG_CACHE_HOME="$TMP/cache" XDG_DATA_HOME="$TMP/data" HERDR_WORKTREE_ROOT="$TMP/wt"
export HARNESS_STATUS_HERDR="$TMP/no-such-herdr" HARNESS_CHECKS_DIR="$TMP/checks"
C="$XDG_CACHE_HOME/harness"; D="$XDG_DATA_HOME/harness"
mkdir -p "$C/herdr-agents" "$C/inbox/boss-a/done" "$D/locks" "$D/tasks/repo-a" "$D/tasks/repo-b" "$TMP/wt/repo-a/br" "$TMP/checks"

now=$(date +%s)
echo '{"agent":"s1","repo":"'"$TMP"'/wt/repo-a/br"}' > "$C/herdr-agents/s1.json"
echo '{broken' > "$C/herdr-agents/bad.json"
printf 'key=repo-a-live\nrunner=pi\ncwd=/x/elsewhere\nttl=45m\nupdated_epoch=%s\n' "$now" > "$D/locks/repo-a-live.lock"
printf 'key=repo-a-old\nrunner=pi\ncwd=/x/elsewhere\nttl=45m\nupdated_epoch=%s\n' "$((now - 99999))" > "$D/locks/repo-a-old.lock"
: > "$D/locks/repo-a-old.lock.guard"
printf '## Meta\n- status: implementing\n' > "$D/tasks/repo-a/task-X-1.md"
printf '## Meta\n- status: done\n' > "$D/tasks/repo-b/task-X-2.md"
: > "$C/inbox/boss-a/r1.md"; : > "$C/inbox/boss-a/r2.md"; : > "$C/inbox/boss-a/done/old.md"
printf '#!/bin/bash\nexit 0\n' > "$TMP/checks/crossrefs.sh"
printf '#!/bin/bash\necho "NG: broken"; exit 1\n' > "$TMP/checks/phases.sh"
printf '#!/bin/bash\necho "skip: nothing"; exit 0\n' > "$TMP/checks/worktrees.sh"

out=$(python3 -I "$SCRIPT" 2>&1); code=$?

expect() { # name pattern
  if grep -Eq -- "$2" <<<"$out"; then echo "ok   $1"; else echo "FAIL $1 (/$2/)"; fails=$((fails + 1)); fi
}
(( code == 0 )) && echo "ok   exit 0" || { echo "FAIL exit $code"; fails=$((fails + 1)); }
expect "herdr unreachable is 確認不可, not stopped" '■ Herdr +確認不可'
expect "sessions: broken record and unknown liveness" 'セッション記録 +2 件'
expect "locks: guard not counted, expired detected" 'ロック +2 件（expired 1, live 1）'
expect "tasks: counts all, lists active only" 'タスクファイル +2 件 / 実行中 1 件'
expect "worktree in use by a record" 'worktree +1 件（in-use 1）'
expect "inbox counts unread, ignores done/" '未読 2 件'
expect "checks distinguish ok / fail / skip" 'checks +(skip 1|成功 1|失敗 1)(, (skip 1|成功 1|失敗 1)){2}'
expect "check failure shows NG line" '失敗 +phases +NG: broken'

out=$(python3 -I "$SCRIPT" --repo repo-b --no-checks 2>&1)
expect "--repo filters tasks" 'タスクファイル +1 件 / 実行中 0 件'

# --- 2回目: レビュー指摘の回帰 ---
printf '## Meta\n- status:\n- branch: x\n## team-implement\n- status: implementing\n' > "$D/tasks/repo-b/task-X-3.md"
out=$(python3 -I "$SCRIPT" --repo repo-b --all --no-checks 2>&1)
expect "empty status is 未記入, not the next line" '未記入'
expect "status outside ## Meta is ignored" '実行中 0 件'

out=$(HARNESS_STATUS_HERDR_TIMEOUT= HARNESS_STATUS_CHECK_TIMEOUT=abc python3 -I "$SCRIPT" --no-checks 2>&1); code=$?
(( code == 0 )) && echo "ok   bad timeout env does not abort" || { echo "FAIL bad timeout env exit $code"; fails=$((fails + 1)); }
expect "bad timeout env still prints sections" 'inbox'

cat > "$TMP/fake-herdr" <<'FAKE'
#!/bin/bash
case "$1 $2" in
  "status server") echo "status: running" ;;
  "agent list") echo "$FAKE_AGENTS" ;;
esac
FAKE
chmod +x "$TMP/fake-herdr"
export HARNESS_STATUS_HERDR="$TMP/fake-herdr"
out=$(FAKE_AGENTS='{"result":{"agents":null}}' python3 -I "$SCRIPT" --no-checks 2>&1)
expect "agents:null degrades to 確認不可 and keeps other sections" '■ Herdr +running（agent 一覧は確認不可'
expect "agents:null still prints inbox" '■ inbox'
A='{"result":{"agents":[{"name":"a1","agent_status":"working","cwd":"'"$TMP"'/wt/repo-a/br"},{"name":"b1","agent_status":"idle","cwd":"/x/repo-b"}]}}'
out=$(FAKE_AGENTS="$A" python3 -I "$SCRIPT" --repo repo-a --no-checks 2>&1)
expect "--repo narrows herdr agents" 'Herdr +running / 名前付き agent 1 件'
out=$(FAKE_AGENTS="$A" python3 -I "$SCRIPT" --all --no-checks 2>&1)
expect "--all lists non-working agents" 'idle +b1'
out=$(FAKE_AGENTS=$'{"result":{"agents":[{"name":"e\u001b[2Jx","agent_status":"idle","cwd":""}]}}' python3 -I "$SCRIPT" --all --no-checks 2>&1)
if grep -q $'\033' <<<"$out"; then echo "FAIL control chars stripped"; fails=$((fails + 1)); else echo "ok   control chars stripped"; fi

# --- 3回目: task-file.sh との保存先・repo 名の一致 ---
export HARNESS_STATUS_HERDR="$TMP/no-such-herdr"
R="$TMP/src/My Repo.x"; git init -q "$R"
E="$TMP/env"; mkdir -p "$E/tasks/My-Repo.x-123" "$E/tasks/other" "$E/locks"
printf '%s' "$R/.git" > "$E/tasks/My-Repo.x-123/.origin"
printf '## Meta\n- status: planning\n' > "$E/tasks/My-Repo.x-123/task-Y-1.md"
printf '## Meta\n- status: planning\n' > "$E/tasks/other/task-Y-2.md"
printf 'key=My-Repo.x-env\nrunner=pi\ncwd=%s\nttl=45m\nupdated_epoch=%s\n' "$TMP" "$now" > "$E/locks/k-env.lock"
printf 'key=k-else\nrunner=pi\ncwd=/nowhere/else\nttl=45m\nupdated_epoch=%s\n' "$now" > "$E/locks/k-else.lock"
out=$(HARNESS_TASKS_DIR="$E/tasks" python3 -I "$SCRIPT" --no-checks 2>&1)
expect "HARNESS_TASKS_DIR is honored; locks follow its sibling" 'ロック +2 件'
out=$(HARNESS_TASKS_DIR="$E/tasks" HARNESS_LOCKS_DIR="$E/locks" python3 -I "$SCRIPT" --repo My-Repo.x --no-checks 2>&1)
expect "HARNESS_LOCKS_DIR + repo key from git common dir (sanitized)" 'ロック +1 件'
expect "bucket with hash suffix maps back to repo key" 'タスクファイル +1 件 / 実行中 1 件'

# checks timeout は 確認不可
printf '#!/bin/bash\nsleep 5\n' > "$TMP/checks/crossrefs.sh"
out=$(HARNESS_STATUS_CHECK_TIMEOUT=1 python3 -I "$SCRIPT" 2>&1)
expect "check timeout is 確認不可" '確認不可.*crossrefs|crossrefs.*確認不可|確認不可 1'

# 改行・タブも出力から潰す
out=$(FAKE_AGENTS=$'{"result":{"agents":[{"name":"a\\nFAKE","agent_status":"idle","cwd":""}]}}' HARNESS_STATUS_HERDR="$TMP/fake-herdr" python3 -I "$SCRIPT" --all --no-checks 2>&1)
if grep -q '^FAKE' <<<"$out"; then echo "FAIL newline injection"; fails=$((fails + 1)); else echo "ok   newline injection stripped"; fi

# --- 4回目: consult 記録の cwd / 非 ASCII の repo key / 配布先の checks ---
export HARNESS_STATUS_HERDR="$TMP/no-such-herdr"
mkdir -p "$TMP/cache4/harness/herdr-consult"
printf '{"agent":"cons1","cwd":"%s/wt/repo-c/br"}' "$TMP" > "$TMP/cache4/harness/herdr-consult/cons1.json"
out=$(XDG_CACHE_HOME="$TMP/cache4" python3 -I "$SCRIPT" --repo repo-c --no-checks 2>&1)
expect "consult record cwd maps to repo" 'セッション記録 +1 件'
K="$TMP/src/日本"; git init -q "$K"
out=$(python3 -I - <<PY
import importlib.util
spec = importlib.util.spec_from_file_location("hs", "$SCRIPT"); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.repo_key("$K"), m.repo_key("$R"), repr(m.repo_key("/no/such")))
PY
)
[[ "$out" == "------ My-Repo.x ''" ]] && echo "ok   repo key comes from task-file.sh" || { echo "FAIL repo key: $out"; fails=$((fails + 1)); }

mkdir -p "$TMP/home5/.claude/scripts" "$TMP/home5/checks"
cp "$SCRIPT" "$TMP/home5/.claude/scripts/"
out=$(HOME="$TMP/home5" HARNESS_CHECKS_DIR= python3 -I "$TMP/home5/.claude/scripts/harness-status.py" 2>&1)
expect "installed copy does not pick an incomplete ~/checks" 'checks +確認不可'

# --- 5回目: 設計変更後の回帰 ---
# 読み取り専用: 未知の repo を見ても bucket を作らない
ls "$D/tasks" > "$TMP/before.txt"
python3 -I "$SCRIPT" --repo anything --no-checks >/dev/null 2>&1
ls "$D/tasks" | cmp -s - "$TMP/before.txt" && echo "ok   status creates no bucket" || { echo "FAIL status created a bucket"; fails=$((fails + 1)); }
# ロックは cwd でなく key の接頭辞で所属 repo を決める（--repo=<target> で取った lease）
out=$(python3 -I "$SCRIPT" --repo repo-a --no-checks 2>&1)
expect "lock belongs to repo by key prefix, not cwd" 'ロック +2 件'
out=$(python3 -I "$SCRIPT" --repo repo-b --no-checks 2>&1)
expect "lock of another repo not counted" 'ロック +0 件'
# waiting-gate は既定表示に出る
printf '## Meta\n- status: waiting-gate1\n' > "$D/tasks/repo-a/task-X-gate.md"
out=$(python3 -I "$SCRIPT" --repo repo-a --no-checks 2>&1)
expect "waiting-gate is listed by default" 'waiting-gate1 +task-X-gate.md'
# 不正 UTF-8 は 1 ファイルだけ「不正」になり、他は出る
printf '## Meta\n- status: \xff\xfe\n' > "$D/tasks/repo-a/task-X-bad.md"
printf 'key=repo-a-bad\n\xff\xfe\n' > "$D/locks/repo-a-bad.lock"
out=$(python3 -I "$SCRIPT" --repo repo-a --no-checks 2>&1)
expect "bad UTF-8 task is per-file" 'タスクファイル +[0-9]+ 件 / 実行中 [1-9]'
expect "bad UTF-8 lock is per-file" 'ロック +3 件'
rm -f "$D/tasks/repo-a/task-X-bad.md" "$D/locks/repo-a-bad.lock"
# cwd 欠落の agent は --repo の件数に入らない
out=$(FAKE_AGENTS='{"result":{"agents":[{"name":"nocwd","agent_status":"working"}]}}' HARNESS_STATUS_HERDR="$TMP/fake-herdr" python3 -I "$SCRIPT" --repo harness --no-checks 2>&1)
expect "agent without cwd is not attributed to --repo" 'agent 0 件'
# worktree 配下のサブディレクトリで動く consult 記録は使用中
mkdir -p "$TMP/wt/repo-c/br/sub" "$TMP/cache6/harness/herdr-consult"
printf '{"agent":"c6","cwd":"%s/wt/repo-c/br/sub"}' "$TMP" > "$TMP/cache6/harness/herdr-consult/c6.json"
out=$(XDG_CACHE_HOME="$TMP/cache6" python3 -I "$SCRIPT" --repo repo-c --no-checks 2>&1)
expect "subdirectory record keeps worktree in-use" 'worktree +1 件（in-use 1）'
# 配布先: 3 本そろった ~/checks があっても選ばない
for n in crossrefs phases worktrees; do printf '#!/bin/bash\necho SHOULD-NOT-RUN\n' > "$TMP/home5/checks/$n.sh"; done
out=$(HOME="$TMP/home5" HARNESS_CHECKS_DIR= python3 -I "$TMP/home5/.claude/scripts/harness-status.py" 2>&1)
if grep -q 'SHOULD-NOT-RUN\|checks +成功' <<<"$out"; then echo "FAIL installed copy ran ~/checks"; fails=$((fails + 1)); else echo "ok   installed copy ignores complete ~/checks"; fi

python3 -I "$SCRIPT" --help >/dev/null 2>&1 && echo "ok   --help" || { echo "FAIL --help"; fails=$((fails + 1)); }
(( fails == 0 )) && echo "all passed" || echo "$fails failed"
exit $(( fails > 0 ))
