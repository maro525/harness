"""Joining records into agents, the timeline, and ActivityState."""

from __future__ import annotations

from dataclasses import replace

from taskboard.activity import (
    TIMELINE_LIMIT,
    TIMELINE_SECONDS,
    ActivityState,
    Notifier,
    build_agents,
    build_document,
    build_timeline,
    parse_time,
    repo_name,
)
from taskboard.harness import (
    AgentRecord,
    HarnessSnapshot,
    InboxItem,
    LockInfo,
    PhaseRun,
    WorktreeInfo,
)
from taskboard.herdr import DISABLED, LiveAgent, LiveResult
from taskboard.model import Board, Card, ParsedTask

NOW = parse_time("2026-11-20T12:00:00+09:00") or 0.0


def record(name: str, **fields: str | None) -> AgentRecord:
    base: dict[str, str | None] = {
        "pane": None,
        "tab": None,
        "kind": "claude",
        "model": None,
        "repo": None,
        "created": "2026-11-20T10:00:00+09:00",
        "owner": None,
        "owner_pane": None,
        "boss": None,
    }
    base.update(fields)
    return AgentRecord(name=name, source="agent", path=f"/r/{name}.json", fields={}, **base)  # type: ignore[arg-type]


def live(*agents: tuple[str, str, str | None]) -> LiveResult:
    return LiveResult(
        ok=True,
        agents=tuple(
            LiveAgent(name, "claude", status, "/w", pane, None, None, None)
            for name, status, pane in agents
        ),
    )


def snapshot(**parts: object) -> HarnessSnapshot:
    base: dict[str, object] = {
        "agents": (),
        "consults": (),
        "inbox": (),
        "locks": (),
        "worktrees": (),
        "phase_runs": (),
        "sources": {},
    }
    base.update(parts)
    return HarnessSnapshot(**base)  # type: ignore[arg-type]


def inbox(boss: str, sender: str, kind: str = "report", read: bool = False) -> InboxItem:
    return InboxItem(
        boss_dir=boss,
        sender=sender,
        to=boss,
        at="2026-11-20T11:00:00+09:00",
        kind=kind,
        stamp="20261120-110000",
        path=f"/i/{boss}/{sender}-{kind}-{read}.md",
        read=read,
        preview="hello",
    )


def lock(key: str, owner: str, task_file: str | None = None) -> LockInfo:
    return LockInfo(
        key=key,
        path=f"/l/{key}.lock",
        runner="claude",
        owner=owner,
        pid="1",
        cwd="/home/dev/src/harness",
        task_file=task_file,
        started="2026-11-20T11:30:00+09:00",
        updated_epoch=int(NOW),
        ttl_seconds=2700,
    )


def card(path: str, branch: str | None, task_id: str = "ABC-1") -> Card:
    task = ParsedTask(
        path=path,
        project="harness",
        task_id=task_id,
        title="t",
        tier="M",
        tier_raw="M",
        status_raw="implementing",
        created=None,
        branch=branch,
        pr_url=None,
        filled_sections=frozenset(),
        decision_tags=frozenset(),
        mtime=0.0,
        size=0,
    )
    return Card(
        task=task,
        phase="implementing",
        declared_phase=None,
        evidence_phase=None,
        stale_status=False,
    )


def by_name(views) -> dict:
    return {v.name: v for v in views}


# -- helpers ---------------------------------------------------------------


def test_repo_name() -> None:
    assert repo_name("/home/dev/.herdr/worktrees/nanco-flutter/feature-x") == "nanco-flutter"
    assert repo_name("/home/dev/src/harness") == "harness"
    assert repo_name(None) is None


def test_parse_time() -> None:
    assert parse_time("2026-11-20T03:00:00Z") == NOW
    assert parse_time("nope") is None and parse_time(None) is None


# -- parents ---------------------------------------------------------------


def test_parent_from_boss_field() -> None:
    views = by_name(build_agents(snapshot(agents=(record("c", boss="b"),)), DISABLED, ()))
    assert (views["c"].parent, views["c"].parent_via) == ("b", "boss")


