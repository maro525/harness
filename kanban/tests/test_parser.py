"""Parser tests, including the malformed shapes found in the real corpus."""

from __future__ import annotations

import textwrap

import pytest

from taskboard.parser import _extract_rounds, parse_text, project_name, split_sections

CANONICAL = textwrap.dedent(
    """\
    # Task: PROJ-1032 — 一覧の並び順が崩れる原因の特定と修正

    ## Meta
    - linear_id: PROJ-1032
    - tier: L
    - created: 2026-07-31
    - status: in-review (PR #87)
    - branch: `feature/proj-sort-fix`

    ## Brief
    Real content here.

    ## Decision Log
    - [startproject] DECISION: chose approach A
    - [team-implement] POST: implemented module X

    ## Design
    <!-- orchestrator が記入 -->

    ## Implementation Notes
    Implemented the thing.

    ## Review
    <!-- team-review が記入 -->

    ## Deploy
    - PR: https://github.com/acme/repo/pull/92
    """
)


def parse(text: str, path: str = "/r/.claude/docs/decisions/task-PROJ-1032-sort-fix.md"):
    return parse_text(text, path, mtime=1.0, size=len(text))


def test_parses_canonical_meta_fields() -> None:
    task = parse(CANONICAL)
    assert task.task_id == "PROJ-1032"
    assert task.tier == "L"
    assert task.status_raw == "in-review (PR #87)"
    assert task.created == "2026-07-31"
    assert task.branch == "feature/proj-sort-fix"


def test_strips_id_prefix_from_title() -> None:
    assert parse(CANONICAL).title == "一覧の並び順が崩れる原因の特定と修正"


def test_extracts_pr_url() -> None:
    assert parse(CANONICAL).pr_url == "https://github.com/acme/repo/pull/92"


def test_comment_only_sections_count_as_empty() -> None:
    task = parse(CANONICAL)
    assert "brief" in task.filled_sections
    assert "implementation notes" in task.filled_sections
    assert "deploy" in task.filled_sections
    # These hold only the template HTML comment.
    assert "design" not in task.filled_sections
    assert "review" not in task.filled_sections


PROCESS_SECTIONS = textwrap.dedent(
    """\
    # Task: ABC-7 — new layout

    ## Meta
    - linear_id: ABC-7
    - tier: M
    - status: reviewing

    ## startproject
    ### Brief
    Goal and scope.
    ### Design
    Chose approach A.
    ### Plan
    1. do it

    ## team-implement
    Implemented the thing.

    ## team-review
    <!-- orchestrator が記入 -->

    ## deploy
    <!-- orchestrator が記入 -->
    """
)


def test_process_named_sections_are_split_on_level_two_only() -> None:
    task = parse(PROCESS_SECTIONS, "/r/.claude/docs/decisions/task-ABC-7-new.md")
    assert "startproject" in task.filled_sections
    assert "team-implement" in task.filled_sections
    # `### Design` stays inside `## startproject`, not a section of its own.
    assert "design" not in task.filled_sections
    assert "team-review" not in task.filled_sections
    assert "deploy" not in task.filled_sections


def test_decision_tags_read_from_list_prefixes_only() -> None:
    assert parse(CANONICAL).decision_tags == frozenset({"startproject", "team-implement"})


def test_decision_tag_in_prose_is_not_counted() -> None:
    """A mention of `[deploy]` in body text must not imply the deploy phase."""
    text = CANONICAL.replace(
        "## Brief\nReal content here.",
        "## Brief\nWe will later run [deploy] and [team-review] as needed.",
    )
    assert "deploy" not in parse(text).decision_tags


@pytest.mark.parametrize(
    ("filename", "expected_id"),
    [
        ("task-PROJ-1032-sort-fix.md", "PROJ-1032"),
        ("task-SHOP-541-seo-update.md", "SHOP-541"),
        ("task-NOID-plan-3tier-audit.md", "NOID"),
        ("task-ADHOC-desktop-alpha2-build.md", "ADHOC"),
        ("task-LOCAL-wordnetwork-20260706.md", "LOCAL"),
        ("task-adhoc-organic-structure.md", "ADHOC"),
        ("task-NOLINEAR-decimal-readout.md", "NOLINEAR"),
        ("task-PROJ-TBD-desktop-app.md", "PROJ-TBD"),
    ],
)
def test_tolerates_nonstandard_filenames(filename: str, expected_id: str) -> None:
    task = parse("# Task: x\n\n## Meta\n- status: done\n", f"/r/.claude/docs/decisions/{filename}")
    assert task.task_id == expected_id


