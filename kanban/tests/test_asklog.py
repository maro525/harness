"""Ask log parser tests.

The fixtures follow the real logs orchestrate's question relay writes
(`.claude/logs/ask-{LINEAR_ID}-{phase}-{YYYYMMDD-HHMM}.md`).
"""

from __future__ import annotations

import time
from pathlib import Path

import pytest

from taskboard import asklog
from taskboard.asklog import MAX_SUMMARY_CHARS, parse_ask_file, parse_ask_name, parse_ask_text

NAME = "ask-NSKETCH-1948-e2e-20261021-1312.md"

BLOCK = """\
#### 待機状態
- state: {state}
- comment_id: 17bfcbca-1db8-4433-a2fe-0beeb3bed55d
- marker: de25bca1
- comment_url: https://linear.app/nsketch/issue/NSKETCH-1948#comment-17bfcbca
- posted_at: 2026-10-21T04:12:47Z
- deadline: 2026-10-21T08:12:47Z
- wake: 14
- timer_task_id: bylr5cllj
- generation: 1
- failures: 0
"""

RESOLVED = (
    "# E2E 質問\n\nQ1. E2E テスト: どちらの色が好きですか？ 1. 赤 2. 青\n\n"
    + BLOCK.format(state="resolved")
    + "\n#### 回答\n- 回答: Q1: 2（青）\n- 経路: Linear\n"
)

WAITING = "# E2E 質問\n\nQ1. どちらの色が好きですか？ 1. 赤 2. 青\n\n" + BLOCK.format(
    state="waiting"
)


def parse(text: str, name: str = NAME):
    parts = parse_ask_name(name)
    assert parts is not None
    return parse_ask_text(text, "/x/" + name, *parts)


# -- filename ---------------------------------------------------------------


@pytest.mark.parametrize(
    ("name", "expected"),
    [
        (NAME, ("NSKETCH-1948", "e2e", "20261021-1312")),
        ("ask-NSKETCH-1948-e2e2-20261021-1352.md", ("NSKETCH-1948", "e2e2", "20261021-1352")),
        ("ask-ABC-1-startproject-20260101-0000.md", ("ABC-1", "startproject", "20260101-0000")),
        ("ask-abc-12-gate2-20260101-0000.md", ("ABC-12", "gate2", "20260101-0000")),
        ("ask-ABC-1-two-part-20260101-0000.md", ("ABC-1", "two-part", "20260101-0000")),
    ],
)
def test_parse_ask_name_with_valid_names_splits_parts(name: str, expected) -> None:
    assert parse_ask_name(name) == expected


@pytest.mark.parametrize(
    "name",
    [
        "ask-NOLINEAR-plan-20260101-0000.md",
        "ask-ABC-1-20260101-0000.md",
        "ask-ABC-1-plan-2026-0000.md",
        "ask-ABC-1-plan-20260101-0000.txt",
        "task-ABC-1-plan-20260101-0000.md",
        "ask-ABC-1-plan-20260101-0000.md.bak",
    ],
)
def test_parse_ask_name_with_foreign_names_returns_none(name: str) -> None:
    assert parse_ask_name(name) is None


# -- state ------------------------------------------------------------------


def test_resolved_log_returns_none() -> None:
    assert parse(RESOLVED) is None


def test_waiting_log_returns_question_fields() -> None:
    q = parse(WAITING)
    assert q is not None
    assert q.linear_id == "NSKETCH-1948"
    assert q.phase == "e2e"
    assert q.summary == "どちらの色が好きですか？ 1. 赤 2. 青"
    assert q.comment_url == "https://linear.app/nsketch/issue/NSKETCH-1948#comment-17bfcbca"
    assert q.posted_at == "2026-10-21T04:12:47Z"
    assert q.deadline == "2026-10-21T08:12:47Z"
    assert q.round == 1


@pytest.mark.parametrize("state", ["expired", "terminal", "", "WAITINGX"])
def test_non_waiting_states_return_none(state: str) -> None:
    assert parse("Q1. x\n\n" + BLOCK.format(state=state)) is None


def test_state_is_case_insensitive() -> None:
    assert parse("Q1. x\n\n" + BLOCK.format(state="Waiting")) is not None


