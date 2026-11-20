"""Readers for the harness's own records (never the agents' conversation logs).

The harness leaves a trail of small files as it delegates work:

  herdr-agents/{name}.json   one per session started by herdr-agent.sh
  herdr-consult/{name}.json  one per consult session (carries `model`)
  inbox/<boss>/*.md          unread reports and questions; `done/` is read
  locks/*.lock               `key=value` task locks (`*.lock.guard` is empty)
  herdr-worktrees/*.json     one per worktree handed to an agent
  task-*.md.ai.log           TSV, one line per successful `phase-run.sh` phase

Other agents write these continuously, so every reader here tolerates a file
that is half-written, truncated or gone: nothing raises. A file that cannot be
parsed is skipped and counted; a directory that cannot be listed is reported
per source, so "unreadable" never looks like "empty".

Like the task scanner, each file is reparsed only when its (mtime_ns, size)
moves, and a cheap stat-only fingerprint drives change detection.
"""

from __future__ import annotations

import json
import os
import re
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from typing import Any, TypeVar

#: Characters of inbox body kept for the preview.
PREVIEW_CHARS = 300
#: Read (`done/`) inbox items kept per boss, newest first.
DONE_PER_BOSS = 50
#: Header lines read from the top of an inbox file.
INBOX_HEADER_KEYS: frozenset[str] = frozenset({"from", "to", "at", "kind"})
#: Bytes read from an inbox file: headers plus a preview, never the whole report.
INBOX_READ_BYTES = 4096

#: Granularity, in seconds, at which lock heartbeats are reported.
HEARTBEAT_BUCKET = 60

#: `<from>-<YYYYmmdd-HHMMSS>[-N][.<kind>].md`. `from` may itself hold hyphens.
_INBOX_NAME = re.compile(
    r"^(?P<sender>.+)-(?P<stamp>\d{8}-\d{6})(?:-(?P<seq>\d+))?(?:\.(?P<kind>[a-z]+))?\.md$"
)
_TTL = re.compile(r"^\s*(?P<n>\d+)\s*(?P<unit>[smhd]?)\s*$")
_TTL_UNITS = {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}

_CacheKey = tuple[int, int]
_Listing = tuple[list[tuple[str, _CacheKey]], str | None]
T = TypeVar("T")


# -- paths -----------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class HarnessPaths:
    """Where the harness keeps its records. Tests pass their own."""

    agents: str
    consult: str
    inbox: str
    locks: str
    worktrees: str

    @classmethod
    def default(cls, env: dict[str, str] | None = None) -> HarnessPaths:
        """Resolve the locations the shell scripts use (same env variables)."""
        env = dict(os.environ) if env is None else env
        home = env.get("HOME") or os.path.expanduser("~")
        cache = env.get("XDG_CACHE_HOME") or os.path.join(home, ".cache")
        data = env.get("XDG_DATA_HOME") or os.path.join(home, ".local", "share")
        harness_cache = os.path.join(cache, "harness")
        return cls(
            agents=os.path.join(harness_cache, "herdr-agents"),
            consult=os.path.join(harness_cache, "herdr-consult"),
            inbox=os.path.join(harness_cache, "inbox"),
            locks=env.get("HARNESS_LOCKS_DIR") or os.path.join(data, "harness", "locks"),
            worktrees=os.path.join(harness_cache, "herdr-worktrees"),
        )


# -- records ---------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class AgentRecord:
    """One `herdr-agents/*.json` or `herdr-consult/*.json` file."""

    name: str
    source: str  # "agent" | "consult"
    path: str
    pane: str | None
    tab: str | None
    kind: str | None
    model: str | None
    repo: str | None
    created: str | None
    owner: str | None
    owner_pane: str | None
    boss: str | None
    #: Every scalar field of the file, for the detail panel.
    fields: dict[str, str]

    def to_json(self) -> dict[str, object]:
        return {
            "name": self.name,
            "source": self.source,
            "path": self.path,
            "pane": self.pane,
            "kind": self.kind,
            "model": self.model,
            "repo": self.repo,
            "created": self.created,
            "owner": self.owner,
            "boss": self.boss,
            "fields": self.fields,
        }


