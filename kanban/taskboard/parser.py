"""TASK_FILE parser.

Deliberately tolerant. The TASK_FILE format is defined by the /orchestrate
command and the startproject / team-implement / team-review / deploy skills,
but files in the wild drift from it: a survey of 1,449 real files found 70
filenames that do not match `task-{LINEAR_ID}-{feature}.md`, 19 files carrying
a YAML frontmatter block alongside `## Meta`, freeform suffixes on `tier:` and
`status:`, and many extra non-canonical `##` sections.

This module never raises on malformed input. A file it cannot understand comes
back as a ParsedTask with `parse_error` set, so the board can show it rather
than silently dropping it.
"""

from __future__ import annotations

import os
import re

from .model import DECISION_TAGS, ParsedTask, Verdict

_H1 = re.compile(r"^#\s+(.+?)\s*$", re.MULTILINE)
_H2 = re.compile(r"^##\s+(.+?)\s*$", re.MULTILINE)
_FRONTMATTER = re.compile(r"\A---\r?\n(.*?)\r?\n---\r?\n", re.DOTALL)
_HTML_COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)

#: `- key: value` / `* key: value` inside the Meta block.
_META_FIELD = re.compile(r"^[ \t]*[-*][ \t]*([^:\n]{1,40}?)[ \t]*:[ \t]*(.*)$", re.MULTILINE)
_YAML_FIELD = re.compile(r"^([A-Za-z_][\w-]{0,39})[ \t]*:[ \t]*(.*)$", re.MULTILINE)

#: A Decision Log entry prefix, e.g. `- [team-implement] POST: ...`.
#: Anchored to the start of a list item on purpose: matching `[deploy]`
#: anywhere in the document produces false positives (measured on real files).
_DECISION_ENTRY = re.compile(
    r"^[ \t]*[-*][ \t]*[`*_]*\[(" + "|".join(DECISION_TAGS) + r")\]",
    re.MULTILINE | re.IGNORECASE,
)

_PR_URL = re.compile(r"https?://[^\s<>)\]]*?/(?:pull|merge_requests)/\d+")

#: `task-PROJ-1032-some-feature.md` -> ("PROJ-1032", "some-feature")
_FILENAME_WITH_ID = re.compile(r"\Atask-([A-Za-z][A-Za-z0-9]*-\d+)-(.+)\Z")
#: Fallback for `task-NOID-plan-audit.md`, `task-adhoc-foo.md`, ...
_FILENAME_LOOSE = re.compile(r"\Atask-([A-Za-z][\w]*(?:-[A-Z0-9]+)?)-(.+)\Z")

#: Markdown emphasis / code ticks that wrap a value, e.g. `**done**` or
#: `` `feature/x` ``. Stripped from the ends only -- deleting these characters
#: everywhere would turn `in_review` into `inreview` and, worse, corrupt branch
#: names like `feature/my_cool_branch`.
_WRAPPER_CHARS = "*`_ \t\"'"

#: Characters removed wherever they appear, used only for placeholder matching
#: where interior punctuation is irrelevant.
_WRAPPERS = str.maketrans("", "", "*`_")

#: Bodies that are present but say nothing. Treated as an empty section so the
#: evidence-based phase derivation is not fooled by placeholder text.
_PLACEHOLDER = re.compile(
    r"\A(?:n/?a|tbd|-+|—+|未着手|未定|未実施|なし|後述|"
    r"（[^）]*(?:フェーズ|後)で記入）|\([^)]*(?:phase|later)[^)]*\))[。.、,]?\Z",
    re.IGNORECASE,
)

#: A section body shorter than this, after stripping, is very likely a
#: placeholder rather than real content.
_MIN_MEANINGFUL_CHARS = 4

#: A whole line that is a markdown heading (`### Brief`, `#### 判定`). The
#: template ships `## startproject` with its `### Brief / Design / Plan`
#: sub-headings already in place, so headings alone are not content.
_HEADING_LINE = re.compile(r"^[ \t]*#{1,6}[ \t].*$", re.MULTILINE)

#: A fenced code block. Sections quote command examples and sample headings
#: inside fences, and those must not be read as rounds or verdicts. The fence
#: may be longer than three backticks (a ```` fence wraps a ``` example), and
#: the closing fence must be at least as long as the opening one.
_FENCE = re.compile(r"^[ \t]*(`{3,}).*?(?:^[ \t]*\1`*[ \t]*$|\Z)", re.MULTILINE | re.DOTALL)

#: `### {m}回目` -- one implementation or review round. Exactly level three:
#: `#### 判定` and other deeper headings live inside a round.
_ROUND_HEADING = re.compile(r"^###[ \t]+(\d+)回目[ \t]*$", re.MULTILINE)

