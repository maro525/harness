#!/bin/bash
# herdr-agent.sh — run any coding agent in its own Herdr tab and talk to it.
#
# The generic counterpart of claude-consult.sh: that one is Claude-specific
# (roles, claude flags), this one only needs "some agent, in a tab, that I can
# send a request to". Used to hand work to another CLI (pi / codex / opencode)
# without leaving the current session.
#
# The agent is started once per (name, repo) and reused: its own tab, its
# session and its context stay alive between calls.
#
# Usage:
#   herdr-agent.sh ensure <name> --kind KIND [OPTIONS]    tab + agent (idempotent)
#   herdr-agent.sh restart <name> [OPTIONS]               fresh session, same tab
#   herdr-agent.sh ask    <name> <request-file|-> [OPTIONS]
#   herdr-agent.sh send   <name> KEY [KEY...]           logical keys (esc, ctrl+c, ...)
#   herdr-agent.sh read   <name> [--lines N]
#   herdr-agent.sh state  <name>
#   herdr-agent.sh close  <name>                          close the tab it owns
#   herdr-agent.sh reap   [--kind KIND]                   close every recorded session
#   herdr-agent.sh list
#
# Boss pattern (a boss delegates and never waits; children report back):
#   herdr-agent.sh delegate <child> <request-file|-> [--boss B] [--no-watch] [--watch-timeout T]
#                                                       hand work over and return at once
#   herdr-agent.sh report <boss> <report-file|-> [--from CHILD] [--kind report|question]
#                                                       run by the child: inbox file + notify
#   herdr-agent.sh inbox  [<boss>] [list|read|ack|clear] [<child>|<file>]
#                                                       the boss reads its inbox (with the
#                                                       action first, the boss is resolved
#                                                       like --boss; ack without a file acks
#                                                       only what the last read printed)
#   herdr-agent.sh watch  <child> --boss B [--watch-timeout T]
#                                                       internal: started detached by delegate
#
# The inbox (${XDG_CACHE_HOME:-~/.cache}/harness/inbox/<boss>/) is the record;
# the notification (a one-line `herdr agent prompt` to the boss, else
# `herdr notification show`) is only a hint. report and inbox work without a
# Herdr server (only the notification is lost).
#
# Options:
#   --kind KIND       agent kind recognized by herdr (claude | pi | codex | ...)
#   --repo DIR        repository to run in (default: $PWD)
#                     Outside Herdr (no HERDR_WORKSPACE_ID) a tab has no workspace
#                     to attach to, so a new workspace is created instead.
#   --topology T      tab (default) | workspace | worktree
#                     tab        : a new tab in the calling workspace
#                     workspace  : a new workspace for the repo (no git changes)
#                     worktree   : a new git worktree + its workspace + a tab
#   --branch BR       worktree: branch to create (default: herdr/<name>)
#   --base REF        worktree: base ref (default: the repo's HEAD)
#   --timeout T       ask: overall timeout, e.g. 20m (default: $HERDR_AGENT_TIMEOUT or 20m)
#   --answer-file F   ask: wait for this file instead of just the settled state
#   --lines N         read: how much scrollback (default 200)
#   --boss B          delegate / watch: who the child reports to (default: $HERDR_BOSS,
#                     else the calling pane's agent name, else $HERDR_PANE_ID)
#   --from CHILD      report: who is reporting (default: this pane's agent name / pane id)
#   --kind K          report: report (default) | question
#   --no-watch        delegate: do not start the watcher
#   --no-wait         ask: hand the request over and return (fan-out; poll yourself)
#   --watch-timeout T delegate / watch: watcher lifetime (default: $HERDR_WATCH_TIMEOUT or 2h).
#                     The watcher reports a child idle without a report after
#                     $HERDR_WATCH_GRACE (default 90s), and leaves an .expired note
#                     when the lifetime runs out first.
#   -- ARGS...        ensure: native arguments for the agent (after --)
#   -h, --help
#
# stdout: ask prints the answer (the --answer-file content, else the pane tail);
#         report prints the inbox file; inbox prints the list / the reports
# stderr: AGENT= / PANE= / KIND= / REPO= / STATE=
#         delegate: AGENT= / BOSS= / REQUEST= / WATCH=<pid|none> / STATE=
#         report:   INBOX= / NOTIFY=<prompt|notification|none>
# exit:   0 = ok, 1 = failed, 2 = usage error

set -uo pipefail

STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/harness/herdr-agents"

die() {
  printf 'herdr-agent: %s\n' "$1" >&2
  exit "${2:-1}"
}

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

# A live Herdr server is what matters, not whether this process lives in a
# pane: everything here addresses panes by id, so a plain terminal works too.
# Checked after argument parsing so that --help works without a server.
herdr_reachable() {
  command -v herdr >/dev/null 2>&1 || return 1
  herdr workspace list >/dev/null 2>&1
}
command -v jq >/dev/null 2>&1 || die "jq is not installed" 1

CMD=""
NAME=""
REQUEST=""
KIND=""
REPO=""
TIMEOUT=${HERDR_AGENT_TIMEOUT:-20m}
TOPOLOGY=${HERDR_AGENT_TOPOLOGY:-tab}
BRANCH=""
BASE=""
ANSWER_FILE=""
LINES=200
NATIVE_ARGS=()
BOSS=""
FROM=""
TARGET=""
WATCH=1
NO_WAIT=0
WATCH_TIMEOUT=${HERDR_WATCH_TIMEOUT:-2h}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kind) KIND=$2; shift 2 ;;
    --repo) REPO=$2; shift 2 ;;
    --timeout) TIMEOUT=$2; shift 2 ;;
    --topology) TOPOLOGY=$2; shift 2 ;;
    --branch) BRANCH=$2; shift 2 ;;
    --base) BASE=$2; shift 2 ;;
    --answer-file) ANSWER_FILE=$2; shift 2 ;;
    --lines) LINES=$2; shift 2 ;;
    --boss) BOSS=$2; shift 2 ;;
    --from) FROM=$2; shift 2 ;;
    --no-watch) WATCH=0; shift ;;
    --no-wait) NO_WAIT=1; shift ;;
    --watch-timeout) WATCH_TIMEOUT=$2; shift 2 ;;
    --) shift; NATIVE_ARGS=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    --*) die "unknown option: $1" 2 ;;
    *)
      if [[ -z "$CMD" ]]; then
        CMD=$1
      elif [[ "$CMD" == "send" && -n "$NAME" ]]; then
        # send takes KEY [KEY...]: every positional after the name is a key.
        NATIVE_ARGS+=("$1")
      elif [[ -z "$NAME" ]]; then
        NAME=$1
      elif [[ -z "$REQUEST" ]]; then
        REQUEST=$1
      elif [[ "$CMD" == "inbox" && -z "$TARGET" ]]; then
        # inbox <boss> <action> <child>: the child filter is a third positional.
        TARGET=$1
      else
        die "unexpected argument: $1" 2
      fi
      shift
      ;;
  esac