@dataclass(frozen=True, slots=True)
class InboxItem:
    """One message in `inbox/<boss>/` (unread) or `inbox/<boss>/done/` (read)."""

    boss_dir: str
    sender: str
    to: str | None
    at: str | None
    kind: str
    stamp: str
    path: str
    read: bool
    preview: str

    def to_json(self) -> dict[str, object]:
        return {
            "bossDir": self.boss_dir,
            "from": self.sender,
            "to": self.to,
            "at": self.at,
            "kind": self.kind,
            "stamp": self.stamp,
            "path": self.path,
            "read": self.read,
            "preview": self.preview,
        }


@dataclass(frozen=True, slots=True)
class LockInfo:
    """One `locks/*.lock` file. Expiry is judged by the client (`updated + ttl`)."""

    key: str
    path: str
    runner: str | None
    owner: str | None
    pid: str | None
    cwd: str | None
    task_file: str | None
    started: str | None
    updated_epoch: int | None
    ttl_seconds: int | None

    def to_json(self) -> dict[str, object]:
        return {
            "key": self.key,
            "path": self.path,
            "runner": self.runner,
            "owner": self.owner,
            "pid": self.pid,
            "cwd": self.cwd,
            "taskFile": self.task_file,
            "started": self.started,
            # Holders heartbeat `updated_epoch` every few seconds. Rounding to
            # the minute keeps that from bumping the activity version each
            # poll; expiry is a 45-minute judgement, so a minute is noise.
            "updatedEpoch": (
                self.updated_epoch // HEARTBEAT_BUCKET * HEARTBEAT_BUCKET
                if self.updated_epoch is not None
                else None
            ),
            "ttlSeconds": self.ttl_seconds,
        }


@dataclass(frozen=True, slots=True)
class WorktreeInfo:
    """One `herdr-worktrees/*.json` file."""

    path: str
    branch: str | None
    owner: str | None
    agent: str | None
    created: str | None
    record_path: str

    def to_json(self) -> dict[str, object]:
        return {
            "path": self.path,
            "branch": self.branch,
            "owner": self.owner,
            "agent": self.agent,
            "created": self.created,
            "recordPath": self.record_path,
        }


@dataclass(frozen=True, slots=True)
class PhaseRun:
    """One line of `task-*.md.ai.log`."""

    task_path: str
    at: str
    phase: str | None
    label: str | None
    runner: str | None
    model: str | None

    def to_json(self) -> dict[str, object]:
        return {
            "taskPath": self.task_path,
            "at": self.at,
            "phase": self.phase,
            "label": self.label,
            "runner": self.runner,
            "model": self.model,
        }


@dataclass(frozen=True, slots=True)
class SourceStatus:
    """Health of one source: an unlistable directory is not "0 items"."""

    ok: bool
    count: int
    skipped: int = 0
    error: str | None = None

    def to_json(self) -> dict[str, object]:
        return {"ok": self.ok, "count": self.count, "skipped": self.skipped, "error": self.error}


@dataclass(frozen=True, slots=True)
class HarnessSnapshot:
    agents: tuple[AgentRecord, ...]
    consults: tuple[AgentRecord, ...]
    inbox: tuple[InboxItem, ...]
    locks: tuple[LockInfo, ...]
    worktrees: tuple[WorktreeInfo, ...]
    phase_runs: tuple[PhaseRun, ...]
    sources: dict[str, SourceStatus]


# -- parsers (pure, never raise) ------------------------------------------


def _read_text(path: str, limit: int | None = None) -> str | None:
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            return handle.read() if limit is None else handle.read(limit)
    except OSError:
        return None


def _str(value: Any) -> str | None:
    if value is None or isinstance(value, (dict, list)):
        return None
    text = str(value).strip()
    return text or None


