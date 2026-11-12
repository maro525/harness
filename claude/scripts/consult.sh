#!/bin/bash
# consult.sh — ask another AI CLI for a design consultation, a review, or an
# implementation hand-off, from the agent you are in (Cursor / pi / Cline /
# OpenCode). Two targets share this implementation:
#
#   --to claude  Claude Code (default; claude-consult.sh is the thin wrapper)
#   --to codex   Codex CLI    (codex-consult.sh is the thin wrapper)
#
# Two backends:
#
#   herdr  (default; required unless -b print)
#     Keeps one session per role in a Herdr tab and submits each question with
#     `herdr agent prompt`. Each session gets its own tab (created on demand in
#     the calling workspace — or a new workspace when the caller is not inside
#     Herdr — same cwd, focus stays where it is) and is reused, so a follow-up
#     question continues the same conversation instead of starting a new one. A
#     tab that no longer hosts the agent, or that lives in another directory, is
#     replaced.
#
#   print  (explicit only: -b print / CONSULT_BACKEND=print)
#     One-shot `claude -p` / `codex exec` in a read-only sandbox. No session, no
#     tab. Never selected automatically: outside Herdr the script stops and asks
#     for a Herdr pane instead of silently changing behaviour.
#
# Contract:
#   stdout : the answer body (with --roles: one `## <role>` section per role)
#   files  : <base>.answer.md (answer) and <base>.json (raw)
#            --roles: <base>.<role>.answer.md / <base>.<role>.json
#            <base> is the prompt file without its extension; with `-` (stdin)
#            it is $TMPDIR/harness-consult/out/<target>-consult-<timestamp>, so
#            nothing is written into the caller's cwd
#   stderr : ANSWER_FILE=<path>, AI_MODEL=<target>/<model>, AGENT=<name>, PANE=<id>
#            (print backend: AI_MODEL=..., SESSION_ID=... (claude only))
#   exit   : 0 = answered, 1 = failed, 2 = usage error
#
# The call blocks until the session answers (herdr backend: until the timeout),
# so run it in the foreground and read stdout — no separate "wait" step.
#
# Run it from the repository you want to discuss: the consult pane inherits the
# cwd and the session reads files relative to it.
#
# Target differences:
#   claude  consult / review may write their answer file (Write tool, limited to
#           their own temp directory), so a fenced Markdown answer survives
#           intact; the terminal markers are only the fallback.
#   codex   consult / review run with `-s read-only`, so they cannot write the
#           answer file and always answer between the markers; implement runs
#           with `-s workspace-write -a never`.

set -euo pipefail

BACKEND=${CONSULT_BACKEND:-${CLAUDE_CONSULT_BACKEND:-auto}}   # auto | herdr | print
TARGET=${CONSULT_TO:-claude}                                  # claude | codex
ROLE=""
ROLES=""
MODEL_OVERRIDE=""
TIMEOUT=${CONSULT_TIMEOUT:-${CLAUDE_CONSULT_TIMEOUT:-20m}}
RESUME_ID=""
NAME_OVERRIDE=""
FORCE_NEW=0
CLOSE_AFTER=0
REUSE_CWD=0
APPEND_FILES=()
INLINE_TEXT=""
WITH_CONTEXT=0
READ_LINES=${CONSULT_READ_LINES:-${CLAUDE_CONSULT_READ_LINES:-800}}
STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/harness/herdr-consult"

# die <message> [exit-code]
die() {
  local msg=$1 code=${2:-1}
  echo "error: $msg" >&2
  exit "$code"
}

usage() {
  cat <<'EOF2'
Usage: consult.sh [OPTIONS] <prompt-file> | -

  Read-only consultation (default), a review, or an implementation hand-off
  from another agent. Inside Herdr the question is sent to a persistent session
  in a Herdr pane (created on demand, reused afterwards); outside Herdr a
  one-shot `claude -p` / `codex exec` runs instead.

  prompt-file   file holding the question (use - for stdin: nothing is written
                into the cwd, the answer lands under $TMPDIR/harness-consult/out)
  --text TEXT    pass the question as an argument (same output location as -);
                handy for a one-liner, and the shortest thing to type
  --context      prepend the repository, branch, recent commits and the number
                of changed files to the question (so a one-liner is enough)
  --append FILE append a previous answer to the question (also -)

Target:
  --to TARGET        claude (default) | codex
                     claude-consult.sh / codex-consult.sh pass this for you

Roles (pick the pane the question goes to):
  --role ROLE        consult (default) | review | implement
                     consult / review read the repo and write only their answer
                     file (claude only — codex is read-only there); implement
                     keeps write access (claude: --permission-mode auto,
                     codex: workspace-write)
  --roles A,B        run several roles in parallel; output is one section per
                     role and answers land in <base>.<role>.answer.md
                     (independent opinions — use chained calls for
                     implement → review so the reviewer sees the result)

Backend:
  -b, --backend B    auto (default) | herdr | print
                     auto = herdr whenever a Herdr server answers, inside a
                     pane or not; it never falls back to the one-shot backend
                     on its own (pass '-b print' to run it)
  -r, --resume ID    print backend only, claude only: resume an earlier session
  --name NAME        herdr backend: agent name (default hc-<role> / hx-<role>)
  --new              herdr backend: replace the role's tab with a fresh one
  --reuse-cwd        herdr backend: reuse a session whose cwd differs

Other:
  -m, --model MODEL  model alias or id (default: claude → opus,
                     codex → ~/.codex/config.toml)
                     claude permission mode is `auto` (CONSULT_PERMISSION_MODE)
  -t, --timeout T    timeout, e.g. 20m / 600s / 600 (default: $CONSULT_TIMEOUT or 20m)
  --close            herdr backend: close the role's pane after the answer;
                     with no prompt file, close the recorded session(s) and exit
  --debug            herdr backend: also save the raw pane text to <base>.pane.txt
  --status           list the recorded Herdr sessions and exit
  --show ROLE|NAME   print the pane text of a role's session and exit
  -h, --help         show this help and exit

Environment:
  CONSULT_TO (claude | codex), CONSULT_BACKEND (auto | herdr | print),
  CONSULT_MODEL, CONSULT_TIMEOUT, CONSULT_IMPLEMENT_MODEL, CONSULT_READ_LINES,
  CONSULT_<ROLE>_ARGS (extra CLI arguments, e.g. --effort high).
  The older CLAUDE_CONSULT_* names are still read as a fallback.

Exit: 0 = answered, 1 = failed, 2 = usage error.
EOF2
}

