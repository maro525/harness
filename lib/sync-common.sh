#!/bin/bash
# Shared sync helpers for sync-pi.sh / sync-claude.sh / sync-opencode.sh / sync-cline.sh.
# A copy lives in maro525/harness (its sync scripts); port fixes to both.
#
# Provides:
#   - Interactive diff + a/p/h/H/s/d/q prompt for syncing HOME <-> repo
#   - Optional non-interactive (auto-copy HOME -> repo) mode via -n
#   - File / directory / rsync-based sync helpers
#
# Source this file from each sync script:
#   source "$SCRIPT_DIR/lib/sync-common.sh"
#   sync_common::parse_args "$(basename "$0")" "Sync ... description ..." "$@"
#   sync_common::show_header "$(basename "$0")"
#
# Public globals (set by helpers, read by callers):
#   INTERACTIVE     1 = interactive (default), 0 = non-interactive
#   PROMPT_ACTION   last interactive_prompt result (a/p/h/H/s/q)
#   DIFF_RESULT     last show_diff result (0=same, 1=different, 2=error)

# Guard against double-sourcing.
if [[ "${SYNC_COMMON_SOURCED:-0}" == "1" ]]; then
  return 0
fi
SYNC_COMMON_SOURCED=1

# Default to interactive; parse_args may flip this.
INTERACTIVE=1
PROMPT_ACTION=""
DIFF_RESULT=0

# Skills installed from the Cloudflare plugin bundle — vendor content, not
# personal config, so they stay out of the repo (cloudflare/ alone is 300+
# files of reference docs). The same bundle lands in ~/.claude/skills,
# ~/.config/opencode/skills and ~/.cline/skills, so all three sync scripts
# exclude this one list.
SYNC_COMMON_CLOUDFLARE_SKILLS=(
  agents-sdk
  cloudflare
  cloudflare-email-service
  cloudflare-one
  cloudflare-one-migrations
  durable-objects
  sandbox-sdk
  turnstile-spin
  web-perf
  workers-best-practices
  wrangler
)

# Print usage and exit. Args: script_name, description.
sync_common::usage() {
  local script_name="$1"
  local description="$2"
  cat <<EOF
Usage: $script_name [OPTIONS]

$description
Default mode: interactive (show diffs and prompt before syncing).

Options:
  -n, --non-interactive  Auto-copy without prompting
  -h, --help             Show this help message and exit
EOF
  exit 0
}

# Parse CLI args. Args: script_name, description, then "$@".
# Sets INTERACTIVE based on flags. Aborts on unknown options.
sync_common::parse_args() {
  local script_name="$1"
  local description="$2"
  shift 2

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--non-interactive)
        INTERACTIVE=0
        shift
        ;;
      -h|--help)
        sync_common::usage "$script_name" "$description"
        ;;
      *)
        echo "Error: Unknown option '$1'" >&2
        sync_common::usage "$script_name" "$description"
        ;;
    esac
  done
}

# Print header banner. Args: script_name.
sync_common::show_header() {
  local script_name="$1"
  echo "=== $script_name ==="
  if [[ $INTERACTIVE -eq 1 ]]; then
    echo "Mode: Interactive (diff/merge)"
  else
    echo "Mode: Non-interactive (auto-copy)"
  fi
  echo ""
}

# Terminal-aware UI width shared by the file header and diff box.
# Echoes a width clamped to [40, 100].
sync_common::ui_width() {
  local width
  width=$(tput cols 2>/dev/null || echo 80)
  if [[ $width -gt 100 ]]; then
    width=100
  elif [[ $width -lt 40 ]]; then
    width=40
  fi
  echo "$width"
}