def parse_agent_record(path: str, source: str) -> AgentRecord | None:
    """Parse a herdr-agents / herdr-consult JSON file; None when unusable."""
    text = _read_text(path)
    if text is None:
        return None
    try:
        document = json.loads(text)
    except ValueError:
        return None
    if not isinstance(document, dict):
        return None
    name = _str(document.get("agent")) or os.path.basename(path).removesuffix(".json")
    fields = {
        key: str(value)
        for key, value in document.items()
        if isinstance(key, str) and not isinstance(value, (dict, list)) and value is not None
    }
    return AgentRecord(
        name=name,
        source=source,
        path=path,
        pane=_str(document.get("pane")),
        tab=_str(document.get("tab")),
        kind=_str(document.get("kind")) or _str(document.get("target")),
        model=_str(document.get("model")),
        repo=_str(document.get("repo")) or _str(document.get("cwd")),
        created=_str(document.get("created")),
        owner=_str(document.get("owner")),
        owner_pane=_str(document.get("owner_pane")),
        boss=_str(document.get("boss")),
        fields=fields,
    )


def parse_inbox_file(path: str, boss_dir: str, read: bool) -> InboxItem | None:
    """Parse an inbox file name and its `key: value` header; None for foreign files."""
    match = _INBOX_NAME.match(os.path.basename(path))
    if match is None:
        return None
    text = _read_text(path, INBOX_READ_BYTES) or ""
    headers: dict[str, str] = {}
    lines = text.splitlines()
    body_start = 0
    for index, line in enumerate(lines):
        key, sep, value = line.partition(":")
        key = key.strip().lower()
        if not sep or key not in INBOX_HEADER_KEYS:
            body_start = index
            break
        headers[key] = value.strip()
    else:
        body_start = len(lines)
    body = " ".join(" ".join(lines[body_start:]).split())
    return InboxItem(
        boss_dir=boss_dir,
        sender=headers.get("from") or match["sender"],
        to=headers.get("to") or None,
        at=headers.get("at") or None,
        kind=headers.get("kind") or match["kind"] or "report",
        stamp=match["stamp"] + (f"-{match['seq']}" if match["seq"] else ""),
        path=path,
        read=read,
        preview=body[:PREVIEW_CHARS],
    )


def parse_ttl(value: str | None) -> int | None:
    """`45m` / `90s` / `2h` / `1d` / `600` -> seconds; None when unparsable."""
    if not value:
        return None
    match = _TTL.match(value)
    if match is None:
        return None
    return int(match["n"]) * _TTL_UNITS[match["unit"]]


def parse_lock_file(path: str) -> LockInfo | None:
    text = _read_text(path, INBOX_READ_BYTES)
    if text is None:
        return None
    values: dict[str, str] = {}
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep:
            values[key.strip()] = value.strip()
    if not values:
        return None
    try:
        updated = int(values["updated_epoch"]) if values.get("updated_epoch") else None
    except ValueError:
        updated = None
    return LockInfo(
        key=values.get("key") or os.path.basename(path).removesuffix(".lock"),
        path=path,
        runner=values.get("runner") or None,
        owner=values.get("owner") or None,
        pid=values.get("pid") or None,
        cwd=values.get("cwd") or None,
        task_file=values.get("task_file") or None,
        started=values.get("started") or None,
        updated_epoch=updated,
        ttl_seconds=parse_ttl(values.get("ttl")),
    )


def parse_worktree_file(path: str) -> WorktreeInfo | None:
    text = _read_text(path)
    if text is None:
        return None
    try:
        document = json.loads(text)
    except ValueError:
        return None
    if not isinstance(document, dict) or not _str(document.get("path")):
        return None
    return WorktreeInfo(
        path=str(document["path"]),
        branch=_str(document.get("branch")),
        owner=_str(document.get("owner")),
        agent=_str(document.get("agent")),
        created=_str(document.get("created")),
        record_path=path,
    )


