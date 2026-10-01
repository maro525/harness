#!/usr/bin/env python3
"""
UserPromptSubmit hook: route user prompts to a skill or agent.

Priority: explicit command (/orchestrate etc.) > skill intent (-> /orchestrate)
> agent intent (OpenCode / firecrawl MCP / Explore) > none.
Lightweight-task exclusion is currently disabled: is_lightweight_task() always
returns False when a skill trigger matched, so any skill trigger yields a
suggestion (the question / single-file patterns below are dead code for now).

Output: additionalContext with a soft recommendation.
"""

import json
import re
import sys

# ---------------------------------------------------------------------------
# Skill intent triggers
# ---------------------------------------------------------------------------

STARTPROJECT_TRIGGERS = {
    "ja": [
        "新機能を",
        "新しい機能",
        "機能を作",
        "機能を開発",
        "機能を実装したい",
        "プロジェクトを始",
        "プロジェクト開始",
        "計画して",
        "計画を立てて",
        "設計から始",
        "要件定義",
        "要件を整理",
        "新規開発",
        "featureを始",
        "featureを進",
        "開発を始めたい",
        "作りたい",
        "つくりたい",
        "構築したい",
        "実装したい",
        "issue #",
        "issueを実行",
        "issueを進",
        "チケットを進",
        "チケットを実行",
        "タスクを始",
        "タスクを進",
        "githubの#",
        "githubの #",
        "をやりたい",
        "をやって",
        "を進めたい",
        "を進めて",
    ],
    "en": [
        "start project",
        "start a project",
        "start new feature",
        "plan this feature",
        "plan the feature",
        "begin development",
        "kick off",
        "start building",
        "new feature",
        "implement issue",
        "work on issue",
        "execute issue",
    ],
}

TEAM_IMPLEMENT_TRIGGERS = {
    "ja": [
        "実装して",
        "実装を開始",
        "実装に進",
        "実装を始",
        "実装フェーズ",
        "コードを書いて",
        "この計画で実装",
        "承認した",
        "承認します",
        "進めて",
        "計画通りに",
        "計画で進めて",
        "実装に入",
        "コーディング",
    ],
    "en": [
        "implement this",
        "start implementing",
        "begin implementation",
        "approved, implement",
        "go ahead and implement",
        "proceed with implementation",
        "code this up",
        "start coding",
    ],
}

TEAM_REVIEW_TRIGGERS = {
    "ja": [
        "レビューして",
        "レビューを",
        "コードレビュー",
        "差分レビュー",
        "実装のレビュー",
        "品質チェック",
        "セキュリティチェック",
        "実装が終わった",
        "実装完了",
        "レビューに進",
        "チェックして",
    ],
    "en": [
        "review this",
        "code review",
        "review the implementation",
        "review the code",
        "check the implementation",
        "quality review",
        "security review",
        "implementation is done",
        "ready for review",
    ],
}

DEPLOY_TRIGGERS = {
    "ja": [
        "デプロイ",
        "prを作",
        "pr作成",
        "pushして",
        "プッシュして",
        "マージ",
        "リリース",
        "本番に",
        "ブランチをpush",
        "prを出",
        "コミットして",
        "コミットを作",
        "ブランチを切",
        "ブランチを作",
        "ブランチを変",
        "チェックアウト",
        "git stash",
        "git rebase",
        "stashして",
        "pullして",
        "タグを",
        "cherry-pick",
    ],
    "en": [
        "deploy",
        "create pr",
        "create a pr",
        "create pull request",
        "push to remote",
        "push the branch",
        "merge this",
        "release this",
        "ship it",
        "send pr",
        "commit this",
        "commit the",
        "make a commit",
        "create branch",
        "switch branch",
        "checkout",
        "git stash",
        "git rebase",
        "git pull",
        "git tag",
        "cherry-pick",
    ],
}

# ---------------------------------------------------------------------------
# Agent intent triggers
# ---------------------------------------------------------------------------

OPENCODE_TRIGGERS = {
    "ja": [
        "設計相談",
        "どう設計すべき",
        "アーキテクチャ相談",
        "デバッグして",
        "原因を分析",
        "トレードオフ",
        "比較検討",
        "深く考えて",
        "second opinion",
    ],
    "en": [
        "design consultation",
        "think deeper",
        "consult opencode",
        "second opinion",
        "trade-off analysis",
        "debug this",
    ],
}

