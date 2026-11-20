"""Join the harness records into agents and a timeline, and keep it current.

Nothing here is stored: every refresh rebuilds the activity document from the
files (see `harness.py`) and the latest `herdr agent list` (see `herdr.py`), so
a restart loses nothing and there is no state to drift.

Joining rules, in order of trust:

- An agent is keyed by name (unique on a Herdr server; records are
  `{name}.json`). When a record's `pane` disagrees with the live pane of the
  same name, the record belongs to an earlier session that reused the name: the
  live session wins and the record is kept only as `recordStale`.
- The parent is `boss`, else `owner: agent:X`, else the agent sitting in the
  pane named by `owner: pane:…` / `owner_pane`, else unknown.
- Time-dependent judgements (lock expiry, elapsed time, "ended in the last
  24h") are left to the browser, so the document -- and its ETag -- only
  changes when the records do.
"""

from __future__ import annotations

import hashlib
import json
import os
import threading
import time
from collections import Counter
from collections.abc import Iterable
from dataclasses import dataclass, replace
from datetime import datetime
from typing import Protocol

from .harness import (
    AgentRecord,
    HarnessScanner,
    HarnessSnapshot,
    InboxItem,
    LockInfo,
    WorktreeInfo,
    safe_name,
)
from .herdr import DISABLED, HerdrPoller, LiveAgent, LiveResult
from .model import Board, Card

#: Timeline window and size.
TIMELINE_SECONDS = 24 * 3600
TIMELINE_LIMIT = 500
#: Characters of an inbox preview shown on a timeline row.
TIMELINE_TEXT_CHARS = 140
#: Inbox kinds that need a human (or boss) to act.
ATTENTION_KINDS: frozenset[str] = frozenset({"question", "blocked", "stalled"})
#: Path segment under which herdr worktrees live: `…/.herdr/worktrees/<repo>/<name>`.
_WORKTREE_SEGMENT = f"{os.sep}.herdr{os.sep}worktrees{os.sep}"


# -- notification ----------------------------------------------------------


class Notifier:
    """One generation counter shared by every state, so one SSE loop wakes for all."""

    def __init__(self) -> None:
        self._condition = threading.Condition()
        self._generation = 0

    @property
    def generation(self) -> int:
        with self._condition:
            return self._generation

    def notify(self) -> None:
        with self._condition:
            self._generation += 1
            self._condition.notify_all()

    def wait_past(self, generation: int, timeout: float) -> int:
        """Block until the generation passes `generation`, or until timeout."""
        with self._condition:
            if self._generation == generation:
                self._condition.wait(timeout)
            return self._generation


# -- helpers ---------------------------------------------------------------


def parse_time(value: str | None) -> float | None:
    """ISO 8601 (with offset) -> epoch seconds; None when missing or unparsable."""
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed.timestamp()


def repo_name(path: str | None) -> str | None:
    """`…/.herdr/worktrees/<repo>/<name>` -> repo; otherwise the last segment."""
    if not path:
        return None
    normalized = os.path.normpath(path)
    if _WORKTREE_SEGMENT in normalized:
        tail = normalized.split(_WORKTREE_SEGMENT, 1)[1]
        return tail.split(os.sep, 1)[0] or None
    return os.path.basename(normalized) or None


def _owner_pane(owner: str | None) -> str | None:
    return owner[len("pane:") :] if owner and owner.startswith("pane:") else None


def _owner_agent(owner: str | None) -> str | None:
    return owner[len("agent:") :] if owner and owner.startswith("agent:") else None


# -- agents ----------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class AgentView:
    name: str
    kind: str | None
    model: str | None
    #: idle | working | done (live), ended (not in a successful list), unknown.
    status: str
    parent: str | None
    parent_via: str | None
    pane: str | None
    cwd: str | None
    created: str | None
    record: AgentRecord | None
    record_stale: bool
    unread_to: dict[str, int]
    unread_from: dict[str, int]
    lock_keys: tuple[str, ...]
    worktree_paths: tuple[str, ...]
    task_paths: tuple[str, ...]

    def to_json(self) -> dict[str, object]:
        return {
            "name": self.name,
            "kind": self.kind,
            "model": self.model,
            "status": self.status,
            "parent": self.parent,
            "parentVia": self.parent_via,
            "pane": self.pane,
            "cwd": self.cwd,
            "repo": repo_name(self.cwd),
            "created": self.created,
            "record": self.record.to_json() if self.record else None,
            "recordStale": self.record_stale,
            "unreadTo": self.unread_to,
            "unreadFrom": self.unread_from,
            "lockKeys": list(self.lock_keys),
            "worktreePaths": list(self.worktree_paths),
            "taskPaths": list(self.task_paths),
        }


