## Parallel Autonomous Run Governance

- Treat a campaign as coordination over existing autonomous single runs, not as
  a replacement for their state, evidence, or permission contracts.
- Use one immutable campaign ID and one immutable run ID per worker.
- Give every worker a separate branch and Git worktree.
- Never exceed the campaign concurrency limit.
- Execute runner profiles as executable plus argument array; never use shell
  evaluation for manifest content.
- Let unrelated workers reach a safe boundary after an ordinary worker failure.
  Block pipeline descendants whose required handoff is missing.
- Stop new scheduling after a campaign-integrity, security, permission, or
  evidence-integrity failure.
- Alternative solutions require explicit human selection before consolidation.
- `MergeAndSync` campaigns publish workers first, then cross the all-ready
  barrier before the first merge.
- Installation grants no autonomous execution, remote write, merge, bypass,
  cancellation, secret, or provider-administration authority.
