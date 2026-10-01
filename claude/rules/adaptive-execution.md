# Adaptive Execution

**Task size determines resource allocation. Use the minimum context needed.**

## Task Size Classification

### Classification Table

| Tier | Files | Complexity | Risk | External Research |
|------|-------|-----------|------|-------------------|
| **XS** | 1 | No logic change | None | Not needed |
| **S** | 1-3 | Single pattern | Low | Not needed |
| **M** | 4-10 | Multi-pattern | Medium | If needed |
| **L** | 10+ | Architecture change | High | Required |

### Classification Logic

`tier = max(file_tier, complexity_tier, risk_tier)` — evaluate the three dimensions independently; the highest wins.

### Hard Triggers (Auto-L)

- Database migration or schema change
- Authentication / authorization changes
- Payment / billing logic
- Public API surface changes
- New core dependency addition

### Examples

| Task | Tier | Reasoning |
|------|------|-----------|
| Fix typo in README | XS | 1 file, no logic, no risk |
| Add input validation to existing endpoint | S | 1-2 files, clear pattern |
| Add new API endpoint with tests | M | 4-6 files, some design decisions |
| Implement user authentication system | L | 10+ files, architecture change, auth (hard trigger) |
| Refactor 3 related modules | M | 4-10 files, multi-pattern, medium risk |
| Add new external library integration | L | New core dependency (hard trigger) |

## Workflow per Tier

Per-phase team structure is defined in each command (`startproject` / `team-implement` / `team-review`). XS skips `/orchestrate` and is implemented directly.

Phases and models per tier (how each phase is launched: `orchestrate.md` "tier 別のフェーズ構成"):

| Tier | startproject | team-implement | team-review | deploy |
|------|--------------|----------------|-------------|--------|
| **S** | Skipped (orchestrate plans) | sonnet | sonnet | haiku |
| **M** | best | opus | opus | haiku |
| **L** | best | best | opus | haiku |

Both tables below use the same invocation: `timeout -k 1m 20m opencode run --agent plan -m github-copilot/gpt-5.6-sol` (details in `$HOME/.claude/rules/tool-routing.md`). Inside `/startproject` (no Agent tool) and `context: fork` commands, run it directly; elsewhere via a subagent.

### External Research (firecrawl MCP + OpenCode)

firecrawl MCP (sourced facts) and OpenCode (implementation know-how) run in parallel.

| Tier | Usage |
|------|-------------|
| **XS** | Never |
| **S** | Never |
| **M** | Only if task involves unknown libraries or external APIs |
| **L** | Standard |

### OpenCode Design Consultation

| Tier | OpenCode Usage |
|------|------------|
| **XS** | Never |
| **S** | Only if debugging a non-obvious issue |
| **M** | Design questions |
| **L** | Standard |

## Escalation

Tasks escalate upward during execution (never downward).

### Checkpoints

1. **After planning** — Re-evaluate before implementation starts
2. **At 30-40% implementation** — Check if scope expanded
3. **Before review** — Verify final scope matches tier

### Escalation Triggers

- File count exceeds tier threshold
- Unresolved design questions accumulate
- New dependency added mid-implementation
- Risk dimension changes (e.g., touching auth code unexpectedly)

### Escalation Behavior

Within `/orchestrate`, team-implement stops and returns `ESCALATION`; orchestrate updates the tier and re-runs startproject with it. Code changed so far stays on the work branch and is continued, not redone.

## Presentation

State the tier and reasoning to the user when classifying:

```
**Task Size: M (Medium)**
- Files: ~6 (4-10 range)
- Complexity: Multi-pattern (new rule + skill updates)
- Risk: Medium (affects framework behavior)
- External research: Not needed
```

User can override the classification.