def test_yaml_frontmatter_is_a_fallback_not_an_override() -> None:
    text = textwrap.dedent(
        """\
        ---
        linear_id: SHOP-541
        status: done
        tier: S
        repo: example-site
        ---

        # Task: SHOP-541 — SEO update

        ## Meta
        - linear_id: SHOP-541
        - tier: M
        - status: in-review
        """
    )
    task = parse(text, "/r/.claude/docs/decisions/task-SHOP-541-seo.md")
    # `## Meta` wins where both define a field...
    assert task.tier == "M"
    assert task.status_raw == "in-review"


def test_yaml_frontmatter_fills_gaps_in_meta() -> None:
    text = textwrap.dedent(
        """\
        ---
        status: done
        created: 2026-05-12
        ---

        # Task: SHOP-541 — SEO update

        ## Meta
        - linear_id: SHOP-541
        """
    )
    task = parse(text, "/r/.claude/docs/decisions/task-SHOP-541-seo.md")
    assert task.status_raw == "done"
    assert task.created == "2026-05-12"


@pytest.mark.parametrize(
    ("raw_tier", "expected"),
    [
        ("M", "M"),
        ("M（8 ファイル・複数パターン・中リスク）", "M"),
        ("L (Auto-L: 認証ロジック変更)", "L"),
        ("S（調査・タスク整理のみ）", "S"),
    ],
)
def test_tier_suffix_is_trimmed_but_raw_is_kept(raw_tier: str, expected: str) -> None:
    task = parse(f"# Task: x\n\n## Meta\n- tier: {raw_tier}\n")
    assert task.tier == expected
    assert task.tier_raw == raw_tier


@pytest.mark.parametrize("body", ["未着手。", "N/A", "TBD", "---", "（実装フェーズで記入）", "-"])
def test_placeholder_bodies_count_as_empty(body: str) -> None:
    task = parse(f"# Task: x\n\n## Meta\n- status: done\n\n## Review\n{body}\n")
    assert "review" not in task.filled_sections


def test_project_derived_from_claude_path() -> None:
    assert (
        project_name("/home/d/src/example-app/.claude/docs/decisions/task-A-1-x.md")
        == "example-app"
    )


def test_project_falls_back_to_parent_directory() -> None:
    assert project_name("/tmp/loose/task-A-1-x.md") == "loose"


def test_empty_document_does_not_raise() -> None:
    task = parse("", "/r/.claude/docs/decisions/task-A-1-x.md")
    assert task.task_id == "A-1"
    assert task.filled_sections == frozenset()
    assert task.parse_error is None


def test_duplicate_headings_are_merged() -> None:
    sections = split_sections("## Notes\nfirst\n\n## Notes\nsecond\n")
    assert "first" in sections["notes"]
    assert "second" in sections["notes"]


def test_unknown_sections_are_kept_and_do_not_break_canonical_ones() -> None:
    text = CANONICAL.replace("## Design", "## Verification\nmeasured.\n\n## Design")
    task = parse(text)
    assert "verification" in task.filled_sections
    assert "brief" in task.filled_sections


@pytest.mark.parametrize(
    ("field", "raw", "expected"),
    [
        ("status", "in_review", "in_review"),
        ("status", "**done**", "done"),
        ("status", "`done`", "done"),
        ("branch", "`feature/my_cool_branch`", "feature/my_cool_branch"),
        ("branch", "feature/snake_case_name", "feature/snake_case_name"),
    ],
)
def test_interior_underscores_survive_wrapper_stripping(
    field: str, raw: str, expected: str
) -> None:
    """Stripping `*`/backtick/`_` globally would corrupt branch names."""
    task = parse(f"# Task: x\n\n## Meta\n- {field}: {raw}\n")
    assert getattr(task, "status_raw" if field == "status" else field) == expected