# Print a diff between two files inside a visual box.
# Sign convention is FIXED regardless of which side is missing:
#   '-' (red)   = repo side
#   '+' (green) = HOME side
# A missing side is diffed against /dev/null, so a file that exists only in
# HOME renders as all '+', and one that exists only in repo as all '-'.
# Renders via delta when available (syntax highlighting, line numbers),
# falling back to colordiff, then plain diff.
# Args: src (HOME path), dst (repo path), [max_lines (default: 40)].
sync_common::print_diff_box() {
  local src="$1"
  local dst="$2"
  local max_lines="${3:-40}"

  local width
  width=$(sync_common::ui_width)

  # Build dash line efficiently — no seq, no multibyte issues
  local dashes
  printf -v dashes '%*s' $((width - 2)) ''
  dashes=${dashes// /─}

  # Fixed orientation: repo is always the '-' side, HOME always the '+' side.
  local repo_side="$dst"
  local home_side="$src"
  [[ -f "$repo_side" ]] || repo_side=/dev/null
  [[ -f "$home_side" ]] || home_side=/dev/null

  # Keep the real filename in the labels so delta can pick the syntax
  # highlighting language from the extension.
  local name
  name=$(basename "${dst:-$src}")
  local repo_label="repo/$name"
  local home_label="HOME/$name"

  echo ""
  echo "┌${dashes}┐"
  printf '│ Diff: \e[31m− repo\e[0m / \e[32m+ HOME\e[0m\n'
  echo "├${dashes}┤"

  local diff_output
  if command -v delta &>/dev/null; then
    diff_output=$(diff -u --label "$repo_label" --label "$home_label" "$repo_side" "$home_side" 2>/dev/null \
      | delta --paging=never --keep-plus-minus-markers --file-style=omit \
              --hunk-header-style='line-number' --hunk-header-decoration-style=omit \
              --width=$((width - 2))) || true
  elif command -v colordiff &>/dev/null; then
    diff_output=$(diff -u --label "$repo_label" --label "$home_label" "$repo_side" "$home_side" 2>/dev/null | colordiff) || true
  else
    diff_output=$(diff -u --label "$repo_label" --label "$home_label" "$repo_side" "$home_side" 2>/dev/null) || true
  fi

  # delta emits a leading blank line — drop it so the box stays tight.
  diff_output="${diff_output#$'\n'}"

  # P2: defensive check for empty diff_output
  if [[ -n "$diff_output" ]]; then
    local count=0
    while IFS= read -r line; do
      if [[ $count -ge $max_lines ]]; then
        echo "│   ... (truncated at $max_lines lines — press (d) for full diff)"
        break
      fi
      echo "│ $line"
      count=$((count + 1))
    done <<< "$diff_output"
  else
    echo "│ (no differences)"
  fi

  echo "└${dashes}┘"
}

# Show the COMPLETE diff between two files (no truncation), paged through
# less when the terminal is interactive so long diffs are fully scrollable.
# Same fixed orientation as print_diff_box: '-' = repo, '+' = HOME.
# Args: src (HOME path), dst (repo path).
sync_common::show_full_diff() {
  local src="$1"
  local dst="$2"

  local repo_side="$dst"
  local home_side="$src"
  [[ -f "$repo_side" ]] || repo_side=/dev/null
  [[ -f "$home_side" ]] || home_side=/dev/null

  local name
  name=$(basename "${dst:-$src}")

  local raw
  raw=$(diff -u --label "repo/$name" --label "HOME/$name" "$repo_side" "$home_side" 2>/dev/null) || true

  if [[ -z "$raw" ]]; then
    echo "  (no differences)"
    return 0
  fi

  local rendered
  if command -v delta &>/dev/null; then
    local width
    width=$(sync_common::ui_width)
    rendered=$(printf '%s\n' "$raw" | delta --paging=never --keep-plus-minus-markers \
      --hunk-header-style='line-number' --hunk-header-decoration-style=omit \
      --width="$width") || rendered="$raw"
  else
    rendered="$raw"
  fi

  # Page through less when interactive; otherwise dump everything.
  if [[ -t 1 ]] && command -v less &>/dev/null; then
    printf '%s\n' "$rendered" | less -R
  else
    printf '%s\n' "$rendered"
  fi
}

# Print a prominent header line for the file currently being prompted.
# Bold filename between two ═ separator lines, sized to terminal width.
# Args: rel_path.
sync_common::print_file_header() {
  local rel_path="$1"

  local width
  width=$(sync_common::ui_width)

  local equals
  printf -v equals '%*s' "$width" ''
  equals=${equals// /═}

  echo ""
  echo "$equals"
  printf '  \e[1mFile: %s\e[0m\n' "$rel_path"
  echo "$equals"
}

# Show diff between two files.
# Args: src, dst.
# Sets: DIFF_RESULT (0=same, 1=different, 2=error).
sync_common::show_diff() {
  local src="$1"
  local dst="$2"

  DIFF_RESULT=0

  if [[ ! -f "$src" ]]; then
    echo "  Source file not found: $src"
    DIFF_RESULT=2
    return 2
  fi

  if [[ ! -f "$dst" ]]; then
    echo "  Destination file not found: $dst"
    DIFF_RESULT=2
    return 2
  fi

  if cmp -s "$src" "$dst"; then
    DIFF_RESULT=0
    return 0
  fi

  DIFF_RESULT=1
  return 1
}

# Interactive prompt for sync decision.
# Args: rel_path, [src], [dst].
# Sets: PROMPT_ACTION (a=all HOME→repo, h=hunks HOME→repo, p=all repo→HOME,
#   H=hunks repo→HOME, s=skip, q=quit). The (d)iff action is handled inline
#   (full diff in a pager) and never surfaces as a PROMPT_ACTION.
sync_common::interactive_prompt() {
  local rel_path="$1"
  local src="${2:-}"
  local dst="${3:-}"

  PROMPT_ACTION=""

  while [[ -z "$PROMPT_ACTION" ]]; do
    sync_common::print_file_header "$rel_path"

    # Show diff/preview box.
    if [[ -n "$src" && -n "$dst" ]]; then
      if [[ ! -f "$src" && -f "$dst" ]]; then
        echo "  (only in repo — not yet in HOME)"
        sync_common::print_diff_box "$src" "$dst"
      elif [[ ! -f "$dst" && -f "$src" ]]; then
        echo "  (new file — not yet in repo)"
        sync_common::print_diff_box "$src" "$dst"
      elif [[ -f "$src" && -f "$dst" ]]; then
        if ! cmp -s "$src" "$dst"; then
          sync_common::print_diff_box "$src" "$dst"
        else
          echo "  (identical — no changes to sync)"
        fi
      fi
    fi

    echo ""
    echo "Actions:"
    echo "  (a) HOME → repo   - Copy all HOME → repo"
    echo "  (h) HOME → repo   - Pick hunks HOME → repo (writes repo only)"
    echo "  (p) repo → HOME   - Copy all repo → HOME"
    echo "  (H) repo → HOME   - Pick hunks repo → HOME (writes HOME only)"
    echo "  (s) skip          - Keep both versions unchanged"
    echo "  (d) diff          - Show full diff in pager"
    echo "  (q) quit          - Stop sync process"
    echo ""
    read -rp "Choose action [a/h/p/H/s/d/q]: " choice < /dev/tty || choice=""

    # Trim leading/trailing whitespace
    choice="$(echo "$choice" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

    # h and H select opposite directions, so they must NOT be case-folded.
    # a/p/s/d/q accept either case for convenience.
    case "$choice" in
      a|A)
        echo "  → Accepted: a (copy all HOME → repo)"
        PROMPT_ACTION="a"
        ;;
      p|P)
        echo "  → Accepted: p (copy all repo → HOME)"
        PROMPT_ACTION="p"
        ;;
      h)
        echo "  → Accepted: h (pick hunks HOME → repo)"
        PROMPT_ACTION="h"
        ;;
      H)
        echo "  → Accepted: H (pick hunks repo → HOME)"
        PROMPT_ACTION="H"
        ;;
      s|S)
        echo "  → Accepted: s (skip)"
        PROMPT_ACTION="s"
        ;;
      d|D)
        # Show the complete diff in a pager, then re-render the prompt.
        sync_common::show_full_diff "$src" "$dst"
        ;;
      q|Q)
        echo "  → Accepted: q (quit)"
        PROMPT_ACTION="q"
        ;;
      "")
        echo "  → No input available. Quitting sync."
        PROMPT_ACTION="q"
        ;;
      *)
        echo "  Invalid choice. Please enter a, h, p, H, s, d, or q."
        ;;
    esac
  done
}

