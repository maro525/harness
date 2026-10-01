"""Command line entry point: `python -m taskboard <folder> [...]`."""

from __future__ import annotations

import argparse
import sys
import webbrowser

from .model import PHASE_ORDER
from .scanner import Scanner
from .server import DEFAULT_POLL_SECONDS, run

DEFAULT_PORT = 8787


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
        nargs="+",
        metavar="FOLDER",
        help="Folder(s) holding task-*.md files, e.g. .claude/docs/decisions",
    )
    parser.add_argument(
        "-r",
        "--recursive",
        action="store_true",
        help=(
            "Treat each FOLDER as a tree to search for .claude/docs/decisions "
            "directories instead of a task folder itself."
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
    return 0


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    folders = tuple(args.folders)

    if args.print_only:
        return print_summary(folders, args.recursive)

    if args.open:
        webbrowser.open(f"http://{args.host}:{args.port}")
    run(
        roots=folders,
        host=args.host,
        port=args.port,
        recursive=args.recursive,
        poll_seconds=args.poll,
        verbose=args.verbose,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
