"""Scanner and change-detection tests."""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from taskboard.scanner import Scanner, discover_decision_dirs, list_task_files, logs_dir_for

TASK = """\
# Task: ABC-1 — first

## Meta
- linear_id: ABC-1
- tier: S
- status: planning

## Brief
Something real.
"""


@pytest.fixture()
def folder(tmp_path: Path) -> Path:
    decisions = tmp_path / "proj" / ".claude" / "docs" / "decisions"
    decisions.mkdir(parents=True)
    (decisions / "task-ABC-1-first.md").write_text(TASK, encoding="utf-8")
    (decisions / "task-ABC-2-second.md").write_text(
        TASK.replace("ABC-1", "ABC-2").replace("planning", "done"), encoding="utf-8"
    )
    (decisions / "notes.md").write_text("ignored", encoding="utf-8")
    return decisions


def test_lists_only_task_files(folder: Path) -> None:
    names = {os.path.basename(p) for p, _ in list_task_files(str(folder))}
    assert names == {"task-ABC-1-first.md", "task-ABC-2-second.md"}


def test_missing_folder_yields_no_files_and_no_exception() -> None:
    assert list_task_files("/nonexistent/path/nope") == []


def test_scan_places_cards_in_columns(folder: Path) -> None:
    board = Scanner(roots=(str(folder),)).scan()
    phases = {c.task.task_id: c.phase for c in board.cards}
    assert phases == {"ABC-1": "planning", "ABC-2": "done"}


def test_scan_reports_project_name(folder: Path) -> None:
    board = Scanner(roots=(str(folder),)).scan()
    assert {c.task.project for c in board.cards} == {"proj"}


def test_empty_root_is_reported_as_an_error(tmp_path: Path) -> None:
    board = Scanner(roots=(str(tmp_path / "missing"),)).scan()
    assert board.cards == ()
    assert board.errors


def test_cache_avoids_reparsing_unchanged_files(folder: Path, monkeypatch) -> None:
    scanner = Scanner(roots=(str(folder),))
    scanner.scan()

    calls = {"n": 0}
    import taskboard.scanner as scanner_module

    real = scanner_module.parse_file

    def counting(path: str, mtime: float, size: int):
        calls["n"] += 1
        return real(path, mtime, size)

    monkeypatch.setattr(scanner_module, "parse_file", counting)
    scanner.scan()
    assert calls["n"] == 0, "unchanged files must come from cache"


def test_cache_invalidated_when_a_file_changes(folder: Path) -> None:
    scanner = Scanner(roots=(str(folder),))
    scanner.scan()
    target = folder / "task-ABC-1-first.md"
    target.write_text(TASK.replace("status: planning", "status: done"), encoding="utf-8")
    os.utime(target, (1_800_000_000, 1_800_000_000))
    board = scanner.scan()
    phases = {c.task.task_id: c.phase for c in board.cards}
    assert phases["ABC-1"] == "done"


def test_deleted_files_drop_out_of_the_board(folder: Path) -> None:
    scanner = Scanner(roots=(str(folder),))
    assert len(scanner.scan().cards) == 2
    (folder / "task-ABC-2-second.md").unlink()
    assert len(scanner.scan().cards) == 1


def test_fingerprint_changes_when_content_changes(folder: Path) -> None:
    scanner = Scanner(roots=(str(folder),))
    before = scanner.fingerprint()
    target = folder / "task-ABC-1-first.md"
    target.write_text(TASK + "\nmore\n", encoding="utf-8")
    os.utime(target, (1_800_000_000, 1_800_000_000))
    assert scanner.fingerprint() != before


def test_fingerprint_stable_when_nothing_changes(folder: Path) -> None:
    scanner = Scanner(roots=(str(folder),))
    assert scanner.fingerprint() == scanner.fingerprint()


def test_discover_finds_decision_dirs_and_prunes_noise(tmp_path: Path) -> None:
    good = tmp_path / "a" / ".claude" / "docs" / "decisions"
    good.mkdir(parents=True)
    (good / "task-A-1-x.md").write_text(TASK, encoding="utf-8")

    buried = tmp_path / "b" / "node_modules" / "pkg" / ".claude" / "docs" / "decisions"
    buried.mkdir(parents=True)
    (buried / "task-B-1-x.md").write_text(TASK, encoding="utf-8")

    found = discover_decision_dirs(str(tmp_path))
    assert str(good) in found
    assert str(buried) not in found, "node_modules must be pruned"