def test_parent_from_owner_agent() -> None:
    views = by_name(build_agents(snapshot(agents=(record("c", owner="agent:b"),)), DISABLED, ()))
    assert (views["c"].parent, views["c"].parent_via) == ("b", "owner")


def test_parent_from_owner_pane_via_live_session() -> None:
    snap = snapshot(agents=(record("c", owner="pane:w1:p1"),))
    views = by_name(build_agents(snap, live(("boss", "idle", "w1:p1")), ()))
    assert (views["c"].parent, views["c"].parent_via) == ("boss", "pane")
    assert views["boss"].record is None  # a live session without a record still shows


def test_parent_from_owner_pane_field() -> None:
    snap = snapshot(agents=(record("c", owner="pane:gone", owner_pane="w1:p1"),))
    views = by_name(build_agents(snap, live(("boss", "idle", "w1:p1")), ()))
    assert views["c"].parent == "boss"


def test_parent_unknown() -> None:
    snap = snapshot(agents=(record("c", owner="pane:w9:p9"),))
    views = by_name(build_agents(snap, live(), ()))
    assert views["c"].parent is None and views["c"].parent_via is None


# -- liveness --------------------------------------------------------------


def test_status_comes_from_live_or_is_ended() -> None:
    snap = snapshot(agents=(record("a", pane="p1"), record("b", pane="p2")))
    views = by_name(build_agents(snap, live(("a", "working", "p1")), ()))
    assert views["a"].status == "working"
    assert views["b"].status == "ended"


def test_status_is_unknown_without_herdr() -> None:
    views = by_name(build_agents(snapshot(agents=(record("a"),)), DISABLED, ()))
    assert views["a"].status == "unknown"
    failed = LiveResult(ok=False, error="timed out")
    assert (
        by_name(build_agents(snapshot(agents=(record("a"),)), failed, ()))["a"].status == "unknown"
    )


def test_pane_mismatch_means_the_record_is_an_earlier_session() -> None:
    snap = snapshot(agents=(record("a", pane="old", boss="b", model="opus"),))
    view = by_name(build_agents(snap, live(("a", "idle", "new")), ()))["a"]
    assert view.record_stale
    assert view.pane == "new"
    assert view.parent is None and view.model is None  # the old record is not trusted
    assert view.record is not None  # but still shown in the detail panel


def test_consult_record_fills_the_model() -> None:
    consult = replace(record("a"), source="consult", model="opus")
    view = build_agents(snapshot(agents=(record("a"),), consults=(consult,)), DISABLED, ())[0]
    assert view.model == "opus"


# -- inbox, locks, worktrees, tasks ---------------------------------------


def test_unread_counts_to_and_from() -> None:
    snap = snapshot(
        agents=(record("child", boss="boss"),),
        inbox=(
            inbox("boss", "child", "report"),
            inbox("boss", "child", "question"),
            inbox("boss", "child", "report", read=True),
            inbox("child", "boss", "report"),
        ),
    )
    views = by_name(build_agents(snap, live(("boss", "idle", "p0")), ()))
    assert views["child"].unread_from == {"report": 1, "question": 1}
    assert views["child"].unread_to == {"report": 1}
    assert views["boss"].unread_to == {"report": 1, "question": 1}


def test_locks_match_by_agent_or_pane() -> None:
    snap = snapshot(
        agents=(record("a", pane="w1:p1"),),
        locks=(lock("k1", "pane:w1:p1"), lock("k2", "agent:a"), lock("k3", "pane:other")),
    )
    view = build_agents(snap, DISABLED, ())[0]
    assert view.lock_keys == ("k1", "k2")


def test_lock_without_owner_matches_nobody() -> None:
    snap = snapshot(agents=(record("a"),), locks=(replace(lock("k", "x"), owner=None),))
    assert build_agents(snap, DISABLED, ())[0].lock_keys == ()


