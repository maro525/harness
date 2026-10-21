"""Parser for the ask logs written by orchestrate's question relay.

`/orchestrate` posts questions to the Linear issue and records each one in
`.claude/logs/ask-{LINEAR_ID}-{phase}-{YYYYMMDD-HHMM}.md`: the question text,
then a `#### 待機状態` block of `- key: value` lines. Later rounds are appended
to the same file under `## 往復 {r}` and get a fresh block, so the *last* block
in the file is the current one. When an answer arrives the block flips to
`state: resolved`.

Only `state: waiting` matters to the board. Like the TASK_FILE parser this
never raises: other agents rewrite these files while the board reads them, and
a half-written log must simply not show up rather than break the scan.

Everything read here is untrusted (the logs quote Linear content). Values are
passed through as plain strings, length-capped; the client escapes them and
decides which URLs may become links.

Because the input is hostile, every regex here must run in linear time: no
quantifier may be followed by another that can match the same characters
(`\\s*(.*?)\\s*$` and friends backtrack quadratically or worse). Trimming is
done with `str.strip()` and comments are located with `str.find()` instead.
Each line is also capped at `MAX_LINE_CHARS` as a second line of defence.
"""

from __future__ import annotations

import re
from datetime import datetime

from .model import PendingQuestion

ASK_PREFIX = "ask-"
ASK_SUFFIX = ".md"

#: `ask-{LINEAR_ID}-{phase}-{YYYYMMDD-HHMM}.md`. Phase names are short slugs
#: (`plan`, `startproject`, `gate2`, `mode`, test runs like `e2e2`); the stamp
#: is anchored at the end so a hyphenated phase still splits correctly.
ASK_NAME_RE = re.compile(
    r"\Aask-(?P<linear_id>[A-Za-z][A-Za-z0-9]*-\d+)-(?P<phase>[A-Za-z0-9_][A-Za-z0-9_-]*?)"
    r"-(?P<stamp>\d{8}-\d{4})\.md\Z"
)

WAIT_HEADING = "待機状態"
#: `####` sections that are bookkeeping, not question text.
NON_QUESTION_HEADINGS: frozenset[str] = frozenset({WAIT_HEADING, "回答", "state"})

#: Ask logs are a few KB. Anything larger is not one and is skipped whole
#: (parsing a truncated prefix could pick up a stale block).
MAX_READ_BYTES = 256 * 1024
#: Lines longer than this are truncated before any regex sees them.
MAX_LINE_CHARS = 4096
MAX_SUMMARY_CHARS = 160
MAX_SUMMARY_ITEMS = 3
MAX_FIELD_CHARS = 500
WAITING = "waiting"

#: Every `\s*` / `\s+` below is followed by a token it cannot match, and each
#: pattern ends in a single `(.*)$`, so matching is linear (see module doc).
#: ATX heading. The title (group 2) is trimmed in `_heading`, not here.
_HEADING_RE = re.compile(r"^(#{1,6})\s(.*)$")
#: `- key: value`. The value (group 2) is trimmed in `_read_fields`.
_FIELD_RE = re.compile(r"^\s*[-*]\s+([A-Za-z_][A-Za-z0-9_]*)\s*:(.*)$")
#: Round numbers are small. Bounding the digits keeps `int()` well clear of
#: Python's int-from-string digit limit (a huge number in an untrusted log
#: would otherwise raise ValueError out of the parser). Matched against the
#: already-trimmed heading title, so nothing may follow the number.
_ROUND_RE = re.compile(r"^往復\s*([0-9]{1,4})$")
WAIT_HEADING_LEVEL = 4
#: Opening/closing code fence: three or more backticks or tildes.
_FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
#: Summary items. The captured text is trimmed in `_collect`.
_SUMMARY_QUESTION_RE = re.compile(r"^\s*[-*]\s*質問\s*[:：](.*)$")
_SUMMARY_Q_RE = re.compile(r"^\s*(?:\*\*)?Q[0-9]+\s*[.．](?:\*\*)?(.*)$")
HTML_COMMENT_OPEN = "<!--"
HTML_COMMENT_CLOSE = "-->"
#: C0 controls (ESC included), DEL, C1 controls (`\x9b` is a one-byte CSI on
#: some terminals) and the bidi embedding/override/isolate controls, which can
#: visually reorder text. `--print` writes these values to a terminal, where an
#: embedded escape sequence would be interpreted.
_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]")


