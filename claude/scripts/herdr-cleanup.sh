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
# carries the owner (the caller's agent name, or the pane id when it had none) at
# start time, and the boss it works for once it was delegated to; anything else
# is left alone. Use --all-owners to tidy records from other sessions, or
# --owner to pick one.
#
# A record is in scope when (any of):
#   - its owner is the owner being tidied
#   - its owner is pane:P (an older record) and Herdr's agent in pane P now
#     carries the owner's name
#   - its boss is the owner's name (so a session stays traceable after its
#     boss pane is gone)
#
# Usage:
#   herdr-cleanup.sh [OPTIONS]
#
# Options:
#   (default)        report only; nothing is closed
#   --apply          close/release, after asking (a terminal) or with --yes
#   --yes            confirm without asking (only after the list was accepted)
#   --include-live   also close recorded sessions that are still alive but idle
#   --owner ID       scope to one owner (agent:NAME | pane:ID | NAME, which means
#                    agent:NAME); default: this session's stable name
#   --all-owners     ignore the owner scope (every recorded session / lease)
#   --boss NAME      whose inbox to report (default: $HERDR_BOSS, else the owner's
#                    name, else this pane's id)
#   --only WHAT      consult | agents | locks | inbox   (repeatable; default: all)
#   --name NAME      limit to one session name
#   --worktrees      also handle worktrees with no recorded session (clean ones
#                    are removed with --apply; dirty ones are only reported)
#   -h, --help       this help
#
# What each category means:
#   consult  ~/.cache/harness/herdr-consult/*.json  (consult.sh sessions)
#   agents   ~/.cache/harness/herdr-agents/*.json   (herdr-agent.sh sessions)
#   locks    ~/.local/share/harness/locks/*.lock    (task-file.sh leases, expired)
#   inbox    ~/.cache/harness/inbox/<boss>/         (unread reports and watcher
#            leftovers; read-only here - nothing is acked or deleted)
#
# exit: 0 = nothing left to do or everything done, 1 = something could not be done,
#       2 = usage error / confirmation missing

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONSULT_STATE="${XDG_CACHE_HOME:-$HOME/.cache}/harness/herdr-consult"
AGENT_STATE="${XDG_CACHE_HOME:-$HOME/.cache}/harness/herdr-agents"
LOCK_DIR="${HARNESS_LOCKS_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/harness/locks}"
WORKTREE_ROOT="${HERDR_WORKTREE_ROOT:-$HOME/.herdr/worktrees}"
WORKTREE_REGISTRY="${XDG_CACHE_HOME:-$HOME/.cache}/harness/herdr-worktrees"
INBOX_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/harness/inbox"
HERDR_AGENT="$SCRIPT_DIR/herdr-agent.sh"

APPLY=0
YES=0
INCLUDE_LIVE=0
LIST_WORKTREES=0
OWNER=""
ALL_OWNERS=0
BOSS=""
NAME_FILTER=""
ONLY=()

usage() { sed -n '/^# Usage:/,/^#  *2 = usage/p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

# need_value <option> <args left>: a value-taking option at the end is a usage error.
need_value() {
  (( $2 >= 2 )) && return 0
  echo "herdr-cleanup: $1 needs a value" >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)        APPLY=1; shift ;;
    --yes)          YES=1; shift ;;
    --include-live) INCLUDE_LIVE=1; shift ;;
    --worktrees)    LIST_WORKTREES=1; shift ;;
    --owner)        need_value "$1" $#; OWNER=$2; shift 2 ;;
    --all-owners)   ALL_OWNERS=1; shift ;;
    --boss)         need_value "$1" $#; BOSS=$2; shift 2 ;;
    --only)         need_value "$1" $#; ONLY+=("$2"); shift 2 ;;
    --name)         need_value "$1" $#; NAME_FILTER=$2; shift 2 ;;
    -h|--help)      usage ;;
    *) echo "herdr-cleanup: unknown option '$1'" >&2; exit 2 ;;
  esac
done

for c in ${ONLY[@]+"${ONLY[@]}"}; do
  case "$c" in
    consult|agents|locks|inbox) ;;
    *) echo "herdr-cleanup: unknown --only '$c' (consult | agents | locks | inbox)" >&2; exit 2 ;;
  esac
done