# Selective hunk-level sync in ONE direction, borrowing git's interactive
# hunk staging (git add -p) inside a throwaway repo. Only `to` is ever
# written — the other side is left untouched, so the two versions are NOT
# forced to become identical: content that exists only in `to` survives any
# hunk you decline. Mechanism:
#   1. commit the `to` version as the baseline (HEAD) of a temp repo
#   2. overwrite the working tree with the `from` version
#   3. `git add -p` lets the user stage hunks one by one
#      (y=take this hunk, n=leave it, s=split, e=edit by hand, q=quit)
#   4. the staged index == baseline + selected hunks == the merged result
#   5. write that result back to `to`
# The temp repo has global/system git config isolated for predictable output.
# Args: from (pull hunks from), to (only file written), rel_path (label).
# Returns 0 if `to` was updated, 1 if aborted / nothing selected.
sync_common::hunk_merge() {
  local from="$1"
  local to="$2"
  local rel_path="$3"

  if [[ ! -f "$from" || ! -f "$to" ]]; then
    echo "  → Cannot hunk-merge: both sides must exist as files"
    return 1
  fi

  local tmpdir
  tmpdir=$(mktemp -d) || { echo "  → hunk-merge: mktemp failed"; return 1; }

  # Keep the real filename (with extension) so git picks syntax highlighting
  # and shows a meaningful path in the add -p prompt.
  local name
  name=$(basename "$rel_path")
  local work="$tmpdir/$name"

  # Isolate from user/global/system git config for predictable behaviour.
  local -a git=(env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
    GIT_TERMINAL_PROMPT=0 git -C "$tmpdir")

  "${git[@]}" init -q
  "${git[@]}" config core.autocrlf false
  "${git[@]}" config user.email sync@local
  "${git[@]}" config user.name sync

  # Commit `to` as the baseline, then overlay `from` in the working tree.
  cp "$to" "$work"
  "${git[@]}" add -- "$name"
  "${git[@]}" commit -q --no-verify -m base
  cp "$from" "$work"

  if "${git[@]}" diff --quiet -- "$name"; then
    echo "  → No differences to merge"
    rm -rf "$tmpdir"
    return 1
  fi

  echo "  → git add -p:  y=take hunk  n=leave  s=split  e=edit  q=quit  (?=help)"
  echo "     '+' lines are the incoming content written into $rel_path on 'y'"
  # Interactive hunk staging against the terminal.
  "${git[@]}" add -p -- "$name" < /dev/tty > /dev/tty 2>&1 || true

  # The staged index now holds baseline + selected hunks = merged result.
  local merged="$tmpdir/.merged"
  if ! "${git[@]}" show ":$name" > "$merged" 2>/dev/null; then
    echo "  → Could not read merged result — nothing written"
    rm -rf "$tmpdir"
    return 1
  fi

  if cmp -s "$merged" "$to"; then
    echo "  → No hunks selected — $rel_path left unchanged"
    rm -rf "$tmpdir"
    return 1
  fi

  cp "$merged" "$to"
  echo "  → Wrote selected hunks to: $to (other side untouched)"
  rm -rf "$tmpdir"
  return 0
}

