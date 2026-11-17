#!/bin/bash
# herdr-cleanup.sh — tidy the sessions, locks and worktrees the harness recorded.
#
# Everything the harness starts leaves a record, and a session that is gone (TUI
# exited, tab closed by hand, machine restarted) leaves the record behind. This
# script reconciles the records with what Herdr actually has, and reports work that
# nobody is watching any more.
#
# Nothing is closed or released unless --apply is given, and --apply changes
# nothing until the person agrees: with a terminal it asks, without one it stops
# and tells you to add --yes. Pass --yes only after the list has been shown and
# accepted.
#
# The default scope is **the sessions the caller itself started**: every record
# carries the owner (the calling pane's agent name, or the pane id) at start time,
# and anything else is left alone. Use --all-owners to tidy records from other
# sessions, or --owner ID to pick one.
#
# Usage:
#   herdr-cleanup.sh [OPTIONS]
#
# Options:
#   (default)        report only; nothing is closed
#   --apply          close/release, after asking (a terminal) or with --yes
#   --yes            confirm without asking (only after the list was accepted)
#   --include-live   also close recorded sessions that are still alive but idle
#   --owner ID       scope to one owner (agent:NAME | pane:ID); default: this session
#   --all-owners     ignore the owner scope (every recorded session / lease)
#   --only WHAT      consult | agents | locks   (repeatable; default: all)
#   --name NAME      limit to one session name
#   --worktrees      also list worktrees whose session is gone (never removes them)
#   -h, --help       this help
#
# What each category means:
#   consult  ~/.cache/harness/herdr-consult/*.json  (consult.sh sessions)
#   agents   ~/.cache/harness/herdr-agents/*.json   (herdr-agent.sh sessions)
#   locks    ~/.local/share/harness/locks/*.lock    (task-file.sh leases, expired)
#
# exit: 0 = nothing left to do or everything done, 1 = something could not be done,
#       2 = usage error / confirmation missing

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONSULT_STATE="${XDG_CACHE_HOME:-$HOME/.cache}/harness/herdr-consult"
AGENT_STATE="${XDG_CACHE_HOME:-$HOME/.cache}/harness/herdr-agents"
LOCK_DIR="${HARNESS_LOCKS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/harness/locks}"
HERDR_AGENT="$SCRIPT_DIR/herdr-agent.sh"

APPLY=0
YES=0
INCLUDE_LIVE=0
LIST_WORKTREES=0
OWNER=""
ALL_OWNERS=0
NAME_FILTER=""
ONLY=()

usage() { sed -n '24,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)        APPLY=1; shift ;;
    --yes)          YES=1; shift ;;
    --include-live) INCLUDE_LIVE=1; shift ;;
    --worktrees)    LIST_WORKTREES=1; shift ;;
    --owner)        OWNER=$2; shift 2 ;;
    --all-owners)   ALL_OWNERS=1; shift ;;
    --only)         ONLY+=("$2"); shift 2 ;;
    --name)         NAME_FILTER=$2; shift 2 ;;
    -h|--help)      usage ;;
    *) echo "herdr-cleanup: unknown option '$1'" >&2; exit 2 ;;
  esac
done

# The owner stamped on records at start time: the calling pane's agent name when
# the pane runs a named agent, otherwise the pane id (same rule as herdr-agent.sh
# and consult.sh).
current_owner() {
  if [[ -n "${HERDR_AGENT_NAME:-}" ]]; then
    printf 'agent:%s' "$HERDR_AGENT_NAME"
  elif [[ -n "${HERDR_PANE_ID:-}" ]]; then
    printf 'pane:%s' "$HERDR_PANE_ID"
  fi
}

if (( ALL_OWNERS == 1 )); then
  OWNER=""
elif [[ -z "$OWNER" ]]; then
  OWNER=$(current_owner)
  if [[ -z "$OWNER" ]]; then
    echo "herdr-cleanup: cannot tell which session this is (no HERDR_AGENT_NAME / HERDR_PANE_ID)." >&2
    echo "               Pass --owner agent:NAME | pane:ID, or --all-owners for every record." >&2
    exit 2
  fi
fi

# in_scope <record file>: does this record belong to the owner we are tidying?
in_scope() {
  [[ -z "$OWNER" ]] && return 0
  [[ "$(field "$1" owner "")" == "$OWNER" ]]
}

