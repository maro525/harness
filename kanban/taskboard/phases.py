"""Phase derivation.

The `status:` field alone cannot drive this board. In a survey of 1,449 real
TASK_FILEs, 338 (23%) declared a phase behind what the file actually contained
-- e.g. `status: planning` on a file whose `## Deploy` section already holds a
merged PR URL. That is expected rather than exceptional: when `/startproject`
runs in one agent and `/team-implement` in another, nobody owns the `status:`
line, because only `/orchestrate` ever wrote it.

So a card's column is the furthest-along of two independent signals:

  declared  -- the normalized `status:` field
  evidence  -- which process sections hold real content, plus (in files
               written before the Decision Log was dropped) which Decision
               Log entry prefixes are present

with one asymmetry: `done` is a claim about intent that no amount of file
content can prove, so only `declared` may assert it.

Evidence has one cap of its own. When the latest `## team-review` round is a
FAIL, the task has been sent back at Gate 2 and is being reworked (or is
waiting to be reviewed again): the review content is evidence of
`implementing`, not of `review`. Without that cap every sent-back task would
show up in the review column flagged stale.
"""

from __future__ import annotations

import re

from .model import PHASE_RANK, Card, ParsedTask, Phase

#: Ordered longest-match-first. The first pattern that matches wins, so more
#: specific states must precede the generic ones they contain.
_STATUS_RULES: tuple[tuple[re.Pattern[str], Phase], ...] = (
    (re.compile(r"\b(?:done|complete|completed|closed|shipped|finished)\b"), "done"),
    # `in-review` / `pr-open` mean the PR is open and awaiting merge -- the
    # state /orchestrate leaves a task in -- so they belong to deploy, not to
    # the review phase (`reviewing`).
    (
        re.compile(
            r"\b(?:deploy|deployed|deploying|merged|merging|released|"
            r"in[-_ ]?review|pr[-_ ]?open)\b"
        ),
        "deploy",
    ),
    (
        re.compile(
            r"\b(?:reviewing|reviewed|review|awaiting[-_ ]?review|ready[-_ ]?for[-_ ]?review)\b"
        ),
        "review",
    ),
    # `implemented` means the implementation is finished, so the task now sits
    # in review -- not in `implementing`.
    (re.compile(r"\b(?:implemented|ready[-_ ]?for[-_ ]?commit|committed)\b"), "review"),
    (
        re.compile(
            r"\b(?:implementing|in[-_ ]?progress|in[-_ ]?flight|wip|"
            r"active|coding|building)\b"
        ),
        "implementing",
    ),
    (re.compile(r"\b(?:planning|planned|plan|proposal|draft|todo|backlog|new)\b"), "planning"),
)

#: Evidence rules, checked from the furthest-along phase backwards. A phase is
#: reached when one of its sections holds real content or its skill logged a
#: decision. Sections are named after the process that fills them
#: (`## team-implement`); the older names (`## Implementation Notes`) and the
#: Decision Log tags are still accepted so existing files keep their column.
_EVIDENCE_RULES: tuple[tuple[Phase, frozenset[str], str], ...] = (
    ("deploy", frozenset({"deploy"}), "deploy"),
    ("review", frozenset({"team-review", "review"}), "team-review"),
    ("implementing", frozenset({"team-implement", "implementation notes"}), "team-implement"),
    ("planning", frozenset({"startproject", "brief"}), "startproject"),
)

#: Markdown emphasis to drop before matching. Underscore is deliberately *not*
#: here: deleting it would weld `in_review` into `inreview` and destroy the very
#: word boundaries the rules rely on. Separators are turned into spaces instead.
_NOISE = str.maketrans("", "", "*`")

#: Separates the status claim from trailing commentary about it.
_COMMENTARY = re.compile(r"[(（\[【,、;；—–]|\s-\s")


def normalize_status(status_raw: str | None) -> Phase | None:
    """Map a freeform `status:` value onto a phase, or None if unrecognized.

    Handles the real-world spread: `done`, `completed`, `in-review`,
    `in_review`, `in review`, `implemented`, `pr-open`, plus markdown emphasis
    and trailing commentary such as `done (PR #24 In Review)`.

    Trailing commentary is a hazard: `done (PR #24 In Review)` must classify as
    `done`, not `review`. Rule order handles that, since `done` is checked
    first.
    """
    if not status_raw:
        return None
    text = status_raw.translate(_NOISE).strip().lower()
    if not text:
        return None

    # The leading token is the claim; anything after an opening bracket or dash
    # is commentary, and the commentary frequently *negates* a later phase --
    # `implemented（deploy 未実行）`, `in review (PR open, NOT merged)`,
    # `pr-open (merge / modal deploy pending approval)`. Searching the whole
    # string would let `deploy` win in all of those. These rules cannot read
    # negation, so they only get to see the commentary when the head says
    # nothing recognizable at all.
    head = _COMMENTARY.split(text, maxsplit=1)[0]
    for candidate in (head, text):
        # Underscores are word characters, so `implemented_pending_device_review`
        # would not match `\breview\b`. Normalize separators to spaces first.
        normalized = re.sub(r"[_/]+", " ", candidate)
        for pattern, phase in _STATUS_RULES:
            if pattern.search(normalized):
                return phase
    return None


def _sent_back(task: ParsedTask) -> bool:
    """True when the latest review round failed and nothing has passed since.

    The round counts are deliberately not compared: a rework round written
    under `## team-implement` does not turn the failed review into evidence of
    `review`. Only a new review round does, and it carries its own verdict.
    """
    return task.latest_review_verdict == "FAIL"


def evidence_phase(task: ParsedTask) -> Phase | None:
    """Derive the furthest phase the file shows actual evidence of reaching.

    Never returns `done`: completion is a declaration, not something the
    presence of content can demonstrate.
    """
    for phase, sections, tag in _EVIDENCE_RULES:
        if sections & task.filled_sections or tag in task.decision_tags:
            if phase == "review" and _sent_back(task):
                return "implementing"
            return phase
    # Legacy: a `## Design` section alone still means planning happened.
    if "design" in task.filled_sections or "orchestrate" in task.decision_tags:
        return "planning"
    return None


def classify(task: ParsedTask) -> Card:
    """Place a parsed task into a column and flag a stale `status:` field."""
    declared = normalize_status(task.status_raw)
    evidence = evidence_phase(task)

    if declared is None and evidence is None:
        return Card(task, "unknown", None, None, stale_status=False)

    if declared == "done":
        # Terminal. Evidence can never override a completion claim.
        return Card(task, "done", declared, evidence, stale_status=False)

    if declared is None:
        assert evidence is not None
        return Card(task, evidence, None, evidence, stale_status=False)

    if evidence is None:
        return Card(task, declared, declared, None, stale_status=False)

    declared_rank = PHASE_RANK[declared]
    evidence_rank = PHASE_RANK[evidence]
    if evidence_rank > declared_rank:
        # The file has moved on but nobody updated `status:` -- surface it.
        return Card(task, evidence, declared, evidence, stale_status=True)
    return Card(task, declared, declared, evidence, stale_status=False)