def _merge_records(
    agents: Iterable[AgentRecord], consults: Iterable[AgentRecord]
) -> dict[str, AgentRecord]:
    """One record per name; a consult record fills in a missing `model`."""
    merged: dict[str, AgentRecord] = {}
    for record in (*agents, *consults):
        current = merged.get(record.name)
        if current is None:
            merged[record.name] = record
        elif current.model is None and record.model:
            fields = {**record.fields, **current.fields, "model": record.model}
            merged[record.name] = replace(current, model=record.model, fields=fields)
    return merged


def _resolve_parent(
    record: AgentRecord | None, pane_owners: dict[str, str], name: str
) -> tuple[str | None, str | None]:
    if record is None:
        return None, None
    if record.boss and record.boss != name:
        return record.boss, "boss"
    agent = _owner_agent(record.owner)
    if agent and agent != name:
        return agent, "owner"
    for pane in (_owner_pane(record.owner), record.owner_pane):
        holder = pane_owners.get(pane) if pane else None
        if holder and holder != name:
            return holder, "pane"
    return None, None


def build_agents(
    snapshot: HarnessSnapshot, live: LiveResult, cards: tuple[Card, ...]
) -> tuple[AgentView, ...]:
    records = _merge_records(snapshot.agents, snapshot.consults)
    live_by_name: dict[str, LiveAgent] = {a.name: a for a in live.agents} if live.ok else {}

    stale = {
        name
        for name, record in records.items()
        if name in live_by_name
        and record.pane
        and live_by_name[name].pane_id
        and record.pane != live_by_name[name].pane_id
    }

    # Pane -> agent sitting in it. Live sessions win over (non-stale) records.
    pane_owners: dict[str, str] = {
        r.pane: name for name, r in records.items() if r.pane and name not in stale
    }
    pane_owners.update({a.pane_id: a.name for a in live_by_name.values() if a.pane_id})

    unread_to: dict[str, Counter[str]] = {}
    unread_from: dict[str, Counter[str]] = {}
    for item in snapshot.inbox:
        if item.read:
            continue
        unread_to.setdefault(item.boss_dir, Counter())[item.kind] += 1
        unread_from.setdefault(item.sender, Counter())[item.kind] += 1

    cards_by_branch: dict[str, list[str]] = {}
    for card in cards:
        if card.task.branch:
            cards_by_branch.setdefault(card.task.branch, []).append(card.task.path)
    card_paths = {card.task.path for card in cards}
    worktrees_by_path = {os.path.normpath(w.path): w for w in snapshot.worktrees}

    views: list[AgentView] = []
    for name in sorted(records.keys() | live_by_name.keys()):
        live_agent = live_by_name.get(name)
        is_stale = name in stale
        record = records.get(name)
        used = None if is_stale else record
        parent, via = _resolve_parent(used, pane_owners, name)
        pane = live_agent.pane_id if live_agent else (used.pane if used else None)
        cwd = (used.repo if used else None) or (live_agent.cwd if live_agent else None)

        if live_agent is not None:
            status = live_agent.status or "unknown"
        elif live.ok:
            status = "ended"
        else:
            status = "unknown"

        holders = {f"agent:{name}"} | ({f"pane:{pane}"} if pane else set())
        locks = [lock.key for lock in snapshot.locks if lock.owner in holders]
        worktrees = [w for w in snapshot.worktrees if w.agent == name]
        if cwd and os.path.normpath(cwd) in worktrees_by_path:
            own = worktrees_by_path[os.path.normpath(cwd)]
            if own not in worktrees:
                worktrees.append(own)
        tasks: list[str] = []
        for worktree in worktrees:
            tasks.extend(cards_by_branch.get(worktree.branch or "", ()))
        for lock in snapshot.locks:
            if lock.key in locks and lock.task_file in card_paths:
                tasks.append(lock.task_file)
        task_paths = tuple(dict.fromkeys(tasks))

        model = used.model if used else None
        if model is None and task_paths:
            runs = [r for r in snapshot.phase_runs if r.task_path in task_paths and r.model]
            model = runs[-1].model if runs else None

        views.append(
            AgentView(
                name=name,
                kind=(live_agent.kind if live_agent else None) or (used.kind if used else None),
                model=model,
                status=status,
                parent=parent,
                parent_via=via,
                pane=pane,
                cwd=cwd,
                created=used.created if used else None,
                record=record,
                record_stale=is_stale,
                unread_to=dict(unread_to.get(safe_name(name), {})),
                unread_from=dict(unread_from.get(name, {})),
                lock_keys=tuple(locks),
                worktree_paths=tuple(w.path for w in worktrees),
                task_paths=task_paths,
            )
        )
    return tuple(views)