def parse_ai_log(path: str, task_path: str) -> tuple[PhaseRun, ...]:
    """Each `{iso}\\tphase=…\\tlabel=…\\trunner=…\\tmodel=…` line; others are skipped."""
    text = _read_text(path)
    if not text:
        return ()
    runs: list[PhaseRun] = []
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) < 2 or not parts[0].strip():
            continue
        values = dict(part.partition("=")[::2] for part in parts[1:] if "=" in part)
        runs.append(
            PhaseRun(
                task_path=task_path,
                at=parts[0].strip(),
                phase=values.get("phase") or None,
                label=values.get("label") or None,
                runner=values.get("runner") or None,
                model=values.get("model") or None,
            )
        )
    return tuple(runs)


# -- listing ---------------------------------------------------------------


def _list(folder: str, accept: Callable[[str], bool]) -> _Listing:
    """(path, key) for each accepted regular file in `folder`, plus a listing error.

    A missing folder is not an error: most sources are absent until first used.
    """
    entries: list[tuple[str, _CacheKey]] = []
    try:
        with os.scandir(folder) as iterator:
            for entry in iterator:
                if not accept(entry.name):
                    continue
                try:
                    if not entry.is_file():
                        continue
                    stat = entry.stat()
                except OSError:
                    continue
                entries.append((entry.path, (stat.st_mtime_ns, stat.st_size)))
    except FileNotFoundError:
        return [], None
    except OSError as exc:
        return [], f"{type(exc).__name__}: {folder}"
    return entries, None


def _subdirs(folder: str) -> tuple[list[str], str | None]:
    try:
        with os.scandir(folder) as iterator:
            names = [
                e.name
                for e in iterator
                if not e.name.startswith(".") and e.is_dir(follow_symlinks=False)
            ]
    except FileNotFoundError:
        return [], None
    except OSError as exc:
        return [], f"{type(exc).__name__}: {folder}"
    return sorted(names), None


def _is_json(name: str) -> bool:
    return name.endswith(".json") and not name.startswith(".")


def _is_lock(name: str) -> bool:
    return name.endswith(".lock") and not name.startswith(".")


def _inbox_order(path: str) -> tuple[str, int, str]:
    """Sort key by (stamp, seq); names the reader would skip sort oldest."""
    name = os.path.basename(path)
    match = _INBOX_NAME.match(name)
    if match is None:
        return ("", 0, name)
    return (match["stamp"], int(match["seq"] or 0), name)


def _is_inbox(name: str) -> bool:
    # `.tmp.*` files are the writers' atomic-rename staging; `.watch` is a dir.
    return name.endswith(".md") and not name.startswith(".")


# -- scanner ---------------------------------------------------------------