# Sync a single file (HOME <-> repo, direction chosen interactively).
# Args: src, dst, [rel_path].
# Returns 0 on accept/push/skip, exits 130 on quit.
sync_common::sync_file() {
  local src="$1"
  local dst="$2"
  local rel_path="${3:-$(basename "$src")}"

  if [[ ! -f "$src" && ! -f "$dst" ]]; then
    return 0
  fi

  if [[ $INTERACTIVE -eq 1 ]]; then
    local only_in_home=0
    local only_in_repo=0
    if [[ ! -f "$dst" ]]; then
      only_in_home=1
    elif [[ ! -f "$src" ]]; then
      only_in_repo=1
    else
      sync_common::show_diff "$src" "$dst" || true
    fi

    while true; do
      sync_common::interactive_prompt "$rel_path" "$src" "$dst"

      case "$PROMPT_ACTION" in
        a)
          if [[ $only_in_repo -eq 1 ]]; then
            echo "  → Cannot copy HOME → repo: HOME version doesn't exist"
            continue
          fi
          mkdir -p "$(dirname "$dst")"
          cp -v "$src" "$dst"
          return 0
          ;;
        p)
          if [[ $only_in_home -eq 1 ]]; then
            echo "  → Cannot push to HOME: repo version doesn't exist yet"
            continue
          fi
          mkdir -p "$(dirname "$src")"
          cp -v "$dst" "$src"
          return 0
          ;;
        h)
          if [[ $only_in_home -eq 1 || $only_in_repo -eq 1 ]]; then
            echo "  → Cannot hunk-merge: file exists on only one side — use (a)/(p)/(s)"
            continue
          fi
          # Pick hunks HOME → repo; only the repo side is written.
          if sync_common::hunk_merge "$src" "$dst" "$rel_path"; then
            return 0
          fi
          # Nothing written — re-prompt so the user can pick another action.
          continue
          ;;
        H)
          if [[ $only_in_home -eq 1 || $only_in_repo -eq 1 ]]; then
            echo "  → Cannot hunk-merge: file exists on only one side — use (a)/(p)/(s)"
            continue
          fi
          # Pick hunks repo → HOME; only the HOME side is written.
          if sync_common::hunk_merge "$dst" "$src" "$rel_path"; then
            return 0
          fi
          # Nothing written — re-prompt so the user can pick another action.
          continue
          ;;
        s)
          if [[ $only_in_home -eq 1 ]]; then
            echo "  → Skipping — new file left as-is in repo"
          elif [[ $only_in_repo -eq 1 ]]; then
            echo "  → Skipping — repo file not copied to HOME"
          else
            echo "  → Skipping — keeping both HOME and repo versions unchanged"
          fi
          return 0
          ;;
        q)
          echo "Sync interrupted by user"
          exit 130
          ;;
      esac
    done
  else
    if [[ -f "$src" ]]; then
      mkdir -p "$(dirname "$dst")"
      cp -v "$src" "$dst"
    fi
  fi

  return 0
}

