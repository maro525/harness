"""Scanner and change-detection tests."""

from __future__ import annotations

import os
from pathlib import Path

import pytest

from taskboard.scanner import Scanner, discover_decision_dirs, list_task_files

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