@pytest.mark.parametrize(
    ("h1", "expected"),
    [
        ("# Task: PROJ-1032 — fix the thing", "fix the thing"),
        # The H1 sometimes names a different ticket than the filename.
        ("# Task: PROJ-1414 — 定期実行でデータを同期する", "定期実行でデータを同期する"),
        ("# Task: PROJ-1348 / PROJ-1363 — 画像をインポートする", "画像をインポートする"),
        # Inline markdown must not reach the card as literal characters.
        ("# Task: X-1 — `cache:clear` にガードが無い", "cache:clear にガードが無い"),
        ("# Task: X-1 — **bold** and `code`", "bold and code"),
    ],
)
def test_title_is_cleaned_for_display(h1: str, expected: str) -> None:
    task = parse(f"{h1}\n\n## Meta\n- status: done\n", "/r/.claude/docs/decisions/task-X-1-f.md")
    assert task.title == expected


def test_title_keeps_a_hyphenated_word_that_is_not_an_id() -> None:
    task = parse(
        "# Task: X-1 — auto-reload should not be stripped\n\n## Meta\n- status: done\n",
        "/r/.claude/docs/decisions/task-X-1-f.md",
    )
    assert task.title == "auto-reload should not be stripped"


@pytest.mark.parametrize("body", ["- N/A", "- TBD", "* 未着手。", "- 未実施", "-   N/A"])
def test_placeholder_as_a_list_item_still_counts_as_empty(body: str) -> None:
    task = parse(f"# Task: x\n\n## Meta\n- status: done\n\n## Review\n{body}\n")
    assert "review" not in task.filled_sections


def test_bom_does_not_break_the_title(tmp_path) -> None:
    """A UTF-8 BOM would otherwise defeat the H1 anchor and pick up a later heading."""
    from taskboard.parser import parse_file

    target = tmp_path / "task-X-1-bom.md"
    target.write_text(
        "# Task: X-1 — real title\n\n## Meta\n- status: done\n\n```bash\n# rm -rf /\n```\n",
        encoding="utf-8-sig",
    )
    stat = target.stat()
    task = parse_file(str(target), stat.st_mtime, stat.st_size)
    assert task.title == "real title"


def test_unreadable_file_becomes_a_card_with_a_parse_error(tmp_path) -> None:
    from taskboard.parser import parse_file

    task = parse_file(str(tmp_path / "task-X-1-missing.md"), 1.0, 0)
    assert task.parse_error is not None
    assert task.task_id == "task-X-1-missing.md"


TEMPLATE = textwrap.dedent(
    """\
    # Task: ABC-7 — new layout

    ## Meta
    - linear_id: ABC-7
    - tier: M
    - created: 2026-09-30 00:05
    - status: planning
    - branch:
    - base:

    ## startproject
    ### Brief
    <!-- orchestrator が startproject の返却 BRIEF から記入 -->

    ### Design
    <!-- orchestrator が startproject の返却 DESIGN から記入 -->

    ### Plan
    <!-- orchestrator が startproject の返却 PLAN から記入 -->

    ## team-implement
    <!-- orchestrator が team-implement の返却 IMPLEMENTATION_NOTES から記入 -->

    ## team-review
    <!-- orchestrator が team-review の返却 REVIEW から記入 -->

    ## deploy
    <!-- orchestrator が deploy の返却 DEPLOY から記入 -->
    """
)


def test_untouched_template_has_no_filled_sections() -> None:
    """The STEP 2 template ships sub-headings; headings alone are not content."""
    task = parse(TEMPLATE, "/r/.claude/docs/decisions/task-ABC-7-new.md")
    # `## Meta` is the only section with content; no process section is filled.
    assert task.filled_sections == frozenset({"meta"})
    assert task.latest_review_verdict is None


@pytest.mark.parametrize(
    ("body", "expected"),
    [
        ("### Brief\n<!-- x -->\n\n### Design\n<!-- y -->\n\n### Plan\n<!-- z -->\n", False),
        ("### Brief\nN/A\n", False),
        ("### Plan\n#### 追加依頼 1\n- 依頼日時: x\n", True),
        ("### 案 2\n利用AI: pi（2026-09-28 10:00）\n#### Brief\n本文がここに入る\n", True),
    ],
)
def test_heading_only_sections_are_empty(body: str, expected: bool) -> None:
    task = parse(f"# Task: x\n\n## Meta\n- status: planning\n\n## startproject\n{body}")
    assert ("startproject" in task.filled_sections) is expected


def review_task(review_body: str):
    text = (
        "# Task: x\n\n## Meta\n- status: implementing\n\n"
        f"## team-implement\nImplemented.\n\n## team-review\n{review_body}"
    )
    return parse(text)


