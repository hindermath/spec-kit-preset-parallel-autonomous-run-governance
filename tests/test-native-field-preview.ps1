#Requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsMacOS) {
    Write-Output 'SKIP: the historical field wrapper is macOS-only.'
    exit 0
}

$wrapper = Join-Path $PSScriptRoot 'run-native-secure-casetracker-field.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('parallel-field-preview-' + [guid]::NewGuid().ToString('N'))
try {
    [void](New-Item -ItemType Directory -Path $root)
    '{}' | Set-Content -LiteralPath (Join-Path $root 'parallel-campaign.json') -Encoding utf8NoBOM
    '{}' | Set-Content -LiteralPath (Join-Path $root 'parallel-runner-profiles.json') -Encoding utf8NoBOM

    foreach ($action in @('Start', 'Stop', 'Resume', 'Consolidate')) {
        $arguments = @('-NoProfile', '-File', $wrapper, '-Action', $action, '-OutputRoot', $root, '-WhatIf')
        if ($action -eq 'Consolidate') { $arguments += '-Merge' }
        $output = @(& pwsh @arguments 2>&1)
        if ($LASTEXITCODE -ne 0 -or -not ($output -match "Preview: $action would invoke")) {
            throw "-WhatIf did not stop $action before child dispatch: $($output -join ' ')"
        }
        if ((Test-Path -LiteralPath (Join-Path $root 'parallel-campaign-state.json')) -or
            (Test-Path -LiteralPath (Join-Path $root 'runtime'))) {
            throw "-WhatIf wrote campaign state for $action."
        }
    }
    Write-Output 'PASS: all mutating field actions stop before coordinator dispatch under -WhatIf.'
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