def test_recursive_scan_collects_multiple_projects(tmp_path: Path) -> None:
    for name in ("p1", "p2"):
        d = tmp_path / name / ".claude" / "docs" / "decisions"
        d.mkdir(parents=True)
        (d / f"task-{name.upper()}-1-x.md").write_text(TASK, encoding="utf-8")
    board = Scanner(roots=(str(tmp_path),), recursive=True).scan()
    assert {c.task.project for c in board.cards} == {"p1", "p2"}


def test_worktrees_are_pruned_to_avoid_duplicate_cards(tmp_path: Path) -> None:
    main = tmp_path / "p" / ".claude" / "docs" / "decisions"
    main.mkdir(parents=True)
    (main / "task-A-1-x.md").write_text(TASK, encoding="utf-8")
    dup = tmp_path / "p" / "worktrees" / "wt1" / ".claude" / "docs" / "decisions"
    dup.mkdir(parents=True)
    (dup / "task-A-1-x.md").write_text(TASK, encoding="utf-8")

    board = Scanner(roots=(str(tmp_path),), recursive=True).scan()
    assert len(board.cards) == 1


# -- pending questions (ask logs) -------------------------------------------

ASK_WAITING = """\
# 質問

Q1. どちらにしますか？ 1. A 2. B

#### 待機状態
- state: waiting
- comment_url: https://linear.app/x/issue/ABC-1#comment-1234abcd
- posted_at: 2026-10-21T04:00:00Z
- deadline: 2026-10-21T08:00:00Z
"""


def write_ask(logs: Path, name: str, text: str, mtime: int = 1_800_000_000) -> Path:
    logs.mkdir(parents=True, exist_ok=True)
    path = logs / name
    path.write_text(text, encoding="utf-8")
    os.utime(path, (mtime, mtime))
    return path


def logs_of(folder: Path) -> Path:
    return folder.parent.parent / "logs"


def by_id(board) -> dict:
    return {c.task.task_id: c for c in board.cards}


def test_logs_dir_for_conventional_and_foreign_folders(folder: Path, tmp_path: Path) -> None:
    assert logs_dir_for(str(folder)) == str(logs_of(folder))
    assert logs_dir_for(str(folder) + os.sep) == str(logs_of(folder))
    assert logs_dir_for(str(tmp_path)) is None


def test_waiting_question_is_attached_to_matching_card(folder: Path) -> None:
    write_ask(logs_of(folder), "ask-ABC-1-plan-20261021-1300.md", ASK_WAITING)
    board = Scanner(roots=(str(folder),)).scan()
    cards = by_id(board)
    assert cards["ABC-1"].question is not None
    assert cards["ABC-1"].question.phase == "plan"
    assert cards["ABC-2"].question is None
    payload = board.to_json()
    assert payload["waitingCount"] == 1
    card_json = next(c for c in payload["cards"] if c["id"] == "ABC-1")
    assert card_json["question"]["commentUrl"].startswith("https://linear.app/")
    assert card_json["question"]["postedAt"] == "2026-10-21T04:00:00Z"


def test_question_for_unknown_id_is_not_attached(folder: Path) -> None:
    write_ask(logs_of(folder), "ask-ZZZ-9-plan-20261021-1300.md", ASK_WAITING)
    board = Scanner(roots=(str(folder),)).scan()
    assert all(c.question is None for c in board.cards)
    assert board.to_json()["waitingCount"] == 0


def test_resolved_question_is_not_attached(folder: Path) -> None:
    text = ASK_WAITING.replace("state: waiting", "state: resolved")
    write_ask(logs_of(folder), "ask-ABC-1-plan-20261021-1300.md", text)
    board = Scanner(roots=(str(folder),)).scan()
    assert by_id(board)["ABC-1"].question is None


def test_newest_waiting_question_wins(folder: Path) -> None:
    logs = logs_of(folder)
    write_ask(logs, "ask-ABC-1-plan-20261021-1300.md", ASK_WAITING, mtime=1_900_000_000)
    newer = ASK_WAITING.replace("04:00:00", "06:00:00").replace("Q1. どちら", "Q1. 新しい")
    write_ask(logs, "ask-ABC-1-gate2-20261021-1500.md", newer, mtime=1_800_000_000)
    question = by_id(Scanner(roots=(str(folder),)).scan())["ABC-1"].question
    assert question is not None
    assert question.phase == "gate2", "posted_at beats mtime"