# ─── argument parsing ────────────────────────────────────────────────────────

need_value() { [[ $# -ge 2 ]] || die "$1 requires a value" 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to)            need_value "$@"; TARGET=$2; shift 2 ;;
    -b|--backend)    need_value "$@"; BACKEND=$2; shift 2 ;;
    --role)          need_value "$@"; ROLE=$2; shift 2 ;;
    --roles)         need_value "$@"; ROLES=$2; shift 2 ;;
    -m|--model)      need_value "$@"; MODEL_OVERRIDE=$2; shift 2 ;;
    -t|--timeout)    need_value "$@"; TIMEOUT=$2; shift 2 ;;
    -r|--resume)     need_value "$@"; RESUME_ID=$2; shift 2 ;;
    --name)          need_value "$@"; NAME_OVERRIDE=$2; shift 2 ;;
    --append)        need_value "$@"; APPEND_FILES+=("$2"); shift 2 ;;
    --text)          need_value "$@"; INLINE_TEXT=$2; shift 2 ;;
    --text=*)        INLINE_TEXT=${1#*=}; shift ;;
    --context)       WITH_CONTEXT=1; shift ;;
    --new)           FORCE_NEW=1; shift ;;
    --debug)         CLAUDE_CONSULT_DEBUG=1; shift ;;
    --close)         CLOSE_AFTER=1; shift ;;
    --reuse-cwd)     REUSE_CWD=1; shift ;;
    --status)        STATUS_ONLY=1; shift ;;
    --show)          need_value "$@"; SHOW_TARGET=$2; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    --)              shift; break ;;
    -)               break ;;   # stdin prompt: read it from standard input
    -*)              usage >&2; exit 2 ;;
    *)               break ;;
  esac
done

# Target = the CLI binary to drive. The agent prefix keeps the two targets from
# sharing a Herdr session name (both live in the same state directory).
case "$TARGET" in
  claude) AGENT_KIND=claude; AGENT_PREFIX=hc ;;
  codex)  AGENT_KIND=codex;  AGENT_PREFIX=hx ;;
  *) usage >&2; exit 2 ;;
esac

if [[ "${SHOW_TARGET:-}" != "" ]]; then  target=$SHOW_TARGET
  if [[ -f "$(printf '%s/%s.json' "$STATE_DIR" "$target")" ]]; then
    : # already an agent name
  else
    target="$AGENT_PREFIX-$target"
  fi
  herdr agent read "$target" --source recent-unwrapped --lines "$READ_LINES"
  exit 0
fi

if [[ "${STATUS_ONLY:-0}" == "1" ]]; then
  if [[ ! -d "$STATE_DIR" ]]; then
    echo "no Herdr consult sessions recorded ($STATE_DIR)" >&2
    exit 0
  fi
  for f in "$STATE_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    name=$(jq -r '.agent // empty' "$f")
    pane=$(jq -r '.pane // empty' "$f")
    cwd=$(jq -r '.cwd // empty' "$f")
    live="gone"
    if [[ -n "$pane" ]] && herdr agent get "$name" >/dev/null 2>&1; then
      live="live"
    fi
    printf '%-14s %-10s %-10s %s\n' "$name" "$live" "$pane" "$cwd"
  done
  exit 0
fi

case "$BACKEND" in
  auto) ;;
  herdr|print) ;;
  *) usage >&2; exit 2 ;;
esac

src=${1:-}
if [[ -z "$src" && -z "$INLINE_TEXT" && "$CLOSE_AFTER" == "1" ]]; then
  CLOSE_ONLY=1
fi
if [[ -z "$src" && -z "$INLINE_TEXT" && "${CLOSE_ONLY:-0}" != "1" ]]; then
  usage >&2
  exit 2
fi

# "auto" means Herdr, never the one-shot fallback: the print backend gives a
# different tool set, no conversation continuity and no tab, so switching to it
# silently would hide that. `-b print` is the explicit opt-in.
#
# Herdr is required to be *reachable*, not to be the caller's multiplexer: the
# scripts only use pane ids, so they work from a plain terminal too (with no
# caller pane, a tab has no workspace to attach to and one is created).
herdr_reachable() {
  command -v herdr >/dev/null 2>&1 || return 1
  herdr workspace list >/dev/null 2>&1
}
if [[ "$BACKEND" == "auto" ]]; then
  if herdr_reachable; then
    BACKEND=herdr
  else
    die "no Herdr server answered — start herdr, or pass -b print for the one-shot backend" 1
  fi
fi
if [[ "$BACKEND" == "herdr" ]] && ! herdr_reachable; then
  die "backend herdr needs a running Herdr server (and the herdr CLI in PATH), or use -b print" 1
fi
if [[ "$BACKEND" == "herdr" ]] && [[ -n "$RESUME_ID" ]]; then
  die "-r/--resume is for the print backend; the herdr backend reuses its pane" 2
fi
if [[ "$TARGET" == "codex" && -n "$RESUME_ID" ]]; then
  die "-r/--resume is claude only; codex has no one-shot session to resume" 2
fi

# ─── timeout helpers ─────────────────────────────────────────────────────────

