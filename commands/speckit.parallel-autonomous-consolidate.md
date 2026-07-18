---
description: Consolidate campaign results under explicit current authority.
---

For `AlternativeSolutions`, require a named human-selected worker and reject
automatic scoring or merging of several candidates.

For `MergeAndSync`, require every eligible worker to be `ReadyForMerge` with an
exact reviewed head, passing required checks, no actionable review thread, and
current explicit merge authority. Cross the all-ready barrier before the first
merge. Revalidate immediately before each merge, follow declared order, and
stop after the first failure. Record already merged and remaining workers;
never claim cross-repository atomicity.
