"""Folder scanning and change detection.

No filesystem watcher, on purpose. Measured on a real 1,449-file corpus:

    os.scandir + stat over every file      6.5 ms
    reading and parsing all 11 MB           55 ms
    pruned os.walk of a whole source tree  133 ms
    naive rglob of the same tree         8,400 ms

At 6.5 ms a stat sweep costs well under 1% of a core at 1 Hz, so polling is
cheap enough that a watcher buys nothing -- and a watcher would cost something
real: on WSL2, inotify never fires for files on Windows-mounted drvfs paths
(`/mnt/c/...`, microsoft/WSL#4739, open since 2019), and watchdog only falls
back to polling when the observer fails to *initialize*. On drvfs inotify
initializes fine and simply stays silent, so a watcher-based board would stop
updating with no error at all. Stat polling behaves identically on every
filesystem.

The naive-rglob number is the other half of the lesson: directory traversal,
not parsing, is what makes this slow. Scanning targets the folders it is given
and prunes aggressively when asked to discover.
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass, field
from typing import ClassVar

from .model import Board, Card
from .parser import parse_file
from .phases import classify

TASK_PREFIX = "task-"
TASK_SUFFIX = ".md"

#: Directories never worth descending into when discovering task folders.
#: Skipping these is the difference between 133 ms and 8.4 s.
PRUNE_DIRS: frozenset[str] = frozenset(
    {
        ".git",
        "node_modules",
        ".venv",
        "venv",
        "__pycache__",
        "dist",
        "build",
        ".next",
        ".nuxt",
        ".cache",
        "target",
        "vendor",
        ".mypy_cache",
        ".pytest_cache",
        ".ruff_cache",
        "worktrees",
    }
)

#: The conventional location of TASK_FILEs inside a project.
DECISIONS_SUFFIX = os.path.join(".claude", "docs", "decisions")

#: Cache key: a file is unchanged when both mtime and size are unchanged.
_CacheKey = tuple[int, int]


def discover_decision_dirs(root: str, max_depth: int = 8) -> list[str]:
    """Find `.claude/docs/decisions` folders beneath `root`, pruning as it goes.

    `worktrees` is pruned along with the usual build/vcs noise: git worktrees
    duplicate an entire decisions folder, which would otherwise show every card
    several times over.
    """
    found: list[str] = []
    root = os.path.abspath(root)
    root_depth = root.rstrip(os.sep).count(os.sep)

    for dirpath, dirnames, _ in os.walk(root, followlinks=False):
        if dirpath.count(os.sep) - root_depth >= max_depth:
            dirnames.clear()
            continue
        dirnames[:] = [
            d
            for d in dirnames
            # `.claude` is the one dotted directory worth entering.
            if d not in PRUNE_DIRS and (not d.startswith(".") or d == ".claude")
        ]
        if dirpath.endswith(DECISIONS_SUFFIX):
            found.append(dirpath)
            # Nothing useful nests below a decisions folder.
            dirnames.clear()
    return sorted(found)


def list_task_files(folder: str) -> list[tuple[str, _CacheKey]]:
    """Return (path, cache_key) for each TASK_FILE directly inside `folder`."""
    entries: list[tuple[str, _CacheKey]] = []
    try:
        with os.scandir(folder) as iterator:
            for entry in iterator:
                if not entry.name.startswith(TASK_PREFIX):
                    continue
                if not entry.name.endswith(TASK_SUFFIX):
                    continue
                try:
                    stat = entry.stat()
                except OSError:
                    continue
                if not entry.is_file():
                    continue
                entries.append((entry.path, (stat.st_mtime_ns, stat.st_size)))
    except OSError:
        return []
    return entries


@dataclass(slots=True)
class Scanner:
    """Scans a set of folders, reparsing only the files that changed."""

    #: How long a discovered folder list stays valid, in seconds. Re-walking a
    #: whole tree on every poll would defeat the point. ClassVar, not a field:
    #: a bare annotation here would make it a constructor argument and a slot.
    FOLDER_TTL: ClassVar[float] = 30.0

    roots: tuple[str, ...]
    recursive: bool = False
    _cache: dict[str, tuple[_CacheKey, Card]] = field(default_factory=dict)
    _folders: tuple[str, ...] = ()
    _folders_resolved_at: float = 0.0

    def folders(self, now: float | None = None) -> tuple[str, ...]:
        """Resolve roots to concrete task folders, memoized for FOLDER_TTL."""
        now = time.time() if now is None else now
        if self._folders and now - self._folders_resolved_at < self.FOLDER_TTL:
            return self._folders

        resolved: list[str] = []
        for root in self.roots:
            root = os.path.abspath(os.path.expanduser(root))
            if not os.path.isdir(root):
                continue
            if self.recursive:
                resolved.extend(discover_decision_dirs(root))
                # A root that is itself a task folder still counts.
                if list_task_files(root) and root not in resolved:
                    resolved.append(root)
            else:
                resolved.append(root)

        self._folders = tuple(dict.fromkeys(resolved))
        self._folders_resolved_at = now
        return self._folders

    def fingerprint(self) -> tuple[int, int]:
        """A cheap signature of the current on-disk state.

        Changes whenever any task file is added, removed, resized or touched.
        This is the ~6.5 ms stat sweep that drives change detection.
        """
        count = 0
        digest = 0
        for folder in self.folders():
            for path, key in list_task_files(folder):
                count += 1
                digest ^= hash((path, key))
        return count, digest

    def scan(self) -> Board:
        """Produce a fresh Board, reparsing only files whose mtime/size moved."""
        started = time.perf_counter()
        cards: list[Card] = []
        seen: set[str] = set()
        errors: list[str] = []
        folders = self.folders()

        if not folders:
            errors.append("No task folders found. Check the paths you passed.")

        for folder in folders:
            for path, key in list_task_files(folder):
                seen.add(path)
                cached = self._cache.get(path)
                if cached is not None and cached[0] == key:
                    cards.append(cached[1])
                    continue
                mtime_ns, size = key
                card = classify(parse_file(path, mtime_ns / 1e9, size))
                self._cache[path] = (key, card)
                cards.append(card)

        for stale_path in self._cache.keys() - seen:
            del self._cache[stale_path]

        cards.sort(key=lambda c: (-c.task.mtime, c.task.task_id))
        elapsed_ms = (time.perf_counter() - started) * 1000
        return Board(
            cards=tuple(cards),
            roots=folders,
            scanned_at=time.time(),
            scan_ms=elapsed_ms,
            errors=tuple(errors),
        )