def test_second_round_uses_last_block_and_its_question() -> None:
    text = (
        RESOLVED
        + "\n## 往復 2\n\nQ1. 二回目の質問です\n\n"
        + BLOCK.format(state="waiting").replace("04:12:47", "05:00:00")
    )
    q = parse(text)
    assert q is not None
    assert q.round == 2
    assert q.summary == "二回目の質問です"
    assert q.posted_at == "2026-10-21T05:00:00Z"


def test_second_round_resolved_after_waiting_first_block_returns_none() -> None:
    text = WAITING + "\n## 往復 2\n\nQ1. 次\n\n" + BLOCK.format(state="resolved")
    assert parse(text) is None


# -- summary ----------------------------------------------------------------


def test_summary_prefers_question_items_and_skips_state_section() -> None:
    text = (
        "### QUESTIONS\n#### Q1\n- 種別: choice\n- 質問: DB はどちらにしますか\n"
        "- 選択肢: 1. A / 2. B\n\n#### Q2\n- 種別: free\n- 質問: 期限はいつですか\n\n"
        "#### STATE\n- 質問: これは STATE なので拾わない\n\n" + BLOCK.format(state="waiting")
    )
    q = parse(text)
    assert q is not None
    assert q.summary == "DB はどちらにしますか / 期限はいつですか"


def test_summary_reads_bold_q_lines_and_caps_at_three() -> None:
    text = (
        "**Q1.** 一つ目\n1. a\n**Q2.** 二つ目\n**Q3.** 三つ目\n**Q4.** 四つ目\n\n"
        + BLOCK.format(state="waiting")
    )
    q = parse(text)
    assert q is not None
    assert q.summary == "一つ目 / 二つ目 / 三つ目"


def test_summary_falls_back_to_first_prose_line() -> None:
    text = "# 見出し\n\n- 箇条書きは飛ばす\n\nこの方針で進めてよいですか\n\n" + BLOCK.format(
        state="waiting"
    )
    q = parse(text)
    assert q is not None
    assert q.summary == "この方針で進めてよいですか"


def test_summary_is_truncated() -> None:
    q = parse("Q1. " + "あ" * 400 + "\n\n" + BLOCK.format(state="waiting"))
    assert q is not None
    assert q.summary is not None
    assert len(q.summary) == MAX_SUMMARY_CHARS
    assert q.summary.endswith("…")


def test_summary_none_when_no_question_text() -> None:
    q = parse(BLOCK.format(state="waiting"))
    assert q is not None
    assert q.summary is None


# -- robustness -------------------------------------------------------------


def test_inline_comments_are_stripped_but_url_fragment_kept() -> None:
    text = "Q1. x\n\n" + BLOCK.format(state="waiting            # waiting / resolved")
    q = parse(text)
    assert q is not None
    assert q.comment_url is not None
    assert q.comment_url.endswith("#comment-17bfcbca")


def test_crlf_and_bom_are_handled(tmp_path: Path) -> None:
    path = tmp_path / NAME
    path.write_bytes(b"\xef\xbb\xbf" + WAITING.replace("\n", "\r\n").encode("utf-8"))
    q = parse_ask_file(str(path), NAME)
    assert q is not None
    assert q.summary == "どちらの色が好きですか？ 1. 赤 2. 青"
    assert q.posted_at == "2026-10-21T04:12:47Z"


def test_missing_fields_become_none() -> None:
    q = parse("Q1. x\n\n#### 待機状態\n- state: waiting\n")
    assert q is not None
    assert (q.comment_url, q.posted_at, q.deadline) == (None, None, None)


@pytest.mark.parametrize("bad", ["yesterday", "2026-13-40T00:00:00Z", "2026-10-21T04:12:47"])
def test_invalid_or_naive_dates_become_none(bad: str) -> None:
    q = parse(WAITING.replace("2026-10-21T04:12:47Z", bad))
    assert q is not None
    assert q.posted_at is None


def test_empty_file_returns_none(tmp_path: Path) -> None:
    path = tmp_path / NAME
    path.write_text("", encoding="utf-8")
    assert parse_ask_file(str(path), NAME) is None


def test_mismatched_filename_returns_none(tmp_path: Path) -> None:
    path = tmp_path / "ask-notes.md"
    path.write_text(WAITING, encoding="utf-8")
    assert parse_ask_file(str(path), path.name) is None


def test_unreadable_file_returns_none(tmp_path: Path) -> None:
    assert parse_ask_file(str(tmp_path / NAME), NAME) is None  # missing
    (tmp_path / "dir").mkdir()
    assert parse_ask_file(str(tmp_path / "dir"), NAME) is None  # a directory