# The agent name Herdr has for a pane, empty when it has none or Herdr cannot be
# asked (the report must still work without a server). lookup_pane fills the
# cache in the calling shell; pane_agent_name reads it.
declare -A PANE_NAMES=()
lookup_pane() {
  [[ -n "$1" && -z "${PANE_NAMES[$1]+set}" ]] || return 0
  PANE_NAMES[$1]=$(herdr agent get "$1" 2>/dev/null |
    jq -r '.result.agent.name // empty' 2>/dev/null || true)
}
pane_agent_name() {
  [[ -n "$1" ]] || return 0
  lookup_pane "$1"
  printf '%s' "${PANE_NAMES[$1]}"
}

# The owner stamped on records at start time, as a name that outlives the pane:
# $HERDR_AGENT_NAME, else the agent name Herdr has for this pane, else the pane
# id (same rule as herdr-agent.sh and consult.sh).
current_owner() {
  local name=${HERDR_AGENT_NAME:-}
  [[ -n "$name" ]] || name=$(pane_agent_name "${HERDR_PANE_ID:-}")
  if [[ -n "$name" ]]; then
    printf 'agent:%s' "$name"
  elif [[ -n "${HERDR_PANE_ID:-}" ]]; then
    printf 'pane:%s' "$HERDR_PANE_ID"
  fi
}

SELF_OWNER=$(current_owner)
if (( ALL_OWNERS == 1 )); then
  OWNER=""
elif [[ -z "$OWNER" ]]; then
  OWNER=$SELF_OWNER
  if [[ -z "$OWNER" ]]; then
    echo "herdr-cleanup: cannot tell which session this is (no HERDR_AGENT_NAME / HERDR_PANE_ID)." >&2
    echo "               Pass --owner agent:NAME | pane:ID | NAME, or --all-owners for every record." >&2
    exit 2
  fi
fi
case "$OWNER" in
  ""|agent:*|pane:*) ;;
  *) OWNER="agent:$OWNER" ;;