# Seconds from "20m" / "600s" / "600".
timeout_seconds() {
  local t=$1 mult=1 num
  case "$t" in
    *m) mult=60 ; num=${t%m} ;;
    *s) num=${t%s} ;;
    *h) mult=3600 ; num=${t%h} ;;
    *)  num=$t ;;
  esac
  num=${num:-0}
  [[ "$num" =~ ^[0-9]+$ ]] || die "invalid timeout: $t" 2
  (( num > 0 )) || die "invalid timeout: $t" 2
  echo $((num * mult))
}
TIMEOUT_S=$(timeout_seconds "$TIMEOUT")

# ─── role table ──────────────────────────────────────────────────────────────

# Directory the consult sessions may write their answer into. One directory per
# agent keeps the Write permission rule narrow (see role_settings).
role_answer_dir() {
  printf '%s/%s' "${CLAUDE_CONSULT_ANSWER_DIR:-${TMPDIR:-/tmp}/harness-consult}" "$1"
}

# Per-target role settings.
#   claude : ROLE_MODEL / ROLE_MODE / ROLE_TOOLS / ROLE_ALLOWED, ROLE_ANSWER=1
#   codex  : ROLE_MODEL (empty = config.toml) / ROLE_SANDBOX, ROLE_ANSWER=0
# ROLE_ANSWER=1 means the role writes its answer file (claude consult/review: the
# Write tool, limited to its own temp directory). codex is read-only there, so it
# answers between the terminal markers only; implement keeps write access
# (claude: acceptEdits, codex: workspace-write). Plan mode is not used for the
# herdr backend because it forbids the answer file (see build_prompt) — the tool
# list is what limits the session.
role_settings() {
  local role=$1
  case "$role" in
    consult|review|implement) ;;
    *) die "unknown role: $role (consult | review | implement)" 2 ;;
  esac

  if [[ "$role" == "implement" ]]; then
    ROLE_MODEL=${CONSULT_IMPLEMENT_MODEL:-${CLAUDE_CONSULT_IMPLEMENT_MODEL:-${CONSULT_MODEL:-${CLAUDE_CONSULT_MODEL:-}}}}
  else
    ROLE_MODEL=${CONSULT_MODEL:-${CLAUDE_CONSULT_MODEL:-}}
  fi
  if [[ -n "$MODEL_OVERRIDE" ]]; then
    ROLE_MODEL=$MODEL_OVERRIDE
  fi

  ROLE_ANSWER=0
  if [[ "$TARGET" == "codex" ]]; then
    ROLE_MODE=""
    ROLE_TOOLS=""
    ROLE_ALLOWED=""
    if [[ "$role" == "implement" ]]; then
      ROLE_SANDBOX=workspace-write
    else
      ROLE_SANDBOX=read-only
    fi
    return 0
  fi

  ROLE_SANDBOX=""
  # `auto` is Claude Code's automatic permission mode: the tab does not stop on
  # approval dialogs, which matters because nobody is watching a consult pane.
  # The tool list still limits consult/review to reading the repo plus writing
  # their answer file. CONSULT_PERMISSION_MODE overrides the mode.
  ROLE_MODE=${CONSULT_PERMISSION_MODE:-auto}
  if [[ "$role" == "implement" ]]; then
    ROLE_TOOLS=""
    ROLE_ALLOWED=""
  else
    ROLE_TOOLS="Read,Grep,Glob,Write"
    ROLE_ALLOWED="Write($(role_answer_dir "$(role_agent_name "$role")")/**)"
    ROLE_ANSWER=1
  fi
  [[ -n "$ROLE_MODEL" ]] || ROLE_MODEL=opus
}

# Extra CLI arguments for a role: CONSULT_<ROLE>_ARGS (or the older
# CLAUDE_CONSULT_<ROLE>_ARGS).
role_extra_args() {
  local role=$1 var name
  name=$(printf '%s' "$role" | tr '[:lower:]' '[:upper:]')
  var="CONSULT_${name}_ARGS"
  if [[ -n "${!var:-}" ]]; then
    printf '%s' "${!var}"
    return 0
  fi
  var="CLAUDE_CONSULT_${name}_ARGS"
  printf '%s' "${!var:-}"
}

role_agent_name() {
  local role=$1
  if [[ -n "$NAME_OVERRIDE" ]]; then
    printf '%s' "$NAME_OVERRIDE"
  else
    printf '%s-%s' "$AGENT_PREFIX" "$role"
  fi
}