def test_invalid_utf8_does_not_raise(tmp_path: Path) -> None:
    path = tmp_path / NAME
    path.write_bytes(b"\xff\xfe Q1. x\n\n" + BLOCK.format(state="waiting").encode("utf-8"))
    assert parse_ask_file(str(path), NAME) is not None


def test_half_written_block_does_not_raise() -> None:
    assert parse("Q1. x\n\n#### 待機状態\n- sta") is None


def test_control_characters_are_removed() -> None:
    q = parse("Q1. a\x1b[31mred\x07\tb\n\n" + BLOCK.format(state="waiting"))
    assert q is not None
    assert q.summary == "a[31mred b"


def test_c1_and_bidi_controls_are_removed() -> None:
    text = "Q1. a\x9b31m\x85b‮c⁦d⁩e‪\n\n" + BLOCK.format(state="waiting")
    q = parse(text)
    assert q is not None
    assert q.summary == "a31mbcde"


# -- hostile structure --------------------------------------------------------

HUGE_ROUND = "9" * 5000


def test_huge_round_number_does_not_raise() -> None:
    text = WAITING + f"\n## 往復 {HUGE_ROUND}\n\nQ1. 次の質問\n\n" + BLOCK.format(state="waiting")
    q = parse(text)
    assert q is not None
    assert q.round == 1, "an out-of-range round heading is not a round heading"


def test_four_digit_round_number_is_read() -> None:
    text = WAITING + "\n## 往復 1234\n\nQ1. 次の質問\n\n" + BLOCK.format(state="waiting")
    q = parse(text)
    assert q is not None
    assert q.round == 1234
    assert q.summary == "次の質問"


@pytest.mark.parametrize("fence", ["```", "~~~", "````"])
def test_fake_waiting_block_inside_fence_is_ignored(fence: str) -> None:
    text = RESOLVED + f"\n{fence}markdown\n" + BLOCK.format(state="waiting") + f"{fence}\n"
    assert parse(text) is None


def test_unclosed_fence_hides_fake_block() -> None:
    assert parse(RESOLVED + "\n```\n" + BLOCK.format(state="waiting")) is None


def test_fence_with_other_marker_does_not_close() -> None:
    text = RESOLVED + "\n```\n~~~\n" + BLOCK.format(state="waiting") + "```\n"
    assert parse(text) is None


def test_waiting_block_after_closed_fence_is_used() -> None:
    text = "Q1. 本物\n\n```\n#### 待機状態\n- state: resolved\n```\n\n" + BLOCK.format(
        state="waiting"
    )
    q = parse(text)
    assert q is not None
    assert q.summary == "本物"


def test_round_heading_inside_fence_is_ignored() -> None:
    text = "Q1. 本物\n\n```\n## 往復 7\n```\n\n" + BLOCK.format(state="waiting")
    q = parse(text)
    assert q is not None
    assert q.round == 1


@pytest.mark.parametrize("hashes", ["###", "#####", "##"])
def test_wait_heading_at_other_levels_is_ignored(hashes: str) -> None:
    text = RESOLVED + "\n" + BLOCK.format(state="waiting").replace("####", hashes, 1)
    assert parse(text) is None


@pytest.mark.parametrize("closer", ["```x", "``` x", "```~"])
def test_fence_closer_with_info_text_does_not_close(closer: str) -> None:
    text = RESOLVED + f"\n```\n{closer}\n" + BLOCK.format(state="waiting") + "```\n"
    assert parse(text) is None


def test_fence_closer_with_trailing_spaces_closes() -> None:
    text = "Q1. 本物\n\n```\n- state: resolved\n```   \n\n" + BLOCK.format(state="waiting")
    q = parse(text)
    assert q is not None
    assert q.summary == "本物"


def test_fields_inside_fence_in_block_are_ignored() -> None:
    text = (
        "Q1. x\n\n#### 待機状態\n```\n- state: waiting\n- comment_url: https://evil.example/\n```\n"
        "- state: resolved\n"
    )
    assert parse(text) is None


def test_heading_inside_fence_does_not_end_block() -> None:
    text = "Q1. x\n\n#### 待機状態\n```\n#### 回答\n```\n- state: waiting\n"
    assert parse(text) is not None