# External (web) research → firecrawl MCP
RESEARCH_TRIGGERS = {
    "ja": [
        "調べて",
        "リサーチして",
        "調査して",
        "最新バージョン",
        "公式ドキュメント",
    ],
    "en": [
        "research this",
        "investigate",
        "look up",
        "latest version",
        "official docs",
    ],
}

# Codebase-wide analysis → Explore subagent (local tools, no web access)
CODEBASE_TRIGGERS = {
    "ja": [
        "コードベース全体",
        "横断的に",
    ],
    "en": [
        "entire codebase",
        "across the codebase",
    ],
}

# ---------------------------------------------------------------------------
# Lightweight task exclusion patterns
# ---------------------------------------------------------------------------

QUESTION_PATTERNS = {
    "ja": [
        "とは何",
        "って何",
        "ってなに",
        "を教えて",
        "を説明して",
        "の意味は",
        "の違いは",
        "はどういう",
        "なぜ失敗",
        "なぜ動かない",
        "どうして",
        "見せて",
        "表示して",
    ],
    "en": [
        "what is",
        "what are",
        "how does",
        "how do",
        "why does",
        "why is",
        "explain",
        "show me",
        "display",
        "can you tell",
        "tell me about",
        "describe",
    ],
}

LIGHTWEIGHT_OPERATION_PATTERNS = {
    "ja": [
        "直して",
        "リネームして",
        "フォーマットして",
        "lintして",
        "テストを実行して",
    ],
    "en": [
        "fix this typo",
        "rename this",
        "format this",
        "run lint",
        "run test",
        "run the test",
    ],
}

# Explicit skill command pattern — includes /orchestrate as primary entry point
EXPLICIT_SKILL_RE = re.compile(
    r"^/(?:orchestrate|startproject|team-implement|team-review|deploy)\b",
    re.IGNORECASE,
)

# Linear ID pattern (e.g. PROJ-573, ABC-123)
LINEAR_ID_RE = re.compile(r"\b([A-Z]+-\d+)\b")


# ---------------------------------------------------------------------------
# Detection logic
# ---------------------------------------------------------------------------


def has_explicit_skill(prompt: str) -> bool:
    return bool(EXPLICIT_SKILL_RE.search(prompt.strip()))


def is_lightweight_task(prompt: str, has_skill_trigger: bool = False) -> bool:
    if has_skill_trigger:
        return False

    prompt_lower = prompt.lower()

    for patterns in QUESTION_PATTERNS.values():
        for pattern in patterns:
            if pattern in prompt_lower:
                return True

    for patterns in LIGHTWEIGHT_OPERATION_PATTERNS.values():
        for pattern in patterns:
            if pattern in prompt_lower:
                return True

    return False


def detect_linear_id(prompt: str) -> str | None:
    """Extract Linear task ID from prompt if present."""
    match = LINEAR_ID_RE.search(prompt)
    return match.group(1) if match else None


def detect_skill_intent(prompt: str) -> tuple[str | None, str]:
    prompt_lower = prompt.lower()

    skill_candidates = [
        ("startproject", STARTPROJECT_TRIGGERS),
        ("team-implement", TEAM_IMPLEMENT_TRIGGERS),
        ("team-review", TEAM_REVIEW_TRIGGERS),
        ("deploy", DEPLOY_TRIGGERS),
    ]

    for skill_name, triggers in skill_candidates:
        for lang_triggers in triggers.values():
            for trigger in lang_triggers:
                if trigger in prompt_lower:
                    return skill_name, trigger

    return None, ""


def detect_agent_intent(prompt: str) -> tuple[str | None, str]:
    prompt_lower = prompt.lower()

    for triggers in OPENCODE_TRIGGERS.values():
        for trigger in triggers:
            if trigger in prompt_lower:
                return "opencode", trigger

    # Codebase triggers are checked first — they are more specific than the
    # generic research wording (e.g. "コードベース全体を調べて" matches both).
    for triggers in CODEBASE_TRIGGERS.values():
        for trigger in triggers:
            if trigger in prompt_lower:
                return "explore", trigger

    for triggers in RESEARCH_TRIGGERS.values():
        for trigger in triggers:
            if trigger in prompt_lower:
                return "firecrawl", trigger

    return None, ""


