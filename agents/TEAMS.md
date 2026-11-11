# Claude Code agent teams for CALI

Setup (committed in the repo):
- `.claude/settings.json` sets `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` and `teammateMode: "in-process"`. Split panes need tmux or iTerm2, and they don't work in Windows Terminal or the VS Code terminal.
- `.claude/agents/cali-*.md` holds one teammate type per role in `AGENTS.md`. Each one points to its role prompt in `agents/0X-*.md` and states which files it owns.

| Teammate type | Role prompt | Owns |
|---|---|---|
| `cali-integrator` | `00-orchestrator.md` | `.github/`, ADR/backlog/plan docs, `CHANGELOG.md` |
| `cali-ios` | `01-ios-agent.md` | `ios/`, docs/04, docs/05 |
| `cali-backend` | `02-backend-agent.md` | `backend/`, `db/`, OpenAPI (only through an agreed contract change) |
| `cali-ai-coach` | `03-ai-coach-agent.md` | AI analytics/policy code, `fixtures/`, docs/09 |
| `cali-design` | `04-design-agent.md` | `docs/design/`, `brand/`, UX/media docs |
| `cali-qa` | `05-qa-agent.md` | `tests/`, `backend/tests/`, `ios/CaliAppTests/`, `evidence/` |
| `cali-contract-reviewer` | `06-contract-review-agent.md` | read-only (Sonnet) |

## Using it

1. Open a new `claude` session in the repo. The lead is the session you type in.
2. Ask for a team in plain language and name the teammate types. Example prompts:

```text
Create an agent team to review the current branch. Spawn teammates with these agent types:
cali-contract-reviewer (contract drift), cali-qa (test coverage against docs/12), cali-backend (security/IDOR).
Name them reviewer, qa, backend. Each one reports findings; don't edit code.
```

```text
Create an agent team for backlog item <ID>. Spawn cali-backend named "be" and cali-qa named "qa".
be implements the endpoint per contracts/openapi.yaml; qa writes integration tests in backend/tests first.
Wait for your teammates to finish before you integrate.
```

3. Controls: ↑/↓ selects a teammate, Enter opens it and lets you message it, Esc interrupts it, `x` stops it, Ctrl+T shows the task list, Shift+Tab changes a teammate's permission mode.
4. To finish, tell the lead "shut down all teammates". The team config is deleted when the session ends. The task list stays in `~/.claude/tasks/`.

## Notes
- Teams cost far more tokens than a single session. Start with 2–4 teammates and give them review or research tasks before parallel implementation.
- Never give two teammates the same file. The ownership table above exists to prevent overwrites.
- Teammates don't see the lead's history, so put the backlog ID, the files involved and the definition of done in the spawn prompt.
- Teammates don't load `skills:` from their definitions. `/resume` doesn't restore in-process teammates. You get one team per session, and teams can't nest.
- Set `"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "0"` to turn the feature off. With teams on, any subagent that Claude names becomes a teammate.
- Teammates start with the lead's permission mode, and their permission requests come back to the lead.