done

[[ -n "$CMD" ]] || { usage >&2; exit 2; }

# A claude child must not stop on approval dialogs: nobody is watching its pane.
# Unless the caller picked a mode explicitly, start it in `auto` (the same default
# consult sessions use). Without this, a caller that passes no flags inherits
# nothing in particular and a caller copying an old example got `acceptEdits`.
if [[ "${KIND:-}" == "claude" ]]; then
  has_mode=0
  for arg in ${NATIVE_ARGS[@]+"${NATIVE_ARGS[@]}"}; do
    case "$arg" in --permission-mode|--permission-mode=*) has_mode=1 ;; esac
  done
  if (( has_mode == 0 )) && [[ "$CMD" == "ensure" || "$CMD" == "restart" ]]; then
    NATIVE_ARGS+=(--permission-mode auto)
  fi
fi

# Naming rule (docs/naming.md): lowercase words joined by '-'. The name becomes
# the Herdr agent name, the tab label and (with --topology worktree) the
# workspace label. Herdr itself refuses anything but [a-z][a-z0-9_-]{0,31}, and
# it does so *after* the tab exists, so check the same rule here and fail before
# anything is created. '-' is the house style; '_' is accepted with a warning.
check_name() {
  local name=$1
  if [[ ! "$name" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
    die "invalid name '$name': use [a-z][a-z0-9_-] up to 32 chars (docs/naming.md)" 2
  fi
  case "$name" in
    *_*) echo "herdr-agent: warning: prefer '-' over '_' in '$name' (docs/naming.md)" >&2 ;;
  esac
}
# report / inbox only touch files: they must keep working when the server is
# down (the notification is checked on its own and degrades to a warning).
case "$CMD" in
  report|inbox) ;;
  *)
    herdr_reachable ||
      die "no herdr CLI in PATH, or no Herdr server answered — start herdr first" 1
    ;;
esac

state_file() { printf '%s/%s.json' "$STATE_DIR" "$1"; }
state_field() { jq -r --arg k "$2" '.[$k] // empty' "$1" 2>/dev/null || true; }

timeout_seconds() {
  local t=$1 mult=1 num
  case "$t" in
    *m) mult=60; num=${t%m} ;;
    *s) num=${t%s} ;;
    *h) mult=3600; num=${t%h} ;;
    *) num=$t ;;
  esac
  [[ "$num" =~ ^[0-9]+$ ]] || die "invalid timeout: $t" 2
  printf '%s' $((num * mult))
}

agent_state() {
  herdr agent get "$1" 2>/dev/null |
    jq -r '.result.agent.agent_status // .result.agent.state // .result.state // "unknown"' 2>/dev/null ||
    printf 'unknown'
}

pane_stable() {
  local name=$1 prev="" cur="" stable=0 waited=0
  while ((waited < 20)); do
    sleep 1
    waited=$((waited + 1))
    cur=$(herdr agent read "$name" --source recent --lines 8 2>/dev/null || true)
    if [[ -n "$cur" && "$cur" == "$prev" ]]; then
      stable=$((stable + 1))
      ((stable >= 2)) && return 0
    else
      stable=0
    fi
    prev=$cur
  done
  return 0
}


cmd_ensure() {
  [[ -n "$NAME" ]] || die "ensure needs a name" 2
  check_name "$NAME"
  [[ -n "$KIND" ]] || die "ensure needs --kind" 2
  REPO=${REPO:-$PWD}
  REPO=$(cd "$REPO" && pwd) || die "not a directory: $REPO"

  local state pane recorded_cwd
  state=$(state_file "$NAME")
  pane=""
  if [[ -f "$state" ]]; then
    pane=$(state_field "$state" pane)
    recorded_cwd=$(state_field "$state" repo)
    if [[ -n "$pane" ]] && herdr agent get "$NAME" >/dev/null 2>&1; then
      if [[ "$recorded_cwd" == "$REPO" ]]; then
        echo "AGENT=$NAME" >&2
        echo "PANE=$pane" >&2
        echo "KIND=$KIND" >&2
        echo "REPO=$REPO" >&2
        echo "STATE=reused" >&2
        return 0
      fi
      echo "herdr-agent: $NAME was started in $recorded_cwd — replacing its tab" >&2
    fi
    cmd_close >/dev/null 2>&1 || true
  fi

  # Topology: a tab in the caller's workspace (default), a workspace of its own,
  # or a git worktree plus its workspace. All three answers carry
  # .result.{workspace,tab,root_pane}.
  local created tab workspace="" ws_owned="false"
  case "$TOPOLOGY" in
    tab)
      # --workspace pins the tab to the caller's workspace: without it the tab can
      # land in whatever workspace another client has focused.
      local -a tab_args=(--cwd "$REPO" --label "$NAME")
      [[ -n "${HERDR_WORKSPACE_ID:-}" ]] && tab_args+=(--workspace "$HERDR_WORKSPACE_ID")
      if ! created=$(herdr tab create "${tab_args[@]}" --no-focus 2>&1); then
        # No workspace to attach to (or the id is stale): fall back to a workspace.
        echo "herdr-agent: tab create failed — creating a workspace instead" >&2
        TOPOLOGY=workspace
        created=$(herdr workspace create --cwd "$REPO" --label "$NAME" --no-focus 2>&1) ||
          die "herdr workspace create failed: $created"
        ws_owned="true"
      fi
      ;;
    workspace)
      created=$(herdr workspace create --cwd "$REPO" --label "$NAME" --no-focus 2>&1) ||
        die "herdr workspace create failed: $created"
      ws_owned="true"
      ;;
    worktree)
      local -a wt_args=(--cwd "$REPO" --label "$NAME" --no-focus)
      [[ -n "$BRANCH" ]] && wt_args+=(--branch "$BRANCH")
      [[ -n "$BASE" ]] && wt_args+=(--base "$BASE")
      created=$(herdr worktree create "${wt_args[@]}" 2>&1) ||
        die "herdr worktree create failed: $created"
      ws_owned="true"
      ;;
    *) die "unknown --topology: $TOPOLOGY (tab | workspace | worktree)" 2 ;;
  esac

  pane=$(jq -r '.result.root_pane.pane_id // .result.tab.root_pane.pane_id // .result.pane.pane_id // empty' <<<"$created")
  tab=$(jq -r '.result.tab.tab_id // .result.tab_id // empty' <<<"$created")
  workspace=$(jq -r '.result.workspace.workspace_id // .result.workspace_id // empty' <<<"$created")
  [[ -n "$pane" ]] || die "could not read the pane id from: $created"
  [[ -n "$tab" ]] && herdr tab rename "$tab" "$NAME" >/dev/null 2>&1 || true
  # A worktree workspace has its own directory; run there, not in REPO.
  if [[ "$TOPOLOGY" == "worktree" ]]; then
    local wt_path
    wt_path=$(jq -r '.result.workspace.identity_cwd // .result.worktree.path // empty' <<<"$created" 2>/dev/null || true)
    [[ -n "$wt_path" ]] && REPO=$wt_path
  fi

  # config.toml may set [terminal] new_cwd = "follow", which sends the new pane
  # to the calling pane's directory and ignores --cwd. Move it ourselves.
  local pane_cwd
  pane_cwd=$(herdr pane get "$pane" 2>/dev/null | jq -r '.result.pane.cwd // empty' 2>/dev/null || true)
  if [[ -n "$pane_cwd" && "$pane_cwd" != "$REPO" ]]; then
    herdr pane run "$pane" "cd $(printf '%q' "$REPO")" >/dev/null 2>&1 || true
    sleep 1
  fi

  # Record the session before starting it: if the agent fails to start (a bad
  # name, an approval dialog), the tab/worktree already exists and `close` has to
  # be able to find it. The start failure below leaves it recorded.
  mkdir -p "$STATE_DIR"
  jq -n --arg agent "$NAME" --arg pane "$pane" --arg tab "$tab" --arg kind "$KIND" \
    --arg workspace "$workspace" --arg topology "$TOPOLOGY" --argjson ws_owned "$ws_owned" \
    --arg repo "$REPO" --arg created "$(date -Iseconds)" \
    '{agent:$agent, pane:$pane, tab:$tab, tab_owned:true, workspace:$workspace,
      workspace_owned:$ws_owned, topology:$topology, kind:$kind, repo:$repo,
      created:$created}' >"$state"

  herdr agent start "$NAME" --kind "$KIND" --pane "$pane" -- "${NATIVE_ARGS[@]}" >&2 ||
    die "could not start $KIND in $pane — $NAME is recorded, so \`herdr-agent.sh close $NAME\` cleans it up"
  pane_stable "$NAME"

  echo "AGENT=$NAME" >&2
  echo "PANE=$pane" >&2
  echo "TAB=$tab" >&2
  echo "KIND=$KIND" >&2
  echo "REPO=$REPO" >&2
  echo "STATE=started" >&2
}