def test_same_posted_at_tie_breaks_on_filename_stamp(folder: Path) -> None:
    logs = logs_of(folder)
    write_ask(logs, "ask-ABC-1-plan-20261021-1300.md", ASK_WAITING, mtime=1_900_000_000)
    write_ask(logs, "ask-ABC-1-gate2-20261021-1500.md", ASK_WAITING, mtime=1_800_000_000)
    question = by_id(Scanner(roots=(str(folder),)).scan())["ABC-1"].question
    assert question is not None
    assert question.phase == "gate2", "stamp beats mtime when posted_at ties"


def test_same_posted_at_and_stamp_falls_back_to_mtime(folder: Path) -> None:
    logs = logs_of(folder)
    write_ask(logs, "ask-ABC-1-plan-20261021-1300.md", ASK_WAITING, mtime=1_800_000_000)
    write_ask(logs, "ask-ABC-1-gate2-20261021-1300.md", ASK_WAITING, mtime=1_900_000_000)
    question = by_id(Scanner(roots=(str(folder),)).scan())["ABC-1"].question
    assert question is not None
    assert question.phase == "gate2"


def test_huge_round_number_does_not_break_scan(folder: Path) -> None:
    text = (
        ASK_WAITING + "\n## 往復 " + "9" * 5000 + "\n\nQ1. x\n\n" + ASK_WAITING.split("\n\n", 2)[2]
    )
    write_ask(logs_of(folder), "ask-ABC-1-plan-20261021-1300.md", text)
    board = Scanner(roots=(str(folder),)).scan()
    assert by_id(board)["ABC-1"].question is not None
    assert board.to_json()["waitingCount"] == 1


def test_fingerprint_changes_when_only_an_ask_log_changes(folder: Path) -> None:
    scanner = Scanner(roots=(str(folder),))
    path = write_ask(logs_of(folder), "ask-ABC-1-plan-20261021-1300.md", ASK_WAITING)
    before = scanner.fingerprint()
    path.write_text(ASK_WAITING.replace("waiting", "resolved"), encoding="utf-8")
    os.utime(path, (1_800_000_100, 1_800_000_100))
    assert scanner.fingerprint() != before


def test_ask_log_change_updates_card_without_reparsing_tasks(folder: Path, monkeypatch) -> None:
    scanner = Scanner(roots=(str(folder),))
    path = write_ask(logs_of(folder), "ask-ABC-1-plan-20261021-1300.md", ASK_WAITING)
    assert by_id(scanner.scan())["ABC-1"].question is not None

    import taskboard.scanner as scanner_module

    def fail(*_args, **_kwargs):
        raise AssertionError("task files must not be reparsed for an ask log change")

    monkeypatch.setattr(scanner_module, "parse_file", fail)
    path.write_text(ASK_WAITING.replace("state: waiting", "state: resolved"), encoding="utf-8")
    os.utime(path, (1_800_000_100, 1_800_000_100))
    assert by_id(scanner.scan())["ABC-1"].question is None


def test_deleted_ask_log_drops_question_and_cache(folder: Path) -> None:
    scanner = Scanner(roots=(str(folder),))
    path = write_ask(logs_of(folder), "ask-ABC-1-plan-20261021-1300.md", ASK_WAITING)
    assert by_id(scanner.scan())["ABC-1"].question is not None
    path.unlink()
    assert by_id(scanner.scan())["ABC-1"].question is None
    assert scanner._ask_cache == {}


def test_foreign_folder_ignores_neighbouring_logs(tmp_path: Path) -> None:
    folder = tmp_path / "tasks"
    folder.mkdir()
    (folder / "task-ABC-1-first.md").write_text(TASK, encoding="utf-8")
    write_ask(tmp_path / "logs", "ask-ABC-1-plan-20261021-1300.md", ASK_WAITING)
    write_ask(folder / "logs", "ask-ABC-1-plan-20261021-1300.md", ASK_WAITING)
    board = Scanner(roots=(str(folder),)).scan()
    assert board.cards[0].question is None


def test_question_does_not_leak_into_cached_card(folder: Path) -> None:
    scanner = Scanner(roots=(str(folder),))
    write_ask(logs_of(folder), "ask-ABC-1-plan-20261021-1300.md", ASK_WAITING)
    scanner.scan()
    assert all(card.question is None for _, card in scanner._cache.values())
