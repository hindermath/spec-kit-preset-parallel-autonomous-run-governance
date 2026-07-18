<#
.SYNOPSIS
    Validiert und koordiniert parallele autonome Spec-Kit-Laeufe.

.DESCRIPTION
    DE: Verwendet ein versioniertes Campaign-Manifest und lokale Runner-Profile,
    erstellt getrennte Git-Worktrees, begrenzt Parallelitaet auf hoechstens
    drei Worker und fuehrt Stop, Resume und Konsolidierung evidenzbasiert aus.

    EN: Uses a versioned campaign manifest and local runner profiles, creates
    isolated Git worktrees, limits concurrency to at most three workers, and
    performs stop, resume, and consolidation from evidence.

.PARAMETER Action
    Validate, Start, Status, Stop, Resume oder Consolidate.

.PARAMETER Manifest
    Pfad zum parallel-campaign.json.

.PARAMETER RunnerConfig
    Lokale JSON-Datei mit Executable/Argument-Array-Profilen.

.PARAMETER State
    Optionaler Pfad zur Campaign-State-Datei.

.PARAMETER RuntimeRoot
    Nicht versioniertes Verzeichnis fuer Worktrees, Logs, Locks und Ergebnisse.

.PARAMETER SelectedWorker
    Menschlich ausgewaehlter Worker fuer AlternativeSolutions.

.PARAMETER Merge
    Fuehrt bei Consolidate die konfigurierte Merge-Command aus.

.EXAMPLE
    pwsh -NoProfile -File scripts/orchestrate-parallel-autonomous-runs.ps1 -Action Validate -Manifest campaign.json -RunnerConfig runners.json