cmd_ask() {
  [[ -n "$NAME" ]] || die "ask needs a name" 2
  [[ -n "$REQUEST" ]] || die "ask needs a request file (or -)" 2
  [[ -f "$(state_file "$NAME")" ]] || die "$NAME is not registered — run ensure first" 2

  local prompt
  if [[ "$REQUEST" == "-" ]]; then prompt=$(cat); else
    [[ -f "$REQUEST" ]] || die "request file not found: $REQUEST" 2
    prompt=$(cat "$REQUEST")
  fi
  [[ -n "$prompt" ]] || die "empty request" 2

  local repo timeout_s request_path pointer
  repo=$(state_field "$(state_file "$NAME")" repo)
  timeout_s=$(timeout_seconds "$TIMEOUT")

  # The full request goes to a file and only a one-line pointer is typed into
  # the pane: long bracketed pastes can be swallowed while the TUI repaints.
  local request_dir="${TMPDIR:-/tmp}/harness-agent"
  mkdir -p "$request_dir"
  request_path="$request_dir/$NAME.request.md"
  printf '%s\n' "$prompt" >"$request_path"
  pointer="Read $request_path and do exactly what it says. Do not ask questions first."

  if [[ -n "$ANSWER_FILE" ]]; then
    : >"$ANSWER_FILE" 2>/dev/null || true
    rm -f "$ANSWER_FILE"
  fi

  local out rc=0
  set +e
  if [[ "$NO_WAIT" == "1" ]]; then
    # Hand the request over and return: the caller fans out several sessions and
    # polls them itself. --wait --until working only observes that the turn
    # started (and presses Enter once if the pointer sits unsent).
    out=$(herdr agent prompt "$NAME" "$pointer" --wait --until working --until blocked --timeout 8000 2>&1)
    rc=$?
    set -e
    if ((rc != 0)); then
      echo "herdr-agent: submission returned $(jq -r '.error.code // "error"' <<<"$out" 2>/dev/null || echo error)" >&2
      exit 1
    fi
    echo "SENT=$NAME" >&2
    exit 0
  fi
  out=$(herdr agent prompt "$NAME" "$pointer" 2>&1)
  rc=$?
  set -e
  if ((rc != 0)); then
    echo "herdr-agent: submission returned $(jq -r '.error.code // "error"' <<<"$out" 2>/dev/null || echo error) — polling anyway" >&2
  fi

  # Poll: answer file first (stable size), otherwise wait for the agent to
  # settle and use the pane tail. A fresh TUI can swallow the submit Enter, so
  # resubmit when the agent stays idle without producing anything.
  local waited=0 resends=0 resend_at=8 size_prev="" size_now state_now
  while :; do
    if [[ -n "$ANSWER_FILE" && -s "$ANSWER_FILE" ]]; then
      size_now=$(wc -c <"$ANSWER_FILE" 2>/dev/null || echo 0)
      if [[ "$size_now" == "$size_prev" && "$size_now" != "0" ]]; then
        break
      fi
      size_prev=$size_now
    fi

    state_now=$(agent_state "$NAME")
    if [[ "$state_now" == "idle" || "$state_now" == "done" ]] && ((waited >= 4)); then
      if [[ -z "$ANSWER_FILE" || -s "$ANSWER_FILE" ]]; then break; fi
    fi

    ((waited >= timeout_s)) && break

    if ((waited >= resend_at && resends < 3)); then
      if [[ "$state_now" == "idle" || "$state_now" == "done" ]]; then
        herdr agent send-keys "$NAME" ctrl+c >/dev/null 2>&1 || true
        sleep 1
        set +e
        out=$(herdr agent prompt "$NAME" "$pointer" 2>&1)
        set -e
        resends=$((resends + 1))
        resend_at=$((waited + 20))
        echo "herdr-agent: nothing started a turn ($state_now) — resubmitted ($resends)" >&2
      else
        resend_at=$((waited + 20))
      fi
    fi

    sleep 2
    waited=$((waited + 2))
  done

  echo "STATE=$(agent_state "$NAME")" >&2

  if [[ -n "$ANSWER_FILE" && -s "$ANSWER_FILE" ]]; then
    cat "$ANSWER_FILE"
    return 0
  fi

  local tail_text
  tail_text=$(herdr agent read "$NAME" --source recent-unwrapped --lines "$LINES" 2>/dev/null || true)
  printf '%s\n' "$tail_text"
  [[ -n "$tail_text" ]] || die "no output from $NAME" 1
}