def parse_ask_name(name: str) -> tuple[str, str, str] | None:
    """Split an ask log filename into (linear_id, phase, stamp), or None."""
    match = ASK_NAME_RE.match(name)
    if match is None:
        return None
    return match.group("linear_id").upper(), match.group("phase"), match.group("stamp")


def parse_ask_file(path: str, name: str) -> PendingQuestion | None:
    """Return the file's question if it is currently waiting, else None."""
    parts = parse_ask_name(name)
    if parts is None:
        return None
    try:
        with open(path, "rb") as handle:
            raw = handle.read(MAX_READ_BYTES + 1)
    except OSError:
        return None
    if len(raw) > MAX_READ_BYTES:
        return None
    text = raw.decode("utf-8-sig", errors="replace")
    return parse_ask_text(text, path, *parts)


def parse_ask_text(
    text: str, path: str, linear_id: str, phase: str, stamp: str
) -> PendingQuestion | None:
    """Parse ask log content. Pure, never raises; None unless state is waiting."""
    normalized = text.replace("\r\n", "\n").replace("\r", "\n").replace("\t", " ")
    lines = [
        _CONTROL_RE.sub("", line[:MAX_LINE_CHARS])
        for line in _strip_html_comments(normalized).split("\n")
    ]
    fenced = _fenced_lines(lines)
    block_at = _last_heading_index(lines, fenced, WAIT_HEADING, WAIT_HEADING_LEVEL)
    if block_at is None:
        return None
    fields = _read_fields(lines, fenced, block_at + 1)
    if fields.get("state", "").lower() != WAITING:
        return None

    round_at, round_no = _current_round(lines, fenced, block_at)
    return PendingQuestion(
        linear_id=linear_id,
        phase=phase,
        stamp=stamp,
        path=path,
        summary=_summarize(lines[round_at:block_at]),
        comment_url=_cap(fields.get("comment_url")),
        posted_at=_iso_or_none(fields.get("posted_at")),
        deadline=_iso_or_none(fields.get("deadline")),
        round=round_no,
    )


def _strip_html_comments(text: str) -> str:
    """Remove `<!-- ... -->` spans; an unclosed `<!--` is kept as text."""
    parts: list[str] = []
    pos = 0
    while True:
        start = text.find(HTML_COMMENT_OPEN, pos)
        if start < 0:
            break
        end = text.find(HTML_COMMENT_CLOSE, start + len(HTML_COMMENT_OPEN))
        if end < 0:
            break
        parts.append(text[pos:start])
        pos = end + len(HTML_COMMENT_CLOSE)
    parts.append(text[pos:])
    return "".join(parts)


def _heading(line: str) -> tuple[int, str] | None:
    """(level, title) of an ATX heading, with the optional closing `#`s removed."""
    match = _HEADING_RE.match(line)
    if match is None:
        return None
    title = match.group(2).strip()
    # CommonMark: a closing run of `#` counts only when preceded by a space.
    without_closer = title.rstrip("#")
    if without_closer != title and (not without_closer or without_closer.endswith(" ")):
        title = without_closer.rstrip()
    return len(match.group(1)), title


def _strip_inline_comment(value: str) -> str:
    """Drop a trailing `# comment` (`state: waiting  # ...`), as in the template.

    Requires whitespace before `#` so `.../NSKETCH-1#comment-abc` survives.
    """
    pos = value.find("#")
    while pos >= 0:
        if pos > 0 and value[pos - 1].isspace():
            return value[:pos]
        pos = value.find("#", pos + 1)
    return value