#: A verdict line in any of the shapes found in real files: `**VERDICT: FAIL**`,
#: `### 判定: FAIL`, `判定: **PASS**`, `#### 判定：FAIL`, `Verdict: PASS`.
_VERDICT = re.compile(
    r"^[ \t]*(?:#{1,6}[ \t]+)?[*_`]*(?:判定|verdict)[*_`]*[ \t]*[:：][ \t]*[*_`]*(PASS|FAIL)\b",
    re.MULTILINE | re.IGNORECASE,
)

#: The team-review template writes `#### 判定: PASS / FAIL` before a verdict is
#: chosen. A line naming both outcomes is that template, not a verdict.
_BOTH_OUTCOMES = re.compile(r"\bPASS\b.*\bFAIL\b|\bFAIL\b.*\bPASS\b", re.IGNORECASE)


def _strip_value(raw: str) -> str:
    """Trim markdown wrappers from the ends of a field value, leaving it intact.

    Interior characters are preserved: `in_review` and `feature/my_cool_branch`
    must survive unchanged.
    """
    return raw.strip().strip(_WRAPPER_CHARS).strip()


def _is_meaningful(body: str) -> bool:
    """True when a section body holds real content rather than a placeholder.

    Template comments and bare headings are removed first: a fresh
    `## startproject` holds `### Brief / Design / Plan` plus comments and
    nothing else, and that must read as empty.
    """
    cleaned = _HEADING_LINE.sub("", _HTML_COMMENT.sub("", body)).strip()
    if len(cleaned) < _MIN_MEANINGFUL_CHARS:
        return False
    # A placeholder is just as much a placeholder when written as a list item:
    # `- N/A` and `- 未着手。` must not count as content.
    cleaned = re.sub(r"\A[-*]\s+", "", cleaned)
    return not _PLACEHOLDER.match(cleaned.translate(_WRAPPERS).strip())


def _strip_fences(body: str) -> str:
    """Drop fenced code blocks so quoted headings and verdicts are not counted."""
    return _FENCE.sub("", body)


def _last_verdict(text: str) -> Verdict | None:
    """The last real verdict line in `text`, or None."""
    verdict: Verdict | None = None
    for match in _VERDICT.finditer(text):
        newline = text.find("\n", match.start())
        line = text[match.start() : newline if newline != -1 else len(text)]
        if _BOTH_OUTCOMES.search(line):
            continue
        verdict = "PASS" if match.group(1).upper() == "PASS" else "FAIL"
    return verdict


def _extract_rounds(body: str) -> tuple[int, Verdict | None]:
    """Return (latest round number, its verdict) for a `## team-review` body.

    The round number is the largest `### {m}回目` present, not the number of
    such headings: reviewing the same round with a second AI adds a second
    `### 2回目`. The verdict is the last one written under that round, so a
    FAIL followed by another AI's PASS on the same round reads as PASS.

    A body without round headings (the older `## Review` layout) is one round
    when it holds content, and its verdict is taken from the whole body.
    """
    text = _strip_fences(body)
    headings = list(_ROUND_HEADING.finditer(text))
    if not headings:
        if not _is_meaningful(text):
            return 0, None
        return 1, _last_verdict(text)

    latest = max(int(match.group(1)) for match in headings)
    verdict: Verdict | None = None
    for index, match in enumerate(headings):
        if int(match.group(1)) != latest:
            continue
        end = headings[index + 1].start() if index + 1 < len(headings) else len(text)
        verdict = _last_verdict(text[match.end() : end]) or verdict
    return latest, verdict


def split_sections(text: str) -> dict[str, str]:
    """Split a document into `## `-delimited sections, keyed by lowercased title.

    Text before the first `##` is ignored. Duplicate headings are concatenated
    rather than overwriting each other.
    """
    sections: dict[str, str] = {}
    matches = list(_H2.finditer(text))
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        key = match.group(1).strip().lower()
        body = text[match.end() : end]
        sections[key] = f"{sections[key]}\n{body}" if key in sections else body
    return sections


def _parse_frontmatter(text: str) -> dict[str, str]:
    match = _FRONTMATTER.match(text)
    if not match:
        return {}
    return {
        key.strip().lower(): _strip_value(value)
        for key, value in _YAML_FIELD.findall(match.group(1))
    }


def _parse_meta_block(meta_body: str) -> dict[str, str]:
    return {
        key.strip().lower(): _strip_value(value) for key, value in _META_FIELD.findall(meta_body)
    }


def _split_filename(stem: str) -> tuple[str | None, str]:
    """Return (task_id, feature) from a `task-...` filename stem.

    Tolerates the ~5% of real filenames that do not carry a `PREFIX-123` id,
    such as `task-NOID-plan-audit` or `task-adhoc-word-network`.
    """
    strict = _FILENAME_WITH_ID.match(stem)
    if strict:
        return strict.group(1), strict.group(2)
    loose = _FILENAME_LOOSE.match(stem)
    if loose:
        return loose.group(1).upper(), loose.group(2)
    if stem.startswith("task-"):
        return None, stem[len("task-") :]
    return None, stem