# Stop the agent in its recorded pane and start a new one there: a fresh
# context in the same tab, without opening another tab.
cmd_restart() {
  [[ -n "$NAME" ]] || die "restart needs a name" 2
  check_name "$NAME"
  local state pane tab kind repo waited=0
  state=$(state_file "$NAME")
  [[ -f "$state" ]] || die "$NAME is not registered — run ensure first" 2
  pane=$(state_field "$state" pane)
  tab=$(state_field "$state" tab)
  kind=$(state_field "$state" kind)
  repo=$(state_field "$state" repo)
  [[ -n "$pane" ]] || die "no pane recorded for $NAME" 1
  REPO=${repo:-$PWD}

  if herdr agent get "$NAME" >/dev/null 2>&1; then
    # Quit politely first: Esc leaves the scrollback view (a TUI that is scrolled
    # does not deliver typed input to the prompt), then /exit works for pi and claude.
    herdr agent send-keys "$NAME" esc >/dev/null 2>&1 || true
    herdr agent send-keys "$NAME" ctrl+end >/dev/null 2>&1 || true
    sleep 1
    herdr agent prompt "$NAME" "/exit" >/dev/null 2>&1 || true
    while ((waited < 10)); do
      herdr agent get "$NAME" >/dev/null 2>&1 || break
      sleep 1
      waited=$((waited + 1))
    done
    if herdr agent get "$NAME" >/dev/null 2>&1; then
      # ctrl+d quits when the editor is empty (pi); ctrl+c twice is the fallback.
      herdr agent send-keys "$NAME" ctrl+d >/dev/null 2>&1 || true
      sleep 1
      herdr agent send-keys "$NAME" ctrl+c >/dev/null 2>&1 || true
      sleep 1
      herdr agent send-keys "$NAME" ctrl+c >/dev/null 2>&1 || true
      waited=0
      while ((waited < 10)); do
        herdr agent get "$NAME" >/dev/null 2>&1 || break
        sleep 1
        waited=$((waited + 1))
      done
    fi
  fi
  if herdr agent get "$NAME" >/dev/null 2>&1; then
    die "$NAME is still running in $pane — quit it by hand, then rerun" 1
  fi

  # The pane must be at a shell prompt again; the agent start below validates it.
  herdr agent start "$NAME" --kind "${kind:-pi}" --pane "$pane" -- "${NATIVE_ARGS[@]}" >&2 ||
    die "could not start ${kind:-pi} in $pane (is the shell prompt back?)"
  pane_stable "$NAME"

  # Older state files recorded no tab; take it from the agent now.
  if [[ -z "$tab" ]]; then
    tab=$(herdr agent get "$NAME" 2>/dev/null |
      jq -r '.result.agent.tab_id // empty' 2>/dev/null || true)
    if [[ -n "$tab" ]]; then
      jq --arg tab "$tab" '. + {tab:$tab}' "$state" >"$state.tmp" && mv "$state.tmp" "$state"
    fi
  fi

  echo "AGENT=$NAME" >&2
  echo "PANE=$pane" >&2
  echo "TAB=$tab" >&2
  echo "KIND=${kind:-pi}" >&2
  echo "REPO=$REPO" >&2
  echo "STATE=restarted" >&2
}