@dataclass(slots=True)
class HarnessScanner:
    """Reads every source, reparsing only files whose (mtime_ns, size) moved."""

    paths: HarnessPaths
    _cache: dict[str, tuple[_CacheKey, Any]] = field(default_factory=dict)

    def _inbox_listing(self) -> tuple[list[tuple[str, str, bool, _CacheKey]], str | None]:
        """(boss_dir, path, read, key) for unread and the newest read items."""
        bosses, error = _subdirs(self.paths.inbox)
        errors = [error] if error else []
        found: list[tuple[str, str, bool, _CacheKey]] = []
        for boss in bosses:
            unread, unread_error = _list(os.path.join(self.paths.inbox, boss), _is_inbox)
            found.extend((boss, path, False, key) for path, key in unread)
            done, done_error = _list(os.path.join(self.paths.inbox, boss, "done"), _is_inbox)
            errors.extend(e for e in (unread_error, done_error) if e)
            # Names start with the sender, so sort on the embedded stamp instead.
            done.sort(key=lambda item: _inbox_order(item[0]), reverse=True)
            found.extend((boss, path, True, key) for path, key in done[:DONE_PER_BOSS])
        # A boss folder that cannot be listed must not look like "0 items, ok".
        return found, "; ".join(errors) or None

    def _listings(self, task_paths: Iterable[str]) -> dict[str, Any]:
        agents = _list(self.paths.agents, _is_json)
        consults = _list(self.paths.consult, _is_json)
        locks = _list(self.paths.locks, _is_lock)
        worktrees = _list(self.paths.worktrees, _is_json)
        logs: list[tuple[str, str, _CacheKey]] = []
        for task_path in task_paths:
            log_path = task_path + ".ai.log"
            try:
                stat = os.stat(log_path)
            except OSError:
                continue
            logs.append((task_path, log_path, (stat.st_mtime_ns, stat.st_size)))
        return {
            "agents": agents,
            "consult": consults,
            "inbox": self._inbox_listing(),
            "locks": locks,
            "worktrees": worktrees,
            "aiLog": (logs, None),
        }

    def fingerprint(self, task_paths: Iterable[str] = ()) -> tuple[int, int]:
        """Stat-only signature of every source; moves on any add/remove/write."""
        count = 0
        digest = 0
        for name, (entries, error) in self._listings(task_paths).items():
            digest ^= hash((name, "error", error))
            for entry in entries:
                count += 1
                digest ^= hash((name, entry))
        return count, digest

    def _parse(self, path: str, key: _CacheKey, parser: Callable[[], T]) -> T:
        cached = self._cache.get(path)
        if cached is not None and cached[0] == key:
            return cached[1]
        value = parser()
        self._cache[path] = (key, value)
        return value

    def scan(self, task_paths: Iterable[str] = ()) -> HarnessSnapshot:
        listings = self._listings(tuple(task_paths))
        seen: set[str] = set()
        sources: dict[str, SourceStatus] = {}

        def collect(name: str, items: list[tuple[str, Callable[[], Any]]], key_of) -> list[Any]:
            out: list[Any] = []
            skipped = 0
            for path, parser in items:
                seen.add(path)
                value = self._parse(path, key_of[path], parser)
                if value is None:
                    skipped += 1
                elif isinstance(value, tuple):
                    out.extend(value)
                else:
                    out.append(value)
            error = listings[name][1]
            sources[name] = SourceStatus(error is None, len(out), skipped, error)
            return out

        def simple(name: str, make: Callable[[str], Any]) -> list[Any]:
            entries = listings[name][0]
            keys = {path: key for path, key in entries}
            return collect(name, [(p, (lambda p=p: make(p))) for p, _ in entries], keys)

        agents = simple("agents", lambda p: parse_agent_record(p, "agent"))
        consults = simple("consult", lambda p: parse_agent_record(p, "consult"))
        locks = simple("locks", parse_lock_file)
        worktrees = simple("worktrees", parse_worktree_file)

        inbox_entries = listings["inbox"][0]
        inbox = collect(
            "inbox",
            [
                (path, (lambda p=path, b=boss, r=read: parse_inbox_file(p, b, r)))
                for boss, path, read, _ in inbox_entries
            ],
            {path: key for _, path, _, key in inbox_entries},
        )

        log_entries = listings["aiLog"][0]
        phase_runs = collect(
            "aiLog",
            [(log, (lambda log=log, t=task: parse_ai_log(log, t))) for task, log, _ in log_entries],
            {log: key for _, log, key in log_entries},
        )

        for stale in self._cache.keys() - seen:
            del self._cache[stale]

        return HarnessSnapshot(
            agents=tuple(sorted(agents, key=lambda r: r.name)),
            consults=tuple(sorted(consults, key=lambda r: r.name)),
            inbox=tuple(sorted(inbox, key=lambda i: (i.boss_dir, i.read, i.stamp, i.path))),
            locks=tuple(sorted(locks, key=lambda lock: lock.key)),
            worktrees=tuple(sorted(worktrees, key=lambda w: w.path)),
            phase_runs=tuple(sorted(phase_runs, key=lambda r: (r.at, r.task_path))),
            sources=sources,
        )


def safe_name(name: str) -> str:
    """Mirror of herdr-agent.sh `safe_name`: the inbox directory for an agent."""
    cleaned = re.sub(r"[^A-Za-z0-9._-]", "_", name)
    return "_" + cleaned if cleaned.startswith(".") else cleaned