def _first_token(value: str | None) -> str | None:
    """`M（8 ファイル・複数パターン）` -> `M`; `L (Auto-L: ...)` -> `L`."""
    if not value:
        return None
    token = re.split(r"[\s(（/,、]", value.strip(), maxsplit=1)[0]
    return token.strip() or None


#: A leading `PROJ-1414 — ` or `PROJ-1348 / PROJ-1363 — ` run. Matched
#: generically rather than against the known id, because the H1 sometimes names
#: a different or additional ticket to the one in the filename.
_TITLE_ID_PREFIX = re.compile(
    r"\A[A-Za-z][A-Za-z0-9]*-[0-9A-Z]+(?:\s*[/,、]\s*[A-Za-z][A-Za-z0-9]*-[0-9A-Z]+)*"
    r"\s*[—–\-:]\s+"
)

#: Inline markdown that should not reach the card as literal characters.
_INLINE_MARKDOWN = re.compile(r"(\*\*|__|`)")


def _derive_title(text: str, feature: str, task_id: str | None) -> str:
    match = _H1.search(text)
    if not match:
        return feature.replace("_", " ").replace("-", " ")
    title = match.group(1).strip()
    # `# Task: PROJ-1032 — description` -> `description`
    title = re.sub(r"\A#*\s*task\s*:\s*", "", title, flags=re.IGNORECASE).strip()
    if task_id:
        title = re.sub(
            r"\A" + re.escape(task_id) + r"\s*[—–\-:]\s*", "", title, flags=re.IGNORECASE
        ).strip()
    title = _TITLE_ID_PREFIX.sub("", title).strip()
    # The card shows plain text, so inline emphasis would render as literal
    # asterisks and backticks.
    title = _INLINE_MARKDOWN.sub("", title).strip()
    return title or feature


def project_name(path: str) -> str:
    """Derive a human project label from a TASK_FILE path.

    `/home/dev/src/example-app/.claude/docs/decisions/task-X.md` -> `example-app`
    Falls back to the containing directory name when the path does not follow
    the `.claude/docs/decisions` convention.
    """
    parts = os.path.normpath(path).split(os.sep)
    if ".claude" in parts:
        index = parts.index(".claude")
        if index > 0:
            return parts[index - 1]
    return parts[-2] if len(parts) >= 2 else "unknown"


def parse_text(text: str, path: str, mtime: float, size: int) -> ParsedTask:
    """Parse TASK_FILE content. Never raises."""
    stem = os.path.basename(path)
    stem = stem[:-3] if stem.endswith(".md") else stem
    file_id, feature = _split_filename(stem)

    sections = split_sections(text)
    meta = _parse_meta_block(sections.get("meta", ""))
    front = _parse_frontmatter(text)

    def field(name: str) -> str | None:
        # `## Meta` is authoritative; frontmatter is only a fallback.
        return meta.get(name) or front.get(name) or None

    task_id = file_id or field("linear_id") or stem
    tier_raw = field("tier")
    pr_match = _PR_URL.search(text)

    filled = frozenset(name for name, body in sections.items() if _is_meaningful(body))
    tags = frozenset(m.lower() for m in _DECISION_ENTRY.findall(sections.get("decision log", "")))

    # The process-named section wins; the older `## Review` is only a fallback.
    _, verdict = _extract_rounds(sections.get("team-review") or sections.get("review") or "")

    return ParsedTask(
        path=path,
        project=project_name(path),
        task_id=task_id,
        title=_derive_title(text, feature, file_id),
        tier=_first_token(tier_raw),
        tier_raw=tier_raw,
        status_raw=field("status"),
        created=field("created"),
        branch=field("branch"),
        pr_url=pr_match.group(0) if pr_match else None,
        filled_sections=filled,
        decision_tags=tags,
        mtime=mtime,
        size=size,
        latest_review_verdict=verdict,
    )


def parse_file(path: str, mtime: float, size: int) -> ParsedTask:
    """Read and parse a TASK_FILE, tolerating concurrent writers.

    Other agents write these files while the board reads them, so decoding uses
    `errors="replace"` and any OS error is surfaced on the card instead of
    aborting the scan.
    """
    try:
        with open(path, encoding="utf-8-sig", errors="replace") as handle:
            text = handle.read()
    except OSError as exc:
        return ParsedTask(
            path=path,
            project=project_name(path),
            task_id=os.path.basename(path),
            title=os.path.basename(path),
            tier=None,
            tier_raw=None,
            status_raw=None,
            created=None,
            branch=None,
            pr_url=None,
            filled_sections=frozenset(),
            decision_tags=frozenset(),
            mtime=mtime,
            size=size,
            parse_error=f"read failed: {exc.strerror or exc}",
        )
    return parse_text(text, path, mtime, size)