# AI_MODEL label for the stderr contract. codex without -m takes the model from
# ~/.codex/config.toml, so read it the way ai-fallback.sh does (top-level
# `model` key only, never anything else from the file).
target_model_label() {
  if [[ "$TARGET" == "claude" ]]; then
    printf 'claude/%s' "$ROLE_MODEL"
    return 0
  fi
  if [[ -n "$ROLE_MODEL" ]]; then
    printf 'codex/%s' "$ROLE_MODEL"
    return 0
  fi
  local name
  name=$(awk '
    /^[[:space:]]*\[/ { exit }
    /^[[:space:]]*model[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*(#.*)?$/, "")
      print; exit
    }' "${CODEX_HOME:-$HOME/.codex}/config.toml" 2>/dev/null | tr -d "\"'")
  printf 'codex/%s' "${name:-default}"
}

# ─── prompt assembly ─────────────────────────────────────────────────────────

# read_source <path|-> prints the file/stdin content.
read_source() {
  if [[ "$1" == "-" ]]; then
    cat
  else
    [[ -f "$1" ]] || die "prompt file not found: $1" 2
    cat "$1"
  fi
}

# A tiny, deterministic context block: repo / branch / recent commits / how many
# files are dirty. It is what makes a one-line question ("CI をはやくしたい")
# answerable without the caller writing a full brief first.
context_header() {
  local repo branch dirty
  repo=$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'none')
  dirty=$(git status --short 2>/dev/null | wc -l | tr -d ' ')
  cat <<EOF
## Context (auto, not part of the question)

- repo: $repo
- branch: $branch
- cwd: $PWD
- changed files: $dirty
- recent commits:
$(git log --oneline -5 2>/dev/null | sed 's/^/  - /' || printf '  - (none)')

--- end of context

EOF
}

prompt_body() {
  local body=$1 f
  if [[ "$WITH_CONTEXT" == "1" ]]; then
    context_header
    printf '\n'
  fi
  printf '%s\n' "$body"
  if [[ ${#APPEND_FILES[@]} -gt 0 ]]; then
    printf '\n---\n## Earlier answer(s) to build on\n\n'
    for f in "${APPEND_FILES[@]}"; do
      printf '### %s\n\n' "${f##*/}"
      read_source "$f"
      printf '\n'
    done
  fi
}

# build_prompt <role> <body> [answer_path]
# The herdr backend needs the protocol (answer file + terminal markers); the
# one-shot print backend returns the answer directly, so it gets prompt_body.
build_prompt() {
  local role=$1 body=$2 answer_path=${3:-}
  prompt_body "$body"
  cat <<EOF2

---
## Harness protocol (not part of the question)

You are running in a persistent Herdr pane, asked by another AI coding agent
rather than by the person at the keyboard. That agent reads your answer
through the terminal, so follow this format exactly.

Role: $role
EOF2

  if [[ -n "$answer_path" ]]; then
    cat <<EOF2

1. Write your complete answer, as Markdown, to this exact path:

   $answer_path

   That path is the only place you may write. Do not create any other file.
2. Then reply in the terminal with nothing but the two marker lines around a
   one-line confirmation:

<<<ANSWER>>>
FILE: $answer_path
<<<END>>>

3. If writing that file fails, put the full answer body between the markers
   instead of the FILE line, and still write nothing outside the markers.
   Never put the markers inside a fenced code block.
EOF2
  else
    cat <<EOF2

1. Do the requested work, then reply with the answer body alone.
2. Wrap it in these two lines, each on its own and on a line by itself:

<<<ANSWER>>>
(the answer)
<<<END>>>

3. Write nothing outside the markers — no preamble, no restating these rules,
   no closing offer. Never put the markers inside a fenced code block.
EOF2
  fi

  cat <<EOF2

--- end of harness protocol ---
EOF2
}

# ─── herdr backend ───────────────────────────────────────────────────────────

herdr_state_file() { printf '%s/%s.json' "$STATE_DIR" "$1"; }

# Agent status as herdr reports it: idle | working | blocked | done | unknown.
herdr_agent_state() {
  local json
  json=$(herdr agent get "$1" 2>/dev/null || echo '{}')
  jq -r '.result.agent.agent_status // .result.agent.state // .result.state // "unknown"' \
    <<<"$json" 2>/dev/null || echo unknown
}

# Wait until the agent's visible output has been stable for two samples (max
# 20s). A fresh pane that is still painting swallows input, including the
# submit Enter, so this is what keeps the first question from going missing.
herdr_wait_stable() {
  local name=$1 prev="" cur="" stable=0 waited=0
  while (( waited < 20 )); do
    sleep 1
    waited=$(( waited + 1 ))
    cur=$(herdr agent read "$name" --source recent --lines 8 2>/dev/null || true)
    if [[ -n "$cur" && "$cur" == "$prev" ]]; then
      stable=$(( stable + 1 ))
      (( stable >= 2 )) && return 0
    else
      stable=0
    fi
    prev=$cur
  done
  return 0
}

# Number of completed <<<ANSWER>>>...<<<END>>> blocks currently in the pane.
herdr_end_markers() {
  local n
  n=$(herdr agent read "$1" --source recent-unwrapped --lines "$READ_LINES" 2>/dev/null |
      grep -c '<<<END>>>' || true)
  printf '%s' "${n:-0}"
}

herdr_state_field() {
  local f=$1 field=$2
  [[ -f "$f" ]] || return 0
  jq -r --arg k "$field" '.[$k] // empty' "$f" 2>/dev/null || true
}


# Close a pane this script created (never a pane we did not record).
herdr_close_pane() {
  local pane=$1
  [[ -n "$pane" ]] || return 0
  herdr pane close "$pane" >/dev/null 2>&1 || true
}

# Close the tab (and its pane) recorded for <name>, then forget the session.
# Sessions own their tab, so closing the pane alone would leave an empty tab.
herdr_close_tab() {
  local tab=$1 pane=$2 owned=${3:-false}
  if [[ "$owned" == "true" && -n "$tab" ]]; then
    herdr tab close "$tab" >/dev/null 2>&1 && return 0
  fi
  herdr_close_pane "$pane"
}

herdr_close_session() {
  local name=$1 state pane tab
  state=$(herdr_state_file "$name")
  pane=$(herdr_state_field "$state" pane)
  tab=$(herdr_state_field "$state" tab)
  herdr_close_tab "$tab" "$pane" "$(herdr_state_field "$state" tab_owned)"
  rm -f "$state"
  echo "closed $name (tab ${tab:-none}, pane ${pane:-unknown})" >&2
}

# Ensure <name> is a live Claude session in its own tab of the calling workspace.
# Prints "<pane-id>" on stdout; progress goes to stderr.
herdr_ensure_session() {
  local name=$1 role=$2 state pane tab stored_cwd live=0 fresh=0

  state=$(herdr_state_file "$name")
  pane=$(herdr_state_field "$state" pane)
  tab=$(herdr_state_field "$state" tab)
  stored_cwd=$(herdr_state_field "$state" cwd)

  if [[ "$FORCE_NEW" == "1" ]]; then
    herdr_close_tab "$tab" "$pane" "$(herdr_state_field "$state" tab_owned)"
    live=0
  elif [[ -n "$pane" ]] && herdr agent get "$name" >/dev/null 2>&1; then
    live=1
    if [[ -n "$stored_cwd" && "$stored_cwd" != "$PWD" ]]; then
      if [[ "$REUSE_CWD" == "1" ]]; then
        echo "warning: reusing $name recorded in $stored_cwd (cwd is $PWD)" >&2
      else
        echo "note: $name was started in $stored_cwd — replacing its tab" >&2
        herdr_close_tab "$tab" "$pane" "$(herdr_state_field "$state" tab_owned)"
        live=0
      fi
    fi
  elif [[ -n "$pane" ]]; then
    # Recorded pane no longer hosts the agent: drop the tab and start over.
    herdr_close_tab "$tab" "$pane" "$(herdr_state_field "$state" tab_owned)"
    live=0
  fi

  if [[ "$live" == "1" ]]; then
    printf '%s' "$pane"
    return 0
  fi

  # One tab per session, created in the caller's workspace: without --workspace
  # the tab can land in whatever workspace another client has focused.
  local created tab
  local -a tab_args=(--cwd "$PWD")
  [[ -n "${HERDR_WORKSPACE_ID:-}" ]] && tab_args+=(--workspace "$HERDR_WORKSPACE_ID")
  if ! created=$(herdr tab create "${tab_args[@]}" --no-focus 2>&1); then
    created=$(herdr tab create "${tab_args[@]}" 2>&1) || die "herdr tab create failed: $created" 1
  fi
  pane=$(jq -r '.result.root_pane.pane_id // .result.tab.root_pane.pane_id // .result.pane.pane_id // empty' <<<"$created")
  tab=$(jq -r '.result.tab.tab_id // .result.tab_id // empty' <<<"$created")
  [[ -n "$pane" ]] || die "could not read pane id from: $created" 1
  [[ -n "$tab" ]] && herdr tab rename "$tab" "$name" >/dev/null 2>&1 || true
  fresh=1

  # Session flags for the role. Everything that takes several values is last.
  # claude: --add-dir is required because file tools refuse paths outside the
  # session cwd, and the request/answer files live in the role's temp directory.
  # codex: no answer file (read-only), so no --add-dir; --no-alt-screen keeps the
  # transcript in the scrollback, which is what herdr reads.
  local -a args=()
  local extra
  extra=$(role_extra_args "$role")
  mkdir -p "$(role_answer_dir "$name")"
  if [[ "$TARGET" == "codex" ]]; then
    args=(-s "$ROLE_SANDBOX" -a never --no-alt-screen)
    if [[ -n "$ROLE_MODEL" ]]; then
      args+=(-m "$ROLE_MODEL")
    fi
  else
    args=(--model "$ROLE_MODEL" --permission-mode "$ROLE_MODE" --strict-mcp-config)
    args+=(--add-dir "$(role_answer_dir "$name")")
    if [[ -n "$ROLE_TOOLS" ]]; then
      args+=(--tools "$ROLE_TOOLS")
    fi
    if [[ -n "${ROLE_ALLOWED:-}" ]]; then
      args+=(--allowedTools "$ROLE_ALLOWED")
    fi
  fi
  if [[ -n "$extra" ]]; then
    # shellcheck disable=SC2206  # intentional word splitting of the env knob
    args+=($extra)
  fi

  # Record the session before starting it: when the TUI stops on a startup dialog
  # (codex's update notice / folder trust, claude's approval), the tab is already
  # there, and `--close` must be able to close it.
  mkdir -p "$STATE_DIR"
  jq -n --arg agent "$name" --arg pane "$pane" --arg tab "$tab" --arg cwd "$PWD" \
        --arg role "$role" --arg model "$ROLE_MODEL" --arg mode "${ROLE_MODE:-$ROLE_SANDBOX}" \
        --arg target "$TARGET" --arg created "$(date -Iseconds)" \
    '{agent:$agent, pane:$pane, tab:$tab, tab_owned:true, cwd:$cwd,
      role:$role, model:$model, mode:$mode, target:$target, created:$created}' > "$state"

  if ! herdr agent start "$name" --kind "$AGENT_KIND" --pane "$pane" -- "${args[@]}" >&2; then
    echo "error: could not start $TARGET in $pane (startup dialog?)" >&2
    echo "       answer it in the pane, then rerun; $name is recorded, so" >&2
    echo "       $(basename "$0") --to $TARGET --close --role $role closes it" >&2
    printf '%s' "$pane"
    exit 1
  fi

  # The TUI ignores (or keeps) input sent while it is still drawing its first
  # frame, so wait until the pane has settled before the caller submits.
  herdr_wait_stable "$name"

  if [[ "$fresh" == "1" ]]; then
    echo "started $name in tab $tab ($(target_model_label), ${ROLE_MODE:-$ROLE_SANDBOX})" >&2
  fi
  printf '%s' "$pane"
}

# Pull the answer out of the pane text.
#
# Two traps to avoid:
#   1. the question is echoed in the pane and the protocol example in it carries
#      a literal <<<ANSWER>>>/<<<END>>> pair, so a plain "last block" would find
#      the example
#   2. a reply keeps streaming, so the markers arrive in pieces
#
# The protocol ends with a fixed anchor line, so only blocks AFTER the last
# anchor belong to the reply. When Claude Code collapses a long paste the echo
# is not rendered at all; then fall back to the last complete block, provided a
# new one appeared since the prompt was submitted (minend).
# Args: pane text via stdin, minend = END-marker count seen before submitting.
herdr_extract_answer() {
  awk -v anchor='end of harness protocol' -v minend="${1:-0}" '
    { L[NR] = $0 }
    END {
      a = 0; total = 0
      for (i = 1; i <= NR; i++) {
        if (index(L[i], anchor)) a = i
        if (index(L[i], "<<<END>>>")) total++
      }
      s = 0
      if (a > 0) {
        for (i = a + 1; i <= NR; i++) {
          if (index(L[i], "<<<ANSWER>>>")) { cs = i }
          else if (cs && index(L[i], "<<<END>>>")) { s = cs; e = i; cs = 0 }
        }
      } else {
        if (total <= minend) exit 1
        for (i = 1; i <= NR; i++) {
          if (index(L[i], "<<<ANSWER>>>")) { cs = i }
          else if (cs && index(L[i], "<<<END>>>")) { s = cs; e = i; cs = 0 }
        }
      }
      if (!s || e <= s + 1) exit 1

      # dedent by the common indent over non-blank lines
      indent = -1
      for (i = s + 1; i < e; i++) {
        if (L[i] ~ /^[[:space:]]*$/) continue
        match(L[i], /^[[:space:]]*/)
        if (indent < 0 || RLENGTH < indent) indent = RLENGTH
      }
      if (indent < 0) indent = 0

      first = 1; lastnb = 0
      for (i = s + 1; i < e; i++) {
        if (L[i] !~ /^[[:space:]]*$/) { if (first) { fi = i; first = 0 } lastnb = i }
      }
      if (first) exit 1
      for (i = fi; i <= lastnb; i++) print substr(L[i], indent + 1)
    }
  '
}

# Send <prompt> to the role's session and write the answer files.
# Args: role, base, prompt, answer_path (file the session writes, may be empty)
herdr_consult() {
  local role=$1 base=$2 prompt=$3 answer_path=${4:-}
  local name pane out rc=0 answer raw

  role_settings "$role"
  name=$(role_agent_name "$role")

  pane=$(herdr_ensure_session "$name" "$role")
  echo "AGENT=$name" >&2
  echo "PANE=$pane" >&2

  # Never pick up the previous turn's file as this turn's answer.
  if [[ -n "$answer_path" ]]; then
    rm -f "$answer_path"
  fi


  # The question goes into a file and only a one-line pointer is typed into the
  # pane: a long bracketed paste can be swallowed (or collapsed) by the TUI
  # while it repaints, and it also bloats the session transcript. codex writes no
  # answer file but reads the request the same way.
  local request_path submit_line
  request_path="$(role_answer_dir "$name")/request-$(basename "${base}").md"
  mkdir -p "$(dirname "$request_path")"
  printf '%s\n' "$prompt" > "$request_path"
  submit_line="Follow the instructions in $request_path now. Do not ask questions first; reply exactly as its protocol section requires."

  # Count the complete answer blocks already in the pane, so a stale reply from
  # an earlier turn can never be mistaken for this one's answer.
  local before
  before=$(herdr_end_markers "$name")

  # No --wait: herdr's 5s activity gate rejects short turns (agent_prompt_stalled)
  # and says nothing about an unsent prompt. Poll instead, and treat the answer
  # file as the primary source.
  set +e
  out=$(herdr agent prompt "$name" "$submit_line" 2>&1)
  rc=$?
  set -e

  # A blocked agent needs a person at the keyboard; stop before waiting.
  if grep -q 'agent_blocked' <<<"$out"; then
    echo "error: $name is waiting on a dialog in pane $pane" >&2
    echo "--- last lines ---" >&2
    herdr agent read "$name" --source recent-unwrapped --lines 40 >&2 2>/dev/null || true
    echo "--- answer it in the pane, then rerun this command ---" >&2
    if [[ "$CLOSE_AFTER" == "1" ]]; then herdr_close_session "$name"; fi
    die "no answer from $name (blocked)" 1
  fi
  if (( rc != 0 )); then
    echo "note: submission returned $(jq -r '.error.code // "error"' <<<"$out" 2>/dev/null || echo error) — checking the pane" >&2
  fi

  # A fresh TUI can swallow the submit Enter (the text sits unsent in the input
  # box), and a working agent keeps its reply above the fold (scrollback is only
  # collected once it settles). So each round: prefer a stable answer file, then
  # the marker block in the pane, and clear + resubmit if the question never
  # turned into a turn.
  local waited=0 raw="" answer="" resends=0 size_prev="" state_now
  local resend_at=8
  while :; do
    if [[ -n "$answer_path" && -s "$answer_path" ]]; then
      local size_now
      size_now=$(wc -c < "$answer_path" 2>/dev/null || echo 0)
      if [[ "$size_now" == "$size_prev" && "$size_now" != "0" ]]; then
        answer=$(cat "$answer_path")
        break
      fi
      size_prev=$size_now
    fi

    raw=$(herdr agent read "$name" --source recent-unwrapped --lines "$READ_LINES" 2>/dev/null || true)
    if answer=$(herdr_extract_answer "$before" <<<"$raw"); then
      break
    fi

    # A TUI that exited (Ctrl+C, a crash, a closed pane) never answers, so stop
    # early instead of waiting out the whole timeout.
    if (( waited >= 10 )) && ! herdr agent get "$name" >/dev/null 2>&1; then
      echo "error: session $name is gone (pane $pane) — the $TARGET TUI exited" >&2
      echo "       retry with --new, or inspect the pane with: $(basename "$0") --to $TARGET --show $name" >&2
      if [[ "$CLOSE_AFTER" == "1" ]]; then herdr_close_session "$name"; fi
      die "session $name disappeared" 1
    fi

    if (( waited >= TIMEOUT_S )); then
      answer=""
      break
    fi

    # An answered turn always leaves a new marker block (the protocol requires
    # it), so "no new block and the agent is idle" means the question never ran:
    # clear whatever is in the input box and submit it again. Ctrl+C clears the
    # input in Claude Code but quits the Codex TUI, so codex gets Esc instead.
    if (( waited >= resend_at && resends < 3 )); then
      state_now=$(herdr_agent_state "$name")
      if [[ "$state_now" == "idle" || "$state_now" == "done" ]]; then
        local clear_key=ctrl+c
        [[ "$TARGET" == "codex" ]] && clear_key=esc
        herdr agent send-keys "$name" "$clear_key" >/dev/null 2>&1 || true
        sleep 1
        set +e
        out=$(herdr agent prompt "$name" "$submit_line" 2>&1)
        set -e
        resends=$(( resends + 1 ))
        resend_at=$(( waited + 20 ))
        echo "note: the question did not start a turn ($state_now) — resubmitted ($resends)" >&2
      else
        resend_at=$(( waited + 20 ))
      fi
    fi

    sleep 2
    waited=$(( waited + 2 ))
  done

  local state_json state
  state=$(herdr agent get "$name" 2>/dev/null || echo '{}')
  state_json=$(jq -r '.result.agent.agent_status // .result.agent.state // .result.state // "unknown"' <<<"$state" 2>/dev/null || echo unknown)

  if [[ "${CLAUDE_CONSULT_DEBUG:-0}" == "1" ]]; then
    printf '%s\n' "$raw" > "${base}.pane.txt"
    echo "debug: pane text saved to ${base}.pane.txt" >&2
  fi
  if [[ -z "${answer:-}" ]]; then
    echo "error: no reply from $name within ${TIMEOUT_S}s (pane $pane, state $state_json)" >&2
    if (( rc != 0 )); then
      echo "       submit said: $out" >&2
    fi
    echo "       inspect: $(basename "$0") --show $name" >&2
    if [[ "$CLOSE_AFTER" == "1" ]]; then herdr_close_session "$name"; fi
    printf '%s\n' "$raw" > "${base}.json"
    die "could not extract the answer from $name" 1
  fi

  # The session writes the full Markdown answer to answer_path (a fenced code
  # block survives there but not in the TUI rendering), so prefer the file and
  # keep the marker body only as the fallback.
  if [[ -n "$answer_path" && -s "$answer_path" ]]; then
    answer=$(cat "$answer_path")
  elif [[ "$answer" =~ ^FILE: ]]; then
    echo "error: $name said it wrote a file, but $answer_path is missing" >&2
    if [[ "$CLOSE_AFTER" == "1" ]]; then herdr_close_session "$name"; fi
    die "no answer file from $name" 1
  fi

  jq -n --arg agent "$name" --arg pane "$pane" --arg role "$role" \
        --arg model "$ROLE_MODEL" --arg backend herdr --arg state "$state_json" \
        --arg submitted "$out" --arg text "$raw" \
    '{backend:$backend, role:$role, agent:$agent, pane:$pane, model:$model,
      state:$state, submit:$submitted, pane_text:$text}' > "${base}.json"
  printf '%s\n' "$answer" > "${base}.answer.md"

  echo "ANSWER_FILE=${base}.answer.md" >&2
  echo "AI_MODEL=$(target_model_label)" >&2
  if [[ "$CLOSE_AFTER" == "1" ]]; then
    herdr_close_session "$name"
  fi

  cat "${base}.answer.md"
}

# ─── print backend (one-shot claude -p / codex exec) ────────────────────────────

claude_print_consult() {
  local base=$1 prompt=$2
  local answer_file="${base}.answer.md" raw_file="${base}.json"
  # The print backend stays strictly read-only, whatever the role's tool list is.
  local args=(-p --model "$ROLE_MODEL" --permission-mode plan --tools "Read,Grep,Glob"
              --strict-mcp-config --output-format json)
  [[ -n "$RESUME_ID" ]] && args+=(--resume "$RESUME_ID")
  local rc=0
  # The prompt goes through stdin, not argv: it can be long (ARG_MAX) and it may
  # start with '-' (a Markdown rule, a bullet), which the CLI would parse as an
  # option.
  printf '%s' "$prompt" |
    timeout -k 1m "${TIMEOUT_S}s" claude "${args[@]}" > "$raw_file" || rc=$?
  if (( rc != 0 )); then
    echo "error: claude exited with $rc (see $raw_file)" >&2
    return 1
  fi
  local result
  result=$(jq -c 'if type == "array" then map(select(.type == "result")) | last else . end' "$raw_file" 2>/dev/null || true)
  if [[ -z "$result" || "$result" == "null" ]]; then
    echo "error: no result event in $raw_file" >&2
    return 1
  fi
  if [[ "$(jq -r '.is_error // false' <<<"$result")" == "true" ]]; then
    echo "error: claude reported an error: $(jq -r '.result // .subtype // "unknown"' <<<"$result")" >&2
    return 1
  fi
  jq -r '.result // empty' <<<"$result" > "$answer_file"
  if [[ ! -s "$answer_file" ]]; then
    echo "error: empty answer (see $raw_file)" >&2
    return 1
  fi
  cat "$answer_file"
  echo "ANSWER_FILE=$answer_file" >&2
  echo "AI_MODEL=$(target_model_label)" >&2
  echo "SESSION_ID=$(jq -r '.session_id // empty' <<<"$result")" >&2
}

# One-shot codex exec in a read-only sandbox, modelled on ai-fallback.sh so both
# paths use the same flags. -o writes the final message, which is the answer; the
# transcript lands in <base>.json.
codex_print_consult() {
  local base=$1 prompt=$2
  local answer_file="${base}.answer.md" raw_file="${base}.json"
  local -a args=(exec -s read-only --ephemeral --skip-git-repo-check --color never
                 -o "$answer_file")
  if [[ -n "$ROLE_MODEL" ]]; then
    args+=(-m "$ROLE_MODEL")
  fi
  local rc=0
  timeout -k 1m "${TIMEOUT_S}s" codex "${args[@]}" -- "$prompt" < /dev/null > "$raw_file" 2>&1 || rc=$?
  if (( rc != 0 )); then
    echo "error: codex exited with $rc (see $raw_file)" >&2
    return 1
  fi
  if [[ ! -s "$answer_file" ]]; then
    echo "error: codex returned no final message (see $raw_file)" >&2
    return 1
  fi
  # codex -o writes the final message without a trailing newline.
  [[ -n "$(tail -c 1 "$answer_file")" ]] && echo >>"$answer_file"
  cat "$answer_file"
  echo "ANSWER_FILE=$answer_file" >&2
  echo "AI_MODEL=$(target_model_label)" >&2
}

print_backend() {
  if [[ "$TARGET" == "codex" ]]; then
    codex_print_consult "$@"
  else
    claude_print_consult "$@"
  fi
}

# ─── main ────────────────────────────────────────────────────────────────────

for cmd in jq "$TARGET"; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is not installed" 1
done
[[ "$BACKEND" == "herdr" ]] && { command -v herdr >/dev/null 2>&1 || die "herdr is not installed" 1; }

if [[ "${CLOSE_ONLY:-0}" == "1" ]]; then
  # `--close` on its own closes the recorded session(s) instead of consulting.
  close_roles=()
  if [[ -n "$ROLES" ]]; then
    IFS=',' read -r -a close_roles <<<"$ROLES"
  elif [[ -n "$ROLE" ]]; then
    close_roles=("$ROLE")
  fi
  if [[ ${#close_roles[@]} -gt 0 ]]; then
    for r in "${close_roles[@]}"; do
      herdr_close_session "$(role_agent_name "${r// /}")"
    done
  else
    for f in "$STATE_DIR"/*.json; do
      [[ -f "$f" ]] || continue
      herdr_close_session "$(jq -r '.agent // empty' "$f")"
    done
  fi
  exit 0
fi

# A prompt with no file name to derive the outputs from (stdin or --text): keep
# them out of the caller's cwd, because a consult must never drop .answer.md /
# .json into the repository.
inline_base() {
  printf '%s/harness-consult/out/%s-consult-%s' \
    "${TMPDIR:-/tmp}" "$TARGET" "$(date +%Y%m%d-%H%M%S)"
}

if [[ -n "$INLINE_TEXT" ]]; then
  [[ -z "$src" ]] || die "--text and a prompt file are mutually exclusive" 2
  prompt=$INLINE_TEXT
  base=$(inline_base)
  mkdir -p "$(dirname "$base")"
elif [[ "$src" == "-" ]]; then
  prompt=$(cat)
  base=$(inline_base)
  mkdir -p "$(dirname "$base")"
else
  prompt=$(read_source "$src")
  base="${src%.*}"
fi
[[ -n "$prompt" ]] || die "empty prompt" 2

if [[ -n "$ROLES" && -n "$ROLE" ]]; then
  die "--role and --roles are mutually exclusive" 2
fi

# Absolute path of the answer file the herdr session writes, or empty when the
# target cannot write one (codex consult/review run read-only and answer between
# the terminal markers). One directory per agent, so the Write permission rule
# stays narrow.
answer_path_for() {
  local role=$1 stem
  if [[ "${ROLE_ANSWER:-0}" != "1" ]]; then
    return 0
  fi
  stem=$(basename "$base")
  printf '%s/%s.answer.md' "$(role_answer_dir "$(role_agent_name "$role")")" "$stem"
}

# Single role.
if [[ -z "$ROLES" ]]; then
  role=${ROLE:-consult}
  role_settings "$role"
  if [[ "$BACKEND" == "print" && "$role" == "implement" ]]; then
    die "the print backend is read-only; use --role implement inside Herdr" 2
  fi
  if [[ "$BACKEND" == "print" ]]; then
    print_backend "$base" "$(prompt_body "$prompt")"
  else
    apath=$(answer_path_for "$role")
    [[ -n "$apath" ]] && mkdir -p "$(dirname "$apath")"
    herdr_consult "$role" "$base" "$(build_prompt "$role" "$prompt" "$apath")" "$apath"
  fi
  exit 0
fi

# Several roles in parallel — one independent opinion per role.
IFS=',' read -r -a role_list <<<"$ROLES"
[[ ${#role_list[@]} -gt 0 ]] || die "empty --roles" 2

pids=()
declare -A codes=()
for role in "${role_list[@]}"; do
  role=${role// /}
  [[ -n "$role" ]] || continue
  if [[ -n "${codes[$role]:-}" ]]; then
    die "duplicate role in --roles: $role" 2
  fi
  codes[$role]=pending
  role_settings "$role"
  if [[ "$BACKEND" == "print" && "$role" == "implement" ]]; then
    die "the print backend is read-only; use --role implement inside Herdr" 2
  fi
  # Both backends write <base>.<role>.answer.md themselves; drop the stdout copy.
  (
    if [[ "$BACKEND" == "print" ]]; then
      print_backend "${base}.${role}" "$(prompt_body "$prompt")"
    else
      apath=$(answer_path_for "$role")
      [[ -n "$apath" ]] && mkdir -p "$(dirname "$apath")"
      herdr_consult "$role" "${base}.${role}" \
        "$(build_prompt "$role" "$prompt" "$apath")" "$apath"
    fi
  ) > /dev/null &
  pids+=("$!:$role")
done

fail=0
for entry in "${pids[@]}"; do
  pid=${entry%%:*}
  role=${entry#*:}
  if wait "$pid"; then codes[$role]=0; else codes[$role]=1; fail=1; fi
done

for role in "${role_list[@]}"; do
  role=${role// /}
  [[ -n "$role" ]] || continue
  echo ""
  echo "## $role"
  echo ""
  if [[ "${codes[$role]}" == "0" && -s "${base}.${role}.answer.md" ]]; then
    cat "${base}.${role}.answer.md"
  else
    echo "_(no answer — see the pane or ${base}.${role}.json)_"
  fi
done

exit "$fail"
