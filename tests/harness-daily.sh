#!/bin/bash
# harness-daily.py の役割判定のテスト。実環境の記録・transcript には触れず、
# 手で組んだ Session と記録だけで判定を確かめる。
# Usage: tests/harness-daily.sh   Exit: 0 = all pass

set -uo pipefail

HARNESS=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$HARNESS/claude/scripts/harness-daily.py"
[[ -f "$SCRIPT" ]] || { echo "not found: $SCRIPT" >&2; exit 1; }

python3 - "$SCRIPT" <<'PY'
import importlib.util
import os
import sys
from datetime import datetime, timedelta

spec = importlib.util.spec_from_file_location('daily', sys.argv[1])
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)

fails = 0


def ok(name, cond, got=''):
    global fails
    if cond:
        print(f'ok   {name}')
    else:
        print(f'FAIL {name} {got}')
        fails += 1


def sess(source, cwd, start, cmds):
    s = d.Session(source, 'sid', cwd, start)
    for c in cmds:
        d.add_cmd(s, start, 'bash', c)
    return s


def rec(name, cwd, created, kind='claude', owner='', boss='', topology='tab', src='record'):
    return {'name': name, 'cwd': cwd, 'created': created, 'kind': kind,
            'owner': owner, 'boss': boss, 'topology': topology, 'src': src}


T0 = datetime(2026, 11, 25, 10, 0, tzinfo=d.JST)
WT = '/home/dev/.herdr/worktrees/repo-a/feature-x'
CHECKOUT = '/home/dev/src/repo-a'

# 1. 名前から決まる役割
for name, want in [
    ('pm-repo-a', d.ROLE_PM),
    ('pm-repo-a-9f3c', d.ROLE_PM),
    ('manager-repo-a', d.ROLE_MANAGER),
    ('manager-repo-a-9f3c', d.ROLE_MANAGER),
    ('orchestrate-nanco-3151', d.ROLE_ORCH),
    ('orchestrate-noissue-fix', d.ROLE_ORCH),
    ('claude-orch-3151', d.ROLE_ORCH),
    ('consult-codex', d.ROLE_CONSULT),
    ('claude-review-1983', d.ROLE_WORKER),
    ('pi-seo-doc', d.ROLE_WORKER),
]:
    got = d.role_of_name(name)
    ok(f'role of {name} is {want}', got == want, f'got {got}')

# 2. worktree は記録のパス一致で名前が決まる（推定ではない）
s = sess('claude', WT, T0, [])
d.assign_roles([s], [rec('claude-orch-3151', WT, T0)])
ok('worktree session takes the recorded name', s.name == 'claude-orch-3151', s.name)
ok('worktree session is orchestrator', s.role == d.ROLE_ORCH, s.role)
ok('worktree name is not a guess', s.role_inferred is False)

# 3. worktree でも種類が違えば名前を借りない（codex が claude の worktree に居る）
s = sess('codex', WT, T0, [])
d.assign_roles([s], [rec('claude-orch-3151', WT, T0, kind='claude')])
ok('other kind does not inherit the name', s.name == '', s.name)
ok('other kind is inferred', s.role_inferred is True)

# 4. checkout は名前で結ばない（PM と manager が同じリポジトリに並ぶ）
s = sess('claude', CHECKOUT, T0, [])
d.assign_roles([s], [rec('manager-repo-a', CHECKOUT, T0)])
ok('checkout session is not named from a record', s.name == '', s.name)
ok('checkout session without evidence has no role', s.role == d.ROLE_NONE, s.role)

# 5. 記録の無いセッションはコマンドで推定する
cases = [
    ('PM', ['~/.claude/scripts/herdr-agent.sh ask manager-repo-a /tmp/req.md'], d.ROLE_PM),
    ('manager', ['~/.claude/scripts/herdr-agent.sh ensure child-a --kind claude'], d.ROLE_MANAGER),
    ('orchestrator', ['~/.claude/scripts/phase-run.sh team-implement --task-file x'], d.ROLE_ORCH),
    ('none', ['git status --short'], d.ROLE_NONE),
]
for label, cmds, want in cases:
    s = sess('cursor', CHECKOUT, T0, cmds)
    d.assign_roles([s], [])
    ok(f'{label} inferred from commands', s.role == want, s.role)
    ok(f'{label} is marked as inferred', s.role_inferred is True)

# 6. ask と ensure が混ざるセッションは PM（manager を起こして依頼する側）
s = sess('cursor', CHECKOUT, T0, [
    '~/.claude/scripts/herdr-agent.sh manager -- --model opus',
    '~/.claude/scripts/herdr-agent.sh ask manager-repo-a /tmp/req.md',
    '~/.claude/scripts/herdr-agent.sh ensure child-a --kind claude',
])
d.assign_roles([s], [])
ok('ask wins over ensure', s.role == d.ROLE_PM, s.role)

print('')
if fails == 0:
    print('all pass')
    sys.exit(0)
print(f'{fails} failed')
sys.exit(1)
PY
