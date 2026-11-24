#!/usr/bin/env python3
"""harness-status — harness の現況を端末で一望する（読み取り専用）。

見るもの（どれも読むだけ。bucket を作る task-file.sh や記録を変える herdr-cleanup.sh は呼ばない）:
  1. Herdr         サーバーの生存と agent 一覧（`herdr status server` / `herdr agent list`）
  2. セッション記録  ~/.cache/harness/herdr-{agents,consult}/*.json と Herdr の実体の突き合わせ
  3. ロック         ~/.local/share/harness/locks/*.lock（lease の更新時刻と TTL。*.lock.guard は数えない）
  4. タスクファイル  ~/.local/share/harness/tasks/<repo>/task-*.md の `## Meta` の status
  5. worktree      ~/.herdr/worktrees/<repo>/<branch>（記録のある・無い）
  6. inbox         ~/.cache/harness/inbox/<boss>/*.md の未読数（既読化しない）
  7. checks        checks/{crossrefs,phases,worktrees}.sh の結果

使い方:
  harness-status.py                 全 repo の件数と要対応項目
  harness-status.py --repo harness  repo で絞る（inbox は boss 単位なので絞らない）
  harness-status.py --all           要対応でない項目も個別に出す
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

JST = timezone(timedelta(hours=9))
HOME = Path.home()
CACHE = Path(os.environ.get("XDG_CACHE_HOME") or HOME / ".cache") / "harness"
DATA = Path(os.environ.get("XDG_DATA_HOME") or HOME / ".local/share") / "harness"
WORKTREE_ROOT = Path(os.environ.get("HERDR_WORKTREE_ROOT") or HOME / ".herdr/worktrees")
HERDR_BIN = os.environ.get("HARNESS_STATUS_HERDR", "herdr")
TASK_FILE_SH = os.environ.get("HARNESS_STATUS_TASKFILE") or str(Path(__file__).resolve().parent / "task-file.sh")
def env_seconds(name: str, default: int) -> int:
    """正の整数の環境変数。空・数値以外・0 以下は既定値に戻す（起動を止めない）。"""
    try:
        value = int(os.environ.get(name, ""))
    except ValueError:
        return default
    return value if value > 0 else default


HERDR_TIMEOUT = env_seconds("HARNESS_STATUS_HERDR_TIMEOUT", 5)
CHECK_TIMEOUT = env_seconds("HARNESS_STATUS_CHECK_TIMEOUT", 60)
DEFAULT_LOCK_TTL = 2700
ACTIVE_STATUSES = ("planning", "implementing", "reviewing", "deploying", "waiting-gate")
CHECK_NAMES = ("crossrefs", "phases", "worktrees")
SHOWN_LIMIT = 10
UNKNOWN = "確認不可"


def run(cmd: list[str], timeout: int) -> tuple[int | None, str]:
    """(exit, 出力)。起動できない・時間切れは exit=None で理由を返す。"""
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL
        )
    except FileNotFoundError:
        return None, "not installed"
    except subprocess.TimeoutExpired:
        return None, f"timeout {timeout}s"
    except OSError as exc:
        return None, str(exc)
    return proc.returncode, proc.stdout + proc.stderr


def tasks_root() -> Path:
    """保存先は task-file.sh に聞く（HARNESS_TASKS_DIR / XDG_DATA_HOME の解決順を再実装しない）。読むだけで何も作らない。"""
    code, out = run(["bash", TASK_FILE_SH, "root"], HERDR_TIMEOUT)
    if code == 0 and out.strip().startswith("/"):
        return Path(out.strip().splitlines()[0])
    return Path(os.environ.get("HARNESS_TASKS_DIR") or DATA / "tasks")


TASKS_ROOT = tasks_root()
LOCKS_ROOT = Path(os.environ.get("HARNESS_LOCKS_DIR") or TASKS_ROOT.parent / "locks")  # task-file.sh と同じ

_KEY_CACHE: dict[str, str] = {}


def repo_key(path: str) -> str:
    """repo の bucket 名。task-file.sh に使い捨ての保存先（/tmp）で `new` させ、出た bucket 名を採る。実際の保存先には何も書かない。"""
    if not path or not Path(path).is_dir():
        return ""
    if path not in _KEY_CACHE:
        key = ""
        with tempfile.TemporaryDirectory(prefix="harness-status.") as tmp:
            env = {**os.environ, "HARNESS_TASKS_DIR": tmp}
            try:
                proc = subprocess.run(
                    ["bash", TASK_FILE_SH, "new", "--feature=probe", f"--repo={path}"],
                    capture_output=True, text=True, timeout=HERDR_TIMEOUT, stdin=subprocess.DEVNULL, env=env,
                )
                if proc.returncode == 0 and proc.stdout.strip():
                    key = Path(proc.stdout.strip().splitlines()[0]).parent.name
            except (OSError, subprocess.TimeoutExpired):
                pass
        _KEY_CACHE[path] = key
    return _KEY_CACHE[path]


def repo_of_path(path: str) -> str:
    """作業場所の repo 名。worktree 置き場の下は <repo>、それ以外は task-file.sh の規則。分からなければ空（所属不明）。"""
    if not path:
        return ""
    try:
        return Path(path).relative_to(WORKTREE_ROOT).parts[0]
    except (ValueError, IndexError):
        return repo_key(path)


def bucket_names(bucket: Path) -> list[str]:
    """bucket の名前。同名 repo の衝突で `<repo>-<cksum>` になったものは、接尾辞を除いた repo 名も返す。"""
    names = [bucket.name]
    m = re.fullmatch(r"(.+)-\d+", bucket.name)
    if m and (bucket / ".origin").is_file():
        names.append(m.group(1))
    return names


def known_repos() -> list[str]:
    try:
        return sorted({n for b in TASKS_ROOT.glob("*") if b.is_dir() for n in bucket_names(b)}, key=len, reverse=True)
    except OSError:
        return []


def repo_of_lock_key(key: str, repos: list[str]) -> str:
    """ロックの key は `<repo>-…`。既知の bucket 名で最長一致させる（cwd は別 repo を指しうるので使わない）。"""
    return next((r for r in repos if key.startswith(r + "-")), "")


def record_path(rec: dict) -> str:
    """セッション記録の作業場所。herdr-agent.sh は repo、consult.sh は cwd に書く。"""
    return str(rec.get("repo") or rec.get("cwd") or "")


def load_json(path: Path) -> dict | None:
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):  # UnicodeDecodeError は ValueError。ファイル単位で握る
        return None
    return data if isinstance(data, dict) else None


CONTROL_CHARS = re.compile(r"[\x00-\x1f\x7f-\x9f]")


def clean(text: str) -> str:
    """保存済みの識別子や診断文に混じる制御文字（端末の表示を改変できる）を潰す。"""
    return CONTROL_CHARS.sub("?", text)


def head(title: str, summary: str) -> None:
    print(f"\n■ {clean(title)}  {clean(summary)}")


def listed(lines: list[str], full: bool) -> None:
    shown = lines if full else lines[:SHOWN_LIMIT]
    for line in shown:
        print(f"  {clean(line)}")
    if len(lines) > len(shown):
        print(f"  … 他 {len(lines) - len(shown)} 件（--all で全件）")


# --- 1. Herdr ---------------------------------------------------------------


def herdr_agents() -> tuple[str, dict[str, dict] | None]:
    """(サーバーの1行, name -> agent)。接続できなければ agents は None（停止とは断定しない）。"""
    code, out = run([HERDR_BIN, "status", "server"], HERDR_TIMEOUT)
    if code is None:
        return f"{UNKNOWN}（{out}）", None
    state = next((ln.split(":", 1)[1].strip() for ln in out.splitlines() if ln.startswith("status:")), "")
    if code != 0 or state != "running":
        return f"{UNKNOWN}（status={state or 'なし'} exit={code}）", None
    code, out = run([HERDR_BIN, "agent", "list"], HERDR_TIMEOUT)
    try:
        agents = json.loads(out)["result"]["agents"]
    except (ValueError, KeyError, TypeError):
        agents = None
    if code != 0 or not isinstance(agents, list):
        return f"running（agent 一覧は{UNKNOWN}: exit={code}）", None
    return "running", {a["name"]: a for a in agents if isinstance(a, dict) and a.get("name")}


def section_herdr(agents: dict[str, dict] | None, server: str, repo: str | None, full: bool) -> None:
    if agents is None:
        head("Herdr", server)
        return
    shown = {n: a for n, a in agents.items() if not repo or repo_of_path(str(a.get("cwd") or "")) == repo}
    counts = Counter(str(a.get("agent_status", "?")) for a in shown.values())
    head("Herdr", f"{server} / 名前付き agent {len(shown)} 件（{', '.join(f'{k} {v}' for k, v in sorted(counts.items())) or 'なし'}）")
    lines = [
        f"{a.get('agent_status', '?'):<8} {n}  {a.get('cwd', '')}"
        for n, a in shown.items()
        if full or a.get("agent_status") == "working"
    ]
    listed(lines, full)


# --- 2. セッション記録 --------------------------------------------------------


def section_sessions(agents: dict[str, dict] | None, repo: str | None, full: bool) -> None:
    rows: list[tuple[str, str, str, str]] = []  # (kind, name, state, repo)
    for kind in ("herdr-agents", "herdr-consult"):
        for path in sorted((CACHE / kind).glob("*.json")):
            rec = load_json(path)
            if rec is None:
                rows.append((kind, path.stem, "不正な記録", ""))
                continue
            name = str(rec.get("agent") or path.stem)
            where = record_path(rec)
            rec_repo = repo_of_path(where) if where else ""
            state = UNKNOWN if agents is None else ("live" if name in agents else "gone")
            rows.append((kind, name, state, rec_repo))
    if repo:
        rows = [r for r in rows if r[3] == repo]
    counts = Counter(r[2] for r in rows)
    head("セッション記録", f"{len(rows)} 件（{', '.join(f'{k} {v}' for k, v in sorted(counts.items())) or 'なし'}）")
    listed([f"{state:<8} {name}  [{kind}] {r}" for kind, name, state, r in rows if state != "live" or full], full)


# --- 3. ロック ---------------------------------------------------------------


def parse_ttl(raw: str) -> int:
    m = re.fullmatch(r"(\d+)([smh]?)", raw.strip())
    if not m:
        return DEFAULT_LOCK_TTL
    return int(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600}[m.group(2)]


def section_locks(repo: str | None, full: bool) -> None:
    now = time.time()
    repos = known_repos()
    rows: list[tuple[str, str]] = []  # (state, text)
    for path in sorted(LOCKS_ROOT.glob("*.lock")):  # *.lock.guard は拡張子が違うので拾わない
        try:
            fields = dict(ln.split("=", 1) for ln in path.read_text().splitlines() if "=" in ln)
        except (OSError, ValueError):
            if not repo or repo_of_lock_key(path.stem, repos) == repo:  # 読めなくてもファイル名で所属を決める
                rows.append(("不正", path.name))
            continue
        if repo and repo_of_lock_key(fields.get("key", path.stem), repos) != repo:
            continue
        try:
            age = int(now - int(fields["updated_epoch"]))
        except (KeyError, ValueError):
            rows.append(("不正", f"{path.name}（updated_epoch が読めない）"))
            continue
        ttl = parse_ttl(fields.get("ttl", ""))
        state = "expired" if age > ttl else "live"
        rows.append((state, f"{fields.get('key', path.stem)}  {age}s / ttl {ttl}s  holder {fields.get('runner', '?')}"))
    counts = Counter(s for s, _ in rows)
    head("ロック", f"{len(rows)} 件（{', '.join(f'{k} {v}' for k, v in sorted(counts.items())) or 'なし'}）")
    listed([f"{s:<8} {t}" for s, t in rows if s != "live" or full], full)


# --- 4. タスクファイル --------------------------------------------------------


def task_status(path: Path) -> str:
    try:
        text = path.read_text()
    except (OSError, ValueError):
        return "不正"
    meta = re.search(r"^## Meta[ \t]*\n(.*?)(?=^## |\Z)", text, re.MULTILINE | re.DOTALL)
    m = re.search(r"^- status:[ \t]*(.*)$", meta.group(1), re.MULTILINE) if meta else None
    return m.group(1).strip() if m and m.group(1).strip() else "未記入"


def section_tasks(repo: str | None, full: bool) -> None:
    rows: list[tuple[str, str, str]] = []  # (repo, file, status)
    try:
        buckets = sorted(p for p in TASKS_ROOT.glob("*") if p.is_dir())
    except OSError:
        buckets = []
    for bucket in buckets:
        names = bucket_names(bucket)
        if repo and repo not in names:
            continue
        for path in sorted(bucket.glob("task-*.md")):
            rows.append((names[-1], path.name, task_status(path)))
    active = [r for r in rows if r[2].startswith(ACTIVE_STATUSES)]
    by_repo = Counter(r[0] for r in rows)
    head("タスクファイル", f"{len(rows)} 件 / 実行中 {len(active)} 件（repo: {', '.join(f'{k} {v}' for k, v in sorted(by_repo.items())) or 'なし'}）")
    listed([f"{st:<14} {name}  [{r}]" for r, name, st in (rows if full else active)], full)


# --- 5. worktree -------------------------------------------------------------


def section_worktrees(repo: str | None, full: bool) -> None:
    in_use: list[Path] = []
    for kind in ("herdr-agents", "herdr-consult"):
        for path in (CACHE / kind).glob("*.json"):
            rec = load_json(path)
            if rec and record_path(rec):
                in_use.append(Path(record_path(rec)))
    rows: list[tuple[str, str]] = []
    for wt in sorted(WORKTREE_ROOT.glob("*/*/")):
        if not wt.is_dir() or (repo and wt.parent.name != repo):
            continue
        path = str(wt).rstrip("/")
        if any(wt == u or wt in u.parents for u in in_use):  # worktree 配下のサブディレクトリで動く記録も使用中
            rows.append(("in-use", path))
            continue
        code, out = run(["git", "--no-optional-locks", "-C", path, "status", "--short"], HERDR_TIMEOUT)
        if code is None or code != 0:
            rows.append(("不明", f"{path}（git status: {UNKNOWN}）"))
        else:
            dirty = len([ln for ln in out.splitlines() if ln.strip()])
            rows.append(("orphan", f"{path}（{'dirty ' + str(dirty) if dirty else 'clean'}）"))
    counts = Counter(s for s, _ in rows)
    head("worktree", f"{len(rows)} 件（{', '.join(f'{k} {v}' for k, v in sorted(counts.items())) or 'なし'}）")
    listed([f"{s:<8} {t}" for s, t in rows if s != "in-use" or full], full)


# --- 6. inbox ----------------------------------------------------------------


def section_inbox(full: bool) -> None:
    rows: list[tuple[str, int]] = []
    for boss in sorted(p for p in (CACHE / "inbox").glob("*") if p.is_dir()):
        unread = len([p for p in boss.glob("*.md") if p.is_file()])  # done/ は既読なので数えない
        rows.append((boss.name, unread))
    total = sum(n for _, n in rows)
    head("inbox", f"未読 {total} 件（boss {len(rows)} 人。既読化はしない）")
    listed([f"{n:>3} 件  {b}" for b, n in rows if n or full], full)


# --- 7. checks ---------------------------------------------------------------


def checks_dir() -> Path | None:
    # 配布先（~/.claude/scripts）では parent×3 が ~/checks になるので、3 本そろった所だけを採る
    candidates = [
        os.environ.get("HARNESS_CHECKS_DIR"),
        str(HOME / "src/harness/checks"),
    ]
    here = Path(__file__).resolve().parent
    if here.name == "scripts" and here.parent.name == "claude":  # repo 内の claude/scripts から動くときだけ。配布先 ~/.claude/scripts では ~/checks を選ばない
        candidates.insert(1, str(here.parent.parent / "checks"))
    return next(
        (Path(c) for c in candidates if c and all((Path(c) / f"{n}.sh").is_file() for n in CHECK_NAMES)),
        None,
    )


def check_result(script: Path) -> tuple[str, str]:
    code, out = run(["bash", str(script)], CHECK_TIMEOUT)
    if code is None:
        return UNKNOWN, out
    last = next((ln.strip() for ln in reversed(out.splitlines()) if ln.strip()), "")
    if code != 0:
        first_ng = next((ln.strip() for ln in out.splitlines() if ln.startswith("NG")), last)
        return "失敗", first_ng
    if re.search(r"skip|検査対象なし", out, re.IGNORECASE):
        return "skip", last
    return "成功", last


def section_checks(full: bool) -> None:
    root = checks_dir()
    if root is None:
        head("checks", f"{UNKNOWN}（checks/ が見つからない。HARNESS_CHECKS_DIR で指定）")
        return
    results = []
    for name in CHECK_NAMES:
        script = root / f"{name}.sh"
        state, note = check_result(script) if script.is_file() else (UNKNOWN, "script なし")
        results.append((name, state, note))
    counts = Counter(s for _, s, _ in results)
    head("checks", ", ".join(f"{k} {v}" for k, v in sorted(counts.items())))
    for name, state, note in results:
        print(f"  {state:<8} {name}" + (f"  {clean(note)[:100]}" if note and (state != "成功" or full) else ""))


# --- main --------------------------------------------------------------------


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="harness の現況を一望する（読み取り専用）")
    parser.add_argument("--repo", help="repo 名で絞る（inbox は boss 単位なので絞らない）")
    parser.add_argument("--all", action="store_true", help="要対応でない項目も個別に出す")
    parser.add_argument("--no-checks", action="store_true", help="checks を走らせない")
    args = parser.parse_args(argv)

    print(f"harness-status  {datetime.now(JST):%Y-%m-%d %H:%M} JST" + (f"  repo={args.repo}" if args.repo else ""))
    try:
        server, agents = herdr_agents()
    except Exception as exc:  # Herdr 応答の想定外でも他の区分は出す
        server, agents = f"{UNKNOWN}（{type(exc).__name__}: {exc}）", None
    sections = [
        lambda: section_herdr(agents, server, args.repo, args.all),
        lambda: section_sessions(agents, args.repo, args.all),
        lambda: section_locks(args.repo, args.all),
        lambda: section_tasks(args.repo, args.all),
        lambda: section_worktrees(args.repo, args.all),
        lambda: section_inbox(args.all),
    ]
    if not args.no_checks:
        sections.append(lambda: section_checks(args.all))
    for section in sections:
        try:
            section()
        except Exception as exc:  # 1 区分の失敗で他の区分を止めない
            print(f"\n■ （区分を表示できなかった: {type(exc).__name__}: {exc}）")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
