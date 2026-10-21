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