esac
# The bare name / pane id of the owner: what a record's boss holds.
OWNER_BARE=${OWNER#agent:}
OWNER_BARE=${OWNER_BARE#pane:}

# Whose inbox to report: --boss, $HERDR_BOSS, the owner's name, this pane's id.
if [[ -z "$BOSS" ]]; then
  BOSS=${HERDR_BOSS:-}
  [[ -n "$BOSS" ]] || BOSS=${OWNER_BARE:-${SELF_OWNER#agent:}}
  BOSS=${BOSS#pane:}
fi

# owns <record owner> <record boss>: is this ours? See the header for the rules.
# OWN_MATCH keeps the rule that matched (all | owner | pane-name | boss), so the
# report can show why a record was picked before anyone runs --apply;
# OWN_MATCH_OWNER keeps the record's owner (what --owner takes to close it).
OWN_MATCH=""
OWN_MATCH_OWNER=""
owns() {
  OWN_MATCH=""
  OWN_MATCH_OWNER=$1
  [[ -z "$OWNER" ]] && { OWN_MATCH=all; return 0; }
  [[ "$1" == "$OWNER" ]] && { OWN_MATCH=owner; return 0; }
  if [[ "$OWNER" == agent:* && "$1" == pane:* ]]; then
    lookup_pane "${1#pane:}"
    [[ "${PANE_NAMES[${1#pane:}]}" == "$OWNER_BARE" ]] && { OWN_MATCH="pane-name"; return 0; }
  fi
  [[ -n "$2" && "$2" == "$OWNER_BARE" ]] && { OWN_MATCH=boss; return 0; }
  return 1
}

# " via:<rule>" when the last in_scope matched on something weaker than the
# owner itself (a reused pane id can make pane-name wrong); empty otherwise.
via_note() {
  case "$OWN_MATCH" in
    pane-name) printf ' via:pane-name(owner:%s)' "$OWN_MATCH_OWNER" ;;
    boss) printf ' via:boss' ;;
  esac
}

# in_scope <record file>: does this record belong to the owner we are tidying?
in_scope() {
  [[ -z "$OWNER" ]] && { OWN_MATCH=all; return 0; }
  owns "$(field "$1" owner "")" "$(field "$1" boss "")"
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

close_record() { # file name tab pane boss
  local file=$1 name=$2 tab=$3 pane=$4 boss=${5:--}
  if (( APPLY == 0 )); then
    printf '  close  %-28s %s boss:%s\n' "$name" "tab ${tab:-none} pane ${pane:-none}" "$boss"
    return 0
  fi
  if [[ -n "$tab" ]]; then
    herdr tab close "$tab" >/dev/null 2>&1
  elif [[ -n "$pane" ]]; then
    herdr pane close "$pane" >/dev/null 2>&1
  fi
  rm -f "$file"
  printf '  closed %-28s %s boss:%s\n' "$name" "tab ${tab:-none} pane ${pane:-none}" "$boss"
}

# A record picked only by its pane's current name (an old pane:P owner) may
# belong to someone else if Herdr reused the pane id, so it is never closed:
# a live one is only reported, a stale one loses its record but no tab/pane.
pane_name_hold() { # agent state
  if (( INCLUDE_LIVE == 1 )) && [[ "$1" == "idle" || "$1" == "done" ]]; then
    printf ' (not closed: pane id may be reused; use --owner pane:ID)'
  fi
}

drop_record() { # file name
  if (( APPLY == 0 )); then
    printf '  remove %-28s stale record (via:pane-name(owner:%s); tab left open)\n' "$2" "$OWN_MATCH_OWNER"
    return 0
  fi
  rm -f "$1"
  printf '  removed %-27s stale record (via:pane-name(owner:%s); tab left open)\n' "$2" "$OWN_MATCH_OWNER"
}

report_header() { printf '\n%s\n' "$1"; }

changed=0
failed=0
unread=0

# ─── the report / apply pass ─────────────────────────────────────────────────
run_cleanup() {
  changed=0
  failed=0
  unread=0

  local who="pane ${HERDR_PANE_ID:--}, boss ${BOSS:--}"
  if [[ -z "$OWNER" ]]; then
    printf 'Scope: every recorded session (--all-owners; self %s, %s)\n' "${SELF_OWNER:--}" "$who"
  elif [[ "$OWNER" == "$SELF_OWNER" ]]; then
    printf 'Scope: %s (this session; %s — use --all-owners to include others)\n' "$OWNER" "$who"
  else
    printf 'Scope: %s (--owner; self %s, %s)\n' "$OWNER" "${SELF_OWNER:--}" "$who"
  fi

  # --- consult sessions ------------------------------------------------------
  if want consult && [[ -d "$CONSULT_STATE" ]]; then
    report_header "consult sessions ($CONSULT_STATE)"
    local found=0 file name tab pane st rboss match
    for file in "$CONSULT_STATE"/*.json; do
      [[ -f "$file" ]] || continue
      name=$(field "$file" agent "")
      [[ -n "$name" ]] || { rm -f "$file"; continue; }
      [[ -n "$NAME_FILTER" && "$name" != "$NAME_FILTER" ]] && continue
      in_scope "$file" || continue
      found=1
      tab=$(field "$file" tab "")
      pane=$(field "$file" pane "")
      rboss="$(field "$file" boss "-")$(via_note)"
      match=$OWN_MATCH
      if alive "$name"; then
        st=$(agent_state "$name")
        if [[ "$match" == "pane-name" ]]; then
          printf '  live   %-28s %s (%s) boss:%s%s\n' "$name" "${tab:-?}" "$st" "$rboss" "$(pane_name_hold "$st")"
        elif (( INCLUDE_LIVE == 1 )) && [[ "$st" == "idle" || "$st" == "done" ]]; then
          close_record "$file" "$name" "$tab" "$pane" "$rboss"; changed=1
        else
          printf '  live   %-28s %s (%s) boss:%s\n' "$name" "${tab:-?}" "$st" "$rboss"
        fi
      elif [[ "$match" == "pane-name" ]]; then
        drop_record "$file" "$name"; changed=1
      else
        close_record "$file" "$name" "$tab" "$pane" "$rboss"; changed=1
      fi
    done
    (( found )) || echo "  (no records)"
  fi

  # --- herdr-agent sessions --------------------------------------------------
  if want agents && [[ -d "$AGENT_STATE" ]]; then
    report_header "herdr-agent sessions ($AGENT_STATE)"
    local found=0 file name st rboss match
    for file in "$AGENT_STATE"/*.json; do
      [[ -f "$file" ]] || continue
      name=$(field "$file" agent "")
      [[ -n "$name" ]] || { rm -f "$file"; continue; }
      [[ -n "$NAME_FILTER" && "$name" != "$NAME_FILTER" ]] && continue
      in_scope "$file" || continue
      found=1
      rboss="$(field "$file" boss "-")$(via_note)"
      match=$OWN_MATCH
      if alive "$name"; then
        st=$(agent_state "$name")
        if [[ "$match" == "pane-name" ]]; then
          printf '  live   %-28s %s (%s) boss:%s%s\n' "$name" "$(field "$file" topology tab)" "$st" "$rboss" "$(pane_name_hold "$st")"
        elif (( INCLUDE_LIVE == 1 )) && [[ "$st" == "idle" || "$st" == "done" ]]; then
          if (( APPLY == 1 )); then
            "$HERDR_AGENT" close "$name" >/dev/null 2>&1 || failed=1
            printf '  closed %-28s (%s) boss:%s\n' "$name" "$st" "$rboss"
          else
            printf '  close  %-28s alive, %s boss:%s\n' "$name" "$st" "$rboss"
          fi
          changed=1
        else
          printf '  live   %-28s %s (%s) boss:%s\n' "$name" "$(field "$file" topology tab)" "$st" "$rboss"
        fi
      elif [[ "$match" == "pane-name" ]]; then
        drop_record "$file" "$name"; changed=1
      else
        # `herdr-agent.sh close` also removes the worktree it owns; fall back to
        # dropping the record when Herdr no longer knows the session.
        if (( APPLY == 1 )); then
          if "$HERDR_AGENT" close "$name" >/dev/null 2>&1; then
            printf '  closed %-28s stale record boss:%s\n' "$name" "$rboss"
          else
            rm -f "$file"
            printf '  removed %-27s stale record (nothing left in herdr) boss:%s\n' "$name" "$rboss"
          fi
        else
          printf '  close  %-28s stale record boss:%s\n' "$name" "$rboss"
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
    # Leases taken by a child this session started belong to this session too:
    # the child's own pane id is the owner, and our record for that child says so.
    local -a mine=()
    [[ -n "$OWNER" ]] && mine+=("$OWNER")
    if [[ -n "$OWNER" ]]; then
      local sf sp sa
      for sf in "$CONSULT_STATE"/*.json "$AGENT_STATE"/*.json; do
        [[ -f "$sf" ]] || continue
        in_scope "$sf" || continue
        sp=$(field "$sf" pane "")
        sa=$(field "$sf" agent "")
        [[ -n "$sp" ]] && mine+=("pane:$sp")
        [[ -n "$sa" ]] && mine+=("agent:$sa")
      done
    fi
    for file in "$LOCK_DIR"/*.lock; do
      [[ -f "$file" ]] || continue
      lock_owner=$(sed -n 's/^owner=//p' "$file" | head -1)
      if [[ -n "$OWNER" ]]; then
        local in_mine=0 mo
        for mo in "${mine[@]}"; do [[ "$lock_owner" == "$mo" ]] && in_mine=1 && break; done
        (( in_mine )) || continue
      fi
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

  # --- the boss's inbox (read-only) -------------------------------------------
  # Unread reports and what watchers left in .watch/. Nothing here is acked or
  # deleted: that stays with `herdr-agent.sh inbox`, after someone has read them.
  if want inbox && [[ -n "$BOSS" ]]; then
    local ibox ibox_name f n=0 pid
    ibox_name=$(printf '%s' "$BOSS" | tr -c 'A-Za-z0-9._-' '_')
    [[ "$ibox_name" == .* ]] && ibox_name="_$ibox_name"
    ibox="$INBOX_ROOT/$ibox_name"
    report_header "inbox ($BOSS) ($ibox)"
    if [[ ! -d "$ibox" ]]; then
      echo "  (no inbox)"
    else
      while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        n=$((n + 1))
        printf '  unread  %s\n' "${f##*/}"
      done < <(ls -1tr -- "$ibox"/*.md 2>/dev/null)
      printf '  %s unread\n' "$n"
      unread=$((unread + n))
      for f in "$ibox"/.watch/*.lock "$ibox"/.watch/*.since "$ibox"/.watch/*.log; do
        [[ -e "$f" ]] || continue
        if [[ -d "$f" ]]; then
          pid=$(cat "$f/pid" 2>/dev/null || true)
          if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            printf '  watch   %-40s (watcher alive, pid %s)\n' "${f##*/}" "$pid"
            continue
          fi
          printf '  watch   %-40s (watcher gone)\n' "${f##*/}"
        else
          printf '  watch   %s\n' "${f##*/}"
        fi
      done
      printf '  (read-only: herdr-agent.sh inbox %s read -> ack -> clear)\n' "$BOSS"
    fi
  fi

  # --- worktrees left behind --------------------------------------------------
  # `herdr worktree list` only knows the current repository, so walk Herdr's own
  # layout instead: ~/.herdr/worktrees/<repo>/<branch>. A worktree that no record
  # points at is an orphan: close removed its workspace but not (for a dirty one)
  # the checkout. Ownership comes from the registry herdr-agent.sh writes next to
  # each worktree it creates, so the default stays "the worktrees this session
  # made" - an unregistered one is left alone unless --all-owners.
  if (( LIST_WORKTREES == 1 )); then
    report_header "worktrees with no recorded session ($WORKTREE_ROOT)"
    local wt_dir wt_path wt_repo wt_key wt_owner wt_boss dirty found=0
    if [[ ! -d "$WORKTREE_ROOT" ]]; then
      echo "  (none)"
    else
      for wt_dir in "$WORKTREE_ROOT"/*/*/; do
        wt_path=${wt_dir%/}
        [[ -d "$wt_path" ]] || continue
        found=1
        # In use by any recorded session (any owner)?
        if grep -rqsF "\"repo\": \"$wt_path\"" "$CONSULT_STATE" "$AGENT_STATE" 2>/dev/null; then
          printf '  in use  %s\n' "$wt_path"
          continue
        fi
        wt_key=$(printf '%s--%s' "$(basename "$(dirname "$wt_path")")" "$(basename "$wt_path")" |
          LC_ALL=C sed 's/[^A-Za-z0-9._-]/-/g')
        wt_owner=""
        wt_boss=""
        if [[ -f "$WORKTREE_REGISTRY/$wt_key.json" ]]; then
          wt_owner=$(jq -r '.owner // empty' "$WORKTREE_REGISTRY/$wt_key.json" 2>/dev/null)
          wt_boss=$(jq -r '.boss // empty' "$WORKTREE_REGISTRY/$wt_key.json" 2>/dev/null)
        fi
        if (( ALL_OWNERS == 0 )) && { [[ -z "$wt_owner" ]] || ! owns "$wt_owner" "$wt_boss"; }; then
          printf '  skip    %-52s (other session: %s)\n' "$wt_path" "${wt_owner:-unregistered}"
          continue
        fi
        # Matched only by the pane's current name: never removed (as with sessions).
        if [[ "$OWN_MATCH" == "pane-name" ]] && (( ALL_OWNERS == 0 )); then
          printf '  skip    %-52s (via:pane-name(owner:%s); use --owner %s)\n' \
            "$wt_path" "$wt_owner" "$wt_owner"
          continue
        fi
        dirty=$(git -C "$wt_path" status --short 2>/dev/null | wc -l | tr -d ' ')
        if (( dirty > 0 )); then
          printf '  keep    %-52s (%s uncommitted)\n' "$wt_path" "$dirty"
          continue
        fi
        if (( APPLY == 1 )); then
          wt_repo=$(git -C "$wt_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null | xargs -r dirname 2>/dev/null)
          if [[ -n "$wt_repo" ]] && git -C "$wt_repo" worktree remove "$wt_path" >/dev/null 2>&1; then
            printf '  removed %-52s (branch kept)\n' "$wt_path"
            rm -f "$WORKTREE_REGISTRY/$wt_key.json"
          else
            printf '  failed  %-52s (remove by hand)\n' "$wt_path"
            failed=1
          fi
          changed=1
        else
          printf '  remove  %-52s (clean; branch is kept)\n' "$wt_path"
          changed=1
        fi
      done
      (( found )) || echo "  (none)"
    fi
  fi
}

# The last line when nothing is to be closed: unread reports are not closed or
# released (they stay with `herdr-agent.sh inbox`), but they are not "nothing".
nothing_left() {
  if (( unread > 0 )); then
    echo "Nothing to close or release. $unread unread report(s) in the inbox above."
  else
    echo "Nothing to clean up."
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
    nothing_left
    exit 0
  fi
  echo ""
  answer=""
  if [[ -r /dev/tty ]]; then
    printf 'Close/release the items above? [y/N] ' >&2
    # A group, so a failed open of /dev/tty (no controlling terminal) stays quiet.
    { read -r answer </dev/tty; } 2>/dev/null || answer=""
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
  nothing_left
fi
(( failed )) && exit 1
exit 0