@pytest.mark.parametrize("title", ["往復 3 の補足", "往復 3x", "往復 3.5"])
def test_round_heading_with_trailing_text_is_not_a_round(title: str) -> None:
    text = WAITING + f"\n## {title}\n\nQ1. 次の質問\n\n" + BLOCK.format(state="waiting")
    q = parse(text)
    assert q is not None
    assert q.round == 1


def test_round_heading_with_trailing_spaces_is_a_round() -> None:
    text = WAITING + "\n## 往復 3   \n\nQ1. 次の質問\n\n" + BLOCK.format(state="waiting")
    q = parse(text)
    assert q is not None
    assert q.round == 3


def test_heading_closing_hashes_are_stripped() -> None:
    text = "Q1. x\n\n#### 待機状態 ####  \n- state: waiting\n"
    assert parse(text) is not None


def test_oversized_file_returns_none(tmp_path: Path) -> None:
    path = tmp_path / NAME
    path.write_bytes(WAITING.encode("utf-8") + b"x" * (asklog.MAX_READ_BYTES + 1))
    assert parse_ask_file(str(path), NAME) is None


def test_file_at_size_limit_is_parsed(tmp_path: Path) -> None:
    head = WAITING.encode("utf-8")
    path = tmp_path / NAME
    path.write_bytes(b" " * (asklog.MAX_READ_BYTES - len(head) - 1) + b"\n" + head)
    assert parse_ask_file(str(path), NAME) is not None


def test_overlong_line_is_truncated() -> None:
    q = parse("Q1. " + "a" * 10_000 + "\n\n" + BLOCK.format(state="waiting"))
    assert q is not None
    assert q.summary is not None
    assert len(q.summary) <= MAX_SUMMARY_CHARS


def test_unclosed_html_comment_keeps_following_text() -> None:
    q = parse("Q1. a<!-- b\n\n" + BLOCK.format(state="waiting"))
    assert q is not None
    assert q.summary == "a<!-- b"


def test_html_comments_are_removed_across_lines() -> None:
    q = parse(
        "<!--\n#### 待機状態\n- state: resolved\n-->Q1. a<!--x-->b\n\n"
        + BLOCK.format(state="waiting")
    )
    assert q is not None
    assert q.summary == "ab"


# -- ReDoS regressions (team-review round 2) ----------------------------------
# Each input took 40+ seconds with the old backtracking regexes.

TIME_BUDGET_S = 0.5


def _timed_parse(text: str) -> float:
    started = time.perf_counter()
    parse(text)
    return time.perf_counter() - started


@pytest.fixture
def no_line_cap(monkeypatch: pytest.MonkeyPatch) -> None:
    """Disable the per-line cap so the regexes themselves are exercised."""
    monkeypatch.setattr(asklog, "MAX_LINE_CHARS", 10**7)


@pytest.mark.usefixtures("no_line_cap")
@pytest.mark.parametrize(
    "text",
    [
        pytest.param("#" + " " * 2000 + "x", id="heading-2000-spaces"),
        pytest.param("####" + " " * 100_000 + "#" * 100 + " " * 100 + "x", id="heading-100k"),
        pytest.param("#### 待機状態\n- state:" + " " * 100_000 + "x", id="field-100k-spaces"),
        pytest.param("#### 待機状態\n- state: waiting" + " #" * 50_000, id="inline-comment-100k"),
        pytest.param("<!--" * 60_000, id="unclosed-html-comment-60k"),
        pytest.param("- 質問: a" + " " * 100_000 + "x", id="summary-question-100k"),
        pytest.param("Q1. a" + " " * 100_000 + "x", id="summary-q-100k"),
        pytest.param("## 往復" + " " * 100_000 + "1x", id="round-100k"),
        pytest.param(" " * 100_000 + "x", id="fence-100k-spaces"),
    ],
)
def test_pathological_line_parses_quickly(text: str) -> None:
    assert _timed_parse(text + "\n\n" + BLOCK.format(state="waiting")) < TIME_BUDGET_S


def test_worst_case_file_at_size_limit_parses_quickly() -> None:
    unit = "#" + " " * 2000 + "x\n- state:" + " " * 2000 + "x\n" + "<!--" * 500 + "\n"
    body = unit * (asklog.MAX_READ_BYTES // len(unit))
    text = "#### 待機状態\n- state: waiting\n" + body
    assert len(text.encode("utf-8")) <= asklog.MAX_READ_BYTES + 64
    assert _timed_parse(text) < TIME_BUDGET_S