# True when rel_path is covered by one of the given exclude patterns.
# A pattern matches when it equals the relative path, is a parent directory
# of it ("cloudflare" excludes "cloudflare/references/x.md"), or matches it
# as a glob ("cloudflare-*").
# Args: rel_path, [pattern...].
sync_common::path_excluded() {
  local rel_path="$1"
  shift

  local pattern
  for pattern in "$@"; do
    [[ -z "$pattern" ]] && continue
    # shellcheck disable=SC2053  # unquoted RHS is intentional (glob match)
    if [[ "$rel_path" == "$pattern" || "$rel_path" == "$pattern"/* || "$rel_path" == $pattern ]]; then
      return 0
    fi
  done

  return 1
}

# Sync files matching a glob pattern in a directory tree (recursive).
# Args: src_dir, dst_dir, [pattern (default: *.md)], [exclude...].
# Each matching file is prompted individually via sync_file.
# Excludes: node_modules/ trees, *.lock files, and any relative path covered
# by an `exclude` argument (see path_excluded for the matching rules).
sync_common::sync_directory() {
  local src_dir="$1"
  local dst_dir="$2"
  local pattern="${3:-*.md}"
  local -a excludes=()
  if [[ $# -gt 3 ]]; then
    excludes=("${@:4}")
  fi

  if [[ ! -d "$src_dir" && ! -d "$dst_dir" ]]; then
    echo "Warning: neither $src_dir nor $dst_dir exists — run the sync script after deploying first." >&2
    return 1
  fi

  mkdir -p "$dst_dir"

  # Walk both sides and take the union of relative paths, so files that
  # exist only in repo (or only in HOME) are both surfaced for sync.
  local -a rel_paths=()
  if [[ -d "$src_dir" ]]; then
    while IFS= read -r -d '' src_file; do
      rel_paths+=("${src_file#$src_dir/}")
    done < <(find "$src_dir" \
      \( -name 'node_modules' -o -name '.git' \) -prune -o \
      -type f -name "$pattern" ! -name '*.lock' -print0 \
      2>/dev/null)
  fi
  if [[ -d "$dst_dir" ]]; then
    while IFS= read -r -d '' dst_file; do
      rel_paths+=("${dst_file#$dst_dir/}")
    done < <(find "$dst_dir" \
      \( -name 'node_modules' -o -name '.git' \) -prune -o \
      -type f -name "$pattern" ! -name '*.lock' -print0 \
      2>/dev/null)
  fi

  if [[ ${#rel_paths[@]} -eq 0 ]]; then
    return 0
  fi

  local excluded_count=0
  while IFS= read -r rel_path; do
    [[ -z "$rel_path" ]] && continue
    if sync_common::path_excluded "$rel_path" ${excludes[@]+"${excludes[@]}"}; then
      excluded_count=$((excluded_count + 1))
      continue
    fi
    sync_common::sync_file "$src_dir/$rel_path" "$dst_dir/$rel_path" "$rel_path" || true
  done < <(printf '%s\n' "${rel_paths[@]}" | sort -u)

  if [[ $excluded_count -gt 0 ]]; then
    echo "Excluded $excluded_count file(s) under $(basename "$src_dir")/ (patterns: ${excludes[*]})"
  fi
}
