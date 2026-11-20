"""Readers for the harness records and the `herdr agent list` poller."""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

import pytest

from taskboard import harness
from taskboard.harness import (
    HarnessPaths,
    HarnessScanner,
    parse_ai_log,
    parse_inbox_file,
    parse_lock_file,
    parse_ttl,
    safe_name,
)
from taskboard.herdr import HerdrPoller, fetch_live_agents, parse_agent_list

# Shapes copied from real files on 2026-11-20.
AGENT_RECORD = {
    "agent": "ads-2824-cdmg",
    "pane": "w23:p9Q",
    "tab": "w23:t97",
    "tab_owned": True,
    "topology": "tab",
    "kind": "claude",
    "repo": "/home/dev/.herdr/worktrees/nanco-flutter/feature-nanco-2824",
    "created": "2026-11-19T06:36:21+09:00",
    "owner": "pane:w23:pZ",
    "boss": "boss-ads",
}
CONSULT_RECORD = {
    "agent": "consult",
    "pane": "w23:pAM",
    "cwd": "/home/dev/src/nanco-next",
    "role": "consult",
    "model": "opus",
    "target": "claude",
    "created": "2026-11-20T10:25:43+09:00",
    "owner": "agent:boss-storage",
    "owner_pane": "w23:pZ",
    "boss": "boss-storage",
}
INBOX_BLOCKED = """\
from: ads-apple-2946
to: boss-ads
at: 2026-11-18T17:29:06+09:00
kind: blocked

ads-apple-2946 が blocked で止まっています。
"""
LOCK = """\
key=harness-task-ai-activity-board
runner=pi
owner=pane:w2N:pX
pid=68595
cwd=/home/dev/src/harness
task_file=
started=2026-11-20T10:53:16+09:00
updated_epoch=1795139596
ttl=45m
"""
WORKTREE = {
    "path": "/home/dev/.herdr/worktrees/nanco-analytics/feature-nanco-2651",
    "branch": "feature/nanco-2651",
    "owner": "pane:w23:pZ",
    "agent": "orchestrate-nanco-2651",
    "created": "2026-11-18T17:51:00+09:00",
}
AI_LOG = (
    "2026-11-20T10:59:13+09:00\tphase=startproject\tlabel=claude/opus\trunner=claude\tmodel=opus\n"
)


def make_paths(root: Path) -> HarnessPaths:
    paths = HarnessPaths(
        agents=str(root / "herdr-agents"),
        consult=str(root / "herdr-consult"),
        inbox=str(root / "inbox"),
        locks=str(root / "locks"),
        worktrees=str(root / "herdr-worktrees"),
    )
    for folder in (paths.agents, paths.consult, paths.inbox, paths.locks, paths.worktrees):
        os.makedirs(folder, exist_ok=True)
    return paths


@pytest.fixture()
def records(tmp_path: Path) -> HarnessPaths:
    paths = make_paths(tmp_path / "h")
    Path(paths.agents, "ads-2824-cdmg.json").write_text(json.dumps(AGENT_RECORD))
    Path(paths.agents, "broken.json").write_text('{"agent": "half')
    Path(paths.consult, "consult.json").write_text(json.dumps(CONSULT_RECORD))
    boss = Path(paths.inbox, "boss-ads")
    (boss / "done").mkdir(parents=True)
    (boss / ".watch").mkdir()
    (boss / "ads-apple-2946-20261118-172906.blocked.md").write_text(INBOX_BLOCKED)
    (boss / "ads-apple-2946-20261118-172906-2.md").write_text("no header at all\n")
    (boss / ".tmp.abc").write_text("staging")
    (boss / "notes.txt").write_text("foreign file")
    (boss / "done" / "ads-2824-prep-20261119-073205.md").write_text("from: ads-2824-prep\n\nok\n")
    Path(paths.locks, "harness-task.lock").write_text(LOCK)
    Path(paths.locks, "harness-task.lock.guard").write_text("")
    Path(paths.worktrees, "a.json").write_text(json.dumps(WORKTREE))
    return paths


# -- parsers ---------------------------------------------------------------


