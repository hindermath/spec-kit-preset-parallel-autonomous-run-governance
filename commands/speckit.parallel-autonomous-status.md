---
description: Inspect a parallel autonomous campaign without changing it.
---

Read the campaign manifest, state, runtime result files, Git worktrees, and
referenced autonomous states. Report queued, running, completed, failed,
blocked, interrupted, and ready workers; observed concurrency; missing or stale
evidence; stop state; selection state; and the next exact action.

Status is read-only. A running marker without a trustworthy live process or
result is `Interrupted`, never success.
