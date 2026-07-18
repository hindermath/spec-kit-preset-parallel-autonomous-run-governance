#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v pwsh >/dev/null 2>&1; then
  printf 'Fehler: PowerShell 7 (pwsh) ist fuer den strukturierten Campaign-Kern erforderlich.\n' >&2
  exit 2
fi

exec pwsh -NoLogo -NoProfile -File \
  "$script_dir/orchestrate-parallel-autonomous-runs.ps1" "$@"