def test_parse_ttl_accepts_the_written_forms() -> None:
    assert parse_ttl("45m") == 2700
    assert parse_ttl("90s") == 90
    assert parse_ttl("2h") == 7200
    assert parse_ttl("600") == 600
    assert parse_ttl("soon") is None
    assert parse_ttl(None) is None


def test_inbox_file_with_headers(tmp_path: Path) -> None:
    path = tmp_path / "ads-apple-2946-20261118-172906.blocked.md"
    path.write_text(INBOX_BLOCKED)
    item = parse_inbox_file(str(path), "boss-ads", read=False)
    assert item is not None
    assert (item.sender, item.to, item.kind) == ("ads-apple-2946", "boss-ads", "blocked")
    assert item.at == "2026-11-18T17:29:06+09:00"
    assert item.preview.startswith("ads-apple-2946 が blocked")


def test_inbox_file_without_headers_falls_back_to_the_name(tmp_path: Path) -> None:
    path = tmp_path / "orch-2823-v2-20261120-095321-3.question.md"
    path.write_text("Which one?\n")
    item = parse_inbox_file(str(path), "boss", read=True)
    assert item is not None
    assert (item.sender, item.kind, item.stamp, item.at) == (
        "orch-2823-v2",
        "question",
        "20261120-095321-3",
        None,
    )
    assert item.preview == "Which one?"


def test_inbox_preview_is_capped(tmp_path: Path) -> None:
    path = tmp_path / "x-20261120-000000.md"
    path.write_text("from: x\n\n" + "a" * 5000)
    item = parse_inbox_file(str(path), "boss", read=False)
    assert item is not None and len(item.preview) == harness.PREVIEW_CHARS


def test_inbox_foreign_name_is_ignored(tmp_path: Path) -> None:
    path = tmp_path / "README.md"
    path.write_text("hello")
    assert parse_inbox_file(str(path), "boss", read=False) is None


def test_lock_file_and_empty_task_file(tmp_path: Path) -> None:
    path = tmp_path / "k.lock"
    path.write_text(LOCK)
    lock = parse_lock_file(str(path))
    assert lock is not None
    assert lock.key == "harness-task-ai-activity-board"
    assert lock.ttl_seconds == 2700 and lock.updated_epoch == 1795139596
    assert lock.task_file is None


def test_lock_heartbeat_is_reported_per_minute(tmp_path: Path) -> None:
    path = tmp_path / "k.lock"
    path.write_text(LOCK)
    first = parse_lock_file(str(path))
    path.write_text(LOCK.replace("1795139596", "1795139599"))
    second = parse_lock_file(str(path))
    assert first is not None and second is not None
    assert first.to_json() == second.to_json()


def test_ai_log_skips_junk_lines(tmp_path: Path) -> None:
    path = tmp_path / "t.md.ai.log"
    path.write_text(AI_LOG + "garbage\n\n" + AI_LOG.replace("startproject", "team-review"))
    runs = parse_ai_log(str(path), "t.md")
    assert [r.phase for r in runs] == ["startproject", "team-review"]
    assert runs[0].model == "opus" and runs[0].label == "claude/opus"


def test_ai_log_missing_or_empty(tmp_path: Path) -> None:
    assert parse_ai_log(str(tmp_path / "none.ai.log"), "x") == ()
    (tmp_path / "e.ai.log").write_text("")
    assert parse_ai_log(str(tmp_path / "e.ai.log"), "x") == ()


def test_safe_name_matches_the_shell_helper() -> None:
    assert safe_name("boss-ads") == "boss-ads"
    assert safe_name("a b/c") == "a_b_c"
    assert safe_name(".hidden") == "_.hidden"


def test_default_paths_follow_the_environment() -> None:
    paths = HarnessPaths.default({"HOME": "/h", "XDG_CACHE_HOME": "/c", "HARNESS_LOCKS_DIR": "/l"})
    assert paths.agents == "/c/harness/herdr-agents"
    assert paths.inbox == "/c/harness/inbox"
    assert paths.locks == "/l"
    assert HarnessPaths.default({"HOME": "/h"}).locks == "/h/.local/share/harness/locks"


# -- scanner ---------------------------------------------------------------


