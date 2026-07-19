---
description: Request a cooperative stop at parallel campaign safe boundaries.
---

Set the campaign stop request after validating identity. Start no new workers.
Do not kill agent, test, build, provider, or merge processes. Let active workers
reach their existing autonomous safe boundary, then persist `PausedByUser` or
`Interrupted` from observed evidence.

During consolidation, honor the same request between provider preflights,
merge commands, synchronization, post-merge actions, and final validation.

*DE: Stop gilt auch waehrend der Konsolidierung und wird zwischen sicheren
Merge- und Closeout-Schritten beachtet.*