def test_tasks_link_by_worktree_branch_and_by_lock() -> None:
    wt = WorktreeInfo("/home/dev/.herdr/worktrees/h/f", "feature/f", None, "a", None, "/w.json")
    snap = snapshot(
        agents=(record("a"), record("b", repo="/home/dev/.herdr/worktrees/h/f")),
        worktrees=(wt,),
        locks=(lock("k", "agent:a", task_file="/t/task-B.md"),),
        phase_runs=(
            PhaseRun("/t/task-A.md", "2026-11-20T11:00:00+09:00", "x", "l", "r", "sonnet"),
        ),
    )
    cards = (card("/t/task-A.md", "feature/f"), card("/t/task-B.md", None, "B"))
    views = by_name(build_agents(snap, DISABLED, cards))
    assert views["a"].task_paths == ("/t/task-A.md", "/t/task-B.md")
    assert views["b"].task_paths == ("/t/task-A.md",)  # its cwd is that worktree
    assert views["a"].model == "sonnet"  # from the linked task's ai.log


# -- timeline --------------------------------------------------------------


def test_timeline_collects_every_kind_newest_first() -> None:
    wt = WorktreeInfo(
        "/home/dev/.herdr/worktrees/h/f", "feature/f", None, "a", "2026-11-20T09:00:00+09:00", "/w"
    )
    snap = snapshot(
        agents=(record("a", pane="p1", boss="b"),),
        inbox=(inbox("b", "a", "question"),),
        locks=(lock("k", "pane:p1"),),
        worktrees=(wt,),
        phase_runs=(
            PhaseRun(
                "/t/task-A.md",
                "2026-11-20T11:45:00+09:00",
                "team-review",
                "claude/opus",
                "claude",
                "opus",
            ),
        ),
    )
    cards = (card("/t/task-A.md", None),)
    agents = build_agents(snap, DISABLED, cards)
    events = build_timeline(snap, agents, cards, NOW)
    assert [e.kind for e in events] == ["phase", "lock", "inbox", "delegate", "worktree"]
    assert events[1].agent == "a" and events[1].boss == "b"
    assert events[0].select == "task:/t/task-A.md" and "ABC-1 team-review" in events[0].text
    assert events[2].sub == "question"


def test_timeline_window_and_limit() -> None:
    old = replace(inbox("b", "a"), at="2026-11-18T00:00:00+09:00")
    many = tuple(replace(inbox("b", f"s{i}"), path=f"/i/{i}") for i in range(TIMELINE_LIMIT + 20))
    events = build_timeline(snapshot(inbox=(old, *many)), (), (), NOW)
    assert len(events) == TIMELINE_LIMIT
    assert all(e.epoch >= NOW - TIMELINE_SECONDS for e in events)


def test_document_counts() -> None:
    snap = snapshot(
        agents=(record("a"),),
        inbox=(inbox("b", "a", "question"), inbox("b", "a", "report"), inbox("b", "a", read=True)),
    )
    document = build_document(snap, DISABLED, (), NOW)
    assert document["counts"] == {"agents": 1, "live": 0, "unread": 2, "attention": 1, "locks": 0}
    assert document["herdr"] == {"ok": False, "error": DISABLED.error}


# -- state -----------------------------------------------------------------


class FakeScanner:
    def __init__(self) -> None:
        self.snap = snapshot()
        self.mark = 0

    def fingerprint(self, task_paths=()) -> tuple[int, int]:
        return (0, self.mark)

    def scan(self, task_paths=()) -> HarnessSnapshot:
        return self.snap


class FakeBoard:
    version = 0
    board = Board(cards=(), roots=(), scanned_at=0.0, scan_ms=0.0)


def test_state_bumps_only_on_content_change() -> None:
    scanner = FakeScanner()
    notifier = Notifier()
    state = ActivityState(scanner, FakeBoard(), notifier)  # type: ignore[arg-type]
    first = state.version
    generation = notifier.generation
    assert state.refresh() is False
    scanner.mark = 1  # files moved, content identical
    assert state.refresh() is False
    assert state.version == first and notifier.generation == generation
    scanner.snap = snapshot(agents=(record("a"),))
    scanner.mark = 2
    assert state.refresh() is True
    assert state.version == first + 1 and notifier.generation == generation + 1


def test_notifier_wait_past_returns_when_already_ahead() -> None:
    notifier = Notifier()
    notifier.notify()
    assert notifier.wait_past(0, timeout=5) == 1
    assert notifier.wait_past(1, timeout=0.01) == 1
