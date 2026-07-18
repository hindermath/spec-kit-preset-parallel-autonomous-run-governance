# Parallel Autonomous Run Governance Preset

Version: `0.1.0`
Status: experimental, opt-in
Priority: `80`
Requires: Spec Kit `>=0.8.3` and `autonomous-run-governance >=0.2.2`

## Purpose / Zweck

This preset coordinates several isolated autonomous Spec Kit runs. It supports
replicated targets, independent features, human-selected alternatives, and
dependency-ordered pipelines. It does not replace the single-run lifecycle and
does not grant execution or remote authority.

*Dieses Preset koordiniert mehrere isolierte autonome Spec-Kit-Laeufe. Es
unterstuetzt gleiche Auftraege in mehreren Zielen, unabhaengige Features,
menschlich ausgewaehlte Alternativen und abhaengigkeitsgeordnete Pipelines. Es
ersetzt nicht den Einzelrun-Lebenszyklus und erteilt keine Ausfuehrungs- oder
Remote-Berechtigung.*

## Install

```bash
specify preset add --dev /path/to/parallel-autonomous-run-governance --priority 80
specify preset info parallel-autonomous-run-governance
```

Version `0.1.0` remains opt-in until deterministic tests, real local development
campaigns, and the Secure CaseTracker Units 00-03 field campaign have passed.

The 13-worker native macOS smoke passed all four topologies. See
[`docs/field-evidence/native-macos-smoke-2026-07-18.md`](docs/field-evidence/native-macos-smoke-2026-07-18.md).

## Development Validation Override

The repository owner explicitly authorized the 2026-07-18 smoke and Secure
CaseTracker field campaigns to run natively on the development Mac. This
temporary, campaign-specific exception must be recorded in campaign evidence.
It does not change the workspace Container-First default for normal Secure
Trader, learner, production, maintenance, or later campaign work.

*Der Repository-Eigentuemer hat die Smoke- und Secure-CaseTracker-Feldkampagnen
vom 2026-07-18 ausdruecklich fuer eine native Ausfuehrung auf dem
Entwicklungs-Mac freigegeben. Diese temporaere, kampagnenspezifische Ausnahme
muss in der Kampagnenevidenz dokumentiert werden. Sie aendert nicht den
Container-First-Standard fuer regulaere Secure-Trader-, Lernenden-, Produktions-,
Wartungs- oder spaetere Kampagnen.*

## Coordinator

```bash
bash .specify/presets/parallel-autonomous-run-governance/scripts/orchestrate-parallel-autonomous-runs.sh \
  -Action Validate \
  -Manifest specs/NNN-campaign/parallel-campaign.json \
  -RunnerConfig ~/.config/spec-kit/parallel-runner-profiles.json
```

```powershell
pwsh -NoProfile -File .specify/presets/parallel-autonomous-run-governance/scripts/orchestrate-parallel-autonomous-runs.ps1 `
  -Action Validate `
  -Manifest specs/NNN-campaign/parallel-campaign.json `
  -RunnerConfig ~/.config/spec-kit/parallel-runner-profiles.json
```

Runner profiles contain executable names and argument arrays, not secrets.
Arguments are executed directly. Do not use shell expressions in a profile.

## Safety

- Maximum supported concurrency is three.
- Every worker owns a separate branch and worktree.
- Stop is cooperative and grants no process-kill authority.
- Alternative consolidation requires explicit human selection.
- Merge-and-sync uses an all-ready barrier and stops on the first merge error.
- Installation grants no remote, merge, bypass, cancellation, secret, or
  provider-administration rights.
