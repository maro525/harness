"""Phase derivation tests.

The cases here are drawn from a survey of 1,449 real TASK_FILEs, so the odd
looking status strings are all values that actually occur.
"""

from __future__ import annotations

import pytest

from taskboard.model import ParsedTask, Verdict
from taskboard.phases import classify, evidence_phase, normalize_status


def make_task(
    *,
    status: str | None = None,
    sections: frozenset[str] = frozenset(),
    tags: frozenset[str] = frozenset(),
    verdict: Verdict | None = None,
) -> ParsedTask:
    return ParsedTask(
        path="/tmp/task-ABC-1-x.md",
        project="p",
        task_id="ABC-1",
        title="t",
        tier="M",
        tier_raw="M",
        status_raw=status,
        created=None,
        branch=None,
        pr_url=None,
        filled_sections=sections,
        decision_tags=tags,
        mtime=0.0,
        size=0,
        latest_review_verdict=verdict,
    )


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("done", "done"),
        ("completed", "done"),
        ("planning", "planning"),
        ("in-progress", "implementing"),
        ("in_progress", "implementing"),
        ("implementing", "implementing"),
        ("in-review", "deploy"),
        ("in_review", "deploy"),
        ("in review", "deploy"),
        ("reviewing", "review"),
        ("review", "review"),
        ("implemented", "review"),
        ("pr-open", "deploy"),
        ("deployed", "deploy"),
        ("merging_and_deploying", "deploy"),
        ("**done**", "done"),
        ("`done`", "done"),
        ("done (PR open)", "done"),
        ("in-review (PR #87)", "deploy"),
        ("completed (deployed 2026-07-23)", "done"),
        ("active", "implementing"),
        ("reviewed", "review"),
        ("ready-for-commit", "review"),
    ],
)
def test_normalize_status_maps_real_world_values(raw: str, expected: str) -> None:
    assert normalize_status(raw) == expected


def test_normalize_status_prefers_done_over_trailing_commentary() -> None:
    # `done (PR #24 In Review)` is done -- the trailing text must not win.
    assert normalize_status("done (PR #24 In Review)") == "done"


def test_normalize_status_handles_underscore_word_boundaries() -> None:
    # Underscores are word characters, so a naive \breview\b would miss this.
    assert normalize_status("implemented_pending_device_review") == "review"


@pytest.mark.parametrize("raw", [None, "", "   ", "???", "🙂"])
def test_normalize_status_returns_none_when_unrecognized(raw: str | None) -> None:
    assert normalize_status(raw) is None


def test_evidence_never_claims_done() -> None:
    task = make_task(
        sections=frozenset({"brief", "design", "implementation notes", "review", "deploy"})
    )
    assert evidence_phase(task) == "deploy"


def test_evidence_uses_decision_log_tags() -> None:
    task = make_task(tags=frozenset({"startproject", "team-implement"}))
    assert evidence_phase(task) == "implementing"


@pytest.mark.parametrize(
    ("sections", "expected"),
    [
        (frozenset({"startproject"}), "planning"),
        (frozenset({"startproject", "team-implement"}), "implementing"),
        (frozenset({"startproject", "team-implement", "team-review"}), "review"),
        (frozenset({"startproject", "team-implement", "team-review", "deploy"}), "deploy"),
    ],
)
def test_evidence_uses_process_named_sections(sections: frozenset[str], expected: str) -> None:
    assert evidence_phase(make_task(sections=sections)) == expected


def test_evidence_none_when_no_signal() -> None:
    assert evidence_phase(make_task()) is None


def test_stale_status_detected_when_evidence_is_ahead() -> None:
    """The headline case: 23% of real files look like this."""
    card = classify(make_task(status="planning", sections=frozenset({"brief", "review", "deploy"})))
    assert card.phase == "deploy"
    assert card.declared_phase == "planning"
    assert card.evidence_phase == "deploy"
    assert card.stale_status is True


def test_declared_wins_when_ahead_of_evidence() -> None:
    card = classify(make_task(status="reviewing", sections=frozenset({"brief"})))
    assert card.phase == "review"
    assert card.stale_status is False


def test_done_is_terminal_and_never_marked_stale() -> None:
    card = classify(make_task(status="done", sections=frozenset({"brief", "implementation notes"})))
    assert card.phase == "done"
    assert card.stale_status is False


def test_evidence_only_when_status_missing() -> None:
    card = classify(make_task(status=None, sections=frozenset({"brief", "implementation notes"})))
    assert card.phase == "implementing"
    assert card.declared_phase is None
    assert card.stale_status is False


