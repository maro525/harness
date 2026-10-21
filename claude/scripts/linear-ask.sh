#!/bin/bash
# shellcheck disable=SC2016  # GraphQL $variables are literal, not shell expansions
# Relay a question to a Linear issue as a comment and wait for a reply.
#
# Used by /orchestrate (see "質問の中継（Linear）" in commands/orchestrate.md).
#
#   linear-ask.sh --check
#   linear-ask.sh --issue ID --body-file PATH [--comment-id UUID]
#                 [--post-only | --timeout SEC] [--interval SEC]
#   linear-ask.sh --reply-to COMMENT_ID --body-file PATH
#
# Key: $LINEAR_API_KEY, else ${XDG_CONFIG_HOME:-~/.config}/harness/linear.env
# (one line `LINEAR_API_KEY=lin_api_...`, owned by you, mode 600 or 400). The
# file is parsed, never sourced. The key never goes to argv, logs or stdout:
# curl reads its config (URL, headers) from stdin via `-K -`.
#
# stdout carries only the machine-readable result; diagnostics go to stderr.
#   ask:   comment_id: / comment_url: (as soon as the question exists),
#          then reply_id: / reply_url: / reply_author: / --- / reply body
#          (--post-only stops after comment_url: and exits 0)
#   check: ok
#
# A reply is the oldest child comment of the question with a non-empty body
# that does not contain "claude-q:" (substring match: Linear re-serializes
# markdown, so the marker may come back escaped as "\[claude-q:...\]").
# Authors are not checked; reply_author: reports who answered.
#
# Exit codes:
#   0   answered (ask) / posted (post-only) / key works (check) /
#       reply posted (reply-to)
#   2   timed out without a reply
#   3   key missing, unreadable, insecure file mode, or rejected by Linear
#   4   API / network failure (incl. 10 consecutive polling failures)
#   64  usage error
#   130 / 143  interrupted (SIGINT / SIGTERM)

set -euo pipefail

readonly API_URL="https://api.linear.app/graphql"
readonly MARKER="claude-q:"
readonly DEFAULT_TIMEOUT=14400
readonly DEFAULT_INTERVAL=20
readonly MAX_BACKOFF=120
readonly MAX_CONSECUTIVE_FAILURES=10
readonly CURL_MAX_TIME=30
readonly CHILDREN_PAGE=50

readonly EXIT_OK=0
readonly EXIT_TIMEOUT=2
readonly EXIT_KEY=3
readonly EXIT_API=4
readonly EXIT_USAGE=64
readonly UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

PROG="$(basename "$0")"
WORK_DIR=""
API_KEY=""
# Set by gql(): the jq-parsed JSON response of the last successful call.
GQL_RESPONSE=""

log() { printf '%s: %s\n' "$PROG" "$*" >&2; }

usage() {
  cat >&2 <<EOF
Usage:
  $PROG --check
  $PROG --issue ID --body-file PATH [--comment-id UUID] [--post-only | --timeout SEC] [--interval SEC]
  $PROG --reply-to COMMENT_ID --body-file PATH

  --check        Verify the API key (viewer query). Prints "ok".
  --issue        Issue identifier (e.g. ABC-123) or UUID to post the question on.
  --body-file    Markdown file with the comment body.
  --comment-id   UUID for the question comment. If a comment with this id
                 already exists, it is not posted again and polling resumes
                 (re-arm). Default: a new UUID.
  --post-only    With --issue: post the question (idempotent), print
                 comment_id/comment_url and exit 0 without waiting. Wait
                 afterwards by re-running with the same --comment-id.
  --timeout      Seconds to wait for a reply (default $DEFAULT_TIMEOUT).
  --interval     Polling interval in seconds (default $DEFAULT_INTERVAL).
  --reply-to     Post the body as a reply to COMMENT_ID (marked so it is
                 never taken as an answer), e.g. "answered in terminal".

Key: \$LINEAR_API_KEY, else \${XDG_CONFIG_HOME:-~/.config}/harness/linear.env
     (LINEAR_API_KEY=..., mode 600). Exit: 0 ok / 2 timeout / 3 key /
     4 API / 64 usage / 130,143 signal.
EOF
}

