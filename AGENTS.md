

## AI handoff maintenance

At session start, read README.md, PROJECT_CONTEXT.md, HANDOFF.md, AGENTS.md and applicable nested instructions. Inspect the current Git branch, status and upstream before editing. Treat documentation as context, not evidence that an operation has already succeeded.

After every meaningful development session, before stopping or handing off:

1. Update HANDOFF.md with the actual branch and relevant commit, changes, checks performed and results, remaining issues, uncommitted work, decisions and the next concrete steps. State checks that were not run.
2. Update PROJECT_CONTEXT.md whenever purpose, architecture, setup, dependencies, configuration, data contracts, constraints or accepted decisions change. Preserve useful decision rationale without copying transcripts.
3. Update relevant existing progress/setup documents and README links; keep documentation consistent.
4. Describe required secrets by environment-variable name or secure setup mechanism only. Never include secret values, chat transcripts, private candidate records or unrelated personal data.
5. Fetch current remote refs and compare all relevant device/archive branches before recommending branch promotion or deduplication. Never force-push, delete branches, rewrite history, invent shared ancestry or silently merge divergent versions. Preserve meaningful alternate work.
6. If interrupted, leave the most current factual handoff possible and identify unverified assumptions. An instruction to maintain handoff files does not grant permission to commit, push, deploy or take external actions.