def _fenced_lines(lines: list[str]) -> list[bool]:
    """Per line: True if it is a code fence line or inside a fenced block.

    Quoted Linear content may contain a fenced sample of a `#### 待機状態`
    block; those lines must not count as structure. As in CommonMark, a fence
    closes on the same character repeated at least as many times with nothing
    but spaces after it; an unclosed fence runs to EOF.
    """
    fenced: list[bool] = []
    opener: str | None = None
    for line in lines:
        match = _FENCE_RE.match(line)
        if opener is None:
            if match is not None:
                opener = match.group(1)
            fenced.append(opener is not None)
            continue
        fenced.append(True)
        if (
            match is not None
            and match.group(1)[0] == opener[0]
            and len(match.group(1)) >= len(opener)
            and not line[match.end() :].strip()
        ):
            opener = None
    return fenced


def _last_heading_index(lines: list[str], fenced: list[bool], title: str, level: int) -> int | None:
    found: int | None = None
    for index, line in enumerate(lines):
        if fenced[index]:
            continue
        heading = _heading(line)
        if heading == (level, title):
            found = index
    return found


def _read_fields(lines: list[str], fenced: list[bool], start: int) -> dict[str, str]:
    """`- key: value` lines from `start` up to the next heading, outside fences."""
    fields: dict[str, str] = {}
    for index in range(start, len(lines)):
        if fenced[index]:
            continue
        line = lines[index]
        if _heading(line) is not None:
            break
        match = _FIELD_RE.match(line)
        if match is None:
            continue
        key = match.group(1).lower()
        value = _strip_inline_comment(match.group(2)).strip()
        # First occurrence wins: a block is written once per state change.
        fields.setdefault(key, value)
    return fields


def _current_round(lines: list[str], fenced: list[bool], block_at: int) -> tuple[int, int]:
    """(start line, round number) of the round the current block belongs to."""
    for index in range(block_at - 1, -1, -1):
        if fenced[index]:
            continue
        heading = _heading(lines[index])
        if heading is None or heading[0] != 2:
            continue
        match = _ROUND_RE.match(heading[1])
        if match is None:
            continue
        try:
            return index + 1, int(match.group(1))
        except ValueError:
            continue
    return 0, 1


def _question_lines(lines: list[str]) -> list[str]:
    """Lines of the round minus bookkeeping sections (待機状態, 回答, STATE)."""
    kept: list[str] = []
    skipping = False
    skip_level = 0
    fenced = _fenced_lines(lines)
    for index, line in enumerate(lines):
        if fenced[index]:
            continue
        heading = _heading(line)
        if heading is not None:
            level, title = heading
            if skipping and level <= skip_level:
                skipping = False
            if title.strip().lower() in NON_QUESTION_HEADINGS:
                skipping, skip_level = True, level
            continue
        if not skipping:
            kept.append(line)
    return kept


def _summarize(lines: list[str]) -> str | None:
    """Up to three question lines: `- 質問:` items, else `Q1.` lines, else prose."""
    body = _question_lines(lines)
    items = _collect(body, _SUMMARY_QUESTION_RE) or _collect(body, _SUMMARY_Q_RE)
    if not items:
        prose = next((line.strip() for line in body if _is_prose(line)), None)
        items = [prose] if prose else []
    if not items:
        return None
    summary = " / ".join(items[:MAX_SUMMARY_ITEMS])
    if len(summary) > MAX_SUMMARY_CHARS:
        summary = summary[: MAX_SUMMARY_CHARS - 1].rstrip() + "…"
    return summary


def _collect(lines: list[str], pattern: re.Pattern[str]) -> list[str]:
    found: list[str] = []
    for line in lines:
        match = pattern.match(line)
        if match is None:
            continue
        value = match.group(1).replace("**", "").strip()
        if value:
            found.append(value)
        if len(found) >= MAX_SUMMARY_ITEMS:
            break
    return found


def _is_prose(line: str) -> bool:
    stripped = line.strip()
    if not stripped:
        return False
    return not stripped.startswith(("-", "*", "|", ">", "+")) and not stripped[0].isdigit()


def _cap(value: str | None) -> str | None:
    if not value:
        return None
    return value[:MAX_FIELD_CHARS]


def _iso_or_none(value: str | None) -> str | None:
    """The value unchanged if it parses as an ISO 8601 datetime, else None."""
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    # A date with no time zone would be read as local time by the browser.
    if parsed.tzinfo is None:
        return None
    return value