# -- timeline --------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class TimelineEvent:
    at: str
    epoch: float
    kind: str  # delegate | inbox | lock | worktree | phase
    sub: str | None
    agent: str | None
    boss: str | None
    repo: str | None
    text: str
    #: Detail-panel selection, `agent:NAME` or `task:PATH`.
    select: str | None

    def to_json(self) -> dict[str, object]:
        return {
            "at": self.at,
            "epoch": self.epoch,
            "kind": self.kind,
            "sub": self.sub,
            "agent": self.agent,
            "boss": self.boss,
            "repo": self.repo,
            "text": self.text,
            "select": self.select,
        }


def _lock_holder(lock: LockInfo, agents: dict[str, AgentView]) -> str | None:
    holder = _owner_agent(lock.owner)
    if holder:
        return holder
    pane = _owner_pane(lock.owner)
    return next((a.name for a in agents.values() if pane and a.pane == pane), None)


def _inbox_event(item: InboxItem) -> TimelineEvent | None:
    epoch = parse_time(item.at)
    if epoch is None or item.at is None:
        return None
    return TimelineEvent(
        at=item.at,
        epoch=epoch,
        kind="inbox",
        sub=item.kind,
        agent=item.sender,
        boss=item.to or item.boss_dir,
        repo=None,
        text=item.preview[:TIMELINE_TEXT_CHARS],
        select=f"agent:{item.sender}",
    )


def _worktree_event(worktree: WorktreeInfo) -> TimelineEvent | None:
    epoch = parse_time(worktree.created)
    if epoch is None or worktree.created is None:
        return None
    return TimelineEvent(
        at=worktree.created,
        epoch=epoch,
        kind="worktree",
        sub=None,
        agent=worktree.agent,
        boss=None,
        repo=repo_name(worktree.path),
        text=worktree.branch or worktree.path,
        select=f"agent:{worktree.agent}" if worktree.agent else None,
    )


def build_timeline(
    snapshot: HarnessSnapshot,
    agents: tuple[AgentView, ...],
    cards: tuple[Card, ...],
    now: float,
) -> tuple[TimelineEvent, ...]:
    """Events of the last 24 h, newest first, at most TIMELINE_LIMIT."""
    by_name = {a.name: a for a in agents}
    projects = {card.task.path: card for card in cards}
    events: list[TimelineEvent | None] = []

    for agent in agents:
        epoch = parse_time(agent.created)
        if epoch is None or agent.created is None:
            continue
        events.append(
            TimelineEvent(
                at=agent.created,
                epoch=epoch,
                kind="delegate",
                sub=agent.kind,
                agent=agent.name,
                boss=agent.parent,
                repo=repo_name(agent.cwd),
                text=f"{agent.parent or '?'} → {agent.name}",
                select=f"agent:{agent.name}",
            )
        )
    events.extend(_inbox_event(item) for item in snapshot.inbox)
    for lock in snapshot.locks:
        epoch = parse_time(lock.started)
        if epoch is None or lock.started is None:
            continue
        holder = _lock_holder(lock, by_name)
        events.append(
            TimelineEvent(
                at=lock.started,
                epoch=epoch,
                kind="lock",
                sub=lock.runner,
                agent=holder,
                boss=by_name[holder].parent if holder in by_name else None,
                repo=repo_name(lock.cwd),
                text=lock.key,
                select=f"agent:{holder}" if holder else None,
            )
        )
    events.extend(_worktree_event(w) for w in snapshot.worktrees)
    for run in snapshot.phase_runs:
        epoch = parse_time(run.at)
        if epoch is None:
            continue
        card = projects.get(run.task_path)
        events.append(
            TimelineEvent(
                at=run.at,
                epoch=epoch,
                kind="phase",
                sub=run.phase,
                agent=None,
                boss=None,
                repo=card.task.project if card else None,
                text=f"{card.task.task_id if card else os.path.basename(run.task_path)}"
                f" {run.phase or '?'} ← {run.label or run.model or '?'}",
                select=f"task:{run.task_path}",
            )
        )

    cutoff = now - TIMELINE_SECONDS
    kept = [e for e in events if e is not None and e.epoch >= cutoff]
    kept.sort(key=lambda e: (-e.epoch, e.kind, e.text))
    return tuple(kept[:TIMELINE_LIMIT])