def test_review_rounds_take_the_largest_round_number_and_its_verdict() -> None:
    body = (
        "### 1回目\n**VERDICT: FAIL**\n- [major] x\n\n"
        "### 2回目\n**VERDICT: FAIL**\n- [major] y\n\n"
        "### 3回目\n**VERDICT: PASS**\n"
    )
    assert _extract_rounds(body) == (3, "PASS")
    assert review_task(body).latest_review_verdict == "PASS"


def test_same_round_reviewed_twice_uses_the_last_verdict_written() -> None:
    """A second AI reviewing the same round adds a second `### 2回目`."""
    body = (
        "### 1回目\n**VERDICT: PASS**\n\n"
        "### 2回目\n利用AI: pi（2026-09-28 10:00）\n\n#### 判定: FAIL\n\n"
        "### 2回目\n利用AI: codex（2026-09-28 11:00）\n\n#### 判定: PASS\n"
    )
    assert _extract_rounds(body) == (2, "PASS")
    assert review_task(body).latest_review_verdict == "PASS"


def test_round_number_is_the_max_not_the_number_of_headings() -> None:
    body = "### 1回目\n**VERDICT: FAIL**\n\n### 1回目\n**VERDICT: FAIL**\n"
    assert _extract_rounds(body) == (1, "FAIL")


@pytest.mark.parametrize(
    ("line", "expected"),
    [
        ("**VERDICT: FAIL**", "FAIL"),
        ("### 判定: FAIL", "FAIL"),
        ("判定: **FAIL**", "FAIL"),
        ("#### 判定：FAIL", "FAIL"),
        ("Verdict: PASS", "PASS"),
        ("#### 判定: PASS", "PASS"),
        ("- **判定**: PASS", None),
        ("#### 判定: PASS / FAIL", None),
        ("The reviewer wrote VERDICT: FAIL in prose", None),
    ],
)
def test_verdict_line_shapes(line: str, expected: str | None) -> None:
    task = review_task(f"### 1回目\n{line}\n- note\n")
    assert task.latest_review_verdict == expected


def test_verdict_after_the_template_line_still_counts() -> None:
    body = "### 1回目\n#### 判定: PASS / FAIL\n\n**VERDICT: FAIL**\n"
    assert review_task(body).latest_review_verdict == "FAIL"


def test_rounds_and_verdicts_inside_code_fences_are_ignored() -> None:
    body = "### 1回目\n**VERDICT: PASS**\n\n```markdown\n### 9回目\n**VERDICT: FAIL**\n```\n"
    assert _extract_rounds(body) == (1, "PASS")
    assert review_task(body).latest_review_verdict == "PASS"


def test_legacy_review_section_without_round_headings_is_one_round() -> None:
    body = "### 判定: FAIL\n- [major] z\n"
    assert _extract_rounds(body) == (1, "FAIL")
    text = f"# Task: x\n\n## Meta\n- status: implementing\n\n## Review\n{body}"
    assert parse(text).latest_review_verdict == "FAIL"


def test_empty_review_section_has_no_rounds() -> None:
    assert _extract_rounds("<!-- orchestrator が記入 -->\n") == (0, None)
    assert review_task("<!-- orchestrator が記入 -->\n").latest_review_verdict is None


def test_verdict_of_an_earlier_round_is_ignored() -> None:
    """A rework round written without a verdict yet has no verdict, not the old FAIL."""
    body = (
        "### 1回目\n**VERDICT: FAIL**\n\n### 2回目\n利用AI: pi（2026-09-28 10:00）\n\n- pending\n"
    )
    assert _extract_rounds(body) == (2, None)


def test_process_named_section_wins_over_legacy_name() -> None:
    text = (
        "# Task: x\n\n## Meta\n- status: implementing\n\n"
        "## team-review\n### 2回目\n**VERDICT: PASS**\n\n"
        "## Review\n### 判定: FAIL\n"
    )
    assert parse(text).latest_review_verdict == "PASS"


def test_four_backtick_fence_does_not_swallow_the_rest_of_the_section() -> None:
    """A ```` fence wrapping a ``` example must close at ````, not run to the end."""
    body = (
        "### 1回目\n**VERDICT: FAIL**\n\n"
        "````bash\nawk '/^```/{fence=!fence}' f\n````\n\n"
        "### 2回目\n**VERDICT: PASS**\n"
    )
    assert _extract_rounds(body) == (2, "PASS")
