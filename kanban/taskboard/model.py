"""Data model for the task board.

Everything here is immutable: the board is read-only by design, and frozen
dataclasses make it safe to share parsed results across the scanner cache and
the HTTP threads without copying.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal

Phase = Literal["planning", "implementing", "review", "deploy", "done", "unknown"]
Verdict = Literal["PASS", "FAIL"]

#: Column order, lowest to highest. `unknown` is deliberately outside the
#: ordering: it means "no signal", not "before planning".
PHASE_ORDER: tuple[Phase, ...] = (
    "planning",
    "implementing",
    "review",
    "deploy",
    "done",
)

PHASE_RANK: dict[Phase, int] = {name: i for i, name in enumerate(PHASE_ORDER)}

#: Decision Log entry prefixes, e.g. `- [team-implement] POST: ...`. Only
#: files written before the Decision Log was dropped carry these.
DECISION_TAGS: tuple[str, ...] = (
    "orchestrate",
    "startproject",
    "team-implement",
    "team-review",
    "deploy",
)


@dataclass(frozen=True, slots=True)
class ParsedTask:
    """One TASK_FILE, parsed but not yet phase-classified."""

    path: str
    project: str
    task_id: str
    title: str
    tier: str | None
    tier_raw: str | None
    status_raw: str | None
    created: str | None
    branch: str | None
    pr_url: str | None
    #: Section name (lowercased) -> whether it holds real content.
    filled_sections: frozenset[str]
    #: Decision Log entry prefixes actually present, e.g. {"startproject"}.
    decision_tags: frozenset[str]
    mtime: float
    size: int
    parse_error: str | None = None
    #: Verdict of the latest `### {m}回目` under `## team-review` (the last
    #: `VERDICT: PASS|FAIL` line written for the highest round number). A
    #: classification-only signal: it is never serialized to JSON.
    latest_review_verdict: Verdict | None = None


@dataclass(frozen=True, slots=True)
class Card:
    """A ParsedTask placed into a board column."""

    task: ParsedTask
    phase: Phase
    declared_phase: Phase | None
    evidence_phase: Phase | None
    #: True when the evidence in the file is further along than `status:` says.
    stale_status: bool

    def to_json(self) -> dict[str, object]:
        t = self.task
        return {
            "path": t.path,
            "project": t.project,
            "id": t.task_id,
            "title": t.title,
            "tier": t.tier,
            "tierRaw": t.tier_raw,
            "statusRaw": t.status_raw,
            "created": t.created,
            "branch": t.branch,
            "prUrl": t.pr_url,
            "phase": self.phase,
            "declaredPhase": self.declared_phase,
            "evidencePhase": self.evidence_phase,
            "staleStatus": self.stale_status,
            "sections": sorted(t.filled_sections),
            "decisionTags": sorted(t.decision_tags),
            "mtime": t.mtime,
            "parseError": t.parse_error,
        }


@dataclass(frozen=True, slots=True)
class Board:
    """A full snapshot of the board, ready to serialize."""

    cards: tuple[Card, ...]
    roots: tuple[str, ...]
    scanned_at: float
    scan_ms: float
    errors: tuple[str, ...] = field(default=())

    def to_json(self) -> dict[str, object]:
        return {
            "columns": list(PHASE_ORDER) + ["unknown"],
            "cards": [c.to_json() for c in self.cards],
            "roots": list(self.roots),
            "scannedAt": self.scanned_at,
            "scanMs": round(self.scan_ms, 1),
            "projects": sorted({c.task.project for c in self.cards}),
            "tiers": sorted({c.task.tier for c in self.cards if c.task.tier}),
            "errors": list(self.errors),
            "counts": {
                name: sum(1 for c in self.cards if c.phase == name)
                for name in (*PHASE_ORDER, "unknown")
            },
            "staleCount": sum(1 for c in self.cards if c.stale_status),
        }