def test_declared_only_when_no_evidence() -> None:
    card = classify(make_task(status="planning"))
    assert card.phase == "planning"
    assert card.evidence_phase is None


def test_unknown_when_no_signal_at_all() -> None:
    card = classify(make_task())
    assert card.phase == "unknown"
    assert card.stale_status is False


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        # Trailing commentary frequently NEGATES a later phase. The leading
        # token is the claim; the parenthetical is not. All of these occur in
        # the real corpus and used to classify as `deploy`.
        ("implemented（deploy 未実行）", "review"),
        # `in review` / `pr-open` mean the PR is open and awaiting merge, which
        # is the deploy column -- /orchestrate ends a task in that state.
        ("in review (PR open, NOT merged)", "deploy"),
        ("review passed (deploy 待ち)", "review"),
        ("in_review (deploy 完了・PR #47 オープン / 自動 merge なし)", "deploy"),
        ("pr-open (merge / modal deploy pending approval)", "deploy"),
        ("implemented (awaiting review/deploy)", "review"),
        ("implemented — PR 作成済み / release へのマージと本番デプロイは未実施", "review"),
        # The head still wins when it is the furthest-along token.
        ("done (PR #24 In Review)", "done"),
        ("completed (deployed 2026-07-23)", "done"),
        # ...and the commentary is still consulted when the head says nothing.
        ("wip (in review)", "implementing"),
        ("??? (deployed)", "deploy"),
    ],
)
def test_leading_token_beats_trailing_commentary(raw: str, expected: str) -> None:
    assert normalize_status(raw) == expected


REVIEWED = frozenset({"startproject", "team-implement", "team-review"})


def test_sent_back_at_gate_two_is_implementing_not_stale() -> None:
    """The headline case: status implementing, latest review FAIL, rework pending."""
    card = classify(make_task(status="implementing", sections=REVIEWED, verdict="FAIL"))
    assert card.phase == "implementing"
    assert card.evidence_phase == "implementing"
    assert card.stale_status is False


def test_pass_on_the_latest_round_is_review_evidence() -> None:
    card = classify(make_task(status="reviewing", sections=REVIEWED, verdict="PASS"))
    assert card.phase == "review"
    assert card.evidence_phase == "review"
    assert card.stale_status is False


def test_pass_with_status_left_at_implementing_is_still_stale() -> None:
    """A forgotten `status:` update after PASS must keep being surfaced."""
    card = classify(make_task(status="implementing", sections=REVIEWED, verdict="PASS"))
    assert card.phase == "review"
    assert card.stale_status is True


def test_review_without_a_verdict_line_is_review_evidence() -> None:
    card = classify(make_task(status="implementing", sections=REVIEWED, verdict=None))
    assert card.phase == "review"
    assert card.stale_status is True


def test_sent_back_without_status_is_implementing() -> None:
    card = classify(make_task(status=None, sections=REVIEWED, verdict="FAIL"))
    assert card.phase == "implementing"
    assert card.declared_phase is None
    assert card.stale_status is False


def test_deploy_evidence_beats_the_sent_back_rule() -> None:
    card = classify(make_task(status="in-review", sections=REVIEWED | {"deploy"}, verdict="FAIL"))
    assert card.phase == "deploy"
    assert card.stale_status is False


def test_sent_back_with_status_planning_is_stale_implementing() -> None:
    card = classify(make_task(status="planning", sections=REVIEWED, verdict="FAIL"))
    assert card.phase == "implementing"
    assert card.stale_status is True


def test_sent_back_declared_reviewing_stays_in_review_without_stale() -> None:
    """`reviewing` after a FAIL means the rework is being reviewed again."""
    card = classify(make_task(status="reviewing", sections=REVIEWED, verdict="FAIL"))
    assert card.phase == "review"
    assert card.evidence_phase == "implementing"
    assert card.stale_status is False


def test_legacy_review_section_with_fail_is_also_sent_back() -> None:
    task = make_task(
        status="implementing",
        sections=frozenset({"brief", "implementation notes", "review"}),
        verdict="FAIL",
    )
    assert evidence_phase(task) == "implementing"


def test_decision_log_review_tag_with_fail_is_also_sent_back() -> None:
    task = make_task(
        tags=frozenset({"startproject", "team-implement", "team-review"}), verdict="FAIL"
    )
    assert evidence_phase(task) == "implementing"
