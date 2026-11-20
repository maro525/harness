#!/usr/bin/env python3
"""harness-daily — その日のセッションと命令を突き合わせて振り返る。

読むもの（すべて読み取り専用）:
  ~/.claude/projects/*/*.jsonl        Claude Code の transcript（親も子も）
  ~/.pi/agent/sessions/*/*.jsonl      pi のセッション
  ~/.codex/sessions/**/*.jsonl        Codex のセッション
  ~/.cursor/chats/*/*/store.db        Cursor のチャット（SQLite）
  ~/.cache/harness/herdr-*/、locks     harness が残した記録（誰がいつ立てたか）

出すもの:
  ・セッション一覧（親 / 子）
  ・失敗したコマンド
  ・役割の逸脱（親が実行したが、本来は子に渡すべきもの）
  ・指示フローの効率（委譲比率、ensure/delegate/consult の回数、繰り返し）
  ・残骸（記録・worktree・ロック）

使い方:
  harness-daily.py                 今日（JST）
  harness-daily.py --date 2026-11-18
  harness-daily.py --days 7        今日を含む 7 日
  harness-daily.py --repo nanco-next
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sqlite3
import subprocess
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

JST = timezone(timedelta(hours=9))
HOME = Path.home()
WORKTREE_MARK = '/.herdr/worktrees/'

# worktree は ~/.herdr/worktrees の下だけにあるとは限らない（~/src/<repo>-<task> に
# 作られたものもある）。パスの文字列ではなく git の印で判定する: linked worktree は
# .git が「ファイル」、通常の clone は「ディレクトリ」。
_WORKTREE_MEMO: dict[str, bool] = {}


def is_linked_worktree(path: str) -> bool:
    if not path:
        return False
    start = os.path.abspath(path)
    if start in _WORKTREE_MEMO:
        return _WORKTREE_MEMO[start]
    cur, verdict = start, False
    while True:
        git = os.path.join(cur, '.git')
        if os.path.isfile(git):
            verdict = True
            break
        if os.path.isdir(git):
            break
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    _WORKTREE_MEMO[start] = verdict
    return verdict

# 親が自分でやってはいけない（子に渡すべき）コマンドの目安
CHILD_WORK = [
    (re.compile(r'\b(pnpm|npm|yarn|bun)\s+(run\s+)?(test|build|lint|type-?check)\b'), 'テスト/ビルド/lint'),
    (re.compile(r'\b(pytest|go\s+test|cargo\s+test|swift\s+test|flutter\s+test|mvn\s+test|gradle\s+test)\b'), 'テスト'),
    (re.compile(r'\b(tsc|eslint|biome|ruff|prettier)\b'), 'lint/format'),
    (re.compile(r'\bgit\s+(commit|push|merge|rebase)\b'), 'git 書き込み'),
    (re.compile(r'\b(gh|glab)\s+(pr|mr)\s+create\b'), 'PR/MR 作成'),
    (re.compile(r'\b(docker|docker-compose|make)\b'), '重いビルド'),
]
EDIT_TOOLS = {'Edit', 'Write', 'MultiEdit', 'NotebookEdit', 'edit', 'write', 'apply_patch'}

# 文章の下書き（draft.sh）と、外に残る文書を書く操作。下書きを使ったかを測るため。
# `draft.sh --kind=…` を実行したときだけ数える。コミットメッセージや規則文に
# 含まれた同じ文字列（heredoc 内）を拾わないよう、コマンド先頭に錨を打つ。
DRAFT_OPS = [(re.compile(r'^(?:\S+=\S*\s+)*(?:[~$][^\s]*/|/)?[\w./-]*draft\.sh\s+--kind='), 'gemini 下書き')]
RESEARCH_OPS = [(re.compile(r'consult\.sh[^\n]*--to\s+pi'), 'gemini 研究')]
OUTWARD_OPS = [
    (re.compile(r'^\[mcp__\w+__save_comment\]'), 'Linear コメント'),
    (re.compile(r'^\[mcp__\w+__(save_issue|create_issue)\]'), 'Linear issue'),
    (re.compile(r'^\[mcp__\w+__(save_document|update_page)\]'), 'Notion'),
    (re.compile(r'\bglab\s+mr\s+(create|note|update)'), 'MR 本文/コメント'),
    (re.compile(r'\bgh\s+pr\s+(create|comment|edit)'), 'PR 本文/コメント'),
    (re.compile(r'\bgit\s+commit\b'), 'コミットメッセージ'),
]
DELEGATE_CMDS = [
    ('herdr-agent.sh ensure', 'ensure'),
    ('herdr-agent.sh delegate', 'delegate'),
    ('claude-consult.sh', 'consult(claude)'),
    ('codex-consult.sh', 'consult(codex)'),
    ('consult.sh', 'consult'),
    ('orchestrate-parallel.sh', 'parallel'),
    ('phase-run.sh', 'phase'),
]


class Session:
    def __init__(self, source: str, sid: str, cwd: str, start: datetime):
        self.source = source
        self.sid = sid
        self.cwd = cwd or ''
        self.start = start
        self.cmds: list[dict] = []

    @property
    def child(self) -> bool:
        return WORKTREE_MARK in self.cwd or is_linked_worktree(self.cwd)

    @property
    def label(self) -> str:
        if not self.cwd:
            return '(cwd 不明)'
        if WORKTREE_MARK in self.cwd:
            return str(Path(self.cwd).relative_to(self.cwd.split(WORKTREE_MARK)[0])).strip()
        if is_linked_worktree(self.cwd):
            # ~/src/<repo>-<task> のように herdr の外に切られた worktree
            return self.short_cwd
        return self.cwd

    @property
    def short_cwd(self) -> str:
        c = self.cwd.replace(str(HOME), '~')
        # pi のセッションは slug を復元しているだけなので、先頭を ~/ に寄せる
        if c.startswith('/home-dev-'):
            c = '~/' + c[len('/home-dev-'):]
        return c


def to_jst(ts) -> datetime | None:
    if ts is None:
        return None
    if isinstance(ts, (int, float)):
        v = ts / 1000 if ts > 10**11 else ts
        return datetime.fromtimestamp(v, JST)
    s = str(ts).replace('Z', '+00:00')
    try:
        d = datetime.fromisoformat(s)
    except ValueError:
        return None
    if d.tzinfo is None:
        d = d.replace(tzinfo=timezone.utc)
    return d.astimezone(JST)


def add_cmd(sess: Session, ts, name: str, command: str, exit_code=None, failed=False):
    sess.cmds.append(
        {
            'ts': to_jst(ts),
            'tool': name,
            'cmd': command,
            'exit': exit_code,
            'failed': failed,
        }
    )


# ─── Claude ──────────────────────────────────────────────────────────────────
def load_claude(since: datetime, until: datetime) -> list[Session]:
    out: list[Session] = []
    for path in glob.glob(str(HOME / '.claude/projects/*/*.jsonl')):
        if datetime.fromtimestamp(os.path.getmtime(path), JST) < since:
            continue
        sess = None
        pending: dict[str, dict] = {}
        try:
            fh = open(path, encoding='utf-8', errors='ignore')
        except OSError:
            continue
        for line in fh:
            try:
                o = json.loads(line)
            except Exception:
                continue
            ts = to_jst(o.get('timestamp'))
            cwd = o.get('cwd') or ''
            sid = o.get('sessionId') or Path(path).stem
            if ts is None:
                # タイムスタンプの無い行（queue-operation など）はセッションの起点にしない
                continue
            if sess is None:
                if ts < since:
                    break
                if ts > until:
                    continue
                sess = Session('claude', sid, cwd, ts)
            if not (since <= ts <= until):
                continue
            if cwd and not sess.cwd:
                sess.cwd = cwd
            msg = o.get('message') or {}
            content = msg.get('content')
            if not isinstance(content, list):
                continue
            for c in content:
                if not isinstance(c, dict):
                    continue
                if c.get('type') == 'tool_use':
                    name = c.get('name') or '?'
                    inp = c.get('input') or {}
                    cmd = inp.get('command') or inp.get('file_path') or inp.get('path') or ''
                    if name == 'Bash':
                        cmd = inp.get('command') or ''
                    elif name in EDIT_TOOLS:
                        cmd = f'[編集] {inp.get("file_path") or inp.get("path") or ""}'
                    elif name in ('Read', 'Grep', 'Glob'):
                        continue
                    else:
                        cmd = f'[{name}] {cmd}'
                    add_cmd(sess, ts, name, cmd)
                    if c.get('id'):
                        pending[c['id']] = sess.cmds[-1]
                elif c.get('type') == 'tool_result':
                    rec = pending.pop(c.get('tool_use_id'), None)
                    if rec is None:
                        continue
                    text = c.get('content')
                    if isinstance(text, list):
                        text = ' '.join(str(x.get('text', '')) for x in text if isinstance(x, dict))
                    text = str(text or '')
                    m = re.search(r'Exit code (\d+)', text)
                    if m:
                        rec['exit'] = int(m.group(1))
                        rec['failed'] = int(m.group(1)) != 0
                    elif c.get('is_error'):
                        rec['failed'] = True
        if sess and sess.cmds:
            out.append(sess)
    return out


# ─── pi ──────────────────────────────────────────────────────────────────────
def load_pi(since: datetime, until: datetime) -> list[Session]:
    out: list[Session] = []
    for path in glob.glob(str(HOME / '.pi/agent/sessions/*/*.jsonl')):
        if datetime.fromtimestamp(os.path.getmtime(path), JST) < since:
            continue
        slug = Path(path).parent.name.strip('-').replace('--', '/')
        sess = None
        try:
            fh = open(path, encoding='utf-8', errors='ignore')
        except OSError:
            continue
        for line in fh:
            try:
                o = json.loads(line)
            except Exception:
                continue
            ts = to_jst(o.get('timestamp'))
            if ts and not (since <= ts <= until):
                continue
            if ts is None:
                continue
            if sess is None:
                if ts is None:
                    continue
                sess = Session('pi', Path(path).stem, '/' + slug, ts)
            msg = o.get('message') or {}
            content = msg.get('content')
            if not isinstance(content, list):
                continue
            for c in content:
                if not isinstance(c, dict) or c.get('type') != 'toolCall':
                    continue
                name = c.get('name') or '?'
                args = c.get('arguments') or {}
                if name in ('bash', 'shell'):
                    add_cmd(sess, ts, name, args.get('command', ''))
                elif name in EDIT_TOOLS:
                    add_cmd(sess, ts, name, f'[編集] {args.get("path", "")}')
        if sess and sess.cmds:
            out.append(sess)
    return out


# ─── Codex ───────────────────────────────────────────────────────────────────
def load_codex(since: datetime, until: datetime) -> list[Session]:
    out: list[Session] = []
    for path in glob.glob(str(HOME / '.codex/sessions/**/*.jsonl'), recursive=True):
        if datetime.fromtimestamp(os.path.getmtime(path), JST) < since:
            continue
        sess = None
        cwd = ''
        try:
            fh = open(path, encoding='utf-8', errors='ignore')
        except OSError:
            continue
        for line in fh:
            try:
                o = json.loads(line)
            except Exception:
                continue
            ts = to_jst(o.get('timestamp'))
            if ts and not (since <= ts <= until):
                continue
            t = o.get('type')
            if t == 'session_meta':
                p = o.get('payload') or {}
                cwd = p.get('cwd') or cwd
            if sess is None:
                if not ts:
                    continue
                sess = Session('codex', Path(path).stem, cwd, ts)
            payload = o.get('payload') or {}
            item = payload.get('item') or {}
            if payload.get('type') in ('item_completed', 'item_started') and item.get('type') == 'CommandExecution':
                cmd = item.get('command')
                if isinstance(cmd, list):
                    cmd = ' '.join(str(x) for x in cmd[-1:]) if cmd else ''
                exit_code = item.get('exit_code')
                failed = exit_code not in (None, 0)
                add_cmd(sess, ts, 'shell', str(cmd or ''), exit_code, failed)
        if sess and sess.cmds:
            out.append(sess)
    return out


# ─── Cursor ─────────────────────────────────────────────────────────────────
def load_cursor(since: datetime, until: datetime) -> list[Session]:
    out: list[Session] = []
    for db in glob.glob(str(HOME / '.cursor/chats/*/*/store.db')):
        chat = Path(db).parent
        try:
            meta = json.loads((chat / 'meta.json').read_text(encoding='utf-8'))
        except Exception:
            meta = {}
        start = to_jst(meta.get('createdAtMs'))
        end = to_jst(meta.get('updatedAtMs')) or start
        if not start:
            continue
        if end < since or start > until:
            continue
        sess = Session('cursor', chat.name, meta.get('cwd') or '', start)
        try:
            con = sqlite3.connect(f'file:{db}?mode=ro', uri=True)
            rows = list(con.execute('select payload from blobs'))
            con.close()
        except Exception:
            continue
        results = {}
        for (payload,) in rows:
            try:
                o = json.loads(payload)
            except Exception:
                continue
            if not isinstance(o, dict):
                continue
            content = o.get('content')
            if not isinstance(content, list):
                continue
            for part in content:
                if not isinstance(part, dict):
                    continue
                if part.get('type') == 'tool-call':
                    name = part.get('toolName') or '?'
                    args = part.get('args') or {}
                    if name.lower() in ('shell', 'bash', 'run_terminal_cmd', 'terminal'):
                        cmd = args.get('command') or args.get('cmd') or ''
                    elif name in EDIT_TOOLS:
                        cmd = f'[編集] {args.get("path") or args.get("file_path") or ""}'
                    elif name in ('Read', 'Grep', 'Glob', 'read_file', 'list_dir'):
                        continue
                    else:
                        cmd = f'[{name}] ' + json.dumps(args)[:120]
                    add_cmd(sess, end, name, str(cmd))
                    if part.get('toolCallId'):
                        results[part['toolCallId']] = sess.cmds[-1]
                elif part.get('type') == 'tool-result':
                    rec = results.get(part.get('toolCallId'))
                    if not rec:
                        continue
                    text = str(part.get('result') or '')
                    m = re.search(r'(?:exit code|Exit code)[:= ]+(\d+)', text)
                    if m:
                        rec['exit'] = int(m.group(1))
                        rec['failed'] = int(m.group(1)) != 0
                    elif re.search(r'\b(error|failed|FAIL)\b', text):
                        rec['failed'] = True
        if sess.cmds:
            out.append(sess)
    return out


# ─── 残骸 ────────────────────────────────────────────────────────────────────
def unmanaged_worktrees() -> list[str]:
    """~/.herdr/worktrees の外に切られた linked worktree（herdr-cleanup が拾えない）。"""
    root = str(HOME / '.herdr/worktrees')
    found = set()
    for pattern in ('src/*/.git', 'src/*/*/.git', 'test/*/.git'):
        for gitfile in glob.glob(str(HOME / pattern)):
            if not os.path.isfile(gitfile):
                continue
            path = os.path.dirname(gitfile)
            if path.startswith(root + os.sep):
                continue
            found.add(path)
    return sorted(found)


def leftovers() -> dict:
    state = HOME / '.cache/harness'
    locks = HOME / '.local/share/harness/locks'
    res = {'sessions': 0, 'worktrees': 0, 'locks': 0, 'unmanaged': [], 'locks_history': 0, 'locks_stale': 0}
    for d in ('herdr-agents', 'herdr-consult'):
        res['sessions'] += len(glob.glob(str(state / d / '*.json')))
    res['locks'] = len(glob.glob(str(locks / '*.lock')))
    # task-file.sh の lock は 9>$path.guard を flock の対象にする（0 バイト）。
    # release はリースだけ消すので、キーごとに 1 個溜まる。状態ではないが、
    # タスク数に比例して増えるので見えるようにしておく。
    guards = glob.glob(str(locks / '*.lock.guard'))
    res['locks_history'] = len(guards)
    res['locks_stale'] = sum(1 for g in guards if not os.path.exists(g[: -len('.guard')]))
    root = HOME / '.herdr/worktrees'
    for wt in glob.glob(str(root / '*' / '*')):
        res['worktrees'] += 1
    res['unmanaged'] = unmanaged_worktrees()
    return res


def herdr_children(since: datetime, until: datetime) -> list[str]:
    """その日に herdr で立てた子・相談先（親が Cursor だとコマンドに残らないため）。"""
    out: list[str] = []
    state = HOME / '.cache/harness'
    for d in ('herdr-agents', 'herdr-consult'):
        for path in glob.glob(str(state / d / '*.json')):
            try:
                o = json.loads(Path(path).read_text(encoding='utf-8'))
            except Exception:
                continue
            ts = to_jst(o.get('created'))
            if ts is None or not (since <= ts <= until):
                continue
            out.append(str(o.get('agent') or Path(path).stem))
    return sorted(out)


def text_stats(sessions: list[Session]) -> Counter:
    """下書き（gemini）と、外に残る文書を書く操作の回数。"""
    counts: Counter = Counter()
    for s in sessions:
        for c in s.cmds:
            for rx, name in DRAFT_OPS + RESEARCH_OPS + OUTWARD_OPS:
                if rx.search(c['cmd']):
                    counts[name] += 1
                    break
    return counts


def main() -> int:
    ap = argparse.ArgumentParser(description='その日のセッション・コマンド・残骸をまとめる')
    ap.add_argument('--date', help='対象日（JST, YYYY-MM-DD）。既定は今日')
    ap.add_argument('--days', type=int, default=1, help='対象日を含む日数（既定 1）')
    ap.add_argument('--repo', help='cwd にこの文字列を含むものだけ')
    args = ap.parse_args()

    if args.date:
        day = datetime.strptime(args.date, '%Y-%m-%d').replace(tzinfo=JST)
    else:
        day = datetime.now(JST).replace(hour=0, minute=0, second=0, microsecond=0)
    until = day + timedelta(days=args.days)
    since = day - timedelta(days=0)
    label = f"{since:%Y-%m-%d}" if args.days == 1 else f"{since:%Y-%m-%d} 〜 {(until - timedelta(days=1)):%Y-%m-%d}"

    sessions: list[Session] = []
    for loader in (load_claude, load_pi, load_codex, load_cursor):
        try:
            sessions.extend(loader(since, until))
        except Exception as exc:  # 壊れたログで全体を止めない
            print(f'warn: {loader.__name__} failed: {exc}', file=sys.stderr)

    if args.repo:
        sessions = [s for s in sessions if args.repo in s.cwd]
    sessions.sort(key=lambda s: s.start)

    print(f'=== harness-daily {label} ===')
    if not sessions:
        print('\nその日のセッションは見つかりませんでした（--date を変えるか --repo を外す）。')

    parents = [s for s in sessions if not s.child]
    children = [s for s in sessions if s.child]
    all_cmds = [c for s in sessions for c in s.cmds]
    failed = [c for c in all_cmds if c['failed']]

    def owner_label(s: Session) -> str:
        return '親' if not s.child else '子'

    print(f'\n■ セッション（{len(sessions)}） 親 {len(parents)} / 子 {len(children)}')
    shown = sessions if len(sessions) <= 30 else sessions[:30]
    for s in shown:
        fails = sum(1 for c in s.cmds if c['failed'])
        print(
            f"  {owner_label(s)}  {s.start:%m-%d %H:%M}  {s.source:<7}  {len(s.cmds):>4} cmds"
            f"  fail {fails:<3} {s.short_cwd}"
        )
    if len(sessions) > len(shown):
        print(f'  … ほか {len(sessions) - len(shown)} セッション（--repo で絞るか、下の集計を見る）')

    print(f'\n■ 失敗したコマンド（{len(failed)}）')
    owner_of = {id(c): s for s in sessions for c in s.cmds}
    for c in sorted(failed, key=lambda x: x['ts'] or since)[:30]:
        s = owner_of[id(c)]
        exit_part = f"exit {c['exit']}" if c['exit'] is not None else 'error'
        print(f"  {c['ts']:%H:%M}  {owner_label(s)} {s.source:<7} {exit_part:<8} {c['cmd'][:100]}")
    if len(failed) > 30:
        print(f'  … ほか {len(failed) - 30} 件')

    print('\n■ 役割の逸脱（親が自分でやった = 子に渡すべきもの）')
    violations = []
    for s in parents:
        for c in s.cmds:
            if c['cmd'].startswith('[編集]'):
                path = c['cmd'][len('[編集] '):].strip()
                # /tmp の依頼文・PR 本文、TASK_FILE などは PM の仕事なので除外
                if not path or path.startswith(('/tmp/', '/var/folders/')):
                    continue
                if '/.local/share/harness/' in path or '/.cache/harness/' in path:
                    continue
                violations.append((s, c, 'リポジトリの編集'))
                continue
            for rx, why in CHILD_WORK:
                if rx.search(c['cmd']):
                    violations.append((s, c, why))
                    break
    if not violations:
        print('  なし')
    else:
        grouped: dict[tuple[str, str], Counter] = defaultdict(Counter)
        first = {}
        for s, c, why in violations:
            key = (s.source, s.short_cwd)
            grouped[key][why] += 1
            if key not in first:
                first[key] = c['ts']
        print(f'  {len(violations)} 件 / {len(grouped)} セッション')
        for (source, cwd), kinds_by_why in sorted(grouped.items(), key=lambda kv: -sum(kv[1].values()))[:15]:
            detail = ' / '.join(f'{w} {n}' for w, n in kinds_by_why.most_common())
            print(f"  {first[(source, cwd)]:%H:%M}  {source:<7} {detail:<32} {cwd}")

    print('\n■ 指示フローの効率')
    n_parent = sum(len(s.cmds) for s in parents)
    n_child = sum(len(s.cmds) for s in children)
    total = n_parent + n_child
    ratio = (n_child / total * 100) if total else 0
    print(f'  コマンド: 親 {n_parent} / 子 {n_child}（委譲比率 {ratio:.0f}%）')
    kinds = Counter()
    for s in parents:
        for c in s.cmds:
            for needle, name in DELEGATE_CMDS:
                if needle in c['cmd']:
                    kinds[name] += 1
                    break
    if kinds:
        print('  委譲の呼び出し: ' + ' / '.join(f'{k} ×{v}' for k, v in sorted(kinds.items())))
    else:
        print('  委譲の呼び出し: なし（自分で全部やっている可能性）')
    made = herdr_children(since, until)
    if made:
        print(f'  herdr で立てた子: {len(made)} 本（' + ', '.join(made[:4]) + ('…' if len(made) > 4 else '') + '）')
    elif not kinds and children:
        print('  子は居るが delegate / phase の記録が無い（親が Cursor だとコマンドに残らない）')
    repeats = Counter(re.sub(r'\s+', ' ', c['cmd'])[:60] for c in all_cmds if not c['cmd'].startswith('['))
    hot = [(k, v) for k, v in repeats.most_common(5) if v >= 3]
    if hot:
        print('  繰り返し: ' + ', '.join(f'{k[:40]} ×{v}' for k, v in hot))
    if children:
        per = sorted(len(s.cmds) for s in children)
        print(f'  子 1 セッションあたりのコマンド数: 中央 {per[len(per) // 2]} / 最大 {per[-1]}')

    tstats = text_stats(sessions)
    if tstats:
        drafts = tstats.get('gemini 下書き', 0)
        research = tstats.get('gemini 研究', 0)
        outward = sum(tstats.get(name, 0) for _, name in OUTWARD_OPS)
        print('\n■ 文章（下書き）')
        print(f'  gemini 下書き {drafts} 件（研究 {research} 件）/ 対外文書の操作 {outward} 件')
        detail = ' / '.join(f'{name} {tstats[name]}' for _, name in OUTWARD_OPS if tstats.get(name))
        if detail:
            print(f'  内訳: {detail}')
        if outward and not drafts:
            print('  → 下書きは `draft.sh --kind=…` に任せる（tool-routing.md「対外文書の下書き」）')

    res = leftovers()
    print('\n■ 残骸')
    line = f"  セッション記録 {res['sessions']} / worktree {res['worktrees']} / ロック {res['locks']}"
    if res['unmanaged']:
        line += f"（ほかに管理外 worktree {len(res['unmanaged'])}）"
    print(line)
    used = [
        p
        for p in res['unmanaged']
        if any(s.cwd == p or s.cwd.startswith(p + os.sep) for s in sessions)
    ]
    if used:
        print('  この日のセッションが使った管理外 worktree（~/.herdr/worktrees の外。cleanup の対象外）:')
        for path in used[:6]:
            print(f"    {path.replace(str(HOME), '~')}")
        if len(used) > 6:
            print(f"    … ほか {len(used) - 6} 本")
        print('  → 次は `git worktree add ~/.herdr/worktrees/{repo}/{branch}` に作る')
    if res['locks_history']:
        print(
            f"  ロック履歴 {res['locks_history']} キー（うち失効 {res['locks_stale']}）: "
            'flock 用の 0 バイト guard。消すのは *.lock が無く誰も握っていないものだけ'
        )
    print('  確認: ~/.claude/scripts/herdr-cleanup.sh --worktrees --all-owners')
    return 0


if __name__ == '__main__':
    sys.exit(main())