die_usage() {
  log "$*"
  usage
  exit "$EXIT_USAGE"
}

cleanup() {
  if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}

on_signal() {
  local code="$1"
  trap - INT TERM
  log "interrupted"
  exit "$code"
}

trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM

# Sleep that the INT/TERM traps can interrupt promptly.
interruptible_sleep() {
  sleep "$1" &
  wait $! || true
}

is_positive_int() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

new_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    python3 -c 'import uuid; print(uuid.uuid4())'
  fi
}

# --- key loading -----------------------------------------------------------

key_file_path() {
  printf '%s/harness/linear.env' "${XDG_CONFIG_HOME:-$HOME/.config}"
}

# Echo "MODE UID" of a file (octal permission bits, owner uid).
file_mode_owner() {
  local path="$1"
  if stat -L -c '%a %u' "$path" 2>/dev/null; then
    return 0
  fi
  stat -L -f '%Lp %u' "$path"
}

# Read LINEAR_API_KEY=... from the key file without sourcing it.
read_key_file() {
  local path="$1"
  local mode owner line value=""

  read -r mode owner < <(file_mode_owner "$path") || {
    log "cannot stat $path"
    return 1
  }
  if [[ "$owner" != "$(id -u)" ]]; then
    log "$path must be owned by the current user"
    return 1
  fi
  if (( (8#$mode & 8#077) != 0 )); then
    log "$path has mode $mode; run: chmod 600 $path"
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?LINEAR_API_KEY=(.*)$ ]]; then
      value="${BASH_REMATCH[2]}"
    fi
  done < "$path"

  value="${value%"${value##*[![:space:]]}"}"
  if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
    value="${BASH_REMATCH[1]}"
  fi
  if [[ -z "$value" ]]; then
    log "$path has no LINEAR_API_KEY= line"
    return 1
  fi
  API_KEY="$value"
}

load_key() {
  local path
  path="$(key_file_path)"

  if [[ -n "${LINEAR_API_KEY:-}" ]]; then
    API_KEY="$LINEAR_API_KEY"
  elif [[ -f "$path" ]]; then
    read_key_file "$path" || exit "$EXIT_KEY"
  else
    log "no Linear API key: set LINEAR_API_KEY or create $path"
    log "  (one line 'LINEAR_API_KEY=lin_api_...', then chmod 600; keys: Linear > Settings > Security & access > Personal API keys)"
    exit "$EXIT_KEY"
  fi

  # Allow only [A-Za-z0-9_-]; refusing anything else keeps the curl config safe.
  if [[ ! "$API_KEY" =~ ^[A-Za-z0-9_-]+$ ]]; then
    log "LINEAR_API_KEY contains unexpected characters"
    exit "$EXIT_KEY"
  fi
}

# --- GraphQL ---------------------------------------------------------------

# gql QUERY VARIABLES_JSON
# Returns 0 and sets GQL_RESPONSE, 3 on auth failure, 4 on any other failure.
gql() {
  local query="$1"
  local variables="$2"
  local payload="$WORK_DIR/payload.json"
  local response="$WORK_DIR/response.json"
  local http_code

  jq -n --arg q "$query" --argjson v "$variables" '{query: $q, variables: $v}' > "$payload"
  : > "$response"

  # Config on stdin (-K -) keeps the key out of argv. printf is a builtin.
  if ! http_code=$(printf 'url = "%s"\nheader = "Authorization: %s"\nheader = "Content-Type: application/json"\n' \
      "$API_URL" "$API_KEY" \
      | curl -sS -K - -X POST --max-time "$CURL_MAX_TIME" \
          --data-binary "@$payload" -o "$response" -w '%{http_code}'); then
    log "request failed (network)"
    return "$EXIT_API"
  fi

  if [[ "$http_code" == "401" || "$http_code" == "403" ]] \
     || jq -e '[.errors[]?.extensions.code? // empty] | index("AUTHENTICATION_ERROR")' "$response" >/dev/null 2>&1; then
    log "Linear rejected the API key (HTTP $http_code)"
    return "$EXIT_KEY"
  fi
  if ! jq -e . "$response" >/dev/null 2>&1; then
    log "non-JSON response (HTTP $http_code)"
    return "$EXIT_API"
  fi
  if jq -e '(.errors // []) | length > 0' "$response" >/dev/null; then
    [[ -n "${GQL_QUIET:-}" ]] || log "GraphQL error (HTTP $http_code): $(jq -c '[.errors[].message]' "$response")"
    return "$EXIT_API"
  fi
  if [[ "$http_code" != "200" ]]; then
    log "unexpected HTTP $http_code"
    return "$EXIT_API"
  fi

  GQL_RESPONSE="$(cat "$response")"
}

# Run gql; exit on auth failure, otherwise pass the status through.
gql_or_exit_on_auth() {
  local rc=0
  gql "$@" || rc=$?
  if [[ "$rc" == "$EXIT_KEY" ]]; then
    exit "$EXIT_KEY"
  fi
  return "$rc"
}

# --- operations ------------------------------------------------------------

cmd_check() {
  gql_or_exit_on_auth 'query { viewer { id name } }' '{}' || exit "$EXIT_API"
  log "key OK (viewer: $(jq -r '.data.viewer.name // "?"' <<< "$GQL_RESPONSE"))"
  echo "ok"
}

# Echo the issue UUID for an identifier or UUID.
resolve_issue() {
  local issue="$1"
  gql_or_exit_on_auth 'query($id: String!) { issue(id: $id) { id } }' \
    "$(jq -n --arg id "$issue" '{id: $id}')" || return "$EXIT_API"
  jq -r '.data.issue.id // empty' <<< "$GQL_RESPONSE"
}

# Echo "URL" if the comment exists, nothing if it does not; 4 on API failure.
comment_url_if_exists() {
  local comment_id="$1"
  local rc=0
  GQL_QUIET=1 gql 'query($id: String!) { comment(id: $id) { id url } }' \
    "$(jq -n --arg id "$comment_id" '{id: $id}')" || rc=$?
  if [[ "$rc" == "$EXIT_KEY" ]]; then
    exit "$EXIT_KEY"
  fi
  if [[ "$rc" != 0 ]]; then
    # Linear answers an unknown id with an "Entity not found" error.
    if jq -e '[.errors[]?.message] | any(test("not found"; "i"))' "$WORK_DIR/response.json" >/dev/null 2>&1; then
      return 0
    fi
    return "$EXIT_API"
  fi
  jq -r '.data.comment.url // empty' <<< "$GQL_RESPONSE"
}

# create_comment INPUT_JSON -> echo URL; idempotent via the client-side id.
create_comment() {
  local input="$1"
  local comment_id url attempt rc
  comment_id="$(jq -r '.id' <<< "$input")"

  for attempt in 1 2 3; do
    rc=0
    gql_or_exit_on_auth \
      'mutation($input: CommentCreateInput!) { commentCreate(input: $input) { success comment { id url } } }' \
      "$(jq -n --argjson input "$input" '{input: $input}')" || rc=$?
    if [[ "$rc" == 0 ]]; then
      if jq -e --arg id "$comment_id" \
          '.data.commentCreate.success == true and .data.commentCreate.comment.id == $id' \
          <<< "$GQL_RESPONSE" >/dev/null; then
        jq -r '.data.commentCreate.comment.url // empty' <<< "$GQL_RESPONSE"
        return 0
      fi
      log "commentCreate returned success != true or no comment id"
    fi
    # The first attempt may have landed (timeout, duplicate id): check.
    rc=0
    url="$(comment_url_if_exists "$comment_id")" || rc=$?
    if [[ "$rc" == "$EXIT_KEY" ]]; then
      exit "$EXIT_KEY"
    fi
    if [[ -n "$url" ]]; then
      echo "$url"
      return 0
    fi
    log "commentCreate failed (attempt $attempt)"
    interruptible_sleep $((attempt * 5))
  done
  return "$EXIT_API"
}

read_body_file() {
  local path="$1"
  if [[ ! -f "$path" || ! -r "$path" ]]; then
    die_usage "body file not readable: $path"
  fi
  if [[ ! -s "$path" ]]; then
    die_usage "body file is empty: $path"
  fi
  cat "$path"
}

cmd_reply() {
  local parent_id="$1"
  local body_file="$2"
  local body issue_uuid input
  body="$(read_body_file "$body_file")"

  gql_or_exit_on_auth 'query($id: String!) { comment(id: $id) { id issue { id } } }' \
    "$(jq -n --arg id "$parent_id" '{id: $id}')" || exit "$EXIT_API"
  issue_uuid="$(jq -r '.data.comment.issue.id // empty' <<< "$GQL_RESPONSE")"
  if [[ -z "$issue_uuid" ]]; then
    log "comment $parent_id not found"
    exit "$EXIT_API"
  fi

  input="$(jq -n --arg id "$(new_uuid)" --arg issue "$issue_uuid" --arg parent "$parent_id" \
    --arg body "$body"$'\n\n'"[${MARKER}done]" \
    '{id: $id, issueId: $issue, parentId: $parent, body: $body}')"
  create_comment "$input" >/dev/null || exit "$EXIT_API"
  log "reply posted"
}

# Poll the question's children until a non-marker reply appears.
wait_for_reply() {
  local comment_id="$1"
  local timeout="$2"
  local interval="$3"
  local deadline=$((SECONDS + timeout))
  local failures=0
  local delay reply rc
  local query='query($id: String!) { comment(id: $id) { children(first: '"$CHILDREN_PAGE"', orderBy: createdAt) { nodes { id url body createdAt user { name displayName } } } } }'
  local variables
  variables="$(jq -n --arg id "$comment_id" '{id: $id}')"

  while (( SECONDS < deadline )); do
    rc=0
    gql_or_exit_on_auth "$query" "$variables" || rc=$?
    if [[ "$rc" != 0 ]]; then
      failures=$((failures + 1))
      if (( failures >= MAX_CONSECUTIVE_FAILURES )); then
        log "giving up after $failures consecutive failures"
        exit "$EXIT_API"
      fi
      delay=$((interval * (1 << (failures < 6 ? failures : 6))))
      (( delay > MAX_BACKOFF )) && delay=$MAX_BACKOFF
      log "poll failed ($failures/$MAX_CONSECUTIVE_FAILURES); retrying in ${delay}s"
      interruptible_sleep "$delay"
      continue
    fi
    failures=0

    reply="$(jq -c --arg m "$MARKER" '
      [.data.comment.children.nodes[]?
       | select((.body // "") | test("\\S")) | select(.body | contains($m) | not)]
      | sort_by(.createdAt) | first // empty' <<< "$GQL_RESPONSE")"
    if [[ -n "$reply" ]]; then
      printf 'reply_id: %s\n' "$(jq -r '.id' <<< "$reply")"
      printf 'reply_url: %s\n' "$(jq -r '.url // ""' <<< "$reply")"
      printf 'reply_author: %s\n' "$(jq -r '.user | if . == null then "" else ((.name // "") + (if .displayName then " (@" + .displayName + ")" else "" end)) end' <<< "$reply")"
      printf -- '---\n'
      jq -r '.body' <<< "$reply"
      exit "$EXIT_OK"
    fi
    interruptible_sleep "$interval"
  done

  log "no reply within ${timeout}s; re-arm with --comment-id $comment_id"
  exit "$EXIT_TIMEOUT"
}

cmd_ask() {
  local issue="$1"
  local body_file="$2"
  local comment_id="$3"
  local timeout="$4"
  local interval="$5"
  local post_only="$6"
  local body issue_uuid url input

  body="$(read_body_file "$body_file")"

  url="$(comment_url_if_exists "$comment_id")" || exit $?
  if [[ -n "$url" ]]; then
    if [[ -n "$post_only" ]]; then
      log "question $comment_id already posted"
    else
      log "question $comment_id already posted; resuming wait"
    fi
  else
    issue_uuid="$(resolve_issue "$issue")" || exit $?
    if [[ -z "$issue_uuid" ]]; then
      log "issue not found: $issue"
      exit "$EXIT_API"
    fi
    input="$(jq -n --arg id "$comment_id" --arg issue "$issue_uuid" \
      --arg body "$body"$'\n\n'"[${MARKER}${comment_id:0:8}]" \
      '{id: $id, issueId: $issue, body: $body}')"
    url="$(create_comment "$input")" || exit $?
    log "question posted"
  fi

  printf 'comment_id: %s\n' "$comment_id"
  printf 'comment_url: %s\n' "$url"
  if [[ -n "$post_only" ]]; then
    exit "$EXIT_OK"
  fi
  wait_for_reply "$comment_id" "$timeout" "$interval"
}

# --- main ------------------------------------------------------------------

MODE=""

# --check / --issue / --reply-to are mutually exclusive.
set_mode() {
  if [[ -n "$MODE" && "$MODE" != "$1" ]]; then
    die_usage "--check, --issue and --reply-to are mutually exclusive"
  fi
  MODE="$1"
}

main() {
  local mode="" issue="" body_file="" comment_id="" reply_to="" post_only=""
  local timeout="$DEFAULT_TIMEOUT" interval="$DEFAULT_INTERVAL" timeout_set=""

  [[ $# -eq 0 ]] && die_usage "no arguments"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check) set_mode check; shift ;;
      --issue) [[ $# -ge 2 ]] || die_usage "--issue needs a value"; issue="$2"; set_mode ask; shift 2 ;;
      --post-only) post_only=1; shift ;;
      --body-file) [[ $# -ge 2 ]] || die_usage "--body-file needs a value"; body_file="$2"; shift 2 ;;
      --comment-id) [[ $# -ge 2 ]] || die_usage "--comment-id needs a value"; comment_id="$2"; shift 2 ;;
      --timeout) [[ $# -ge 2 ]] || die_usage "--timeout needs a value"; timeout="$2"; timeout_set=1; shift 2 ;;
      --interval) [[ $# -ge 2 ]] || die_usage "--interval needs a value"; interval="$2"; shift 2 ;;
      --reply-to) [[ $# -ge 2 ]] || die_usage "--reply-to needs a value"; reply_to="$2"; set_mode reply; shift 2 ;;
      -h|--help) usage; exit "$EXIT_OK" ;;
      *) die_usage "unknown option: $1" ;;
    esac
  done
  mode="$MODE"

  is_positive_int "$timeout" || die_usage "--timeout must be a positive integer"
  is_positive_int "$interval" || die_usage "--interval must be a positive integer"
  if [[ -n "$comment_id" && ! "$comment_id" =~ $UUID_RE ]]; then
    die_usage "--comment-id must be a UUID (8-4-4-4-12 hex)"
  fi
  if [[ "$mode" == "reply" && ! "$reply_to" =~ $UUID_RE ]]; then
    die_usage "--reply-to must be a UUID (8-4-4-4-12 hex)"
  fi
  if [[ -n "$post_only" && "$mode" != "ask" ]]; then
    die_usage "--post-only needs --issue"
  fi
  if [[ -n "$post_only" && -n "$timeout_set" ]]; then
    die_usage "--post-only and --timeout are mutually exclusive"
  fi
  case "$mode" in
    check) ;;
    ask) [[ -n "$body_file" ]] || die_usage "--issue needs --body-file" ;;
    reply) [[ -n "$body_file" ]] || die_usage "--reply-to needs --body-file" ;;
    *) die_usage "one of --check, --issue or --reply-to is required" ;;
  esac

  local dep
  for dep in curl jq; do
    if ! command -v "$dep" >/dev/null 2>&1; then
      log "$dep is required"
      exit "$EXIT_API"
    fi
  done

  load_key
  WORK_DIR="$(mktemp -d)"

  case "$mode" in
    check) cmd_check ;;
    reply) cmd_reply "$reply_to" "$body_file" ;;
    ask)
      comment_id="$(printf '%s' "${comment_id:-$(new_uuid)}" | tr '[:upper:]' '[:lower:]')"
      cmd_ask "$issue" "$body_file" "$comment_id" "$timeout" "$interval" "$post_only"
      ;;
  esac
}

main "$@"