# ---------------------------------------------------------------------------
# Skill descriptions
# ---------------------------------------------------------------------------

SKILL_DESCRIPTIONS = {
    # startproject / team-implement / team-review → /orchestrate に統一
    "startproject": (
        "[Skill Routing] Detected project/feature start intent (trigger: '{trigger}'). "
        "Use `/orchestrate` for the full workflow (plan → implement → review → deploy). "
        "Run: /orchestrate {prompt_summary}"
    ),
    "team-implement": (
        "[Skill Routing] Detected implementation intent (trigger: '{trigger}'). "
        "Use `/orchestrate` (/team-implement only works when called by it). "
        "Run: /orchestrate {prompt_summary}"
    ),
    "team-review": (
        "[Skill Routing] Detected review intent (trigger: '{trigger}'). "
        "Use `/orchestrate` (/team-review only works when called by it). "
        "Run: /orchestrate {prompt_summary}"
    ),
    # deploy は git 単体操作もあるので /deploy を残しつつ /orchestrate も案内
    "deploy": (
        "[Skill Routing] Detected git/deploy intent (trigger: '{trigger}'). "
        "Git write operation only (commit, push, PR, branch, merge, etc.): /deploy\n"
        "Full project workflow: /orchestrate {prompt_summary}"
    ),
}


# ---------------------------------------------------------------------------
# Main routing logic
# ---------------------------------------------------------------------------


def route_prompt(prompt: str) -> dict | None:
    # 1. Explicit skill command → do nothing
    if has_explicit_skill(prompt):
        return None

    # 2. Check for skill intent
    skill, trigger = detect_skill_intent(prompt)
    if skill and not is_lightweight_task(prompt, has_skill_trigger=True):
        prompt_summary = prompt.strip()[:80]
        if len(prompt.strip()) > 80:
            prompt_summary += "..."

        # Linear ID が含まれていれば補足情報として追加
        linear_id = detect_linear_id(prompt)
        linear_note = f" (Linear ID detected: {linear_id})" if linear_id else ""

        context_msg = SKILL_DESCRIPTIONS[skill].format(
            trigger=trigger,
            prompt_summary=prompt_summary,
        ) + linear_note

        return {
            "hookSpecificOutput": {
                "hookEventName": "UserPromptSubmit",
                "additionalContext": context_msg,
            }
        }

    # 3. Agent intent (OpenCode / firecrawl MCP / Explore)
    agent, trigger = detect_agent_intent(prompt)
    if agent == "opencode":
        return {
            "hookSpecificOutput": {
                "hookEventName": "UserPromptSubmit",
                "additionalContext": (
                    f"[Agent Routing] Detected '{trigger}' - consider OpenCode CLI "
                    "for deep reasoning, via a subagent for context isolation."
                ),
            }
        }
    elif agent == "firecrawl":
        return {
            "hookSpecificOutput": {
                "hookEventName": "UserPromptSubmit",
                "additionalContext": (
                    f"[Agent Routing] Detected '{trigger}' - run external "
                    "research on two parallel tracks via subagents: firecrawl MCP "
                    "(firecrawl_search / firecrawl_scrape) for sourced facts, and "
                    "`timeout -k 1m 20m opencode run --agent plan -m github-copilot/gpt-5.6-sol` "
                    "for implementation know-how (keep --agent plan, no 2>/dev/null, "
                    "run in the background). Prefer firecrawl when they disagree."
                ),
            }
        }
    elif agent == "explore":
        return {
            "hookSpecificOutput": {
                "hookEventName": "UserPromptSubmit",
                "additionalContext": (
                    f"[Agent Routing] Detected '{trigger}' - consider the Explore "
                    "subagent for codebase-wide analysis (context isolation)."
                ),
            }
        }

    # 4. No routing needed
    return None


def main():
    try:
        data = json.load(sys.stdin)
        prompt = data.get("prompt", "")

        if len(prompt) < 5:
            sys.exit(0)

        result = route_prompt(prompt)
        if result:
            print(json.dumps(result))

        sys.exit(0)

    except Exception as e:
        print(f"Hook error: {e}", file=sys.stderr)
        sys.exit(0)


if __name__ == "__main__":
    main()