want() { # category
  (( ${#ONLY[@]} == 0 )) && return 0
  local c
  for c in "${ONLY[@]}"; do [[ "$c" == "$1" ]] && return 0; done
  return 1
}

alive() { herdr agent get "$1" >/dev/null 2>&1; }

agent_state() { # name -> idle|working|blocked|done|unknown
  herdr agent get "$1" 2>/dev/null |
    jq -r '.result.agent.agent_status // .result.agent.state // .result.state // "unknown"' 2>/dev/null ||
    echo unknown
}

# jq on a state file, with a default (the files are small and machine-written).
field() { # file key default
  local v
  v=$(jq -r --arg k "$2" '.[$k] // empty' "$1" 2>/dev/null)
  printf '%s' "${v:-$3}"
}

close_record() { # file name tab pane
  local file=$1 name=$2 tab=$3 pane=$4
  if (( APPLY == 0 )); then
    printf '  close  %-28s %s\n' "$name" "tab ${tab:-none} pane ${pane:-none}"
    return 0
  fi
  if [[ -n "$tab" ]]; then
    herdr tab close "$tab" >/dev/null 2>&1
  elif [[ -n "$pane" ]]; then
    herdr pane close "$pane" >/dev/null 2>&1
  fi
  rm -f "$file"
  printf '  closed %-28s %s\n' "$name" "tab ${tab:-none} pane ${pane:-none}"
}

report_header() { printf '\n%s\n' "$1"; }

changed=0
failed=0

# ─── the report / apply pass ─────────────────────────────────────────────────
run_cleanup() {
  changed=0
  failed=0

  if [[ -n "$OWNER" ]]; then
    printf 'Scope: %s (this session — use --all-owners to include others)\n' "$OWNER"
  else
    printf 'Scope: every recorded session (--all-owners)\n'
  fi

  # --- consult sessions ------------------------------------------------------
  if want consult && [[ -d "$CONSULT_STATE" ]]; then
    report_header "consult sessions ($CONSULT_STATE)"
    local found=0 file name tab pane st
    for file in "$CONSULT_STATE"/*.json; do
      [[ -f "$file" ]] || continue
      name=$(field "$file" agent "")
      [[ -n "$name" ]] || { rm -f "$file"; continue; }
      [[ -n "$NAME_FILTER" && "$name" != "$NAME_FILTER" ]] && continue
      in_scope "$file" || continue
      found=1
      tab=$(field "$file" tab "")
      pane=$(field "$file" pane "")
      if alive "$name"; then
        st=$(agent_state "$name")
        if (( INCLUDE_LIVE == 1 )) && [[ "$st" == "idle" || "$st" == "done" ]]; then
          close_record "$file" "$name" "$tab" "$pane"; changed=1
        else
          printf '  live   %-28s %s (%s)\n' "$name" "${tab:-?}" "$st"
        fi
      else
        close_record "$file" "$name" "$tab" "$pane"; changed=1
      fi
    done
    (( found )) || echo "  (no records)"
  fi

  # --- herdr-agent sessions --------------------------------------------------
  if want agents && [[ -d "$AGENT_STATE" ]]; then
    report_header "herdr-agent sessions ($AGENT_STATE)"
    local found=0 file name st
    for file in "$AGENT_STATE"/*.json; do
      [[ -f "$file" ]] || continue
      name=$(field "$file" agent "")
      [[ -n "$name" ]] || { rm -f "$file"; continue; }
      [[ -n "$NAME_FILTER" && "$name" != "$NAME_FILTER" ]] && continue
      in_scope "$file" || continue
      found=1
      if alive "$name"; then
        st=$(agent_state "$name")
        if (( INCLUDE_LIVE == 1 )) && [[ "$st" == "idle" || "$st" == "done" ]]; then
          if (( APPLY == 1 )); then
            "$HERDR_AGENT" close "$name" >/dev/null 2>&1 || failed=1
            printf '  closed %-28s (%s)\n' "$name" "$st"
          else
            printf '  close  %-28s alive, %s\n' "$name" "$st"
          fi
          changed=1
        else
          printf '  live   %-28s %s (%s)\n' "$name" "$(field "$file" topology tab)" "$st"
        fi
      else
        # `herdr-agent.sh close` also removes the worktree it owns; fall back to
        # dropping the record when Herdr no longer knows the session.
        if (( APPLY == 1 )); then
          if "$HERDR_AGENT" close "$name" >/dev/null 2>&1; then
            printf '  closed %-28s stale record\n' "$name"
          else
            rm -f "$file"
            printf '  removed %-27s stale record (nothing left in herdr)\n' "$name"
          fi
        else
          printf '  close  %-28s stale record\n' "$name"
        fi
        changed=1
      fi
    done
    (( found )) || echo "  (no records)"
  fi

  # --- expired task locks ----------------------------------------------------
  if want locks && [[ -d "$LOCK_DIR" ]]; then
    report_header "task locks ($LOCK_DIR)"
    local found=0 file key runner upd ttl_s age now lock_owner
    now=$(date +%s)
    for file in "$LOCK_DIR"/*.lock; do
      [[ -f "$file" ]] || continue
      lock_owner=$(sed -n 's/^owner=//p' "$file" | head -1)
      [[ -z "$OWNER" || "$lock_owner" == "$OWNER" ]] || continue
      found=1
      key=$(sed -n 's/^key=//p' "$file" | head -1)
      runner=$(sed -n 's/^runner=//p' "$file" | head -1)
      upd=$(sed -n 's/^updated_epoch=//p' "$file" | head -1)
      ttl_s=$(sed -n 's/^ttl=//p' "$file" | head -1)
      case "$ttl_s" in
        *m) ttl_s=$(( ${ttl_s%m} * 60 )) ;;
        *h) ttl_s=$(( ${ttl_s%h} * 3600 )) ;;
        *s) ttl_s=${ttl_s%s} ;;
      esac
      [[ "$ttl_s" =~ ^[0-9]+$ ]] || ttl_s=2700
      age=$(( now - ${upd:-0} ))
      if (( age > ttl_s )); then
        if (( APPLY == 1 )); then
          rm -f "$file"
          printf '  released %-27s (%ss old, holder %s)\n' "${key:-?}" "$age" "${runner:-?}"
        else
          printf '  release  %-26s expired (%ss > %ss, holder %s)\n' \
            "${key:-?}" "$age" "$ttl_s" "${runner:-?}"
        fi
        changed=1
      else
        printf '  live     %-26s %ss old, ttl %ss (holder %s)\n' \
          "${key:-?}" "$age" "$ttl_s" "${runner:-?}"
      fi
    done
    (( found )) || echo "  (no locks)"
  fi

  # --- worktrees with no session ---------------------------------------------
  if (( LIST_WORKTREES == 1 )); then
    report_header "worktrees without a recorded session"
    local row branch path wt
    mapfile -t wt < <(herdr worktree list 2>/dev/null |
      jq -r '.result.worktrees[]? | "\(.branch)\t\(.path)"' 2>/dev/null)
    if (( ${#wt[@]} == 0 )); then
      echo "  (none)"
    else
      for row in "${wt[@]}"; do
        branch=${row%%$'\t'*}
        path=${row#*$'\t'}
        printf '  %-40s %s\n' "$branch" "$path"
        printf '      remove: git worktree remove %s   (only if nothing is running there)\n' "$path"
      done
    fi
  fi
}

# ─── apply gate: show, confirm, then act ─────────────────────────────────────
if (( APPLY == 1 && YES == 0 )); then
  # Report first so the person (or the agent that will ask them) sees exactly
  # what would be closed.
  APPLY=0
  run_cleanup
  if (( changed == 0 )); then
    echo ""
    echo "Nothing to clean up."
    exit 0
  fi
  echo ""
  answer=""
  if [[ -r /dev/tty ]]; then
    printf 'Close/release the items above? [y/N] ' >&2
    read -r answer </dev/tty || answer=""
  fi
  case "$answer" in
    y|Y|yes|YES) ;;
    *)
      echo "herdr-cleanup: nothing was closed. Show the list to the person, then" >&2
      echo "               re-run with --apply --yes once they agree." >&2
      exit 2
      ;;
  esac
  APPLY=1
  echo ""
  run_cleanup
  echo ""
  echo "Cleanup applied."
  (( failed )) && exit 1
  exit 0
fi

run_cleanup
echo ""
if (( APPLY == 0 )) && (( changed == 1 )); then
  echo "Report only. Nothing was closed."
  echo "Next: show this list to the person, then re-run with --apply --yes."
elif (( changed == 1 )); then
  echo "Cleanup applied."
else
  echo "Nothing to clean up."
fi
(( failed )) && exit 1
exit 0