cmd_send() {
  [[ -n "$NAME" ]] || die "send needs a name" 2
  local -a keys=()
  [[ -n "$REQUEST" ]] && keys+=("$REQUEST")
  keys+=(${NATIVE_ARGS[@]+"${NATIVE_ARGS[@]}"})
  ((${#keys[@]} > 0)) || die "send needs at least one key" 2
  herdr agent send-keys "$NAME" "${keys[@]}"
}
cmd_read() {
  [[ -n "$NAME" ]] || die "read needs a name" 2
  herdr agent read "$NAME" --source recent-unwrapped --lines "$LINES"
}

cmd_state() {
  [[ -n "$NAME" ]] || die "state needs a name" 2
  printf '%s\n' "$(agent_state "$NAME")"
}

# Close the session recorded for <name>.
close_named() {
  local name=$1 state pane tab
  state=$(state_file "$name")
  if [[ ! -f "$state" ]]; then
    echo "herdr-agent: $name is not registered" >&2
    return 1
  fi
  pane=$(state_field "$state" pane)
  tab=$(state_field "$state" tab)
  # Close the workspace we created (it takes its tab with it), else the tab we
  # created, else just the pane: never a workspace/tab we did not create.
  # A worktree workspace also owns a git worktree on disk: remove it too (no
  # --force — a dirty worktree is left alone and reported).
  local workspace ws_owned topology
  workspace=$(state_field "$state" workspace)
  ws_owned=$(state_field "$state" workspace_owned)
  topology=$(state_field "$state" topology)
  if [[ "$ws_owned" == "true" && -n "$workspace" ]]; then
    if [[ "$topology" == "worktree" ]]; then
      if herdr worktree remove --workspace "$workspace" >/dev/null 2>&1; then
        rm -f "$state"
        echo "closed worktree workspace $workspace ($name)" >&2
        return 0
      fi
      echo "herdr-agent: could not remove the worktree for $workspace (uncommitted changes?) — closing the workspace only" >&2
    fi
    herdr workspace close "$workspace" >/dev/null 2>&1 &&
      { rm -f "$state"; echo "closed workspace $workspace ($name)" >&2; return 0; }
  fi
  if [[ "$(state_field "$state" tab_owned)" == "true" && -n "$tab" ]]; then
    herdr tab close "$tab" >/dev/null 2>&1 || herdr pane close "$pane" >/dev/null 2>&1 || true
  elif [[ -n "$pane" ]]; then
    herdr pane close "$pane" >/dev/null 2>&1 || true
  fi
  rm -f "$state"
  echo "closed $name (tab ${tab:-none}, pane ${pane:-unknown})" >&2
}

cmd_close() {
  [[ -n "$NAME" ]] || die "close needs a name" 2
  close_named "$NAME" || exit 1
}

# Close every recorded session, optionally only one kind: the explicit cleanup
# for the end of a task (there is no TTL; sessions live until closed).
cmd_reap() {
  if [[ -n "$NAME" || -n "$REQUEST" ]]; then
    die "reap takes no arguments — use --kind KIND to filter" 2
  fi
  [[ -d "$STATE_DIR" ]] || { echo "no agents registered" >&2; return 0; }
  local f name kind closed=0
  for f in "$STATE_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    name=$(state_field "$f" agent)
    kind=$(state_field "$f" kind)
    [[ -n "$name" ]] || continue
    if [[ -n "$KIND" && "$kind" != "$KIND" ]]; then
      continue
    fi
    close_named "$name"
    closed=$((closed + 1))
  done
  if ((closed == 0)); then
    echo "nothing to reap" >&2
  fi
}

cmd_list() {
  [[ -d "$STATE_DIR" ]] || { echo "no agents registered" >&2; return 0; }
  local f name pane tab kind repo state
  printf '%-14s %-8s %-10s %-10s %-8s %-25s %s\n' \
    NAME KIND STATE PANE TAB CREATED REPO
  for f in "$STATE_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    name=$(state_field "$f" agent)
    pane=$(state_field "$f" pane)
    tab=$(state_field "$f" tab)
    kind=$(state_field "$f" kind)
    repo=$(state_field "$f" repo)
    state=$(agent_state "$name")
    printf '%-14s %-8s %-10s %-10s %-8s %-25s %s\n' \
      "$name" "$kind" "$state" "$pane" "$tab" "$(state_field "$f" created)" "$repo"
  done
}

# --- Boss pattern: delegate / report / inbox / watch -------------------------
#
# A boss delegates and returns at once; the child reports back with `report`,
# which writes an immutable file into the boss's inbox and then notifies the
# boss. The inbox is the record, the notification only a hint: a boss that
# missed it still finds the report with `inbox`.

INBOX_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/harness/inbox"
# Kinds the watcher writes; everything else in the inbox came from the child.
WATCH_KINDS="blocked stalled gone expired"
WATCH_POLL=5
WATCH_GRACE=${HERDR_WATCH_GRACE:-90s}
WATCH_GONE_AFTER=3

# File-system safe form of a name or pane id (w23:p1 -> w23_p1).
safe_name() {
  local s
  s=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')
  [[ "$s" == .* ]] && s="_$s"
  printf '%s' "$s"
}

# One line for a prompt / notification / header: control characters
# (newlines, tabs, escapes) become spaces.
one_line() { printf '%s' "$1" | tr '[:cntrl:]' ' '; }

# A positive duration for the watcher (2h, 90s, 15m, 30); 1 when invalid.
valid_watch_duration() {
  [[ "$1" =~ ^[0-9]+[smh]?$ ]] || return 1
  [[ "${1%[smh]}" =~ [1-9] ]]
}

inbox_dir() { printf '%s/%s' "$INBOX_ROOT" "$(safe_name "$1")"; }
watch_dir() { printf '%s/.watch' "$(inbox_dir "$1")"; }

ensure_inbox() {
  local dir
  dir=$(inbox_dir "$1")
  (umask 077 && mkdir -p "$dir/done" "$dir/.watch") || die "cannot create $dir" 1
  printf '%s' "$dir"
}

script_path() {
  readlink -f "$0" 2>/dev/null ||
    printf '%s/%s' "$(cd "$(dirname "$0")" && pwd)" "$(basename "$0")"
}

# The agent name of a pane, empty when the pane runs no named agent.
pane_agent_name() {
  [[ -n "$1" ]] || return 0
  herdr agent get "$1" 2>/dev/null | jq -r '.result.agent.name // empty' 2>/dev/null || true
}

# --boss, else $HERDR_BOSS, else this pane's agent name, else this pane's id.
resolve_boss() {
  local name
  if [[ -n "$BOSS" ]]; then printf '%s' "$BOSS"; return 0; fi
  if [[ -n "${HERDR_BOSS:-}" ]]; then printf '%s' "$HERDR_BOSS"; return 0; fi
  name=$(pane_agent_name "${HERDR_PANE_ID:-}")
  if [[ -n "$name" ]]; then printf '%s' "$name"; return 0; fi
  [[ -n "${HERDR_PANE_ID:-}" ]] || return 1
  printf '%s' "$HERDR_PANE_ID"
}

# --from, else this pane's agent name, else this pane's id.
resolve_from() {
  local name
  if [[ -n "$FROM" ]]; then printf '%s' "$FROM"; return 0; fi
  name=$(pane_agent_name "${HERDR_PANE_ID:-}")
  if [[ -n "$name" ]]; then printf '%s' "$name"; return 0; fi
  [[ -n "${HERDR_PANE_ID:-}" ]] || return 1
  printf '%s' "$HERDR_PANE_ID"
}

header_field() { sed -n "1,6s/^$2: //p" "$1" 2>/dev/null | head -n 1; }

is_watch_kind() { [[ " $WATCH_KINDS " == *" $1 "* ]]; }

# write_inbox <boss> <from> <kind>  (body on stdin) -> prints the new file.
# Files are never overwritten: <from>-<YYYYmmdd-HHMMSS>[-N][.<kind>].md, written
# to a temp file first and then linked into place. ln (or mv -n where hard links
# are not supported) refuses an existing name, so two reports in the same second
# both survive and a reader never sees half a report.
WRITE_INBOX_MAX_TRIES=100
write_inbox() {
  local boss=$1 from=$2 kind=$3 dir stamp base suffix="" path tmp n=1
  dir=$(ensure_inbox "$boss") || return 1
  stamp=$(date +%Y%m%d-%H%M%S)
  [[ "$kind" == "report" ]] || suffix=".$kind"
  base="$(safe_name "$from")-$stamp"
  tmp=$(mktemp "$dir/.tmp.XXXXXX") || return 1
  if ! {
    printf 'from: %s\nto: %s\nat: %s\nkind: %s\n\n' \
      "$(one_line "$from")" "$(one_line "$boss")" "$(date -Iseconds)" "$kind"
    cat
  } >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  path="$dir/$base$suffix.md"
  while ((n <= WRITE_INBOX_MAX_TRIES)); do
    if ln -- "$tmp" "$path" 2>/dev/null; then
      rm -f "$tmp"
      printf '%s' "$path"
      return 0
    fi
    # No hard links on this file system: mv -n never replaces an existing file.
    if [[ ! -e "$path" ]] && mv -n -- "$tmp" "$path" 2>/dev/null && [[ ! -e "$tmp" ]]; then
      printf '%s' "$path"
      return 0
    fi
    n=$((n + 1))
    path="$dir/$base-$n$suffix.md"
  done
  rm -f "$tmp"
  return 1
}

# notify_boss <boss> <from> <kind> <path>: a one-line prompt into the boss's
# pane when it is an agent, else a Herdr notification (a person reads it).
# Never fails: the inbox file is already written.
notify_boss() {
  local boss=$1 from=$2 kind=$3 path=$4 label out code sound="done" target=$1
  case "$kind" in
    report) label="報告あり" ;;
    question) label="質問あり" ;;
    blocked) label="子が止まった（blocked）" ;;
    stalled) label="報告なしで停止" ;;
    gone) label="子が消えた" ;;
    expired) label="監視の寿命切れ" ;;
    *) label="inbox（$kind）" ;;
  esac
  # The prompt goes into the boss's input line: it must stay one line.
  boss=$(one_line "$boss")
  from=$(one_line "$from")
  path=$(one_line "$path")
  if ! herdr_reachable; then
    echo "herdr-agent: warning: no Herdr server — $boss was not notified (the report is in the inbox)" >&2
    echo "NOTIFY=none" >&2
    return 0
  fi
  if herdr agent get "$target" >/dev/null 2>&1; then
    if out=$(herdr agent prompt "$target" "$label（$from）: $path" 2>&1); then
      echo "NOTIFY=prompt" >&2
      return 0
    fi
    code=$(jq -r '.error.code // "error"' <<<"$out" 2>/dev/null || echo error)
    echo "herdr-agent: warning: could not prompt $boss ($code) — showing a notification instead" >&2
    sound=request
  fi
  if herdr notification show "$label（$from → $boss）" --body "$path" --sound "$sound" >/dev/null 2>&1; then
    echo "NOTIFY=notification" >&2
  else
    echo "herdr-agent: warning: could not notify $boss (the report is in the inbox)" >&2
    echo "NOTIFY=none" >&2
  fi
}

