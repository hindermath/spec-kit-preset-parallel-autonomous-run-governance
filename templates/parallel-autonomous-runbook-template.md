# Parallel Autonomous Campaign Runbook

## Identity And Scope

| Field | Value |
|---|---|
| Campaign ID | `[UUID]` |
| Topology | `[ReplicatedTargets/IndependentFeatures/AlternativeSolutions/Pipeline]` |
| Delivery mode | `[LocalImplementation/PublishPR/MergeAndSync]` |
| Maximum concurrency | `[1-3]` |
| Runner profile | `[profile]` |
| Execution environment | `[native/container + identifier]` |

## Authority

Installation is not execution authority. Record current local, publish, merge,
bypass, cancellation, secret, and provider-administration authority separately.
Ambiguity defaults to `LocalImplementation`.

## Policy Exception

If the campaign uses an explicit owner override, record the authorizer, exact
scope, reason, authorization date, expiry condition, and policies affected.
An exception recorded here applies only to this campaign and does not amend the
underlying workspace policy.

## Isolation

Each worker owns one branch and one linked worktree. Runtime logs, locks, and
local runner bindings stay outside tracked feature artifacts. The normal
checkout is never switched or reset.

Sequential workers in one repository may declare `baseWorkerId`. It must name
a direct dependency in the same repository. The coordinator creates the new
branch from that predecessor's validated exact head, not from a moving branch
name.

## Scheduling

Ordinary worker failures do not cancel unrelated running workers. Pipeline
descendants wait for validated immutable handoffs. Campaign-integrity,
security, permission, and evidence-integrity failures stop new scheduling.

## Stop And Resume

A cooperative stop prevents new workers and lets active workers reach their
safe boundary. After interruption, reconcile process outcome, Git state,
worker result, autonomous state, and evidence before retry.

## Consolidation

Alternative solutions require a named human selection. A `MergeAndSync`
campaign first publishes every worker. All workers must then pass exact-head
gates and reviews before the first deterministic merge. Stop after the first
merge failure and record any unavoidable partial state.