def test_scan_reads_every_source(records: HarnessPaths, tmp_path: Path) -> None:
    task = tmp_path / "task-X-1.md"
    task.write_text("# Task")
    Path(str(task) + ".ai.log").write_text(AI_LOG)

    snapshot = HarnessScanner(records).scan([str(task)])

    assert [r.name for r in snapshot.agents] == ["ads-2824-cdmg"]
    assert snapshot.sources["agents"].skipped == 1  # the half-written JSON
    assert snapshot.consults[0].model == "opus"
    unread = [i for i in snapshot.inbox if not i.read]
    read = [i for i in snapshot.inbox if i.read]
    assert len(unread) == 2 and len(read) == 1
    assert [lock.key for lock in snapshot.locks] == ["harness-task-ai-activity-board"]
    assert snapshot.worktrees[0].branch == "feature/nanco-2651"
    assert snapshot.phase_runs[0].task_path == str(task)
    assert all(status.ok for status in snapshot.sources.values())


def test_missing_folders_are_empty_not_errors(tmp_path: Path) -> None:
    paths = HarnessPaths(*(str(tmp_path / name) for name in "abcde"))
    snapshot = HarnessScanner(paths).scan()
    assert snapshot.agents == () and snapshot.inbox == ()
    assert all(status.ok for status in snapshot.sources.values())


def test_unlistable_folder_is_reported(tmp_path: Path) -> None:
    paths = make_paths(tmp_path / "h")
    blocker = tmp_path / "file"
    blocker.write_text("")
    paths = HarnessPaths(str(blocker), paths.consult, paths.inbox, paths.locks, paths.worktrees)
    status = HarnessScanner(paths).scan().sources["agents"]
    assert not status.ok and status.error


def test_done_items_are_capped_newest_first(tmp_path: Path) -> None:
    paths = make_paths(tmp_path / "h")
    done = Path(paths.inbox, "boss", "done")
    done.mkdir(parents=True)
    for minute in range(harness.DONE_PER_BOSS + 5):
        (done / f"c-20261120-10{minute:02d}00.md").write_text("from: c\n\nx")
    items = HarnessScanner(paths).scan().inbox
    assert len(items) == harness.DONE_PER_BOSS
    assert min(i.stamp for i in items) == "20261120-100500"


def test_done_items_are_capped_by_stamp_not_by_sender(tmp_path: Path) -> None:
    # Names start with the sender: "zed-" sorts after "abe-" whatever the time.
    paths = make_paths(tmp_path / "h")
    done = Path(paths.inbox, "boss", "done")
    done.mkdir(parents=True)
    for minute in range(harness.DONE_PER_BOSS):
        (done / f"zed-20261120-09{minute:02d}00.md").write_text("from: zed\n\nold")
    (done / "abe-20261120-110000.md").write_text("from: abe\n\nnew")
    (done / "abe-20261120-110000-2.md").write_text("from: abe\n\nnewer")
    items = HarnessScanner(paths).scan().inbox
    assert len(items) == harness.DONE_PER_BOSS
    names = {os.path.basename(i.path) for i in items}
    assert {"abe-20261120-110000.md", "abe-20261120-110000-2.md"} <= names
    assert "zed-20261120-090000.md" not in names
    assert "zed-20261120-090100.md" not in names


def test_unlistable_boss_folder_is_reported(tmp_path: Path) -> None:
    paths = make_paths(tmp_path / "h")
    boss = Path(paths.inbox, "boss")
    boss.mkdir(parents=True)
    (boss / "c-20261120-100000.md").write_text("from: c\n\nx")
    (boss / "done").write_text("")  # a file where the folder should be
    status = HarnessScanner(paths).scan().sources["inbox"]
    assert not status.ok and "done" in (status.error or "")
    assert status.count == 1


def test_unchanged_files_are_not_reparsed(
    records: HarnessPaths, monkeypatch: pytest.MonkeyPatch
) -> None:
    scanner = HarnessScanner(records)
    scanner.scan()
    calls: list[str] = []
    original = harness.parse_lock_file
    monkeypatch.setattr(harness, "parse_lock_file", lambda p: calls.append(p) or original(p))
    scanner.scan()
    assert calls == []
    lock = Path(records.locks, "harness-task.lock")
    lock.write_text(LOCK + "\n")
    scanner.scan()
    assert calls == [str(lock)]


