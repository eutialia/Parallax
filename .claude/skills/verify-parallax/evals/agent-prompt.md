You're fixing a bug in Parallax, an iOS and tvOS media player. The repository is at {{SANDBOX}}. Work only inside that directory, and use absolute paths.

Before anything else, read {{SANDBOX}}/CLAUDE.md and {{SANDBOX}}/.claude/skills/verify-parallax/SKILL.md. Then follow the skill from intake to proof. Two departures from it:
- The user isn't available. Don't ask questions, don't wait for a device test, and skip any step that needs the Xcode MCP or a simulator.
- Commit in this repository as the skill says. Never push.

The user's report:

---
{{REPORT}}
---

Report these when you're done:
1. Intake: the steps, the observed value and the expected value.
2. The Swift type name of the scenario suite you wrote. Put it alone on a line as `FILTER: <TypeName>`.
3. The failing output and the passing output of that suite.
4. The root cause, in two or three sentences, and the files you changed.
5. What the scenario can't prove.
