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
#   -- ARGS...        ensure: native arguments for the agent (after --)
#   -h, --help
#
# stdout: ask prints the answer (the --answer-file content, else the pane tail)
# stderr: AGENT= / PANE= / KIND= / REPO= / STATE=
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
      else
        die "unexpected argument: $1" 2
      fi
      shift
      ;;
  esac
done

[[ -n "$CMD" ]] || { usage >&2; exit 2; }
herdr_reachable ||
  die "no herdr CLI in PATH, or no Herdr server answered — start herdr first" 1

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

  herdr agent start "$NAME" --kind "$KIND" --pane "$pane" -- "${NATIVE_ARGS[@]}" >&2 ||
    die "could not start $KIND in $pane (approval dialog?)"
  pane_stable "$NAME"

  mkdir -p "$STATE_DIR"
  jq -n --arg agent "$NAME" --arg pane "$pane" --arg tab "$tab" --arg kind "$KIND" \
    --arg workspace "$workspace" --arg topology "$TOPOLOGY" --argjson ws_owned "$ws_owned" \
    --arg repo "$REPO" --arg created "$(date -Iseconds)" \
    '{agent:$agent, pane:$pane, tab:$tab, tab_owned:true, workspace:$workspace,
      workspace_owned:$ws_owned, topology:$topology, kind:$kind, repo:$repo,
      created:$created}' >"$state"

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
  *) usage >&2; exit 2 ;;
esac