.EXAMPLE
    pwsh -NoProfile -File scripts/orchestrate-parallel-autonomous-runs.ps1 -Action Start -Manifest campaign.json -RunnerConfig runners.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Validate', 'Start', 'Status', 'Stop', 'Resume', 'Consolidate')]
    [string] $Action,

    [Parameter(Mandatory)]
    [string] $Manifest,

    [string] $RunnerConfig = '',
    [string] $State = '',
    [string] $RuntimeRoot = '',
    [string] $SelectedWorker = '',
    [switch] $Merge
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-PARCondition {
    param(
        [Parameter(Mandatory)][bool] $Condition,
        [Parameter(Mandatory)][string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Read-PARJson {
    param([Parameter(Mandatory)][string] $Path)

    Assert-PARCondition (Test-Path -LiteralPath $Path -PathType Leaf) "JSON-Datei fehlt: $Path"
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
}

function Write-PARJsonAtomic {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)] $Value
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }
    $temp = "${Path}.tmp.$PID"
    $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temp -Encoding utf8NoBOM
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Get-PARSha256 {
    param([Parameter(Mandatory)][string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-PARUuid {
    param([Parameter(Mandatory)][string] $Value)
    $parsed = [guid]::Empty
    return [guid]::TryParse($Value, [ref] $parsed) -and $parsed -ne [guid]::Empty
}

function Invoke-PARGit {
    param(
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string[]] $Arguments,
        [switch] $AllowFailure
    )

    $output = & git -C $Repository @Arguments 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "git -C $Repository $($Arguments -join ' ') fehlgeschlagen: $($output -join [Environment]::NewLine)"
    }
    return @{
        ExitCode = $code
        Output = @($output)
    }
}

function Resolve-PARRepository {
    param(
        [Parameter(Mandatory)][string] $Value,
        [Parameter(Mandatory)][string] $ManifestDirectory
    )

    if ([IO.Path]::IsPathRooted($Value)) {
        return [IO.Path]::GetFullPath($Value)
    }
    return [IO.Path]::GetFullPath((Join-Path $ManifestDirectory $Value))
}

function Get-PARWorkerState {
    param(
        [Parameter(Mandatory)][hashtable] $CampaignState,
        [Parameter(Mandatory)][string] $WorkerId
    )
    return @($CampaignState.workers | Where-Object { $_.workerId -eq $WorkerId })[0]
}

function Test-PARAutonomousPreset {
    param([Parameter(Mandatory)][string] $Repository)

    $registryPath = Join-Path $Repository '.specify/presets/.registry'
    if (-not (Test-Path -LiteralPath $registryPath -PathType Leaf)) {
        return $false
    }
    $registry = Read-PARJson $registryPath
    if (-not $registry.presets.ContainsKey('autonomous-run-governance')) {
        return $false
    }
    $entry = $registry.presets['autonomous-run-governance']
    if (-not [bool] $entry.enabled) {
        return $false
    }
    return [version] $entry.version -ge [version] '0.2.2'
}

function Test-PARDag {
    param([Parameter(Mandatory)][object[]] $Workers)

    $known = @{}
    $inDegree = @{}
    $children = @{}
    foreach ($worker in $Workers) {
        $known[$worker.workerId] = $true
        $inDegree[$worker.workerId] = 0
        $children[$worker.workerId] = [Collections.Generic.List[string]]::new()
    }
    foreach ($worker in $Workers) {
        foreach ($dependency in @($worker.dependsOn)) {
            Assert-PARCondition $known.ContainsKey($dependency) "Unbekannte Abhaengigkeit '$dependency' bei '$($worker.workerId)'."
            Assert-PARCondition ($dependency -ne $worker.workerId) "Worker '$($worker.workerId)' darf nicht von sich selbst abhaengen."
            $inDegree[$worker.workerId]++
            $children[$dependency].Add($worker.workerId)
        }
    }
    foreach ($worker in $Workers) {
        foreach ($dependency in @($worker.dependsOn)) {
            $producer = @($Workers | Where-Object { $_.workerId -eq $dependency })[0]
            $matchingHandoffs = @($producer.handoffs | Where-Object { $_.consumerWorkerId -eq $worker.workerId })
            Assert-PARCondition ($matchingHandoffs.Count -eq 1) "Pipeline-Abhaengigkeit '$dependency' -> '$($worker.workerId)' benoetigt genau einen deklarierten Handoff."
            Assert-PARCondition (-not [string]::IsNullOrWhiteSpace([string] $matchingHandoffs[0].path)) "Handoff '$dependency' -> '$($worker.workerId)' benoetigt einen Pfad."
        }
    }
    $queue = [Collections.Generic.Queue[string]]::new()
    foreach ($id in $inDegree.Keys) {
        if ($inDegree[$id] -eq 0) {
            $queue.Enqueue($id)
        }
    }
    $visited = 0
    while ($queue.Count -gt 0) {
        $id = $queue.Dequeue()
        $visited++
        foreach ($child in $children[$id]) {
            $inDegree[$child]--
            if ($inDegree[$child] -eq 0) {
                $queue.Enqueue($child)
            }
        }
    }
    Assert-PARCondition ($visited -eq $Workers.Count) 'Die Worker-Abhaengigkeiten enthalten einen Zyklus.'
}

function Test-PARCampaign {
    param(
        [Parameter(Mandatory)][hashtable] $Campaign,
        [Parameter(Mandatory)][hashtable] $Profiles,
        [Parameter(Mandatory)][string] $ManifestDirectory,
        [switch] $SkipCleanCheck
    )

    Assert-PARCondition ($Campaign.schemaVersion -eq '1.0') 'Campaign schemaVersion muss 1.0 sein.'
    Assert-PARCondition (Test-PARUuid ([string] $Campaign.campaignId)) 'campaignId muss eine nichtleere UUID sein.'
    Assert-PARCondition (@('ReplicatedTargets', 'IndependentFeatures', 'AlternativeSolutions', 'Pipeline') -contains $Campaign.topology) 'Unbekannte Campaign-Topologie.'
    Assert-PARCondition (@('LocalImplementation', 'PublishPR', 'MergeAndSync') -contains $Campaign.deliveryMode) 'Unbekannter deliveryMode.'
    Assert-PARCondition ([int] $Campaign.maxConcurrency -ge 1 -and [int] $Campaign.maxConcurrency -le 3) 'maxConcurrency muss zwischen 1 und 3 liegen.'
    Assert-PARCondition ($Campaign.workers.Count -gt 0) 'Mindestens ein Worker ist erforderlich.'
    Assert-PARCondition $Profiles.profiles.ContainsKey([string] $Campaign.runnerProfile) "Runner-Profil '$($Campaign.runnerProfile)' fehlt."

    $runnerProfileData = $Profiles.profiles[[string] $Campaign.runnerProfile]
    Assert-PARCondition (-not [string]::IsNullOrWhiteSpace([string] $runnerProfileData.executable)) 'Runner executable fehlt.'
    Assert-PARCondition ($runnerProfileData.arguments -is [object[]]) 'Runner arguments muss ein Array sein.'

    $workerIds = @($Campaign.workers | ForEach-Object { [string] $_.workerId })
    $runIds = @($Campaign.workers | ForEach-Object { [string] $_.runId })
    $branches = @($Campaign.workers | ForEach-Object { [string] $_.branch })
    Assert-PARCondition (($workerIds | Sort-Object -Unique).Count -eq $workerIds.Count) 'workerId muss eindeutig sein.'
    Assert-PARCondition (($runIds | Sort-Object -Unique).Count -eq $runIds.Count) 'runId muss eindeutig sein.'
    Assert-PARCondition (($branches | Sort-Object -Unique).Count -eq $branches.Count) 'branch muss campaignweit eindeutig sein.'

    foreach ($worker in $Campaign.workers) {
        Assert-PARCondition (-not [string]::IsNullOrWhiteSpace([string] $worker.workerId)) 'workerId darf nicht leer sein.'
        Assert-PARCondition (Test-PARUuid ([string] $worker.runId)) "runId von '$($worker.workerId)' ist keine UUID."
        Assert-PARCondition (-not [string]::IsNullOrWhiteSpace([string] $worker.branch)) "branch von '$($worker.workerId)' fehlt."
        $repository = Resolve-PARRepository ([string] $worker.repository) $ManifestDirectory
        Assert-PARCondition (Test-Path -LiteralPath $repository -PathType Container) "Repository fehlt: $repository"
        $inside = Invoke-PARGit $repository @('rev-parse', '--is-inside-work-tree') -AllowFailure
        Assert-PARCondition ($inside.ExitCode -eq 0) "Kein Git-Worktree: $repository"
        $baseWorkerId = if ($worker.ContainsKey('baseWorkerId')) { [string] $worker.baseWorkerId } else { '' }
        if ([string]::IsNullOrWhiteSpace($baseWorkerId)) {
            Assert-PARCondition (-not [string]::IsNullOrWhiteSpace([string] $worker.baseRef)) "baseRef oder baseWorkerId von '$($worker.workerId)' fehlt."
            $base = Invoke-PARGit $repository @('rev-parse', '--verify', "$($worker.baseRef)^{commit}") -AllowFailure
            Assert-PARCondition ($base.ExitCode -eq 0) "baseRef '$($worker.baseRef)' fehlt in $repository."
        } else {
            Assert-PARCondition ($workerIds -contains $baseWorkerId) "baseWorkerId '$baseWorkerId' von '$($worker.workerId)' ist unbekannt."
            Assert-PARCondition (@($worker.dependsOn) -contains $baseWorkerId) "baseWorkerId '$baseWorkerId' muss direkte Abhaengigkeit von '$($worker.workerId)' sein."
            $baseWorker = @($Campaign.workers | Where-Object { $_.workerId -eq $baseWorkerId })[0]
            $baseRepository = Resolve-PARRepository ([string] $baseWorker.repository) $ManifestDirectory
            Assert-PARCondition ($baseRepository -eq $repository) "baseWorkerId '$baseWorkerId' muss dasselbe Repository wie '$($worker.workerId)' verwenden."
        }
        if (-not $SkipCleanCheck) {
            $dirty = Invoke-PARGit $repository @('status', '--porcelain')
            Assert-PARCondition ($dirty.Output.Count -eq 0) "Repository ist nicht sauber: $repository"
        }
        if ([bool] $Campaign.requireAutonomousPreset) {
            Assert-PARCondition (Test-PARAutonomousPreset $repository) "autonomous-run-governance >= 0.2.2 fehlt oder ist deaktiviert: $repository"
        }
    }

    Test-PARDag @($Campaign.workers)

    $mergeOrder = @($Campaign.consolidation.mergeOrder)
    Assert-PARCondition ($mergeOrder.Count -eq $workerIds.Count) 'mergeOrder muss jeden Worker genau einmal enthalten.'
    Assert-PARCondition (($mergeOrder | Sort-Object -Unique).Count -eq $workerIds.Count) 'mergeOrder enthaelt Duplikate.'
    foreach ($id in $mergeOrder) {
        Assert-PARCondition ($workerIds -contains $id) "mergeOrder enthaelt unbekannten Worker '$id'."
    }
    if ($Campaign.topology -eq 'AlternativeSolutions') {
        Assert-PARCondition ([bool] $Campaign.consolidation.humanSelectionRequired) 'AlternativeSolutions erfordert humanSelectionRequired=true.'
    }
}

function Get-PARInitialCampaignState {
    param(
        [Parameter(Mandatory)][hashtable] $Campaign,
        [Parameter(Mandatory)][string] $ManifestPath
    )

    $workerStates = foreach ($worker in $Campaign.workers) {
        [ordered]@{
            workerId = [string] $worker.workerId
            runId = [string] $worker.runId
            status = 'Pending'
            worktree = 'N/A'
            processId = $null
            exitCode = $null
            headSha = 'N/A'
            autonomousStatePath = 'N/A'
            autonomousStateSha256 = 'N/A'
            resultPath = 'N/A'
            prUrl = $null
            handoffs = @()
            summary = 'Not started.'
        }
    }
    return [ordered]@{
        schemaVersion = '1.0'
        campaignId = [string] $Campaign.campaignId
        manifestSha256 = Get-PARSha256 $ManifestPath
        status = 'Prepared'
        phase = 'Preflight'
        deliveryMode = [string] $Campaign.deliveryMode
        stopRequested = $false
        selectedWorkerId = $null
        maximumObservedConcurrency = 0
        workers = @($workerStates)
        updatedAt = [DateTime]::UtcNow.ToString('o')
    }
}

function Set-PARStateTimestamp {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Mutates only the in-memory campaign state passed by the caller.')]
    param([Parameter(Mandatory)][hashtable] $CampaignState)
    $CampaignState.updatedAt = [DateTime]::UtcNow.ToString('o')
}

function ConvertTo-PARArgumentList {
    param(
        [Parameter(Mandatory)][object[]] $Arguments,
        [Parameter(Mandatory)][hashtable] $Values
    )

    $expanded = foreach ($argument in $Arguments) {
        $value = [string] $argument
        foreach ($key in $Values.Keys) {
            $value = $value.Replace("{$key}", [string] $Values[$key])
        }
        $value
    }
    return @($expanded)
}

function Invoke-PARProcessAsync {
    param(
        [Parameter(Mandatory)][string] $Executable,
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][string] $StdoutPath,
        [Parameter(Mandatory)][string] $StderrPath
    )

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Executable
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        [void] $psi.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    Assert-PARCondition $process.Start() "Runner konnte nicht gestartet werden: $Executable"
    return @{
        Process = $process
        StdoutTask = $process.StandardOutput.ReadToEndAsync()
        StderrTask = $process.StandardError.ReadToEndAsync()
        StdoutPath = $StdoutPath
        StderrPath = $StderrPath
    }
}

function Complete-PARWorker {
    param(
        [Parameter(Mandatory)][hashtable] $RunningEntry,
        [Parameter(Mandatory)][hashtable] $WorkerState,
        [Parameter(Mandatory)][hashtable] $Worker,
        [Parameter(Mandatory)][hashtable] $Campaign,
        [Parameter(Mandatory)][string] $ResultPath
    )

    $process = $RunningEntry.Process.Process
    $stdout = $RunningEntry.Process.StdoutTask.GetAwaiter().GetResult()
    $stderr = $RunningEntry.Process.StderrTask.GetAwaiter().GetResult()
    $stdout | Set-Content -LiteralPath $RunningEntry.Process.StdoutPath -Encoding utf8NoBOM
    $stderr | Set-Content -LiteralPath $RunningEntry.Process.StderrPath -Encoding utf8NoBOM
    $WorkerState.exitCode = $process.ExitCode
    $WorkerState.processId = $null

    if ($process.ExitCode -ne 0) {
        $WorkerState.status = 'Failed'
        $WorkerState.summary = "Runner exit code $($process.ExitCode)."
        return
    }

    if (-not (Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
        $head = (Invoke-PARGit $RunningEntry.Worktree @('rev-parse', 'HEAD')).Output[0]
        $autonomousStates = @(Get-ChildItem -LiteralPath (Join-Path $RunningEntry.Worktree 'specs') -Filter 'autonomous-run-state.json' -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
        if ([bool] $Campaign.requireAutonomousPreset -and $autonomousStates.Count -eq 0) {
            $WorkerState.status = 'Failed'
            $WorkerState.summary = 'Runner succeeded but produced no autonomous-run-state.json.'
            return
        }
        $statePath = if ($autonomousStates.Count -gt 0) { $autonomousStates[0].FullName } else { 'N/A' }
        $stateHash = if ($statePath -ne 'N/A') { Get-PARSha256 $statePath } else { 'N/A' }
        $relativeState = if ($statePath -ne 'N/A') { [IO.Path]::GetRelativePath($RunningEntry.Worktree, $statePath) } else { 'N/A' }
        $derivedStatus = if ($Campaign.deliveryMode -eq 'LocalImplementation') { 'Completed' } else { 'ReadyForMerge' }
        $derivedHandoffs = @()
        foreach ($declaredHandoff in @($Worker.handoffs)) {
            $handoffPath = [IO.Path]::GetFullPath((Join-Path $RunningEntry.Worktree ([string] $declaredHandoff.path)))
            $worktreePrefix = [IO.Path]::GetFullPath($RunningEntry.Worktree).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            if (-not $handoffPath.StartsWith($worktreePrefix, [StringComparison]::Ordinal) -or
                -not (Test-Path -LiteralPath $handoffPath -PathType Leaf)) {
                $WorkerState.status = 'Failed'
                $WorkerState.summary = "Runner succeeded but did not produce declared handoff '$($declaredHandoff.path)'."
                return
            }
            $derivedHandoffs += [ordered]@{
                consumerWorkerId = [string] $declaredHandoff.consumerWorkerId
                path = [string] $declaredHandoff.path
                sha256 = Get-PARSha256 $handoffPath
            }
        }
        $result = [ordered]@{
            schemaVersion = '1.0'
            campaignId = [string] $Campaign.campaignId
            workerId = [string] $Worker.workerId
            runId = [string] $Worker.runId
            status = $derivedStatus
            headSha = [string] $head
            autonomousStatePath = $relativeState
            autonomousStateSha256 = $stateHash
            evidencePath = 'N/A'
            prUrl = $null
            handoffs = @($derivedHandoffs)
            summary = 'Derived from successful runner exit.'
        }
        Write-PARJsonAtomic $ResultPath $result
    }

    $resultData = Read-PARJson $ResultPath
    Assert-PARCondition ($resultData.schemaVersion -eq '1.0') "Worker result schemaVersion ist ungueltig: $ResultPath"
    Assert-PARCondition ($resultData.campaignId -eq $Campaign.campaignId) "Worker result campaignId stimmt nicht: $ResultPath"
    Assert-PARCondition ($resultData.workerId -eq $Worker.workerId) "Worker result workerId stimmt nicht: $ResultPath"
    Assert-PARCondition ($resultData.runId -eq $Worker.runId) "Worker result runId stimmt nicht: $ResultPath"
    Assert-PARCondition (@('Completed', 'ReadyForMerge', 'Failed') -contains $resultData.status) "Worker result status ist ungueltig: $ResultPath"
    if ($Campaign.deliveryMode -eq 'MergeAndSync') {
        Assert-PARCondition ($resultData.status -eq 'ReadyForMerge') "MergeAndSync worker must stop at ReadyForMerge: $ResultPath"
        Assert-PARCondition (-not [string]::IsNullOrWhiteSpace([string] $resultData.prUrl)) "MergeAndSync worker result requires prUrl: $ResultPath"
    }
    $actualHead = (Invoke-PARGit $RunningEntry.Worktree @('rev-parse', 'HEAD')).Output[0]
    Assert-PARCondition ($resultData.headSha -eq $actualHead) "Worker result headSha ist nicht der aktuelle Worktree-Head: $ResultPath"

    $validatedHandoffs = @()
    foreach ($declaredHandoff in @($Worker.handoffs)) {
        $resultHandoffs = @($resultData.handoffs | Where-Object {
            $_.consumerWorkerId -eq $declaredHandoff.consumerWorkerId -and $_.path -eq $declaredHandoff.path
        })
        Assert-PARCondition ($resultHandoffs.Count -eq 1) "Worker '$($Worker.workerId)' lieferte den deklarierten Handoff zu '$($declaredHandoff.consumerWorkerId)' nicht eindeutig."
        $handoffPath = [IO.Path]::GetFullPath((Join-Path $RunningEntry.Worktree ([string] $declaredHandoff.path)))
        $worktreePrefix = [IO.Path]::GetFullPath($RunningEntry.Worktree).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        Assert-PARCondition ($handoffPath.StartsWith($worktreePrefix, [StringComparison]::Ordinal)) "Handoff verlaesst den Worker-Worktree: $handoffPath"
        Assert-PARCondition (Test-Path -LiteralPath $handoffPath -PathType Leaf) "Handoff-Datei fehlt: $handoffPath"
        $actualHash = Get-PARSha256 $handoffPath
        Assert-PARCondition ($resultHandoffs[0].sha256 -eq $actualHash) "Handoff-Hash stimmt nicht: $handoffPath"
        $validatedHandoffs += [ordered]@{
            consumerWorkerId = [string] $declaredHandoff.consumerWorkerId
            path = [string] $declaredHandoff.path
            sourcePath = $handoffPath
            sha256 = $actualHash
        }
    }

    $WorkerState.status = [string] $resultData.status
    $WorkerState.headSha = [string] $resultData.headSha
    $WorkerState.autonomousStatePath = [string] $resultData.autonomousStatePath
    $WorkerState.autonomousStateSha256 = [string] $resultData.autonomousStateSha256
    $WorkerState.resultPath = $ResultPath
    $WorkerState.prUrl = $resultData.prUrl
    $WorkerState.handoffs = @($validatedHandoffs)
    $WorkerState.summary = [string] $resultData.summary
}

function Invoke-PARStart {
    param(
        [Parameter(Mandatory)][hashtable] $Campaign,
        [Parameter(Mandatory)][hashtable] $Profiles,
        [Parameter(Mandatory)][string] $ManifestPath,
        [Parameter(Mandatory)][string] $ManifestDirectory,
        [Parameter(Mandatory)][string] $StatePath,
        [Parameter(Mandatory)][string] $RuntimePath,
        [switch] $IsResume
    )

    [void](New-Item -ItemType Directory -Path $RuntimePath -Force)
    $lockPath = Join-Path $RuntimePath 'campaign.lock'
    try {
        [void](New-Item -ItemType Directory -Path $lockPath -ErrorAction Stop)
    } catch {
        throw "Campaign-Lock ist bereits aktiv: $lockPath"
    }

    try {
        if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
            $campaignState = Read-PARJson $StatePath
            Assert-PARCondition ($campaignState.campaignId -eq $Campaign.campaignId) 'State campaignId stimmt nicht mit Manifest ueberein.'
            Assert-PARCondition ($campaignState.manifestSha256 -eq (Get-PARSha256 $ManifestPath)) 'Manifest hat sich seit dem State-Checkpoint geaendert.'
            if (-not $IsResume) {
                Assert-PARCondition (@('Prepared', 'PausedByUser', 'Interrupted') -contains $campaignState.status) 'Bestehende Campaign ist nicht startbar; Resume oder Status verwenden.'
            }
        } else {
            $campaignState = Get-PARInitialCampaignState $Campaign $ManifestPath
        }

        if ($IsResume) {
            Assert-PARCondition (@('PausedByUser', 'Interrupted', 'Failed') -contains $campaignState.status) 'Campaign ist nicht in einem Resume-faehigen Zustand.'
            foreach ($workerState in $campaignState.workers) {
                if (@('Interrupted', 'Running') -contains $workerState.status) {
                    $workerState.status = 'Pending'
                    $workerState.processId = $null
                    $workerState.summary = 'Revalidated for resume.'
                }
            }
            $campaignState.stopRequested = $false
        }

        $campaignState.status = 'Active'
        $campaignState.phase = 'Execute'
        Set-PARStateTimestamp $campaignState
        Write-PARJsonAtomic $StatePath $campaignState

        $runnerProfileData = $Profiles.profiles[[string] $Campaign.runnerProfile]
        $running = @{}
        $worktreesRoot = Join-Path $RuntimePath 'worktrees'
        $logsRoot = Join-Path $RuntimePath 'logs'
        $resultsRoot = Join-Path $RuntimePath 'results'
        $promptsRoot = Join-Path $RuntimePath 'prompts'
        foreach ($path in @($worktreesRoot, $logsRoot, $resultsRoot, $promptsRoot)) {
            [void](New-Item -ItemType Directory -Path $path -Force)
        }

        while ($true) {
            $campaignState = Read-PARJson $StatePath
            $madeProgress = $false

            foreach ($worker in $Campaign.workers) {
                $workerState = Get-PARWorkerState $campaignState ([string] $worker.workerId)
                if ($workerState.status -ne 'Pending') {
                    continue
                }
                $dependencyStates = @($worker.dependsOn | ForEach-Object { (Get-PARWorkerState $campaignState ([string] $_)).status })
                if (@($dependencyStates | Where-Object { $_ -in @('Failed', 'Blocked', 'Interrupted') }).Count -gt 0) {
                    $workerState.status = 'Blocked'
                    $workerState.summary = 'A required dependency did not complete.'
                    $madeProgress = $true
                    continue
                }
                if (@($dependencyStates | Where-Object { $_ -notin @('Completed', 'ReadyForMerge', 'Merged') }).Count -gt 0) {
                    continue
                }
                $incomingHandoffs = @()
                foreach ($dependency in @($worker.dependsOn)) {
                    $dependencyState = Get-PARWorkerState $campaignState ([string] $dependency)
                    $matchingHandoffs = @($dependencyState.handoffs | Where-Object { $_.consumerWorkerId -eq $worker.workerId })
                    Assert-PARCondition ($matchingHandoffs.Count -eq 1) "Validierter Handoff '$dependency' -> '$($worker.workerId)' fehlt."
                    $handoffSource = [string] $matchingHandoffs[0].sourcePath
                    Assert-PARCondition (Test-Path -LiteralPath $handoffSource -PathType Leaf) "Handoff-Quelle fehlt: $handoffSource"
                    Assert-PARCondition ((Get-PARSha256 $handoffSource) -eq $matchingHandoffs[0].sha256) "Handoff-Quelle wurde nach Validierung veraendert: $handoffSource"
                    $incomingHandoffs += [ordered]@{
                        producerWorkerId = [string] $dependency
                        sourcePath = $handoffSource
                        sha256 = [string] $matchingHandoffs[0].sha256
                    }
                }
                if ([bool] $campaignState.stopRequested -or $running.Count -ge [int] $Campaign.maxConcurrency) {
                    continue
                }

                $repository = Resolve-PARRepository ([string] $worker.repository) $ManifestDirectory
                $worktree = Join-Path $worktreesRoot ([string] $worker.workerId)
                if (-not (Test-Path -LiteralPath $worktree -PathType Container)) {
                    $branchExists = Invoke-PARGit $repository @('show-ref', '--verify', '--quiet', "refs/heads/$($worker.branch)") -AllowFailure
                    Assert-PARCondition ($branchExists.ExitCode -ne 0) "Branch existiert bereits: $($worker.branch)"
                    $baseWorkerId = if ($worker.ContainsKey('baseWorkerId')) { [string] $worker.baseWorkerId } else { '' }
                    if ([string]::IsNullOrWhiteSpace($baseWorkerId)) {
                        $startPoint = [string] $worker.baseRef
                    } else {
                        $baseWorkerState = Get-PARWorkerState $campaignState $baseWorkerId
                        Assert-PARCondition (@('Completed', 'ReadyForMerge', 'Merged') -contains $baseWorkerState.status) "baseWorkerId '$baseWorkerId' ist nicht bereit."
                        $startPoint = [string] $baseWorkerState.headSha
                        $baseCommit = Invoke-PARGit $repository @('rev-parse', '--verify', "$startPoint^{commit}") -AllowFailure
                        Assert-PARCondition ($baseCommit.ExitCode -eq 0) "Head von baseWorkerId '$baseWorkerId' fehlt in $repository."
                    }
                    $add = Invoke-PARGit $repository @('worktree', 'add', '-b', [string] $worker.branch, $worktree, $startPoint)
                    Assert-PARCondition ($add.ExitCode -eq 0) "Worktree konnte nicht erstellt werden: $worktree"
                }

                $promptPath = Join-Path $promptsRoot "$($worker.workerId).txt"
                $resultPath = Join-Path $resultsRoot "$($worker.workerId).json"
                $featureInput = [string] $worker.featureInput
                if (-not [IO.Path]::IsPathRooted($featureInput)) {
                    $featureInput = Join-Path $worktree $featureInput
                }
                $handoffInstructions = if (@($worker.handoffs).Count -eq 0) {
                    'No outgoing handoff file is required.'
                } else {
                    "Create every outgoing handoff file declared in this JSON before finishing: $($worker.handoffs | ConvertTo-Json -Depth 10 -Compress)"
                }
                $incomingHandoffInstructions = if ($incomingHandoffs.Count -eq 0) {
                    'No incoming handoff is required.'
                } else {
                    "Treat these validated, immutable incoming handoffs as required input: $($incomingHandoffs | ConvertTo-Json -Depth 10 -Compress)"
                }
                $workerDeliveryMode = if ($Campaign.deliveryMode -eq 'MergeAndSync') { 'PublishPR' } else { [string] $Campaign.deliveryMode }
                $resultInstructions = if ($Campaign.deliveryMode -eq 'MergeAndSync') {
                    @"
The campaign retains all merge authority. Your worker delivery boundary is PublishPR: commit, push, create the PR, but do not merge it.
Before finishing, write worker-result schema 1.0 to: $resultPath
Set status ReadyForMerge, headSha to the exact pushed head, prUrl to the created PR URL, autonomousStatePath and autonomousStateSha256 to the final state, and include every declared handoff with its SHA-256.
"@
                } else {
                    'The coordinator derives a local worker result when no explicit result file is written.'
                }
                $prompt = @"
Execute the installed speckit.autonomous workflow for this worker.
Campaign ID: $($Campaign.campaignId)
Worker ID: $($worker.workerId)
Run ID: $($worker.runId)
Campaign delivery mode: $($Campaign.deliveryMode)
Worker delivery mode: $workerDeliveryMode
Feature input: $featureInput
$incomingHandoffInstructions
$handoffInstructions
$resultInstructions
Do not infer remote, merge, bypass, cancellation, secret, or provider authority.
"@
                $prompt | Set-Content -LiteralPath $promptPath -Encoding utf8NoBOM
                $handoffDeclarations = @($worker.handoffs)
                $handoffsJson = if ($handoffDeclarations.Count -eq 0) {
                    '[]'
                } else {
                    $handoffDeclarations | ConvertTo-Json -Depth 10 -Compress
                }
                $values = @{
                    campaignId = [string] $Campaign.campaignId
                    workerId = [string] $worker.workerId
                    runId = [string] $worker.runId
                    worktree = $worktree
                    repository = $repository
                    branch = [string] $worker.branch
                    prompt = $prompt
                    promptFile = $promptPath
                    resultFile = $resultPath
                    resultDirectory = $resultsRoot
                    handoffsJson = $handoffsJson
                }
                $arguments = ConvertTo-PARArgumentList @($runnerProfileData.arguments) $values
                $processInfo = Invoke-PARProcessAsync ([string] $runnerProfileData.executable) $arguments $worktree (Join-Path $logsRoot "$($worker.workerId).out.log") (Join-Path $logsRoot "$($worker.workerId).err.log")
                $workerState.status = 'Running'
                $workerState.worktree = $worktree
                $workerState.processId = $processInfo.Process.Id
                $workerState.summary = 'Runner active.'
                $running[[string] $worker.workerId] = @{
                    Worker = $worker
                    Worktree = $worktree
                    ResultPath = $resultPath
                    Process = $processInfo
                }
                if ($running.Count -gt [int] $campaignState.maximumObservedConcurrency) {
                    $campaignState.maximumObservedConcurrency = $running.Count
                }
                $madeProgress = $true
            }

            foreach ($workerId in @($running.Keys)) {
                $entry = $running[$workerId]
                if (-not $entry.Process.Process.HasExited) {
                    continue
                }
                $workerState = Get-PARWorkerState $campaignState $workerId
                try {
                    Complete-PARWorker $entry $workerState $entry.Worker $Campaign $entry.ResultPath
                } catch {
                    $workerState.status = 'Failed'
                    $workerState.summary = $_.Exception.Message
                }
                $entry.Process.Process.Dispose()
                $running.Remove($workerId)
                $madeProgress = $true
            }

            Set-PARStateTimestamp $campaignState
            Write-PARJsonAtomic $StatePath $campaignState

            $terminal = @('Completed', 'ReadyForMerge', 'Merged', 'Failed', 'Blocked')
            $nonTerminal = @($campaignState.workers | Where-Object { $_.status -notin $terminal })
            if ($nonTerminal.Count -eq 0 -and $running.Count -eq 0) {
                break
            }
            if ([bool] $campaignState.stopRequested -and $running.Count -eq 0) {
                $campaignState.status = 'PausedByUser'
                $campaignState.phase = 'Paused'
                Set-PARStateTimestamp $campaignState
                Write-PARJsonAtomic $StatePath $campaignState
                return
            }
            if (-not $madeProgress) {
                Start-Sleep -Milliseconds 200
            }
        }

        $campaignState = Read-PARJson $StatePath
        if (@($campaignState.workers | Where-Object { $_.status -eq 'Failed' }).Count -gt 0) {
            $campaignState.status = 'Failed'
        } elseif ($Campaign.topology -eq 'AlternativeSolutions') {
            $campaignState.status = 'AwaitingSelection'
        } elseif ($Campaign.deliveryMode -eq 'MergeAndSync') {
            Assert-PARCondition (@($campaignState.workers | Where-Object { $_.status -ne 'ReadyForMerge' }).Count -eq 0) 'MergeAndSync worker result must be ReadyForMerge.'
            $campaignState.status = 'ReadyForConsolidation'
        } else {
            $campaignState.status = 'Completed'
        }
        $campaignState.phase = if ($campaignState.status -eq 'Completed') { 'Completed' } else { 'Consolidate' }
        Set-PARStateTimestamp $campaignState
        Write-PARJsonAtomic $StatePath $campaignState
    } finally {
        if (Test-Path -LiteralPath $lockPath -PathType Container) {
            Remove-Item -LiteralPath $lockPath -Force
        }
    }
}

function Invoke-PARConsolidate {
    param(
        [Parameter(Mandatory)][hashtable] $Campaign,
        [Parameter(Mandatory)][hashtable] $Profiles,
        [Parameter(Mandatory)][string] $StatePath,
        [Parameter(Mandatory)][string] $Selection,
        [switch] $DoMerge
    )

    $campaignState = Read-PARJson $StatePath
    $eligibleIds = @($Campaign.consolidation.mergeOrder)
    if ($Campaign.topology -eq 'AlternativeSolutions') {
        Assert-PARCondition (-not [string]::IsNullOrWhiteSpace($Selection)) 'AlternativeSolutions erfordert -SelectedWorker.'
        Assert-PARCondition ($eligibleIds -contains $Selection) "SelectedWorker '$Selection' ist unbekannt."
        $eligibleIds = @($Selection)
        $campaignState.selectedWorkerId = $Selection
    }

    foreach ($id in $eligibleIds) {
        $workerState = Get-PARWorkerState $campaignState $id
        Assert-PARCondition ($workerState.status -in @('Completed', 'ReadyForMerge')) "Worker '$id' ist nicht konsolidierungsbereit."
    }

    if (-not $DoMerge) {
        $campaignState.status = 'Consolidated'
        $campaignState.phase = 'Completed'
        Set-PARStateTimestamp $campaignState
        Write-PARJsonAtomic $StatePath $campaignState
        return
    }

    Assert-PARCondition ($Campaign.deliveryMode -eq 'MergeAndSync') '-Merge erfordert deliveryMode MergeAndSync.'
    Assert-PARCondition $Campaign.consolidation.ContainsKey('mergeProfile') 'consolidation.mergeProfile fehlt.'
    $mergeProfileName = [string] $Campaign.consolidation.mergeProfile
    Assert-PARCondition $Profiles.mergeProfiles.ContainsKey($mergeProfileName) "Merge-Profil '$mergeProfileName' fehlt."
    $mergeProfile = $Profiles.mergeProfiles[$mergeProfileName]
    $campaignState.status = 'Merging'
    $campaignState.phase = 'MergeAndSync'
    Write-PARJsonAtomic $StatePath $campaignState

    foreach ($id in $eligibleIds) {
        $workerState = Get-PARWorkerState $campaignState $id
        Assert-PARCondition (-not [string]::IsNullOrWhiteSpace([string] $workerState.prUrl)) "Worker '$id' hat keine prUrl."
        $values = @{
            campaignId = [string] $Campaign.campaignId
            workerId = $id
            prUrl = [string] $workerState.prUrl
            headSha = [string] $workerState.headSha
        }
        $arguments = ConvertTo-PARArgumentList @($mergeProfile.arguments) $values
        & ([string] $mergeProfile.executable) @arguments
        if ($LASTEXITCODE -ne 0) {
            $campaignState.status = 'MergeFailed'
            $workerState.summary = "Merge failed with exit code $LASTEXITCODE."
            Set-PARStateTimestamp $campaignState
            Write-PARJsonAtomic $StatePath $campaignState
            throw "Merge fehlgeschlagen; Campaign nach Worker '$id' angehalten."
        }
        $workerState.status = 'Merged'
        $workerState.summary = 'Merged in declared order.'
        Set-PARStateTimestamp $campaignState
        Write-PARJsonAtomic $StatePath $campaignState
    }

    $campaignState.status = 'Completed'
    $campaignState.phase = 'Completed'
    Set-PARStateTimestamp $campaignState
    Write-PARJsonAtomic $StatePath $campaignState
}

$manifestPath = [IO.Path]::GetFullPath($Manifest)
$manifestDirectory = Split-Path -Parent $manifestPath
$campaign = Read-PARJson $manifestPath

if (-not $State) {
    $State = Join-Path $manifestDirectory 'parallel-campaign-state.json'
}
$statePath = [IO.Path]::GetFullPath($State)

if (-not $RuntimeRoot) {
    $RuntimeRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) ".specify/parallel-runs/$($campaign.campaignId)"
}
$runtimePath = [IO.Path]::GetFullPath($RuntimeRoot)

if ($Action -eq 'Status') {
    $statusData = Read-PARJson $statePath
    $statusData | ConvertTo-Json -Depth 30
    exit 0
}

if ($Action -eq 'Stop') {
    $statusData = Read-PARJson $statePath
    Assert-PARCondition ($statusData.campaignId -eq $campaign.campaignId) 'State campaignId stimmt nicht.'
    $statusData.stopRequested = $true
    $statusData.status = 'StopRequested'
    $statusData.phase = 'Stopping'
    Set-PARStateTimestamp $statusData
    Write-PARJsonAtomic $statePath $statusData
    Write-Output 'PASS: cooperative stop requested; no process was killed.'
    exit 0
}

Assert-PARCondition (-not [string]::IsNullOrWhiteSpace($RunnerConfig)) "-RunnerConfig ist fuer Action '$Action' erforderlich."
$runnerConfigPath = [IO.Path]::GetFullPath($RunnerConfig)
$profiles = Read-PARJson $runnerConfigPath
Assert-PARCondition ($profiles.schemaVersion -eq '1.0') 'RunnerConfig schemaVersion muss 1.0 sein.'

$skipClean = $Action -in @('Resume', 'Consolidate')
Test-PARCampaign $campaign $profiles $manifestDirectory -SkipCleanCheck:$skipClean

switch ($Action) {
    'Validate' {
        Write-Output "PASS: campaign $($campaign.campaignId), $($campaign.workers.Count) worker, max concurrency $($campaign.maxConcurrency)."
    }
    'Start' {
        Invoke-PARStart $campaign $profiles $manifestPath $manifestDirectory $statePath $runtimePath
        Write-Output "PASS: campaign state written to $statePath"
    }
    'Resume' {
        Invoke-PARStart $campaign $profiles $manifestPath $manifestDirectory $statePath $runtimePath -IsResume
        Write-Output "PASS: campaign resumed; state written to $statePath"
    }
    'Consolidate' {
        Invoke-PARConsolidate $campaign $profiles $statePath $SelectedWorker -DoMerge:$Merge
        Write-Output "PASS: campaign consolidation recorded in $statePath"
    }
}
