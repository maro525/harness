"""Command line entry point: `python -m taskboard <folder> [...]`."""

from __future__ import annotations

import argparse
import os
import sys
import time
import webbrowser

from .activity import build_document
from .harness import HarnessPaths, HarnessScanner
from .herdr import DEFAULT_POLL_SECONDS as DEFAULT_HERDR_POLL_SECONDS
from .herdr import DISABLED, fetch_live_agents
from .model import PHASE_ORDER, Card
from .scanner import Scanner
from .server import DEFAULT_POLL_SECONDS, HarnessOptions, run

DEFAULT_PORT = 8787


def default_tasks_root() -> str:
    """Task folders read when `--harness` is given without FOLDER."""
    data = os.environ.get("XDG_DATA_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "share"
    )
    return os.path.join(data, "harness", "tasks")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="taskboard",
        description=(
            "Serve a kanban board built from TASK_FILE markdown documents "
            "(task-{LINEAR_ID}-{feature}.md)."
        ),
    )
    parser.add_argument(
        "folders",
        nargs="*",
        metavar="FOLDER",
        help=(
            "Folder(s) holding task-*.md files. The current layout is "
            "~/.local/share/harness/tasks (one folder per repository); the "
            "legacy location is {repo}/.claude/docs/decisions. Optional with "
            "--harness, which then reads ~/.local/share/harness/tasks recursively"
        ),
    )
    parser.add_argument(
        "-r",
        "--recursive",
        action="store_true",
        help=(
            "Treat each FOLDER as a tree to search for folders holding "
            "task-*.md (both ~/.local/share/harness/tasks/<repo> and the "
            "legacy .claude/docs/decisions)"
        ),
    )
    parser.add_argument("-p", "--port", type=int, default=DEFAULT_PORT, help="Port (default 8787)")
    parser.add_argument("--host", default="127.0.0.1", help="Bind address (default 127.0.0.1)")
    parser.add_argument(
        "--poll",
        type=float,
        default=DEFAULT_POLL_SECONDS,
        metavar="SECONDS",
        help=f"Change-detection interval (default {DEFAULT_POLL_SECONDS})",
    )
    parser.add_argument("--open", action="store_true", help="Open a browser on start")
    parser.add_argument("-v", "--verbose", action="store_true", help="Log HTTP requests")
    parser.add_argument(
        "--harness",
        action="store_true",
        help=(
            "Add the Agents and Timeline views, built from the harness records "
            "(herdr sessions, inbox, locks, worktrees, ai.log). Off by default"
        ),
    )
    parser.add_argument(
        "--no-herdr",
        action="store_true",
        help="With --harness: never call `herdr agent list` (liveness shows as unknown)",
    )
    parser.add_argument(
        "--herdr-poll",
        type=float,
        default=DEFAULT_HERDR_POLL_SECONDS,
        metavar="SECONDS",
        help=f"With --harness: herdr poll interval (default {DEFAULT_HERDR_POLL_SECONDS:g})",
    )
    parser.add_argument(
        "--print",
        dest="print_only",
        action="store_true",
        help="Print a one-shot text summary and exit (no server)",
    )
    return parser


def print_summary(folders: tuple[str, ...], recursive: bool) -> int:
    board = Scanner(roots=folders, recursive=recursive).scan()
    for message in board.errors:
        print(f"warning: {message}", file=sys.stderr)
    if not board.cards:
        print("No task files found.", file=sys.stderr)
        return 1

    counts = {name: 0 for name in (*PHASE_ORDER, "unknown")}
    for card in board.cards:
        counts[card.phase] += 1

    width = max(len(name) for name in counts)
    print(f"{len(board.cards)} tasks in {len(board.roots)} folder(s), {board.scan_ms:.0f} ms\n")
    for name, count in counts.items():
        if count:
            print(f"  {name:<{width}}  {count}")
    stale = [c for c in board.cards if c.stale_status]
    if stale:
        print(f"\n  {len(stale)} task(s) have a stale `status:` field:")
        for card in stale[:10]:
            print(
                f"    {card.task.task_id:<16} status={card.task.status_raw!r} "
                f"-> evidence shows {card.evidence_phase}"
            )
        if len(stale) > 10:
            print(f"    ... and {len(stale) - 10} more")
    print_waiting(board.cards)
    return 0


def print_harness(folders: tuple[str, ...], recursive: bool, use_herdr: bool) -> None:
    """Agents, unread inbox and held locks, for `--print --harness`."""
    board = Scanner(roots=folders, recursive=recursive).scan()
    snapshot = HarnessScanner(HarnessPaths.default()).scan(c.task.path for c in board.cards)
    live = fetch_live_agents() if use_herdr else DISABLED
    document = build_document(snapshot, live, board.cards, time.time())
    counts = document["counts"]
    herdr = "ok" if live.ok else f"unavailable ({live.error})"
    print(f"\nharness  (herdr: {herdr})")
    print(f"  agents  {counts['agents']}  (live {counts['live']})")
    print(f"  unread  {counts['unread']}  (needs attention {counts['attention']})")
    print(f"  locks   {counts['locks']}")
    for source, status in document["sources"].items():
        if not status["ok"]:
            print(f"  warning : {source}: {status['error']}")


def print_waiting(cards: tuple[Card, ...]) -> None:
    """List tasks with a relayed question still waiting for an answer."""
    waiting = [(c, c.question) for c in cards if c.question is not None]
    if not waiting:
        return
    print(f"\n  {len(waiting)} task(s) are waiting for an answer:")
    for card, question in waiting:
        deadline = question.deadline or "no deadline"
        print(f"    {card.task.task_id:<16} [{question.phase}] deadline {deadline}")
        if question.summary:
            print(f"      {question.summary}")
        if question.comment_url:
            print(f"      {question.comment_url}")


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    folders = tuple(args.folders)
    recursive = args.recursive
    if not folders:
        if not args.harness:
            parser.error("FOLDER is required (or pass --harness)")
        folders = (default_tasks_root(),)
        recursive = True

    if args.print_only:
        status = print_summary(folders, recursive)
        if args.harness:
            print_harness(folders, recursive, not args.no_herdr)
            return 0
        return status

    harness = (
        HarnessOptions(herdr=not args.no_herdr, herdr_poll_seconds=args.herdr_poll)
        if args.harness
        else None
    )

    if args.open:
        webbrowser.open(f"http://{args.host}:{args.port}")
    run(
        roots=folders,
        host=args.host,
        port=args.port,
        recursive=recursive,
        poll_seconds=args.poll,
        verbose=args.verbose,
        harness=harness,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
