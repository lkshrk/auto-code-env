---
description: Implement a Linear ticket on a new branch.
agent: build
---

Implement Linear ticket $ARGUMENTS.

1. Read the ticket, its comments and linked documents with the Linear tools. Restate the goal and the acceptance criteria in a few lines. If they are unclear or contradict the code, stop and ask.
2. Create a branch `<ticket-id-lowercase>-<short-slug>` from the default branch.
3. Implement the smallest change that meets the acceptance criteria. Stay inside the ticket's scope; note anything else you notice instead of doing it.
4. Run the repository's checks and fix failures you caused.
5. Commit with a Conventional Commit message that references the ticket id.
6. Report: what changed, the checks you ran and their results, open questions. Do not push or open a PR unless asked.
