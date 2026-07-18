# Parallel Autonomous Campaign Evidence

## Campaign

| Field | Value |
|---|---|
| Campaign ID | `[UUID]` |
| Manifest SHA-256 | `[sha256]` |
| Execution environment | `[native/container]` |
| Environment identifier | `[host platform or image digest]` |
| Agent family | `[agent]` |
| Policy override | `[authorizer, date, scope, expiry or N/A]` |
| Configured concurrency | `[count]` |
| Maximum observed concurrency | `[count]` |

## Workers

| Worker | Run ID | Repository | Head | Autonomous state | Gates | Result |
|---|---|---|---|---|---|---|
| `[id]` | `[UUID]` | `[repo]` | `[sha]` | `[path + hash]` | `[evidence]` | `[status]` |

## Handoffs

| Producer | Consumer | Path | SHA-256 | Validation |
|---|---|---|---|---|
| `[worker]` | `[worker]` | `[path]` | `[sha256]` | `[Pass/Open]` |

## Consolidation

Record the all-ready barrier, human alternative selection where applicable,
deterministic merge order, each exact reviewed head, and any partial remote
state. Evidence documents authority but never grants it.
