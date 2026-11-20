"""`--print` summary tests."""

from __future__ import annotations

from pathlib import Path

import pytest

from taskboard.__main__ import main

TASK = """\
# Task: ABC-1 — first

## Meta
- linear_id: ABC-1
- status: planning
"""

ASK_WAITING = """\
Q1. どちらにしますか？

#### 待機状態
- state: waiting
- comment_url: https://linear.app/x/issue/ABC-1#comment-1234abcd
- posted_at: 2026-10-21T04:00:00Z
- deadline: 2026-10-21T08:00:00Z
"""


@pytest.fixture()
def decisions(tmp_path: Path) -> Path:
    folder = tmp_path / "proj" / ".claude" / "docs" / "decisions"
    folder.mkdir(parents=True)
    (folder / "task-ABC-1-first.md").write_text(TASK, encoding="utf-8")
    return folder


def test_print_lists_waiting_questions(decisions: Path, capsys) -> None:
    logs = decisions.parent.parent / "logs"
    logs.mkdir()
    (logs / "ask-ABC-1-plan-20261021-1300.md").write_text(ASK_WAITING, encoding="utf-8")

    assert main(["--print", str(decisions)]) == 0

    out = capsys.readouterr().out
    assert "1 task(s) are waiting for an answer" in out
    assert "ABC-1" in out and "[plan]" in out and "2026-10-21T08:00:00Z" in out
    assert "どちらにしますか？" in out
    assert "https://linear.app/x/issue/ABC-1#comment-1234abcd" in out


def test_print_without_waiting_questions_omits_section(decisions: Path, capsys) -> None:
    assert main(["--print", str(decisions)]) == 0
    assert "waiting for an answer" not in capsys.readouterr().out


def test_folder_is_required_without_harness(capsys) -> None:
    with pytest.raises(SystemExit) as caught:
        main([])
    assert caught.value.code == 2
    assert "FOLDER is required" in capsys.readouterr().err


def test_print_harness_summarizes_agents(
    decisions: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys
) -> None:
    cache = tmp_path / "cache"
    agents = cache / "harness" / "herdr-agents"
    agents.mkdir(parents=True)
    (agents / "child.json").write_text('{"agent": "child", "boss": "boss"}')
    inbox = cache / "harness" / "inbox" / "boss"
    inbox.mkdir(parents=True)
    (inbox / "child-20261120-110000.blocked.md").write_text("from: child\nkind: blocked\n\nstuck")
    monkeypatch.setenv("XDG_CACHE_HOME", str(cache))
    monkeypatch.setenv("HARNESS_LOCKS_DIR", str(tmp_path / "locks"))

    assert main(["--print", "--harness", "--no-herdr", str(decisions)]) == 0

    out = capsys.readouterr().out
    assert "herdr: unavailable (disabled (--no-herdr))" in out
    assert "agents  1  (live 0)" in out
    assert "unread  1  (needs attention 1)" in out


def test_harness_without_folder_reads_the_default_tasks_root(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys
) -> None:
    tasks = tmp_path / "home" / ".local" / "share" / "harness" / "tasks" / "repo"
    tasks.mkdir(parents=True)
    (tasks / "task-ABC-1-first.md").write_text(TASK, encoding="utf-8")
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.delenv("XDG_DATA_HOME", raising=False)
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path / "cache"))
    monkeypatch.setenv("HARNESS_LOCKS_DIR", str(tmp_path / "locks"))

    assert main(["--print", "--harness", "--no-herdr"]) == 0
    assert "1 tasks in 1 folder(s)" in capsys.readouterr().out


def test_harness_without_folder_follows_xdg_data_home(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, capsys
) -> None:
    tasks = tmp_path / "data" / "harness" / "tasks" / "repo"
    tasks.mkdir(parents=True)
    (tasks / "task-ABC-1-first.md").write_text(TASK, encoding="utf-8")
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.setenv("XDG_DATA_HOME", str(tmp_path / "data"))
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path / "cache"))
    monkeypatch.setenv("HARNESS_LOCKS_DIR", str(tmp_path / "locks"))

    assert main(["--print", "--harness", "--no-herdr"]) == 0
    assert "1 tasks in 1 folder(s)" in capsys.readouterr().out