# -- document --------------------------------------------------------------


def build_document(
    snapshot: HarnessSnapshot, live: LiveResult, cards: tuple[Card, ...], now: float
) -> dict[str, object]:
    agents = build_agents(snapshot, live, cards)
    timeline = build_timeline(snapshot, agents, cards, now)
    unread = [item for item in snapshot.inbox if not item.read]
    return {
        "herdr": {"ok": live.ok, "error": live.error},
        "sources": {name: status.to_json() for name, status in snapshot.sources.items()},
        "agents": [a.to_json() for a in agents],
        "inbox": [item.to_json() for item in snapshot.inbox],
        "locks": [lock.to_json() for lock in snapshot.locks],
        "worktrees": [w.to_json() for w in snapshot.worktrees],
        "timeline": [e.to_json() for e in timeline],
        "counts": {
            "agents": len(agents),
            "live": sum(1 for a in agents if a.status not in ("ended", "unknown")),
            "unread": len(unread),
            "attention": sum(1 for item in unread if item.kind in ATTENTION_KINDS),
            "locks": len(snapshot.locks),
        },
    }


# -- state -----------------------------------------------------------------


class BoardSource(Protocol):
    @property
    def version(self) -> int: ...

    @property
    def board(self) -> Board: ...


class ActivityState:
    """Current activity document; rebuilt when any source moves."""

    def __init__(
        self,
        scanner: HarnessScanner,
        board: BoardSource,
        notifier: Notifier,
        herdr: HerdrPoller | None = None,
        poll_seconds: float = 1.0,
    ) -> None:
        self._scanner = scanner
        self._board = board
        self._notifier = notifier
        self._herdr = herdr
        self._poll_seconds = poll_seconds
        self._lock = threading.Lock()
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._version = 0
        self._inputs: object = None
        self._key = ""
        self._payload = b""
        self._document: dict[str, object] = {}
        self.refresh(force=True)

    @property
    def live(self) -> LiveResult:
        return self._herdr.result if self._herdr is not None else DISABLED

    @property
    def version(self) -> int:
        with self._lock:
            return self._version

    @property
    def document(self) -> dict[str, object]:
        with self._lock:
            return self._document

    def snapshot(self) -> tuple[int, bytes]:
        with self._lock:
            return self._version, self._payload

    def wake(self) -> None:
        """Ask the loop to refresh now (the herdr poller calls this)."""
        self._wake.set()

    def refresh(self, force: bool = False) -> bool:
        board_version = self._board.version
        cards = self._board.board.cards
        task_paths = tuple(card.task.path for card in cards)
        live = self.live
        now = time.time()
        # The minute term lets events age out of the 24 h window.
        inputs = (self._scanner.fingerprint(task_paths), live, board_version, int(now // 60))
        if not force and inputs == self._inputs:
            return False
        snapshot = self._scanner.scan(task_paths)
        self._inputs = inputs
        document = build_document(snapshot, live, cards, now)
        encoded = json.dumps(document, ensure_ascii=False, sort_keys=True).encode("utf-8")
        key = hashlib.blake2b(encoded, digest_size=16).hexdigest()
        with self._lock:
            if key == self._key and not force:
                return False
            self._key = key
            self._payload = encoded
            self._document = document
            self._version += 1
        self._notifier.notify()
        return True

    def start(self) -> None:
        if self._herdr is not None:
            self._herdr.start()
        threading.Thread(target=self._loop, name="taskboard-activity", daemon=True).start()

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()
        if self._herdr is not None:
            self._herdr.stop()

    def _loop(self) -> None:
        while not self._stop.is_set():
            self._wake.wait(self._poll_seconds)
            self._wake.clear()
            if self._stop.is_set():
                return
            try:
                self.refresh()
            except Exception:  # noqa: BLE001 - a bad read must not kill the poller
                continue
