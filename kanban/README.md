# taskboard

A read-only kanban board over the `TASK_FILE` markdown documents that
`/orchestrate` and the `startproject` / `team-implement` / `team-review` /
`deploy` skills write to `.claude/docs/decisions/task-{LINEAR_ID}-{feature}.md`.

Point it at a folder, get a board.

```bash
python3 -m taskboard .claude/docs/decisions --open
```

No dependencies. Python 3.11+ standard library only.

## Install

Install once as an editable tool and `taskboard` works from any directory:

```bash
uv tool install --editable ~/src/harness/kanban
taskboard --recursive ~/src --open
```

`--editable` matters. The tool environment points at this source tree rather
than a copy, so edits here take effect on the next run with no reinstall.
Reinstall only when `pyproject.toml` changes -- a new dependency or a renamed
entry point -- via `uv tool install --editable --force ~/src/harness/kanban`.

Run it on a new machine once per machine; the install lives in
`~/.local/share/uv/tools`, not in this repo.

Without installing, `python3 -m taskboard` still works, but only with this
folder as the working directory.

## Why it exists

`/orchestrate` keeps the whole pipeline in one place, so the `status:` field in
each task file stays accurate. Run the phases in separate agents instead --
`/startproject` in agent A, `/team-implement` in agent B -- and nobody owns that
field any more, because only the orchestrator ever wrote it.

That is not hypothetical. Across 1,449 real task files, **338 (23%)** declared a
phase behind what the file actually contained: `status: planning` on documents
whose `## Deploy` section already held a merged PR URL.

So this board does not trust `status:` on its own. It reads two signals and
takes the furthest-along one, and it tells you when they disagree.

## Usage

```bash
# one folder
python3 -m taskboard .claude/docs/decisions

# several folders
python3 -m taskboard ~/src/proj-a/.claude/docs/decisions ~/src/proj-b/.claude/docs/decisions

# search a whole tree for .claude/docs/decisions folders
python3 -m taskboard --recursive ~/src

# no server, just a summary
python3 -m taskboard --print --recursive ~/src
```

| Flag | Meaning |
|---|---|
| `-r`, `--recursive` | Treat each argument as a tree to search, not a task folder |
| `-p`, `--port` | Port (default 8787) |
| `--host` | Bind address (default `127.0.0.1`) |
| `--poll SECONDS` | Change-detection interval (default 1.0) |
| `--open` | Open a browser on start |
| `--print` | Print a text summary and exit |
| `-v`, `--verbose` | Log HTTP requests |

## How a card gets its column

Columns are `planning → implementing → review → deploy → done`, plus `unknown`
for files with no usable signal.

**Declared** — the `status:` field from `## Meta`, or from YAML frontmatter if
`## Meta` does not define it. Normalized against the values that actually occur
in the wild: `done`, `completed`, `in-review`, `in_review`, `in review`,
`implemented`, `pr-open`, `deployed`, `planning`, `in-progress`, and so on,
including bold/backtick wrapping and trailing commentary like
`done (PR #24 In Review)`. This covers 98.8% of real values; anything else is
treated as no signal rather than guessed at. `in-review` / `pr-open` mean the
PR is open and awaiting merge, so they map to **deploy** (where `/orchestrate`
leaves a finished task); the review phase itself is `reviewing`.

**Evidence** — which process sections hold real content (template comments,
`N/A`, `未着手` and similar placeholders do not count, and neither do bare
headings: a `## startproject` holding only `### Brief / Design / Plan` and
comments is empty): `## startproject`, `## team-implement`, `## team-review`,
`## deploy`. Only the `##` heading decides the section; the `### {m}回目` /
`### 案 {k}` sub-headings and the `利用AI:` / `採用:` lines inside them do not
move a card. Files written before the current layout are still read: the old
section names (`## Brief`, `## Implementation Notes`, `## Review`) count for
the same phases, and so do their Decision Log entry prefixes
(`- [startproject]`, `- [team-implement]`, `- [team-review]`, `- [deploy]`).
Those prefixes are matched only at the start of a list item; a `[deploy]`
mentioned in prose is not evidence that deploy ran.

One cap on evidence: when the latest `### {m}回目` under `## team-review`
carries a FAIL verdict (`**VERDICT: FAIL**`, `#### 判定: FAIL` and the other
spellings in use), the task was sent back at Gate 2, so the review content
counts as evidence of **implementing**, not review. A later `### {m+1}回目`
with a PASS lifts the cap again; a filled `## deploy` always wins over it. The
verdict is the last one written under the highest round number, so a second
AI's PASS on the same round overrides an earlier FAIL. Verdicts and round
numbers are internal to this classification and are not shown on the card.

**The column** is whichever is further along, with one asymmetry: only
`declared` may assert `done`. Completion is a claim about intent, and no amount
of file content can demonstrate it.

When evidence runs ahead of `status:`, the card is flagged **stale** — an amber
badge, and a `--print` listing. That flag is the point of the tool, not a
defect: it shows you exactly which tasks moved on without anyone updating the
file.

## Design notes

**There is no filesystem watcher, deliberately.** Measured on the 1,449-file
corpus:

| operation | time |
|---|---|
| `os.scandir` + `stat` over every file | 6.5 ms |
| read and parse all 11 MB | 55 ms |
| pruned `os.walk` of a whole source tree | 133 ms |
| naive `rglob` of the same tree | 8,400 ms |

A stat sweep at 1 Hz costs under 1% of a core, so a watcher buys nothing — and
it would cost something real. On WSL2, inotify never fires for files on
Windows-mounted `drvfs` paths (`/mnt/c/...`,
[microsoft/WSL#4739](https://github.com/microsoft/WSL/issues/4739), open since
2019), and `watchdog` only falls back to polling when its observer fails to
*initialize*. On drvfs inotify initializes fine and simply stays silent, so a
watcher-based board would stop updating with no error at all. Stat polling
behaves the same on every filesystem.

The `rglob` row is the other half of the lesson: **directory traversal, not
parsing, is the cost.** Scanning targets the folders it is given, and prunes
`node_modules`, `.git`, build output and `worktrees` when asked to discover.
Parsed results are cached on `(mtime_ns, size)`, so a rescan of an unchanged
tree takes ~5 ms.

**Updates** go out as an SSE stream carrying only a version token; the client
then refetches `/api/board` with `If-None-Match`, so an unchanged board costs a
bare `304`. SSE over HTTP/1.1 is capped at 6 connections per origin, so if the
stream cannot be held — most likely because the board is open in many tabs — the
client falls back to polling rather than silently going stale.

**The parser never raises.** Other agents write these files while the board
reads them, so reads tolerate partial content and a file that cannot be
understood shows up as a card with a parse error rather than disappearing.

## Endpoints

| Path | Purpose |
|---|---|
| `/` | The board |
| `/api/board` | JSON snapshot, `ETag` / `If-None-Match` |
| `/events` | SSE change stream |
| `/healthz` | Liveness |

`/api/board` returns one object per card with `phase`, `declaredPhase`,
`evidencePhase` and `staleStatus`, so the classification is inspectable rather
than buried. The review verdict that feeds `evidencePhase` is not exposed.

## Development

```bash
uv run --with pytest python -m pytest tests -q
uvx ruff check . && uvx ruff format --check .
```

The tests encode the malformed shapes found in the real corpus — non-standard
filenames (`task-NOID-…`, `task-adhoc-…`), YAML frontmatter alongside `## Meta`,
freeform `tier:` suffixes, placeholder section bodies, and status strings whose
trailing commentary contradicts the status itself.