def test_fingerprint_moves_on_new_inbox_item(records: HarnessPaths) -> None:
    scanner = HarnessScanner(records)
    before = scanner.fingerprint()
    assert scanner.fingerprint() == before
    Path(records.inbox, "boss-ads", "z-20261120-120000.md").write_text("from: z\n\nhi")
    assert scanner.fingerprint() != before


# -- herdr -----------------------------------------------------------------

LIST_JSON = json.dumps(
    {
        "result": {
            "agents": [
                {
                    "agent": "claude",
                    "agent_status": "working",
                    "cwd": "/w",
                    "name": "child",
                    "pane_id": "w1:p2",
                    "tab_id": "w1:t1",
                    "workspace_id": "w1",
                },
                {"agent": "cursor", "agent_status": "idle", "name": "boss", "pane_id": "w1:p1"},
                {"agent": "claude"},
            ]
        }
    }
)


def python(code: str) -> list[str]:
    return [sys.executable, "-c", code]


def test_parse_agent_list() -> None:
    result = parse_agent_list(LIST_JSON)
    assert result.ok
    assert [(a.name, a.kind, a.status) for a in result.agents] == [
        ("boss", "cursor", "idle"),
        ("child", "claude", "working"),
    ]


@pytest.mark.parametrize("text", ["", "not json", "[]", '{"result": {}}'])
def test_parse_agent_list_rejects_unexpected_output(text: str) -> None:
    assert not parse_agent_list(text).ok


def test_fetch_ok() -> None:
    result = fetch_live_agents(python(f"print({LIST_JSON!r})"), timeout=5)
    assert result.ok and len(result.agents) == 2


def test_fetch_missing_command() -> None:
    result = fetch_live_agents(["definitely-not-a-herdr-binary"], timeout=1)
    assert not result.ok and "not found" in (result.error or "")


def test_fetch_nonzero_exit() -> None:
    result = fetch_live_agents(python("import sys; sys.stderr.write('boom'); sys.exit(3)"))
    assert not result.ok and result.error == "exit 3: boom"


def test_fetch_timeout_kills_the_process_group(tmp_path: Path) -> None:
    marker = tmp_path / "child.pid"
    # The child spawns a grandchild; both must be gone after the timeout.
    code = (
        "import subprocess, sys, time;"
        f"p = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)']);"
        f"open({str(marker)!r}, 'w').write(str(p.pid));"
        "time.sleep(30)"
    )
    started = time.monotonic()
    result = fetch_live_agents(python(code), timeout=0.5)
    assert not result.ok and "timed out" in (result.error or "")
    assert time.monotonic() - started < 5
    grandchild = int(marker.read_text())
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        try:
            os.kill(grandchild, 0)
        except ProcessLookupError:
            break
        # A zombie still answers kill(0); reap check via /proc state.
        stat = Path(f"/proc/{grandchild}/stat")
        if stat.exists() and stat.read_text().split()[2] == "Z":
            break
        time.sleep(0.05)
    else:
        pytest.fail("grandchild survived the timeout")


def test_poller_reports_only_changes() -> None:
    calls: list[int] = []
    poller = HerdrPoller(lambda: calls.append(1), python(f"print({LIST_JSON!r})"), interval=60)
    assert poller.poll_once() is True
    assert poller.poll_once() is False
    assert len(calls) == 1 and poller.result.ok


def test_stop_kills_a_call_in_flight(tmp_path: Path) -> None:
    marker = tmp_path / "pid"
    code = f"import os, time; open({str(marker)!r}, 'w').write(str(os.getpid())); time.sleep(30)"
    poller = HerdrPoller(lambda: None, python(code), interval=60, timeout=30)
    poller.start()
    deadline = time.monotonic() + 5
    while not (marker.exists() and marker.read_text()) and time.monotonic() < deadline:
        time.sleep(0.05)
    pid = int(marker.read_text())
    poller.stop()
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        stat = Path(f"/proc/{pid}/stat")
        if not stat.exists() or stat.read_text().split()[2] == "Z":
            break
        time.sleep(0.05)
    else:
        pytest.fail("herdr call survived stop()")
    assert not poller.result.ok  # the killed call is not reported as a live list