# The watcher of <child> under <boss>: its lock dir and pid, if it is alive.
watcher_pid() {
  local lock pid
  lock="$(watch_dir "$1")/$(safe_name "$2").lock"
  pid=$(cat "$lock/pid" 2>/dev/null || true)
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && printf '%s' "$pid"
}

# Stop the watcher of <child> under <boss> (if any) and drop its lock. Waits a
# little for it to exit so that it cannot touch the new delegation's marker.
WATCHER_STOP_WAIT=20 # tenths of a second
replace_watcher() {
  local boss=$1 child=$2 pid i=0
  pid=$(watcher_pid "$boss" "$child" || true)
  [[ -n "$pid" ]] || return 0
  echo "herdr-agent: $child already had a watcher ($pid) — replacing it" >&2
  kill "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && ((i < WATCHER_STOP_WAIT)); do
    sleep 0.1
    i=$((i + 1))
  done
  rm -rf -- "$(watch_dir "$boss")/$(safe_name "$child").lock"
}

protocol_section() {
  local boss=$1 child=$2 self=$3
  cat <<EOF

---

## 報告のしかた（herdr-agent.sh delegate が自動で付けた節）

あなたは司令塔 \`$boss\` から \`$child\` という名前で仕事を任された子エージェントです。司令塔はこの画面を見ていません。結果は次のコマンドで届けてください。

- 終わったら、報告を Markdown で書いて **1 回だけ**送る:
  \`$self report $boss <報告ファイル> --from $child\`
  （本文を標準入力で渡すなら \`<報告ファイル>\` の代わりに \`-\`）
- 報告に書くこと: やったこと / 変えたファイル / 確認したこと（実行したコマンドと結果）/ 未解決・判断してほしいこと
- 質問や判断が必要になったら、そこで作業を止め、質問を書いて \`--kind question\` を付けて送る。ターミナルで返事を待たない
- 他のエージェントを起動しない・相談しない（\`herdr agent start\`、\`herdr-agent.sh ensure\` / \`delegate\`、\`claude-consult.sh\`、サブエージェント・タスク委譲系のツールはすべて使わない）
- 依頼された範囲の外のファイルは変えない
EOF
}

cmd_delegate() {
  [[ -n "$NAME" ]] || die "delegate needs a child name" 2
  check_name "$NAME"
  [[ -n "$REQUEST" ]] || die "delegate needs a request file (or -)" 2
  [[ -f "$(state_file "$NAME")" ]] || die "$NAME is not registered — run ensure first" 2

  local prompt boss self child_safe wdir
  if [[ "$REQUEST" == "-" ]]; then prompt=$(cat); else
    [[ -f "$REQUEST" ]] || die "request file not found: $REQUEST" 2
    prompt=$(cat "$REQUEST")
  fi
  [[ -n "$prompt" ]] || die "empty request" 2
  boss=$(resolve_boss) || die "delegate needs --boss (or HERDR_BOSS, or run it inside a Herdr pane)" 2
  [[ "$boss" != "$NAME" ]] || die "$NAME cannot report to itself — pass --boss" 2
  if ((WATCH)); then
    valid_watch_duration "$WATCH_TIMEOUT" ||
      die "invalid --watch-timeout / HERDR_WATCH_TIMEOUT: $WATCH_TIMEOUT (e.g. 2h, 90m)" 2
    valid_watch_duration "$WATCH_GRACE" ||
      die "invalid HERDR_WATCH_GRACE: $WATCH_GRACE (e.g. 90s, 5m)" 2
  fi
  self=$(script_path)
  child_safe=$(safe_name "$NAME")
  wdir="$(ensure_inbox "$boss")/.watch"

  # Reports not older than this marker answer this delegation. It is taken
  # before the submit (a fast child may report within the same second) but only
  # becomes the child's marker once the submit went through: a failed delegate
  # leaves the previous watcher and its marker alone.
  local since_new
  since_new=$(mktemp "$wdir/.since.XXXXXX") || die "cannot write to $wdir" 1

  # One file per delegation, private to this user (ask keeps its fixed name):
  # a pending request is never overwritten by the next one.
  local request_dir="${TMPDIR:-/tmp}/harness-agent" request_path pointer
  (umask 077 && mkdir -p "$request_dir") || { rm -f "$since_new"; die "cannot create $request_dir" 1; }
  request_path=$(umask 077 && mktemp -d "$request_dir/$child_safe-$(date +%Y%m%d-%H%M%S)-XXXXXX") ||
    { rm -f "$since_new"; die "cannot create a request file in $request_dir" 1; }
  request_path="$request_path/request.md"
  if ! (umask 077 && { printf '%s\n' "$prompt"; protocol_section "$boss" "$NAME" "$self"; } >"$request_path"); then
    rm -f "$since_new"
    die "cannot write $request_path" 1
  fi
  pointer="Read $request_path and do exactly what it says; report back as its last section says."

  # --wait --until working only observes that the turn started. A short job can
  # go idle -> done without a visible working state, so stalled is not a failure;
  # only when the pointer still sits unsent in the input line is Enter pressed
  # once (the text itself is never typed twice).
  local out rc code tail_text
  out=$(herdr agent prompt "$NAME" "$pointer" --wait --until working --until blocked --timeout 8000 2>&1)
  rc=$?
  if ((rc != 0)); then
    code=$(jq -r '.error.code // "error"' <<<"$out" 2>/dev/null || echo error)
    case "$code" in
      agent_blocked)
        rm -f "$since_new"
        die "$NAME is blocked (an approval dialog?) — answer it first: herdr-agent.sh read $NAME" 1
        ;;
      agent_prompt_stalled | timeout)
        tail_text=$(herdr agent read "$NAME" --source recent-unwrapped --lines 6 2>/dev/null || true)
        if [[ "$tail_text" == *"$request_path"* && "$(agent_state "$NAME")" != "working" ]]; then
          herdr agent send-keys "$NAME" enter >/dev/null 2>&1 || true
          echo "herdr-agent: the request was still in the input line — pressed Enter once" >&2
        else
          echo "herdr-agent: no working state observed ($code) — the turn may already be over" >&2
        fi
        ;;
      *)
        rm -f "$since_new"
        die "could not submit to $NAME: $(one_line "$out")" 1
        ;;
    esac
  fi

  # The submit went through: this delegation supersedes the previous one.
  replace_watcher "$boss" "$NAME"
  mv -f -- "$since_new" "$wdir/$child_safe.since"

  local watch_pid="none" log="$wdir/$child_safe.log"
  if ((WATCH)); then
    # A session of its own, so the watcher outlives the shell that delegated
    # (tool runners kill their process group when a command returns).
    if command -v setsid >/dev/null 2>&1; then
      setsid "$self" watch "$NAME" --boss "$boss" --watch-timeout "$WATCH_TIMEOUT" \
        </dev/null >>"$log" 2>&1 &
    else
      nohup "$self" watch "$NAME" --boss "$boss" --watch-timeout "$WATCH_TIMEOUT" \
        </dev/null >>"$log" 2>&1 &
    fi
    watch_pid=$!
    disown "$watch_pid" 2>/dev/null || true
  fi

  echo "AGENT=$NAME" >&2
  echo "BOSS=$boss" >&2
  echo "REQUEST=$request_path" >&2
  echo "WATCH=$watch_pid" >&2
  echo "STATE=$(agent_state "$NAME")" >&2
}

cmd_report() {
  local boss=$NAME body from kind=${KIND:-report} path
  [[ -n "$boss" ]] || die "report needs the boss name" 2
  [[ -n "$REQUEST" ]] || die "report needs a report file (or -)" 2
  [[ "$kind" =~ ^[a-z]+$ ]] || die "invalid --kind: $kind" 2
  if [[ "$REQUEST" == "-" ]]; then body=$(cat); else
    [[ -f "$REQUEST" ]] || die "report file not found: $REQUEST" 2
    body=$(cat "$REQUEST")
  fi
  [[ -n "$body" ]] || die "empty report" 2
  from=$(resolve_from) || die "report needs --from (no Herdr pane to name the sender)" 2

  path=$(printf '%s\n' "$body" | write_inbox "$boss" "$from" "$kind") ||
    die "could not write to the inbox of $boss" 1
  echo "INBOX=$path" >&2
  printf '%s\n' "$path"
  notify_boss "$boss" "$from" "$kind" "$path"
}

# Unread inbox files of <dir>, oldest first, optionally only from <child>.
inbox_files() {
  local dir=$1 child=$2 f
  # ls -tr: modification time, oldest first (names start with the sender).
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    if [[ -n "$child" && "$(header_field "$f" from)" != "$child" ]]; then
      continue
    fi
    printf '%s\n' "$f"
  done < <(ls -1tr -- "$dir"/*.md 2>/dev/null)
}

INBOX_ACTIONS="list read ack clear"

# The inbox file an ack names: a path in the inbox, or its file name.
inbox_file_arg() {
  local dir=$1 arg=$2 f
  if [[ "$arg" == */* ]]; then f=$arg; else f="$dir/$arg"; fi
  [[ "${f##*/}" == *.md && "${f##*/}" != .* && -f "$f" ]] || return 1
  [[ "$(cd "$(dirname "$f")" && pwd -P)" == "$(cd "$dir" && pwd -P)" ]] || return 1
  printf '%s' "$f"
}

cmd_inbox() {
  local boss=$NAME action=${REQUEST:-list} child=$TARGET dir f n=0
  # Action first (inbox read child-a): the boss is resolved like --boss.
  # A boss literally named list / read / ack / clear needs --boss.
  if [[ -n "$boss" && " $INBOX_ACTIONS " == *" $boss "* ]]; then
    [[ -z "$TARGET" ]] || die "unexpected argument: $TARGET" 2
    action=$boss
    child=$REQUEST
    boss=""
  fi
  if [[ -z "$boss" ]]; then
    boss=$(resolve_boss) || die "inbox needs the boss name (or --boss / HERDR_BOSS)" 2
  fi
  dir=$(inbox_dir "$boss")
  # What the last read printed: ack without a file acks only these.
  local last_read="$dir/.last-read"

  case "$action" in
    list)
      [[ -d "$dir" ]] || { echo "no inbox for $boss" >&2; return 0; }
      printf '%-9s %-26s %-16s %s\n' KIND AT FROM FILE
      while IFS= read -r f; do
        printf '%-9s %-26s %-16s %s\n' "$(header_field "$f" kind)" "$(header_field "$f" at)" \
          "$(header_field "$f" from)" "$f"
        n=$((n + 1))
      done < <(inbox_files "$dir" "$child")
      ((n > 0)) || echo "nothing unread for $boss" >&2
      ;;
    read)
      local printed=()
      while IFS= read -r f; do
        ((n > 0)) && printf '\n'
        printf '===== %s\n' "$f"
        cat "$f"
        printed+=("$f")
        n=$((n + 1))
      done < <(inbox_files "$dir" "$child")
      if [[ -d "$dir" ]]; then
        if ((n > 0)); then printf '%s\n' "${printed[@]}" >"$last_read"; else rm -f "$last_read"; fi
      fi
      ((n > 0)) || echo "nothing unread for $boss" >&2
      ;;
    ack)
      # ack <file>: that file. ack [<child>]: what the last read printed (from
      # <child> only, when named) — never a report that came in after the read.
      if [[ "$child" == *.md || "$child" == */* ]]; then
        f=$(inbox_file_arg "$dir" "$child") || die "not an unread file of the inbox of $boss: $child" 2
        mv -- "$f" "$dir/done/" || die "could not ack $f" 1
        echo "acked 1 file(s) for $boss" >&2
        return 0
      fi
      if [[ ! -f "$last_read" ]]; then
        echo "nothing to ack for $boss: run read first, or name the file (ack <file>)" >&2
        return 0
      fi
      local rest=()
      while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        if [[ -n "$child" && "$(header_field "$f" from)" != "$child" ]]; then
          rest+=("$f")
          continue
        fi
        mv -- "$f" "$dir/done/" && n=$((n + 1))
      done <"$last_read"
      if ((${#rest[@]} > 0)); then printf '%s\n' "${rest[@]}" >"$last_read"; else rm -f "$last_read"; fi
      echo "acked $n file(s) for $boss" >&2
      ;;
    clear)
      [[ -d "$dir" ]] || { echo "no inbox for $boss" >&2; return 0; }
      rm -f -- "$dir"/done/*.md "$dir"/.tmp.*
      # Leftovers of watchers that are gone (a live watcher keeps its files).
      local lock name pid
      for lock in "$dir"/.watch/*.lock; do
        [[ -d "$lock" ]] || continue
        pid=$(cat "$lock/pid" 2>/dev/null || true)
        [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && continue
        rm -rf -- "$lock"
      done
      for f in "$dir"/.watch/*.since "$dir"/.watch/*.log; do
        [[ -e "$f" ]] || continue
        name=${f##*/}
        name=${name%.*}
        [[ -d "$dir/.watch/$name.lock" ]] && continue
        rm -f -- "$f"
      done
      echo "cleared read reports and stale watcher files for $boss (unread ones are kept)" >&2
      ;;
    *) die "unknown inbox action: $action (list | read | ack | clear)" 2 ;;
  esac
}

# Has <child> reported to <boss> since the delegation marker?
child_reported() {
  local dir since f
  dir=$(inbox_dir "$1")
  since="$dir/.watch/$(safe_name "$2").since"
  [[ -f "$since" ]] || return 1
  for f in "$dir"/*.md "$dir"/done/*.md; do
    # Not older than the marker: a report in the same second still counts.
    [[ -f "$f" && ! "$f" -ot "$since" ]] || continue
    [[ "$(header_field "$f" from)" == "$2" ]] || continue
    is_watch_kind "$(header_field "$f" kind)" && continue
    return 0
  done
  return 1
}

# watch_note <kind> <what happened>: a watcher note in the inbox + notification.
watch_note() {
  local kind=$1 text=$2 path tail_text
  tail_text=$(herdr agent read "$NAME" --source recent-unwrapped --lines 40 2>/dev/null || true)
  path=$( {
    printf '%s\n\n' "$text"
    # shellcheck disable=SC2016 # the backticks are a Markdown fence
    printf 'pane の末尾（herdr agent read %s --lines 40）:\n\n```\n%s\n```\n' "$NAME" "$tail_text"
  } | write_inbox "$BOSS" "$NAME" "$kind") || { echo "watch: could not write the $kind note" >&2; return 0; }
  echo "watch: $kind -> $path" >&2
  notify_boss "$BOSS" "$NAME" "$kind" "$path"
}

release_watch_lock() {
  [[ -n "${WATCH_LOCK:-}" ]] || return 0
  [[ "$(cat "$WATCH_LOCK/pid" 2>/dev/null)" == "$$" ]] && rm -rf "$WATCH_LOCK"
  return 0
}

# Started detached by delegate: watch one delegation until the child reports,
# stops without reporting, disappears, or the lifetime runs out. Polls the
# agent state (agent wait returns at once on a state that is already settled).
cmd_watch() {
  [[ -n "$NAME" ]] || die "watch needs a child name" 2
  [[ -n "$BOSS" ]] || die "watch needs --boss" 2
  local wdir lock life_s grace_s deadline now json state idle_since="" blocked_noted=0 fails=0
  # Checked here too: a watcher started by hand must not run with a broken clock.
  valid_watch_duration "$WATCH_TIMEOUT" || die "watch: invalid --watch-timeout: $WATCH_TIMEOUT" 2
  valid_watch_duration "$WATCH_GRACE" || die "watch: invalid HERDR_WATCH_GRACE: $WATCH_GRACE" 2
  life_s=$(timeout_seconds "$WATCH_TIMEOUT") || exit 2
  grace_s=$(timeout_seconds "$WATCH_GRACE") || exit 2
  wdir="$(ensure_inbox "$BOSS")/.watch"
  lock="$wdir/$(safe_name "$NAME").lock"

  if ! mkdir "$lock" 2>/dev/null; then
    if [[ -n "$(watcher_pid "$BOSS" "$NAME" || true)" ]]; then
      echo "watch: $NAME is already watched — exiting" >&2
      return 0
    fi
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || die "watch: cannot take $lock" 1
  fi
  printf '%s\n' "$$" >"$lock/pid"
  date -Iseconds >"$lock/started"
  # Only our own lock is removed: a newer delegate may already have replaced it
  # (it kills this watcher and takes over the lock and the .since marker).
  WATCH_LOCK=$lock
  trap release_watch_lock EXIT
  trap 'kill "$!" 2>/dev/null; exit 0' TERM INT
  echo "watch: $NAME -> $BOSS (pid $$, $(date -Iseconds))" >&2

  deadline=$(($(date +%s) + life_s))
  while :; do
    if child_reported "$BOSS" "$NAME"; then
      echo "watch: $NAME reported — done" >&2
      rm -f "$wdir/$(safe_name "$NAME").since"
      return 0
    fi
    now=$(date +%s)
    if ((now >= deadline)); then
      echo "watch: lifetime ($WATCH_TIMEOUT) over without a report — giving up" >&2
      watch_note expired "$NAME の監視が寿命（$WATCH_TIMEOUT）で切れました。報告はまだありません。子はまだ作業中かもしれません。様子を見て、必要なら同じ子に delegate し直してください（新しい watcher が付きます）。"
      rm -f "$wdir/$(safe_name "$NAME").since"
      return 0
    fi

    if json=$(herdr agent get "$NAME" 2>/dev/null); then
      fails=0
      state=$(jq -r '.result.agent.agent_status // "unknown"' <<<"$json" 2>/dev/null || echo unknown)
    else
      fails=$((fails + 1))
      state=gone
    fi

    case "$state" in
      working)
        idle_since=""
        blocked_noted=0
        ;;
      blocked)
        idle_since=""
        if ((blocked_noted == 0)); then
          watch_note blocked "$NAME が blocked で止まっています（承認ダイアログなど）。報告はまだありません。"
          blocked_noted=1
        fi
        ;;
      idle | done)
        [[ -n "$idle_since" ]] || idle_since=$now
        if ((now - idle_since >= grace_s)); then
          watch_note stalled "$NAME が $state のまま ${grace_s} 秒たちましたが、報告がありません。"
          rm -f "$wdir/$(safe_name "$NAME").since"
          return 0
        fi
        ;;
      gone)
        if ((fails >= WATCH_GONE_AFTER)); then
          watch_note gone "$NAME が見つかりません（pane が閉じた / Herdr サーバが止まった）。報告はありません。"
          rm -f "$wdir/$(safe_name "$NAME").since"
          return 0
        fi
        ;;
    esac
    # In the background + wait, so that a TERM from a newer delegate is handled
    # at once instead of after the sleep.
    sleep "$WATCH_POLL" &
    wait $! 2>/dev/null
  done
}

case "$CMD" in
  ensure) cmd_ensure ;;
  restart) cmd_restart ;;
  send) cmd_send ;;
  ask) cmd_ask ;;
  read) cmd_read ;;
  state) cmd_state ;;
  close) cmd_close ;;
  reap) cmd_reap ;;
  list) cmd_list ;;
  delegate) cmd_delegate ;;
  report) cmd_report ;;
  inbox) cmd_inbox ;;
  watch) cmd_watch ;;
  *) usage >&2; exit 2 ;;
esac
